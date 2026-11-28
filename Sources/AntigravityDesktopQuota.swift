import AppKit
import ApplicationServices

/// Reads the focused, already open quota pane in the user's Google client. The connector
/// never activates either app, modifies its accessibility tree, or navigates inside it.
enum AntigravityDesktopQuota {
    enum Failure: LocalizedError, Equatable {
        case invalidAccount, permissionRequired, appNotVisible, paneNotAvailable, accountNotVerified, clientNotResponding

        var errorDescription: String? {
            switch self {
            case .invalidAccount: return "请填写要同步额度的 Google 账号邮箱。"
            case .permissionRequired: return "需在「系统设置」中允许搞词元使用辅助功能。"
            case .appNotVisible: return "请打开所选 Google 客户端的额度面板。"
            case .paneNotAvailable: return "未读到所选 Google 客户端的额度面板。"
            case .accountNotVerified: return "额度面板未显示与设置一致的已登录 Google 账号。"
            case .clientNotResponding: return "Google 客户端的额度面板暂时不可读取。"
            }
        }
    }

    enum Route: Equatable, Sendable {
        case embedded, standalone

        init?(_ connection: Connection) {
            switch connection {
            case .geminiApp: self = .embedded
            case .agentLocal: self = .standalone
            default: return nil
            }
        }

        var bundleIdentifier: String {
            self == .embedded ? "com.google.GeminiMacOS" : "com.google.antigravity"
        }

        var snapshotSource: String {
            self == .embedded ? "Gemini 内置 Antigravity · 本机窗口" : "Antigravity 独立版 · 本机窗口"
        }

        func isQuotaTitle(_ value: String) -> Bool {
            let title = AntigravityDesktopQuota.displayText(value).lowercased()
            let scoped: Set<String> = ["antigravity usage", "antigravity model usage", "antigravity model quotas",
                                       "antigravity 额度", "antigravity 模型额度", "antigravity 用量", "antigravity 模型配額"]
            if scoped.contains(title) { return true }
            guard self == .standalone else { return false }
            return ["view usage", "model usage", "model quotas", "models & quota", "models and quota", "models",
                    "查看用量", "模型额度", "模型配额", "模型", "模型配額"].contains(title)
        }
    }

    static func read(connection: Connection, expectedEmail: String) async throws -> UsageSnapshot {
        guard let route = Route(connection), let email = AntigravityStatusLine.canonicalEmail(expectedEmail) else { throw Failure.invalidAccount }
        guard AXIsProcessTrusted() else { throw Failure.permissionRequired }
        let target = try await MainActor.run { () throws -> Client in
            let matches = NSWorkspace.shared.runningApplications.filter {
                $0.bundleIdentifier == route.bundleIdentifier && !$0.isTerminated && !$0.isHidden && $0.processIdentifier > 0
            }
            guard matches.count == 1, let app = matches.first, let launchDate = app.launchDate else { throw Failure.appNotVisible }
            return Client(pid: app.processIdentifier, launchDate: launchDate)
        }
        let work = Task.detached(priority: .utility) { try readClient(target, route: route, email: email) }
        let snapshot = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
        let stillVisible = await MainActor.run {
            guard let current = NSRunningApplication(processIdentifier: target.pid) else { return false }
            return current.bundleIdentifier == route.bundleIdentifier && current.launchDate == target.launchDate
                && !current.isHidden && !current.isTerminated
        }
        guard stillVisible else { throw Failure.appNotVisible }
        return snapshot
    }

    private struct Client: Sendable {
        let pid: pid_t
        let launchDate: Date
    }

    private struct ParsedPane {
        var snapshot: UsageSnapshot
        var identityIndices: [Int]
    }

    /// Fixture seam. `title` and `lines` must come from a single, positively identified pane.
    static func parsePane(title: String, lines: [String], route: Route, expectedEmail: String,
                          observedAt: Date = Date()) throws -> UsageSnapshot {
        guard let email = AntigravityStatusLine.canonicalEmail(expectedEmail) else { throw Failure.invalidAccount }
        return try parse(title: title, lines: lines, route: route, email: email, observedAt: observedAt).snapshot
    }

