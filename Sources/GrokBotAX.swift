import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Grok Bot 左下角头像栏目：只按下账户按钮，读取「套餐 N% 已用」，再直投 Escape 收起。
/// 不读取或识别聊天语义，不点击栏目里的其他项目，不访问网络、Cookie、凭证或私有数据库。
enum GrokBotAX {
    struct Observation: Equatable {
        var plan: String
        var weeklyPercentUsed: Double
    }

    struct AvatarCandidate: Equatable {
        var title: String
        var x: Double
        var y: Double
        var windowHeight: Double
    }

    enum CollectOutcome: Equatable {
        case notRunning
        case needsPermission
        case foregroundBusy
        case throttled
        case unavailable
        case observation(Observation)
    }

    static let bundleID = "com.anysphere.sand"
    static let popupSettleMicros: useconds_t = 900_000
    static let navigateThrottle: TimeInterval = 300
    private static var lastNavigateAt: [UUID: Date] = [:]
    private static let navigateLock = NSLock()

    /// 栏目文本必须完整匹配套餐与「已用」。已展开栏目可能重复提供同一菜单项；冲突候选全部拒绝。
    static func parse(lines: [String]) -> Observation? {
        guard let expression = try? NSRegularExpression(pattern: #"^([A-Za-z][A-Za-z0-9+]*(?: [A-Za-z][A-Za-z0-9+]*){0,5})\s+(0(?:\.\d+)?|[1-9]\d*(?:\.\d+)?)%\s*已用$"#) else { return nil }
        var found: Observation?
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = expression.firstMatch(in: line, range: range),
                  match.range == range,
                  let planRange = Range(match.range(at: 1), in: line),
                  let usedRange = Range(match.range(at: 2), in: line),
                  let used = Double(line[usedRange]), used.isFinite, (0...100).contains(used) else { continue }
            let plan = String(line[planRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plan.isEmpty, plan.count <= 64,
                  plan.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !$0.properties.isJoinControl }) else { return nil }
            let candidate = Observation(plan: plan, weeklyPercentUsed: used)
            if let found, found != candidate { return nil }
            found = candidate
        }
        return found
    }

    /// 昵称不固定：仅考虑窗口下 20% 的有标题 AXPopUpButton，先选最靠下，再选最靠左。
    static func chooseAvatar(_ candidates: [AvatarCandidate]) -> AvatarCandidate? {
        candidates.filter {
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            $0.windowHeight > 0 && $0.y >= $0.windowHeight * 0.8
        }.sorted {
            if $0.y != $1.y { return $0.y > $1.y }
            return $0.x < $1.x
        }.first
    }

    /// 自动读取在解析已展开栏目前就避开前台；手动同步可直接读取已展开的栏目。
    static func shouldReadWithoutNavigation(isActive: Bool, userInitiated: Bool) -> Bool {
        userInitiated || !isActive
    }

    static func navigationThrottled(_ accountID: UUID, now: Date = Date()) -> Bool {
        navigateLock.lock()
        defer { navigateLock.unlock() }
        return now.timeIntervalSince(lastNavigateAt[accountID] ?? .distantPast) < navigateThrottle
    }

    static func markNavigated(_ accountID: UUID, now: Date = Date()) {
        navigateLock.lock()
        lastNavigateAt[accountID] = now
        navigateLock.unlock()
    }

    static func resetNavigationForTesting(_ accountID: UUID) {
        navigateLock.lock()
        lastNavigateAt.removeValue(forKey: accountID)
        navigateLock.unlock()
    }

    static func runningApp() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleID && !$0.isTerminated
        }
    }

    private static func windowLines(_ axApp: AXUIElement) -> [String] {
        var lines: [String] = []
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windows) == .success,
              let windows = windows as? [AXUIElement] else { return [] }
        for window in windows { AXShared.collectTexts(window, into: &lines) }
        return lines
    }

    private static func collectPopUpButtons(_ element: AXUIElement, windowHeight: Double, into result: inout [(AXUIElement, AvatarCandidate)], depth: Int = 0) {
        if depth > AXShared.maxDepth { return }
        if AXShared.axString(element, kAXRoleAttribute) == "AXPopUpButton" {
            let title = AXShared.axString(element, kAXTitleAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !title.isEmpty, let position = point(element, attribute: kAXPositionAttribute) {
                result.append((element, AvatarCandidate(title: title, x: position.x, y: position.y, windowHeight: windowHeight)))
            }
        }
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
           let children = children as? [AXUIElement] {
            for child in children { collectPopUpButtons(child, windowHeight: windowHeight, into: &result, depth: depth + 1) }
        }
    }

    private static func point(_ element: AXUIElement, attribute: String) -> (x: Double, y: Double)? {
        var reference: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &reference) == .success,
              let reference, CFGetTypeID(reference) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(reference as! AXValue, .cgPoint, &point) else { return nil }
        return (point.x, point.y)
    }

    private static func height(_ element: AXUIElement) -> Double {
        var reference: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &reference) == .success,
              let reference, CFGetTypeID(reference) == AXValueGetTypeID() else { return 0 }
        var size = CGSize.zero
        guard AXValueGetValue(reference as! AXValue, .cgSize, &size) else { return 0 }
        return size.height
    }

    private static func accountButton(_ axApp: AXUIElement) -> AXUIElement? {
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windows) == .success,
              let windows = windows as? [AXUIElement] else { return nil }
        var buttons: [(AXUIElement, AvatarCandidate)] = []
        for window in windows { collectPopUpButtons(window, windowHeight: height(window), into: &buttons) }
        guard let chosen = chooseAvatar(buttons.map(\.1)) else { return nil }
        return buttons.first(where: { $0.1 == chosen })?.0
    }

    private static func sendEscape(to pid: pid_t) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false) else { return }
        down.postToPid(pid)
        usleep(60_000)
        up.postToPid(pid)
    }

    /// 自动读取允许非前台导航，但按账户节流 5 分钟；手动同步立即导航且不受该节流限制。
    static func collect(accountID: UUID, allowPrompt: Bool = false, allowNavigation: Bool = false, userInitiated: Bool = false, now: Date = Date()) -> CollectOutcome {
        guard let app = runningApp() else { return .notRunning }
        guard AXIsProcessTrusted() else {
            if allowPrompt {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            return .needsPermission
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        guard shouldReadWithoutNavigation(isActive: app.isActive, userInitiated: userInitiated) else { return .foregroundBusy }
        if let observed = parse(lines: windowLines(axApp)) { return .observation(observed) }
        guard allowNavigation, !app.isActive else { return app.isActive ? .foregroundBusy : .unavailable }
        if !userInitiated {
            guard !navigationThrottled(accountID, now: now) else { return .throttled }
            markNavigated(accountID, now: now)
        }

        if let button = accountButton(axApp),
           AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
            usleep(popupSettleMicros)
            let observed = parse(lines: windowLines(axApp))
            sendEscape(to: app.processIdentifier)
            return observed.map { .observation($0) } ?? .unavailable
        }
        return .unavailable
    }
}
