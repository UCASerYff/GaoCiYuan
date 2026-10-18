import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

// V2.1：豆包桌面端 AX 读取升级到 Kimi 桥标准（对齐 KimiDesktopBridge 的既有模式）。
// 主 app（DoubaoBridge）与 doubao-reader 助手编译同一文件，动作/延迟/节流常量单一来源。
// 动作面（2.31.2 起）：按下头像（AXPopUpButton 含「套餐」）→ 弹层内直读「当前时段额度用量 X%」「N 次额度重置」→ Escape 关弹层；
// 旧版兜底：弹层菜单「额度状态」→ 订阅与额度管理页 →「返回」。其余全部只读。
// 后台导航实测可行（探测全程豆包 isActive=false 即可读），故不再 unhide——侵入性最小化。
// 零网络、零凭证；不读取聊天内容。
enum DoubaoAX {
    struct Observation: Equatable {
        var plan: String? = nil            // 套餐名（如「标准套餐」）
        var currentUsedPercent: Double?    // 当前时段已用 %；页面原话「未消耗/开始使用后计时」忠实转写为 0
        var weeklyUsedPercent: Double?     // 近 7 天已用 %
        var weeklyRawLessThanOne = false   // 近 7 天页面原文为「已用 <1%」：不编造精确数字，按不足 1% 处理（记 1%）
        var weeklyResetAt: Date? = nil     // 「9月22日 12:21 重置」
        var resetCredits: Int? = nil       // 「额度重置 N 次」剩余重置机会
        var giftDeadline: Date? = nil      // 「赠送时长至12月14日」（无年份，已过则取明年，同 detectResetTime 约定）
        var hasPageMarkers = false         // 页面标记：含「订阅与额度管理」或「当前时段」+「近 7 天」
    }

    enum CollectOutcome: Equatable {
        case notRunning          // 豆包未运行
        case needsPermission     // 未授权辅助功能
        case foregroundBusy      // 豆包前台使用中：设计内跳过，不导航、不是失败
        case throttled           // 距上次自动导航不足 5 分钟
        case noPage              // 读取/导航后仍无页面标记（页面结构可能已变化）
        case observation(Observation)
    }

    static let bundleID = "com.bot.pc.doubao"
    static let avatarPressDelayMicros: useconds_t = 900_000 // 弹层动画 + 渲染等待（对齐 WorkBuddy 弹层实测）
    static let quotaPressDelayMicros: useconds_t = 500_000
    static let settleDelayMicros: useconds_t = 1_200_000 // 进页后等 WebArea 渲染
    static let navigateThrottle: TimeInterval = 300

    // 导航节流 per-account 记录并加锁：refreshAll 并行时不竞态（同 KimiDesktopBridge）。
    private static var lastNavigateAt: [UUID: Date] = [:]
    private static let navigateLock = NSLock()
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