    private static func parse(title: String, lines: [String], route: Route, email: String, observedAt: Date) throws -> ParsedPane {
        guard route.isQuotaTitle(title) else { throw Failure.paneNotAvailable }
        let strings = lines.map(displayText)
        let identities = accountEvidence(strings)
        guard !identities.isEmpty, identities.allSatisfy({ $0.email == email }) else { throw Failure.accountNotVerified }
        var quotas: [Quota] = []
        var group: String?
        var seen = Set<String>()
        for (index, line) in strings.enumerated() {
            if let modelGroup = modelGroup(line) {
                group = modelGroup
                continue
            }
            guard let activeGroup = group, let label = quotaLabel(line) else {
                if !isSupplementaryQuotaText(line) { group = nil }
                continue
            }
            let value = label.value.isEmpty && index + 1 < strings.count ? strings[index + 1] : label.value
            let id = activeGroup.lowercased().replacingOccurrences(of: " ", with: "-") + "-" + label.window.rawValue
            guard seen.insert(id).inserted else { throw Failure.paneNotAvailable }
            if isUnavailable(value) { continue }
            guard let percent = remainingPercentage(value) else { throw Failure.paneNotAvailable }
            quotas.append(Quota(id: id, title: "\(activeGroup) · \(label.window.title)",
                                usedPercent: label.used ? percent : 100 - percent,
                                resetsAt: nil, windowSeconds: label.window.seconds))
        }
        guard !quotas.isEmpty else { throw Failure.paneNotAvailable }
        var snapshot = UsageSnapshot.empty(source: route.snapshotSource)
        snapshot.observedAt = observedAt
        snapshot.quotas = quotas
        try snapshot.validate()
        return ParsedPane(snapshot: snapshot, identityIndices: identities.flatMap { $0.indices })
    }

