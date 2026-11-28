import AppKit
import ApplicationServices
import Security

/// Reads the focused, already open quota pane in the user's Google client.
enum AntigravityDesktopQuota {
    enum Failure: LocalizedError, Equatable {
        case invalidAccount, permissionRequired, appNotVisible, paneNotAvailable, accountNotVerified, clientNotVerified, clientNotResponding

        var errorDescription: String? {
            switch self {
            case .invalidAccount: return "请填写要同步额度的 Google 账号邮箱。"
            case .permissionRequired: return "需在「系统设置」中允许搞词元使用辅助功能。"
            case .appNotVisible: return "请将所选 Google 客户端置于前台并打开额度面板。"
            case .paneNotAvailable: return "未读到所选 Google 客户端的额度面板。"
            case .accountNotVerified: return "额度面板未显示与设置一致的已登录 Google 账号。"
            case .clientNotVerified: return "无法验证所选 Google 客户端的签名。"
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

        var signingRequirement: String {
            #"anchor apple generic and identifier "\#(bundleIdentifier)" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "EQHXZ8M8AV""#
        }

        var snapshotSource: String {
            self == .embedded ? "Gemini 内置 Antigravity · 已核验窗口" : "Antigravity 独立版 · 已核验窗口"
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
            guard matches.count == 1, let app = matches.first, let launchDate = app.launchDate,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { throw Failure.appNotVisible }
            return Client(pid: app.processIdentifier, launchDate: launchDate)
        }
        let work = Task.detached(priority: .utility) { try readClient(target, route: route, email: email) }
        let snapshot = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
        let stillVisible = await MainActor.run {
            guard let current = NSRunningApplication(processIdentifier: target.pid) else { return false }
            return current.bundleIdentifier == route.bundleIdentifier && current.launchDate == target.launchDate
                && !current.isHidden && !current.isTerminated
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
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
        if route == .embedded {
            let quotas = try parseEmbeddedQuotas(strings, observedAt: observedAt)
            return try makePane(quotas: quotas, route: route, observedAt: observedAt, identityIndices: identities.flatMap(\.indices))
        }
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
        return try makePane(quotas: quotas, route: route, observedAt: observedAt, identityIndices: identities.flatMap(\.indices))
    }

    private static func parseEmbeddedQuotas(_ lines: [String], observedAt: Date) throws -> [Quota] {
        guard let quotas = try GeminiEmbeddedAntigravityQuota.parse(lines: lines, observedAt: observedAt) else {
            throw Failure.paneNotAvailable
        }
        return quotas
    }

    private static func makePane(quotas: [Quota], route: Route, observedAt: Date, identityIndices: [Int] = []) throws -> ParsedPane {
        guard !quotas.isEmpty else { throw Failure.paneNotAvailable }
        var snapshot = UsageSnapshot.empty(source: route.snapshotSource)
        snapshot.observedAt = observedAt
        snapshot.quotas = quotas
        try snapshot.validate()
        return ParsedPane(snapshot: snapshot, identityIndices: identityIndices)
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
    private static let settingsTitles: Set<String> = ["settings", "preferences", "antigravity settings", "设置", "設定"]
    private static let geminiMenuLock = NSLock()

    private static func readClient(_ client: Client, route: Route, email: String) throws -> UsageSnapshot {
        try verifyGoogleProcess(client.pid, route: route)
        let query = AccessibilityQuery(timeout: route == .embedded ? .seconds(8) : .seconds(3),
                                       messagingTimeout: route == .embedded ? 0.30 : 0.12)
        let app = AXUIElementCreateApplication(client.pid)
        try query.prepare(app)
        guard let window = try query.element(app, kAXFocusedWindowAttribute) else {
            if route == .embedded { Log.connectors.notice("Gemini Antigravity missing focused window") }
            throw Failure.paneNotAvailable
        }
        try query.prepare(window)
        guard belongsToProcess(window, pid: client.pid) else { throw Failure.paneNotAvailable }
        _ = try foregroundWindow(app, original: window, query: query)
        switch route {
        case .embedded:
            guard geminiMenuLock.try() else { throw Failure.clientNotResponding }
            defer { geminiMenuLock.unlock() }
            guard let picker = try findGeminiPicker(in: window, query: query),
                  let menu = try findGeminiMenu(picker, query: query),
                  let pane = try openedGeminiPane(menu, query: query),
                  belongsToProcess(pane, pid: client.pid) else { throw Failure.paneNotAvailable }
            return try readEmbeddedMenu(menu, pane: pane, picker: picker, app: app, window: window, email: email, query: query)
        case .standalone:
            return try readStandalonePane(app: app, window: window, pid: client.pid, email: email, query: query)
        }
    }

    private static func readStandalonePane(app: AXUIElement, window: AXUIElement, pid: pid_t, email: String,
                                           query: AccessibilityQuery) throws -> UsageSnapshot {
        let (pane, title) = try standalonePane(in: window, pid: pid, query: query)
        var leaves: [(element: AXUIElement, text: String)] = []
        try collectText(pane, depth: 0, query: query, into: &leaves)
        let parsed = try parse(title: title, lines: leaves.map { $0.text }, route: .standalone, email: email, observedAt: Date())
        _ = try foregroundWindow(app, original: window, query: query)
        let (current, currentTitle) = try standalonePane(in: window, pid: pid, query: query)
        guard CFEqual(current, pane), currentTitle == title else { throw Failure.paneNotAvailable }
        for index in Set(parsed.identityIndices) {
            let (element, text) = leaves[index]
            guard belongsToProcess(element, pid: pid), try !query.isHidden(element),
                  try query.leafText(element) == text else { throw Failure.accountNotVerified }
        }
        _ = try foregroundWindow(app, original: window, query: query)
        return parsed.snapshot
    }

    private static func standalonePane(in window: AXUIElement, pid: pid_t,
                                       query: AccessibilityQuery) throws -> (AXUIElement, String) {
        let title = try query.string(window, kAXTitleAttribute)
        let isSettings = settingsTitles.contains(title.lowercased()) || Route.standalone.isQuotaTitle(title)
        var panes: [(AXUIElement, String)] = []
        try findStandalonePanes(window, inSettings: isSettings, depth: 0, query: query, into: &panes)
        guard panes.count == 1, let pane = panes.first, belongsToProcess(pane.0, pid: pid) else { throw Failure.paneNotAvailable }
        return pane
    }

    private static func belongsToProcess(_ element: AXUIElement, pid: pid_t) -> Bool {
        var owner: pid_t = 0
        return pid > 0 && AXUIElementGetPid(element, &owner) == .success && owner == pid
    }

    private struct GeminiPicker {
        let button: AXUIElement
        let container: AXUIElement
        let webArea: AXUIElement
        let origin: URL
    }

    private struct GeminiMenu {
        let root: AXUIElement
        let disclosure: AXUIElement
    }

    private static func label(_ element: AXUIElement, query: AccessibilityQuery) throws -> [String] {
        try [kAXTitleAttribute, kAXDescriptionAttribute].map { try query.string(element, $0).lowercased() }
    }

    private static func hasMenuLabel(_ element: AXUIElement, _ expected: String, query: AccessibilityQuery) throws -> Bool {
        try label(element, query: query).contains(expected) || query.leafText(element).lowercased() == expected
            || query.string(element, kAXHelpAttribute).lowercased() == expected
    }

    private static func isModelLabel(_ labels: [String]) -> Bool {
        labels.contains { $0 == "select model" || $0.hasPrefix("select model, current:") }
    }

    private static func geminiOrigin(_ web: AXUIElement, query: AccessibilityQuery) throws -> URL? {
        guard let url = try query.url(web),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "http", parts.host == "127.0.0.1", let port = parts.port, (1...65535).contains(port),
              parts.user == nil, parts.password == nil,
              parts.queryItems?.filter({ $0.name == "hostVariant" }).map(\.value) == ["gemini-app"] else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    private static func findGeminiPicker(in element: AXUIElement, webArea: AXUIElement? = nil, origin: URL? = nil, depth: Int = 0,
                                         query: AccessibilityQuery) throws -> GeminiPicker? {
        guard depth < 8 else { return nil }
        let role = try query.string(element, kAXRoleAttribute)
        guard [kAXWindowRole, kAXScrollAreaRole, kAXGroupRole, "AXWebArea", kAXSplitGroupRole].contains(role),
              try !query.isHidden(element) else { return nil }
        let origin = role == "AXWebArea" ? try geminiOrigin(element, query: query) : origin
        let webArea = role == "AXWebArea" ? element : webArea
        guard role != "AXWebArea" || origin != nil else { return nil }
        // The sidebar holds user conversations, outside the quota reader's scope.
        if try label(element, query: query).contains("sidebar") { return nil }
        let children = try query.list(element)
        if let origin, let webArea {
            let buttons = try children.filter {
                try query.string($0, kAXRoleAttribute) == kAXPopUpButtonRole &&
                    isModelLabel(label($0, query: query)) && !query.isHidden($0)
            }
            guard buttons.count <= 1 else { throw Failure.paneNotAvailable }
            if let button = buttons.first { return GeminiPicker(button: button, container: element, webArea: webArea, origin: origin) }
        }
        for child in children {
            if let found = try findGeminiPicker(in: child, webArea: webArea, origin: origin, depth: depth + 1, query: query) { return found }
        }
        return nil
    }

    private static func findGeminiMenu(_ picker: GeminiPicker, query: AccessibilityQuery) throws -> GeminiMenu? {
        var menus: [GeminiMenu] = []
        try collectGeminiMenus(in: picker.container, requireModelLabel: false, query: query, into: &menus)
        if menus.isEmpty {
            try collectGeminiMenus(in: picker.webArea, requireModelLabel: true, query: query, into: &menus)
        }
        if menus.isEmpty {
            let kinds = try query.list(picker.container).prefix(20).map { try query.string($0, kAXRoleAttribute) }
            Log.connectors.notice("Gemini Antigravity composer roles: \(kinds.joined(separator: ","), privacy: .public)")
        }
        guard menus.count <= 1 else { throw Failure.paneNotAvailable }
        return menus.first
    }

    private static func collectGeminiMenus(in node: AXUIElement, requireModelLabel: Bool, depth: Int = 0, query: AccessibilityQuery,
                                           into menus: inout [GeminiMenu]) throws {
        guard depth < 8, try !query.isHidden(node) else { return }
        let role = try query.string(node, kAXRoleAttribute)
        if role == kAXMenuRole {
            if requireModelLabel, try !isModelLabel(label(node, query: query)) { return }
            if let disclosure = try geminiDisclosure(in: node, query: query) {
                menus.append(GeminiMenu(root: node, disclosure: disclosure))
            }
            return
        }
        guard depth == 0 || [kAXGroupRole, kAXUnknownRole, kAXPopoverRole, kAXPopUpButtonRole, kAXScrollAreaRole,
                             "AXLayoutArea", "AXLayoutItem"].contains(role),
              try !label(node, query: query).contains("sidebar") else { return }
        for child in try query.list(node) {
            try collectGeminiMenus(in: child, requireModelLabel: requireModelLabel, depth: depth + 1, query: query, into: &menus)
        }
    }

    private static func geminiDisclosure(in menu: AXUIElement, query: AccessibilityQuery) throws -> AXUIElement? {
        let candidates = try query.list(menu).filter { try hasMenuLabel($0, "view usage", query: query) && !query.isHidden($0) }
        var controls: [AXUIElement] = []
        var expanded: [AXUIElement] = []
        for candidate in candidates where !controls.contains(where: { CFEqual($0, candidate) }) {
            let state = try query.bool(candidate, kAXExpandedAttribute)
            if state == true { expanded.append(candidate) }
            if try state != nil || query.supports("AXExpand", on: candidate) || query.supports("AXCollapse", on: candidate) {
                controls.append(candidate)
            }
        }
        if expanded.count == 1 { return expanded.first }
        if expanded.count > 1 {
            let withUsage = try expanded.filter { try openedGeminiPane(GeminiMenu(root: menu, disclosure: $0), query: query) != nil }
            guard withUsage.count == 1 else { throw Failure.paneNotAvailable }
            return withUsage.first
        }
        guard controls.count <= 1 else { throw Failure.paneNotAvailable }
        return controls.first
    }

    private static func openedGeminiPane(_ menu: GeminiMenu, query: AccessibilityQuery) throws -> AXUIElement? {
        let expanded = try query.bool(menu.disclosure, kAXExpandedAttribute)
        if expanded == false { return nil }
        if try hasCompactQuota(in: menu.disclosure, query: query) { return menu.disclosure }
        let panels = try query.list(menu.root).filter { panel in
            try !CFEqual(panel, menu.disclosure) && !query.isHidden(panel)
                && hasMenuLabel(panel, "view usage", query: query) && hasCompactQuota(in: panel, query: query)
        }
        Log.connectors.notice("Gemini Antigravity visible usage panel candidates: \(panels.count, privacy: .public)")
        guard panels.count <= 1 else { throw Failure.paneNotAvailable }
        return panels.first
    }

    private static func hasCompactQuota(in node: AXUIElement, query: AccessibilityQuery) throws -> Bool {
        let lines = try geminiQuotaText(node, query: query)
        return try GeminiEmbeddedAntigravityQuota.parse(lines: lines, observedAt: Date()) != nil
    }

    static func foregroundWindow(_ app: AXUIElement, original: AXUIElement, allowRecreated: Bool = false,
                                 query: AccessibilityQuery) throws -> AXUIElement {
        guard try query.isTrue(app, kAXFrontmostAttribute),
              let activeWindow = try query.element(app, kAXFocusedWindowAttribute),
              try !query.isTrue(activeWindow, kAXMinimizedAttribute), try !query.isHidden(activeWindow) else {
            throw Failure.appNotVisible
        }
        if CFEqual(activeWindow, original) { return activeWindow }
        guard allowRecreated, try query.string(activeWindow, kAXSubroleAttribute) == kAXStandardWindowSubrole else {
            throw Failure.appNotVisible
        }
        let standard = try query.list(app, kAXWindowsAttribute).filter {
            try query.string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole
        }
        guard standard.count == 1, let only = standard.first, CFEqual(only, activeWindow) else { throw Failure.appNotVisible }
        return activeWindow
    }

    private static func verifyGoogleProcess(_ pid: pid_t, route: Route) throws {
        var code: SecCode?
        var requirement: SecRequirement?
        guard pid > 0,
              SecRequirementCreateWithString(route.signingRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary, [], &code) == errSecSuccess,
              let code, SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { throw Failure.clientNotVerified }
    }

    private static func reopenGeminiPane(app: AXUIElement, window: AXUIElement, origin: URL, query: AccessibilityQuery) throws -> AXUIElement {
        var pressedPicker = false
        var pressedUsage = false
        for _ in 0..<28 {
            do {
                let window = try foregroundWindow(app, original: window, allowRecreated: true, query: query)
                if let picker = try findGeminiPicker(in: window, query: query), picker.origin == origin {
                    if let menu = try findGeminiMenu(picker, query: query) {
                        if let pane = try openedGeminiPane(menu, query: query) { return pane }
                        if !pressedUsage {
                            try query.performFirstSupported(["AXExpand", kAXPressAction], on: menu.disclosure)
                            pressedUsage = true
                        }
                    } else if !pressedPicker {
                        try query.perform(kAXPressAction, on: picker.button)
                        pressedPicker = true
                    }
                }
            } catch Failure.clientNotResponding {
                // AppKit can briefly invalidate accessibility children while changing modes.
            }
            try query.pause()
        }
        throw Failure.paneNotAvailable
    }

    private static func readEmbeddedMenu(_ menu: GeminiMenu, pane: AXUIElement, picker: GeminiPicker, app: AXUIElement,
                                         window: AXUIElement, email: String, query: AccessibilityQuery) throws -> UsageSnapshot {
        let lines = try geminiQuotaText(pane, query: query)
        let observedAt = Date()
        let readings = try parseEmbeddedQuotas(lines, observedAt: observedAt)
        _ = try foregroundWindow(app, original: window, query: query)
        guard let current = try findGeminiMenu(picker, query: query), CFEqual(current.root, menu.root),
              try openedGeminiPane(current, query: query) != nil else { throw Failure.paneNotAvailable }
        let account = Result {
            if try query.supports(kAXCancelAction, on: menu.root) {
                try query.perform(kAXCancelAction, on: menu.root)
            } else {
                try query.perform(kAXPressAction, on: picker.button)
            }
            Log.connectors.notice("Gemini Antigravity closed usage menu for native account verification")
            return try readGeminiAccount(app: app, window: window, query: query)
        }
        let restore = AccessibilityQuery(timeout: .seconds(4), checksCancellation: false, messagingTimeout: 0.3)
        let reopened = Result { try reopenGeminiPane(app: app, window: window, origin: picker.origin, query: restore) }
        guard try account.get() == email else { throw Failure.accountNotVerified }
        guard try geminiQuotaText(reopened.get(), query: query) == lines else { throw Failure.paneNotAvailable }
        return try makePane(quotas: readings, route: .embedded, observedAt: observedAt).snapshot
    }

    private static func geminiQuotaText(_ node: AXUIElement, depth: Int = 0, query: AccessibilityQuery) throws -> [String] {
        guard depth < 8, try !query.isHidden(node) else { return [] }
        let role = try query.string(node, kAXRoleAttribute)
        let structural = [kAXGroupRole, kAXUnknownRole, kAXScrollAreaRole, kAXMenuItemRole, "AXLayoutArea", "AXLayoutItem"]
        if textRoles.contains(role) { return [try query.leafText(node)].filter { !$0.isEmpty } }
        guard depth == 0 || structural.contains(role) else { return [] }
        let children = try query.list(node)
        let text = try children.flatMap { try geminiQuotaText($0, depth: depth + 1, query: query) }
        if !text.isEmpty { return text }
        let leaf = try query.leafText(node)
        return leaf.lowercased().contains("limit") ? [leaf] : []
    }

    private static func findStandalonePanes(_ element: AXUIElement, inSettings: Bool, depth: Int,
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
            if Route.standalone.isQuotaTitle(title) {
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
                if Route.standalone.isQuotaTitle(title) {
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
            try findStandalonePanes(child, inSettings: scoped, depth: depth + 1, query: query, into: &panes)
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

    final class AccessibilityQuery {
        private let deadline: ContinuousClock.Instant
        private let checksCancellation: Bool
        private let messagingTimeout: Float
        private var remaining = 1200

        init(timeout: Duration = .seconds(2), checksCancellation: Bool = true, messagingTimeout: Float = 0.12) {
            deadline = ContinuousClock.now + timeout
            self.checksCancellation = checksCancellation
            self.messagingTimeout = messagingTimeout
        }

        private func checkBudget() throws {
            if checksCancellation { try Task.checkCancellation() }
            guard ContinuousClock.now < deadline, remaining > 0 else { throw Failure.clientNotResponding }
            remaining -= 1
        }

        func prepare(_ element: AXUIElement) throws {
            try checkBudget()
            guard AXUIElementSetMessagingTimeout(element, messagingTimeout) == .success else { throw Failure.clientNotResponding }
        }

        func perform(_ action: String, on element: AXUIElement) throws {
            try prepare(element)
            let result = AXUIElementPerformAction(element, action as CFString)
            if result == .apiDisabled { throw Failure.permissionRequired }
            guard result == .success else { throw Failure.paneNotAvailable }
        }

        func supports(_ action: String, on element: AXUIElement) throws -> Bool {
            try prepare(element)
            var actions: CFArray?
            guard AXUIElementCopyActionNames(element, &actions) == .success else { return false }
            return (actions as? [String])?.contains(action) == true
        }

        func performFirstSupported(_ actions: [String], on element: AXUIElement) throws {
            guard let action = try actions.first(where: { try supports($0, on: element) }) else { throw Failure.paneNotAvailable }
            try perform(action, on: element)
        }

        func pause() throws {
            try checkBudget()
            Thread.sleep(forTimeInterval: 0.03)
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

        func url(_ element: AXUIElement) throws -> URL? {
            if let value = try attribute(element, kAXURLAttribute) as? URL { return value }
            let text = try string(element, kAXURLAttribute)
            return URL(string: text)
        }

        func leafText(_ leaf: AXUIElement) throws -> String {
            for name in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                let value = try string(leaf, name)
                if !value.isEmpty { return value }
            }
            return ""
        }

        func isTrue(_ element: AXUIElement, _ name: String) throws -> Bool {
            try bool(element, name) == true
        }

        func bool(_ element: AXUIElement, _ name: String) throws -> Bool? {
            try attribute(element, name) as? Bool
        }

        func isHidden(_ element: AXUIElement) throws -> Bool {
            try isTrue(element, kAXHiddenAttribute)
        }

        func children(_ parent: AXUIElement, role: String) throws -> [AXUIElement] {
            if let visible = try children(parent, attribute: kAXVisibleChildrenAttribute) { return visible }
            guard role != "AXScrollArea" else { return [] }
            return try children(parent, attribute: kAXChildrenAttribute) ?? []
        }

        func list(_ parent: AXUIElement, _ attributeName: String = kAXChildrenAttribute) throws -> [AXUIElement] {
            if let list = try attribute(parent, attributeName) as? [AXUIElement] {
                guard list.count <= 64 else { throw Failure.paneNotAvailable }
                return list
            }
            return try children(parent, attribute: attributeName) ?? []
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