    static func runningApp() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { ($0.bundleIdentifier ?? "") == bundleID && !$0.isTerminated }
    }

    // MARK: - 纯解析（fixture 测试）

    static func parse(lines rawLines: [String], now: Date = Date()) -> Observation {
        let lines = rawLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var obs = Observation()
        let hasCurrent = lines.contains("当前时段")
        let hasWeekly = lines.contains("近 7 天") || lines.contains("近7天")
        // 2.31.2 弹层形态：「当前时段额度用量 X%」单行道即弹层标记（旧页标记保留兼容）。
        let hasPopupUsage = lines.contains { $0.contains("当前时段额度用量") }
        obs.hasPageMarkers = lines.contains { $0.contains("订阅与额度管理") } || (hasCurrent && hasWeekly) || hasPopupUsage
        let cal = Calendar.current

        // 套餐名：以「套餐」结尾的短行，排除「升级至…」按钮文案。
        for l in lines where l.hasSuffix("套餐") && l.count <= 12 && !l.hasPrefix("升级") { obs.plan = l; break }

        // 2.31.2 弹层：「当前时段额度用量 2%」同一行内取已用百分比（含「<1%」忠实记 1%）。
        if obs.currentUsedPercent == nil,
           let l = lines.first(where: { $0.contains("当前时段额度用量") }),
           let re = try? NSRegularExpression(pattern: #"当前时段额度用量\s*(<|＜)?\s*(\d+(?:\.\d+)?)\s*%"#),
           let m = re.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)),
           let rv = Range(m.range(at: 2), in: l), let v = Double(l[rv]), (0...100).contains(v) {
            obs.currentUsedPercent = m.range(at: 1).location != NSNotFound ? 1 : v
        }

        // 已用百分比：「已用 <1%」忠实记录 lessThan 标志，不编造精确数字。
        func usedPercent(after index: Int, lookahead: Int = 3) -> (value: Double, lessThanOne: Bool)? {
            guard index >= 0, index < lines.count else { return nil }
            for j in index...min(lines.count - 1, index + lookahead) {
                let l = lines[j]
                if l == "未消耗" { return (0, false) } // 页面原话：未开始消耗
                if let re = try? NSRegularExpression(pattern: #"已用\s*[:：]?\s*(<|＜)?\s*(\d+(?:\.\d+)?)\s*%"#),
                   let m = re.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)),
                   let rv = Range(m.range(at: 2), in: l), let v = Double(l[rv]), (0...100).contains(v) {
                    let lt = m.range(at: 1).location != NSNotFound
                    return lt ? (1, true) : (v, false)
                }
            }
            return nil
        }

        if let i = lines.firstIndex(of: "当前时段"), let r = usedPercent(after: i) {
            obs.currentUsedPercent = r.value
        }
        if let i = lines.firstIndex(where: { $0 == "近 7 天" || $0 == "近7天" }) {
            if let r = usedPercent(after: i) {
                obs.weeklyUsedPercent = r.value
                obs.weeklyRawLessThanOne = r.lessThanOne
            }
            // 「9月22日 12:21 重置」由 QuotaValueParser.detectResetTime 覆盖（含跨年补明年）。
            for j in i...min(lines.count - 1, i + 3) {
                if let d = QuotaValueParser.detectResetTime(lines[j]) { obs.weeklyResetAt = d; break }
            }
        }

        // 剩余重置机会：「额度重置」行后的「N 次」。
        if let i = lines.firstIndex(of: "额度重置"), i + 1 < lines.count,
           let re = try? NSRegularExpression(pattern: #"^(\d+)\s*次$"#),
           let m = re.firstMatch(in: lines[i + 1], range: NSRange(lines[i + 1].startIndex..., in: lines[i + 1])),
           let r = Range(m.range(at: 1), in: lines[i + 1]) {
            obs.resetCredits = Int(lines[i + 1][r])
        }
        // 2.31.2 弹层形态：「1 次额度重置」同一行内取剩余重置机会。
        if obs.resetCredits == nil,
           let l = lines.first(where: { $0.hasSuffix("次额度重置") }),
           let re = try? NSRegularExpression(pattern: #"^(\d+)\s*次额度重置$"#),
           let m = re.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)),
           let r = Range(m.range(at: 1), in: l) {
            obs.resetCredits = Int(l[r])
        }

        // 赠送时长：「赠送时长至12月14日」无年份，补当前年，已过取明年。
        for l in lines {
            if let re = try? NSRegularExpression(pattern: #"赠送时长至\s*(\d{1,2})\s*月\s*(\d{1,2})\s*日"#),
               let m = re.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)),
               let rm = Range(m.range(at: 1), in: l), let rd = Range(m.range(at: 2), in: l),
               let mo = Int(l[rm]), let d = Int(l[rd]) {
                let y = cal.component(.year, from: now)
                if let date = cal.date(from: DateComponents(year: y, month: mo, day: d)) {
                    obs.giftDeadline = date < now ? cal.date(from: DateComponents(year: y + 1, month: mo, day: d)) : date
                }
                break
            }
        }
        return obs
    }

    // 「9月22日 12:21 重置」等形态由 QuotaValueParser.detectResetTime 统一覆盖（含跨年补明年）。

    // MARK: - AX 读取与后台导航

    private static func windowLines(_ axApp: AXUIElement) -> [String] {
        var lines: [String] = []
        var wins: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &wins) == .success,
           let arr = wins as? [AXUIElement] {
            for w in arr { AXShared.collectTexts(w, into: &lines) }
        }
        return lines
    }

    // 按 role + 文本精确查找（返回键只用「返回」本身，避免误按其他含「返回」的控件）。
    private static func find(_ el: AXUIElement, role: String, text: String, exact: Bool, depth: Int = 0) -> AXUIElement? {
        if depth > AXShared.maxDepth { return nil }
        if AXShared.axString(el, kAXRoleAttribute) == role {
            let texts = [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute].compactMap { AXShared.axString(el, $0)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            for t in texts where exact ? t == text : t.contains(text) { return el }
        }
        var kids: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
           let arr = kids as? [AXUIElement] {
            for k in arr { if let f = find(k, role: role, text: text, exact: exact, depth: depth + 1) { return f } }
        }
        return nil
    }

    private static func press(_ el: AXUIElement) -> Bool {
        AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
    }

    private static func pressInWindows(_ axApp: AXUIElement, role: String, text: String, exact: Bool) -> Bool {
        guard let el = findInWindows(axApp, role: role, text: text, exact: exact) else { return false }
        return press(el)
    }

    private static func findInWindows(_ axApp: AXUIElement, role: String, text: String, exact: Bool) -> AXUIElement? {
        var wins: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &wins) == .success,
              let arr = wins as? [AXUIElement] else { return nil }
        for w in arr { if let el = find(w, role: role, text: text, exact: exact) { return el } }
        return nil
    }

    // 2.31.2 实测：头像 AXPopUpButton 的 AXPress 返回成功但不开弹层，合成鼠标事件（公开 postToPid /
    // SkyLight SLEventPostToPid / NSEvent windowNumber 全矩阵）也都被忽略；但「AXFocused 聚焦 + 回车」
    // 键盘直投可稳定开弹层（postToPid 键盘事件豆包不拒）。仅在聚焦写入成功时才发回车，避免误触输入框。
    private static func focusReturnOpen(_ el: AXUIElement, pid: pid_t) -> Bool {
        guard AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { return false }
        usleep(200_000)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false) else { return false }
        down.postToPid(pid)
        usleep(80_000)
        up.postToPid(pid)
        return true
    }

    /// 读取订阅与额度管理页。allowPrompt 仅在用户手动同步或首次同步该连接器时为 true。
    static func collect(accountID: UUID, allowPrompt: Bool = false, allowNavigation: Bool = false) -> CollectOutcome {
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

        // 页面正好开着：直接只读，不导航。
        var obs = parse(lines: windowLines(axApp))
        if obs.hasPageMarkers { return .observation(obs) }
        guard allowNavigation else { return .noPage }

        // 前台使用中不打扰：状态而非错误（同 Kimi 桥）。
        if app.isActive { return .foregroundBusy }
        guard !navigationThrottled(accountID) else { return .throttled }
        markNavigated(accountID)

        // 后台导航：头像（AXPopUpButton 含「套餐」）开弹层；AXPress 无效时聚焦+回车兜底。
        let debug = ProcessInfo.processInfo.environment["DOUBAO_AX_DEBUG"] == "1"
        if let avatar = findInWindows(axApp, role: "AXPopUpButton", text: "套餐", exact: false) {
            _ = press(avatar)
            usleep(avatarPressDelayMicros)
            // 2.31.2 起弹层直接给出「当前时段额度用量 X%」「N 次额度重置」：直读弹层，读完关弹层。
            var lines = windowLines(axApp)
            if debug { FileHandle.standardError.write("after AXPress: \(lines.count) lines, markers=\(parse(lines: lines).hasPageMarkers)\n".data(using: .utf8)!) }
            obs = parse(lines: lines)
            if !obs.hasPageMarkers, focusReturnOpen(avatar, pid: app.processIdentifier) {
                usleep(avatarPressDelayMicros)
                lines = windowLines(axApp)
                if debug { FileHandle.standardError.write("after focus+Return: \(lines.count) lines, markers=\(parse(lines: lines).hasPageMarkers)\n".data(using: .utf8)!) }
                obs = parse(lines: lines)
            }
            if obs.hasPageMarkers {
                closePopup(axApp, pid: app.processIdentifier)
                return .observation(obs)
            }
            // 旧版兜底：弹层菜单「额度状态」→ 订阅与额度管理页。
            if pressInWindows(axApp, role: "AXMenuItem", text: "额度状态", exact: false) {
                usleep(quotaPressDelayMicros + settleDelayMicros)
                obs = parse(lines: windowLines(axApp))
                // Leave the page the way we found it: press「返回」, best effort.
                _ = pressInWindows(axApp, role: "AXButton", text: "返回", exact: true)
            } else {
                // 弹层还开着但没读到：关弹层恢复原状。
                closePopup(axApp, pid: app.processIdentifier)
            }
        }
        return obs.hasPageMarkers ? .observation(obs) : .noPage
    }

    /// 关弹层：先按 Escape（直投键盘事件，实测豆包弹层可收）；还开着则 AXCancel 弹层菜单项兜底。全程 best effort。
    private static func closePopup(_ axApp: AXUIElement, pid: pid_t) {
        sendEscape(to: pid)
        usleep(200_000)
        if parse(lines: windowLines(axApp)).hasPageMarkers {
            _ = cancelInWindows(axApp, role: "AXMenuItem")
        }
    }

    private static func sendEscape(to pid: pid_t) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false) else { return }
        down.postToPid(pid)
        usleep(60_000)
        up.postToPid(pid)
    }

    // 对弹层里第一个指定 role 的控件执行 AXCancel（关弹层兜底）。
    private static func cancelInWindows(_ axApp: AXUIElement, role: String, depth cap: Int = 30) -> Bool {
        var wins: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &wins) == .success,
              let arr = wins as? [AXUIElement] else { return false }
        func findRole(_ el: AXUIElement, _ depth: Int) -> AXUIElement? {
            if depth > cap { return nil }
            if AXShared.axString(el, kAXRoleAttribute) == role { return el }
            var kids: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
               let arr = kids as? [AXUIElement] {
                for k in arr { if let f = findRole(k, depth + 1) { return f } }
            }
            return nil
        }
        for w in arr {
            if let el = findRole(w, 0),
               AXUIElementPerformAction(el, kAXCancelAction as CFString) == .success { return true }
        }
        return false
    }
}