    private static func displayText(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func valueAfterLabel(_ line: String, label: String) -> String? {
        guard line.lowercased().hasPrefix(label) else { return nil }
        let rest = line.dropFirst(label.count)
        guard rest.isEmpty || rest.first?.isWhitespace == true || rest.first == ":" || rest.first == "：" else { return nil }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":：")))
    }

    private static func accountEvidence(_ lines: [String]) -> [(email: String, indices: [Int])] {
        let labels = ["signed in as", "signed-in google account", "current google account", "已登录为", "当前 google 账号",
                      "已登入為", "目前登入的 google 帳戶"]
        return lines.enumerated().compactMap { index, line in
            guard let candidate = labels.lazy.compactMap({ valueAfterLabel(line, label: $0) }).first else { return nil }
            if !candidate.isEmpty { return (AntigravityStatusLine.canonicalEmail(candidate) ?? "", [index]) }
            guard index + 1 < lines.count else { return ("", [index]) }
            return (AntigravityStatusLine.canonicalEmail(lines[index + 1]) ?? "", [index, index + 1])
        }
    }

    private static func modelGroup(_ line: String) -> String? {
        let name = line.trimmingCharacters(in: CharacterSet(charactersIn: ":： ")).lowercased()
        switch name {
        case "gemini models", "gemini 模型": return "Gemini Models"
        case "claude and gpt models", "claude 和 gpt 模型": return "Claude and GPT models"
        case "gemini 4 argon": return "Gemini 4 Argon"
        default: return nil
        }
    }

    private enum Window: String {
        case weekly, fiveHour = "5h"
        var title: String { self == .weekly ? "每周" : "5 小时" }
        var seconds: Double { self == .weekly ? 604_800 : 18_000 }
    }

    private static func quotaLabel(_ line: String) -> (window: Window, used: Bool, value: String)? {
        let labels: [(String, Window, Bool)] = [
            ("weekly limit remaining", .weekly, false), ("five hour limit remaining", .fiveHour, false),
            ("5-hour limit remaining", .fiveHour, false), ("5 hour limit remaining", .fiveHour, false),
            ("weekly limit used", .weekly, true), ("five hour limit used", .fiveHour, true),
            ("每周剩余额度", .weekly, false), ("5 小时剩余额度", .fiveHour, false),
            ("每週剩餘配額", .weekly, false), ("5 小時剩餘配額", .fiveHour, false),
        ]
        for (label, window, used) in labels {
            if let value = valueAfterLabel(line, label: label) { return (window, used, value) }
        }
        return nil
    }

    private static func remainingPercentage(_ value: String) -> Double? {
        guard value.range(of: #"^[0-9]{1,3}(?:\.[0-9]{1,6})?\s*[%％]$"#, options: .regularExpression) != nil,
              let percent = Double(value.dropLast().trimmingCharacters(in: .whitespaces)), (0...100).contains(percent) else { return nil }
        return percent
    }

    private static func isUnavailable(_ value: String) -> Bool {
        ["—", "-", "n/a", "unavailable", "不可用"].contains(value.lowercased())
    }

    private static func isSupplementaryQuotaText(_ value: String) -> Bool {
        let lower = value.lowercased()
        return value.isEmpty || isUnavailable(value) || remainingPercentage(value) != nil
            || ["models within this group:", "resets in ", "resets at ", "refreshes in "].contains(where: lower.hasPrefix)
    }

    private static let paneRoles: Set<String> = ["AXWindow", "AXSheet", "AXPopover", "AXDialog", "AXGroup", "AXTabGroup", "AXScrollArea", "AXWebArea", "AXSplitGroup"]
    private static let modalRoles: Set<String> = ["AXSheet", "AXPopover", "AXDialog"]
    private static let textRoles: Set<String> = ["AXStaticText", "AXHeading"]
    private static let settingsTitles: Set<String> = ["settings", "preferences", "antigravity settings", "gemini settings", "设置", "設定"]

    private static func readClient(_ client: Client, route: Route, email: String) throws -> UsageSnapshot {
        let query = AccessibilityQuery()
        let app = AXUIElementCreateApplication(client.pid)
        try query.prepare(app)
        guard let window = try query.element(app, kAXFocusedWindowAttribute) else { throw Failure.paneNotAvailable }
        try query.prepare(window)
        var windowPID: pid_t = 0
        guard AXUIElementGetPid(window, &windowPID) == .success, windowPID == client.pid,
              try !query.isHidden(window), try !query.isTrue(window, kAXMinimizedAttribute) else { throw Failure.paneNotAvailable }
        let windowTitle = try query.string(window, kAXTitleAttribute)
        let settings = settingsTitles.contains(windowTitle.lowercased()) || route.isQuotaTitle(windowTitle)
        var panes: [(AXUIElement, String)] = []
        try findPanes(window, route: route, inSettings: settings, depth: 0, query: query, into: &panes)
        guard panes.count == 1, let (pane, title) = panes.first else { throw Failure.paneNotAvailable }
        var leaves: [(element: AXUIElement, text: String)] = []
        try collectText(pane, depth: 0, query: query, into: &leaves)
        let parsed = try parse(title: title, lines: leaves.map { $0.text }, route: route, email: email, observedAt: Date())
        for index in Set(parsed.identityIndices) {
            guard try query.leafText(leaves[index].element) == leaves[index].text else { throw Failure.accountNotVerified }
        }
        guard let current = try query.element(app, kAXFocusedWindowAttribute), CFEqual(current, window),
              try !query.isTrue(window, kAXMinimizedAttribute), try !query.isHidden(pane) else { throw Failure.paneNotAvailable }
        return parsed.snapshot
    }

    private static func findPanes(_ element: AXUIElement, route: Route, inSettings: Bool, depth: Int,
                                  query: AccessibilityQuery, into panes: inout [(AXUIElement, String)]) throws {
        guard depth < 12 else { return }
        try query.prepare(element)
        let role = try query.string(element, kAXRoleAttribute)
        guard paneRoles.contains(role), try !query.isHidden(element) else { return }
        let subrole = try query.string(element, kAXSubroleAttribute)
        let modal = modalRoles.contains(role) || subrole == kAXDialogSubrole
        let scoped = inSettings || modal
        if scoped {
            let title = try query.string(element, kAXTitleAttribute)
            if route.isQuotaTitle(title) {
                panes.append((element, title))
                return
            }
        }
        let children = try query.children(element, role: role)
        if scoped {
            for child in children {
                try query.prepare(child)
                guard try textRoles.contains(query.string(child, kAXRoleAttribute)), try !query.isHidden(child) else { continue }
                let title = try query.leafText(child)
                if route.isQuotaTitle(title) {
                    panes.append((element, title))
                    return
                }
            }
        }
        // Outside Settings, a web area may hold a visible modal but also may contain a chat.
        // Only inspect the role of direct web-area children in that case.
        for child in children {
            if !scoped && role == "AXWebArea" {
                try query.prepare(child)
                guard try modalRoles.contains(query.string(child, kAXRoleAttribute)) else { continue }
            }
            try findPanes(child, route: route, inSettings: scoped, depth: depth + 1, query: query, into: &panes)
        }
    }

    private static func collectText(_ element: AXUIElement, depth: Int, query: AccessibilityQuery,
                                    into leaves: inout [(element: AXUIElement, text: String)]) throws {
        guard depth < 14, leaves.count < 96 else { throw Failure.paneNotAvailable }
        try query.prepare(element)
        let role = try query.string(element, kAXRoleAttribute)
        guard (paneRoles.contains(role) || textRoles.contains(role)), try !query.isHidden(element) else { return }
        if textRoles.contains(role) {
            let text = try query.leafText(element)
            if !text.isEmpty { leaves.append((element, text)) }
            return
        }
        for child in try query.children(element, role: role) {
            try collectText(child, depth: depth + 1, query: query, into: &leaves)
        }
    }

    private final class AccessibilityQuery {
        private let deadline = ContinuousClock.now + .seconds(2)
        private var remaining = 700

        private func checkBudget() throws {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline, remaining > 0 else { throw Failure.clientNotResponding }
            remaining -= 1
        }

        func prepare(_ element: AXUIElement) throws {
            try checkBudget()
            guard AXUIElementSetMessagingTimeout(element, 0.12) == .success else { throw Failure.clientNotResponding }
        }

        private func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
            try checkBudget()
            var value: CFTypeRef?
            switch AXUIElementCopyAttributeValue(element, name as CFString, &value) {
            case .success: return value
            case .apiDisabled: throw Failure.permissionRequired
            case .cannotComplete, .invalidUIElement: throw Failure.clientNotResponding
            default: return nil
            }
        }

        func element(_ parent: AXUIElement, _ name: String) throws -> AXUIElement? {
            guard let value = try attribute(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(value, to: AXUIElement.self)
        }

        func string(_ element: AXUIElement, _ name: String) throws -> String {
            let value = try attribute(element, name)
            if let value = value as? String, value.count <= 240 { return displayText(value) }
            if let value = value as? NSAttributedString, value.length <= 240 { return displayText(value.string) }
            return ""
        }

        func leafText(_ leaf: AXUIElement) throws -> String {
            for name in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                let value = try string(leaf, name)
                if !value.isEmpty { return value }
            }
            return ""
        }

        func isTrue(_ element: AXUIElement, _ name: String) throws -> Bool {
            (try attribute(element, name) as? Bool) == true
        }

        func isHidden(_ element: AXUIElement) throws -> Bool {
            try isTrue(element, kAXHiddenAttribute)
        }

        func children(_ parent: AXUIElement, role: String) throws -> [AXUIElement] {
            if let visible = try children(parent, attribute: kAXVisibleChildrenAttribute) { return visible }
            guard role != "AXScrollArea" else { return [] }
            return try children(parent, attribute: kAXChildrenAttribute) ?? []
        }

        private func children(_ parent: AXUIElement, attribute name: String) throws -> [AXUIElement]? {
            try checkBudget()
            var count = 0
            let status = AXUIElementGetAttributeValueCount(parent, name as CFString, &count)
            if status == .cannotComplete || status == .invalidUIElement { throw Failure.clientNotResponding }
            if status == .apiDisabled { throw Failure.permissionRequired }
            guard status == .success else { return nil }
            guard count <= 64 else { throw Failure.paneNotAvailable }
            guard count > 0 else { return [] }
            try checkBudget()
            var values: CFArray?
            let copied = AXUIElementCopyAttributeValues(parent, name as CFString, 0, count, &values)
            if copied == .cannotComplete || copied == .invalidUIElement { throw Failure.clientNotResponding }
            if copied == .apiDisabled { throw Failure.permissionRequired }
            guard copied == .success else { return nil }
            return values as? [AXUIElement]
        }
    }
}
