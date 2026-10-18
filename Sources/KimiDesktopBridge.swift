import AppKit
import ApplicationServices

// Read-only Accessibility observer of the local Kimi desktop app's subscription page.
// No network requests, no credentials, no cookies, no JS injection. The only actions ever
// performed are pressing「设置…」「我的订阅」「返回」to reach and leave the quota page.
enum KimiDesktopBridge {
    struct Observation: Equatable {
        var plan: String? = nil
        var monthlyUsedPercent: Double? = nil
        var validUntil: Date? = nil
        var weeklyResetDate: Date? = nil
        var fiveHourUsedPercent: Double? = nil
        var fiveHourResetAt: Date? = nil
        var giftName: String? = nil
        var giftDeadline: Date? = nil
        var boosterStatus: String? = nil
        var hasPageMarkers: Bool = false
    }

    static let bundleID = "com.moonshot.kimichat"
    static let planNames = ["Pro", "Andante", "Moderato", "Allegretto", "Allegro"]
    static let navigateThrottle: TimeInterval = 300
    // 导航节流按账户记录并加锁：refreshAll 并行时不再竞态，第二个 Kimi 桌面账户也不再被全局节流。
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

    // MARK: - Pure parsing (unit-tested with real page dumps)

    static func parse(lines rawLines: [String], now: Date = Date()) -> Observation {
        let lines = rawLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var obs = Observation()
        obs.hasPageMarkers = lines.contains("用量进度") && lines.contains("总使用量")
        guard let markerIndex = lines.firstIndex(of: "总使用量") else { return obs }
        let cal = Calendar.current

        func percentAfter(_ index: Int, lookahead: Int = 4) -> Double? {
            guard index >= 0, index < lines.count else { return nil }
            for j in index...min(lines.count - 1, index + lookahead) {
                let l = lines[j]
                if let m = try? NSRegularExpression(pattern: #"^(\d+(?:\.\d+)?)\s*%$"#).firstMatch(in: l, range: NSRange(l.startIndex..., in: l)),
                   let r = Range(m.range(at: 1), in: l), let v = Double(l[r]), (0...100).contains(v) { return v }
            }
            return nil
        }
        func ymd(_ y: Int, _ m: Int, _ d: Int) -> Date? {
            cal.date(from: DateComponents(year: y, month: m, day: d))
        }
        func fullDate(_ text: String, prefix: String) -> Date? {
            guard let re = try? NSRegularExpression(pattern: prefix + #"(\d{4})-(\d{2})-(\d{2})"#),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let ry = Range(m.range(at: 1), in: text), let rm = Range(m.range(at: 2), in: text), let rd = Range(m.range(at: 3), in: text),
                  let y = Int(text[ry]), let mo = Int(text[rm]), let d = Int(text[rd]) else { return nil }
            return ymd(y, mo, d)
        }

        obs.monthlyUsedPercent = percentAfter(markerIndex)

        // Plan name: nearest known plan label just before the quota block (AXHeading / AXStaticText).
        for j in stride(from: markerIndex - 1, through: max(0, markerIndex - 14), by: -1) {
            let l = lines[j]
            if let name = planNames.first(where: { l == $0 || l.hasPrefix($0 + " ") }) { obs.plan = name; break }
        }

        for j in 0..<lines.count {
            let l = lines[j]
            if obs.validUntil == nil, let d = fullDate(l, prefix: #"有效期至\s*[:：]?\s*"#) { obs.validUntil = d }
            if obs.weeklyResetDate == nil, let d = fullDate(l, prefix: #"^"#), l.hasSuffix("后重置") { obs.weeklyResetDate = d }
            if obs.giftDeadline == nil, let d = fullDate(l, prefix: #"截止至\s*"#) { obs.giftDeadline = d }
            if l == "赠送额度", obs.giftName == nil, j + 1 < lines.count {
                let next = lines[j + 1]
                if !next.hasPrefix("截止"), next.count <= 30 { obs.giftName = next }
            }
            if l == "额度加油包", obs.boosterStatus == nil, j + 1 < lines.count {
                let next = lines[j + 1]
                if next.count <= 12 { obs.boosterStatus = next }
            }
            if obs.fiveHourUsedPercent == nil, l.contains("5 小时用量") || l.contains("5小时用量") {
                obs.fiveHourUsedPercent = percentAfter(j)
                // 5-hour window reset: "MM-dd HH:mm 后重置" on a following line.
                for k in j...min(lines.count - 1, j + 4) {
                    let t = lines[k]
                    if let re = try? NSRegularExpression(pattern: #"^(\d{2})-(\d{2})\s+(\d{2}):(\d{2})\s*后重置$"#),
                       let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
                       let rm = Range(m.range(at: 1), in: t), let rd = Range(m.range(at: 2), in: t),
                       let rh = Range(m.range(at: 3), in: t), let rmin = Range(m.range(at: 4), in: t),
                       let mo = Int(t[rm]), let d = Int(t[rd]), let h = Int(t[rh]), let mi = Int(t[rmin]) {
                        obs.fiveHourResetAt = cal.date(from: DateComponents(year: cal.component(.year, from: now), month: mo, day: d, hour: h, minute: mi))
                        break
                    }
                }
            }
        }
        return obs
    }

    static func snapshot(_ obs: Observation) throws -> UsageSnapshot {
        guard obs.hasPageMarkers, let monthly = obs.monthlyUsedPercent else {
            throw MonitorError.message("订阅页额度区块未读取到（页面结构可能已变化）。上次数据已保留。")
        }
        var s = UsageSnapshot.empty(source: "Kimi 桌面订阅页")
        s.quotas.append(Quota(id: "kimi-desktop-monthly", title: "Kimi \(obs.plan ?? "会员") · 每月", usedPercent: monthly, resetsAt: obs.validUntil, windowSeconds: 2_592_000))
        if let five = obs.fiveHourUsedPercent {
            s.quotas.append(Quota(id: "kimi-desktop-5h", title: "Kimi Code · 5 小时", usedPercent: five, resetsAt: obs.fiveHourResetAt, windowSeconds: 18_000))
        }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        var parts = ["Kimi 桌面端订阅页（辅助功能只读）；页面显示已用百分比，界面按剩余展示"]
        if let v = obs.validUntil { parts.append("有效期至 \(f.string(from: v))") }
        if let w = obs.weeklyResetDate { parts.append("Kimi Code 每周 \(f.string(from: w)) 后重置") }
        if let g = obs.giftName { parts.append("赠送额度：\(g)"); if let gd = obs.giftDeadline { parts.append("赠送额度截止至 \(f.string(from: gd))") } }
        if let b = obs.boosterStatus { parts.append("额度加油包：\(b)") }
        parts.append("未读取到的字段不编造，以页面实际显示为准。")
        s.note = parts.joined(separator: "；")
        // E2 到期提醒数据源：只填页面实际读到的有效期 / 赠送截止日。
        var deadlines: [Deadline] = []
        if let v = obs.validUntil { deadlines.append(Deadline(label: "Kimi 会员有效期", date: v)) }
        if let gd = obs.giftDeadline { deadlines.append(Deadline(label: "赠送额度（\(obs.giftName ?? "赠送")）截止", date: gd)) }
        s.deadlines = deadlines.isEmpty ? nil : deadlines
        try s.validate()
        return s
    }

    // MARK: - Accessibility reading

    static func runningApp() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID && !$0.isTerminated }
    }

    private static func axString(_ el: AXUIElement, _ attr: String) -> String? {
        AXShared.axString(el, attr)
    }

    private static func collectTexts(_ el: AXUIElement, depth: Int, into out: inout [String]) {
        AXShared.collectTexts(el, depth: depth, into: &out, limit: 1500)
    }

    private static func windowLines(_ axApp: AXUIElement) -> [String] {
        var lines: [String] = []
        var wins: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &wins) == .success,
           let arr = wins as? [AXUIElement] {
            for w in arr { collectTexts(w, depth: 0, into: &lines) }
        }
        return lines
    }

    private static func find(_ el: AXUIElement, role: String, title: String, depth: Int = 0) -> AXUIElement? {
        if depth > 30 { return nil }
        if axString(el, kAXRoleAttribute) == role {
            let texts = [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute].compactMap { axString(el, $0)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            if texts.contains(title) { return el }
        }
        var kids: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
           let arr = kids as? [AXUIElement] {
            for k in arr { if let f = find(k, role: role, title: title, depth: depth + 1) { return f } }
        }
        return nil
    }

    private static func press(_ el: AXUIElement) -> Bool {
        var cur: AXUIElement? = el
        for _ in 0..<4 {
            guard let c = cur else { return false }
            var actions: CFArray?
            if AXUIElementCopyActionNames(c, &actions) == .success,
               let list = actions as? [String], list.contains("AXPress") {
                return AXUIElementPerformAction(c, "AXPress" as CFString) == .success
            }
            var p: CFTypeRef?
            AXUIElementCopyAttributeValue(c, kAXParentAttribute as CFString, &p)
            // CF 类型条件转换：先比对 CFTypeID，避免 as! 在异常对象上崩溃。
            cur = p.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? unsafeBitCast($0, to: AXUIElement.self) : nil }
        }
        return false
    }

    private static func pressInWindows(_ axApp: AXUIElement, role: String, title: String) -> Bool {
        var wins: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &wins) == .success,
              let arr = wins as? [AXUIElement] else { return false }
        for w in arr { if let el = find(w, role: role, title: title), press(el) { return true } }
        return false
    }

    static func fetch(_ account: Account, userInitiated: Bool = false) async throws -> ConnectorResult {
        let cancellation = ConnectorCancellation()
        return try await withTaskCancellationHandler(operation: {
            let result = try await Task.detached(priority:.utility) {
                try read(accountID:account.id, allowPrompt:userInitiated, allowNavigation:userInitiated, cancellation:cancellation)
            }.value
            try Task.checkCancellation()
            return result
        }, onCancel:{cancellation.cancel()})
    }

    static func read(accountID: UUID, allowPrompt: Bool = false, allowNavigation: Bool = false, cancellation: ConnectorCancellation = ConnectorCancellation()) throws -> ConnectorResult {
        try cancellation.check()
        guard let app = runningApp() else {
            throw MonitorError.message("Kimi 桌面端未运行。启动后将在下次同步自动补读；上次数据已保留。")
        }
        guard AXIsProcessTrusted() else {
            // 授权弹窗只在用户手动同步或首次同步该连接器时触发，定时轮询不弹窗。
            if allowPrompt {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            throw MonitorError.message("需在「系统设置 - 隐私与安全性 - 辅助功能」中勾选允许「搞词元」，允许后点立即同步即可读取。上次数据已保留。")
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // AXEnhancedUserInterface 用后还原：记录原值，退出时恢复，避免长期改变目标应用的无障碍行为。
        var prevEnhanced: CFTypeRef?
        let hadEnhanced = AXUIElementCopyAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, &prevEnhanced) == .success
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        defer {
            if hadEnhanced, let prev = prevEnhanced {
                AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, prev)
            } else {
                AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            }
        }
        usleep(1_500_000)

        try cancellation.check()
        var obs = parse(lines: windowLines(axApp))
        if !obs.hasPageMarkers {
            guard allowNavigation else { return .status("Kimi 当前页面未显示额度，自动同步不会打开订阅页；可打开订阅页后重读或手动同步，上次数据已保留。") }
            if app.isActive {
                // 设计内跳过，不是失败：状态消息，不触发总览告警与菜单栏红点。
                return .status("Kimi 前台使用中，稍后自动补读；上次数据已保留。")
            }
            guard !navigationThrottled(accountID) else {
                return .status("距上次自动导航不足 5 分钟，本次沿用上次数据。")
            }
            try cancellation.check()
            markNavigated(accountID)
            var opened = false
            var mb: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &mb) == .success,
               let menuBar = mb, CFGetTypeID(menuBar) == AXUIElementGetTypeID() {
                let bar = unsafeBitCast(menuBar, to: AXUIElement.self)
                for title in ["设置…", "Settings…"] {
                    if let item = find(bar, role: "AXMenuItem", title: title), press(item) { opened = true; break }
                }
            }
            guard opened else {
                throw MonitorError.message("未能后台打开 Kimi 设置页（菜单项不可用）。上次数据已保留。")
            }
            usleep(1_300_000)
            try cancellation.check()
            obs = parse(lines: windowLines(axApp))
            if !obs.hasPageMarkers, pressInWindows(axApp, role: "AXLink", title: "我的订阅") {
                usleep(1_000_000)
                try cancellation.check()
            obs = parse(lines: windowLines(axApp))
            }
            // Leave the page the way we found it: press「返回」, best effort.
            _ = pressInWindows(axApp, role: "AXButton", title: "返回")
        }
        return .snapshot(try snapshot(obs))
    }
}