// doubao-reader helper 输出载荷的编解码：与 helper 编译同一文件，两侧格式不漂移。
enum DoubaoReaderPayload {
    static func encode(_ obs: DoubaoAX.Observation) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var d: [String: Any] = ["hasPageMarkers": obs.hasPageMarkers, "weeklyRawLessThanOne": obs.weeklyRawLessThanOne]
        if let v = obs.plan { d["plan"] = v }
        if let v = obs.currentUsedPercent { d["currentUsedPercent"] = v }
        if let v = obs.weeklyUsedPercent { d["weeklyUsedPercent"] = v }
        if let v = obs.weeklyResetAt { d["weeklyResetAt"] = iso.string(from: v) }
        if let v = obs.resetCredits { d["resetCredits"] = v }
        if let v = obs.giftDeadline { d["giftDeadline"] = iso.string(from: v) }
        return d
    }

    static func parse(_ obj: [String: Any]) -> DoubaoAX.Observation? {
        guard obj["hasPageMarkers"] as? Bool == true else { return nil }
        let iso = ISO8601DateFormatter()
        var obs = DoubaoAX.Observation()
        obs.hasPageMarkers = true
        obs.plan = obj["plan"] as? String
        obs.currentUsedPercent = obj["currentUsedPercent"] as? Double
        obs.weeklyUsedPercent = obj["weeklyUsedPercent"] as? Double
        obs.weeklyRawLessThanOne = obj["weeklyRawLessThanOne"] as? Bool ?? false
        if let s = obj["weeklyResetAt"] as? String { obs.weeklyResetAt = iso.date(from: s) }
        obs.resetCredits = obj["resetCredits"] as? Int
        if let s = obj["giftDeadline"] as? String { obs.giftDeadline = iso.date(from: s) }
        return obs
    }
}
