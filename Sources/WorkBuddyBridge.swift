import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

// WorkBuddy（腾讯）积分余额 AX 桥：与豆包同一模式（DoubaoAX/AXShared），动作面只有一个——
// 按下左下角账户 AXPopUpButton 打开弹层，只读「积分余额 刷新 N」按钮标题，读完按 Escape 关弹层。
// 零网络、零凭证；积分值只进快照，绝不写日志；前台使用中不打扰；自动读取 5 分钟节流。
enum WorkBuddyAX {
    enum CollectOutcome: Equatable {
        case notRunning          // WorkBuddy 未运行
        case needsPermission     // 未授权辅助功能
        case foregroundBusy      // WorkBuddy 前台使用中：设计内跳过，不导航、不是失败
        case throttled           // 距上次自动读取不足 5 分钟
        case noCredits           // 读取/导航后仍无积分行（页面结构可能已变化）
        case observation(Double) // 积分余额（原始值，不截断）
    }

    static let bundleID = "com.tencent.workbuddy.mac"
    static let popupSettleMicros: useconds_t = 900_000 // 弹层动画 + 渲染等待
    static let navigateThrottle: TimeInterval = 300

    // 导航节流 per-account 记录并加锁：refreshAll 并行时不竞态（同 DoubaoAX/KimiDesktopBridge）。
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

    /// 从窗口文本行找积分：含「积分余额」的行里抓第一个数字（允许千分位逗号与小数）。
    /// 实测弹层按钮标题形如「积分余额 刷新 1,096.36」。解析不出即 nil，绝不编造。
    static func parseCredits(lines rawLines: [String]) -> Double? {
        let lines = rawLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let re = try? NSRegularExpression(pattern: #"([0-9][0-9,]*(?:\.\d+)?)"#) else { return nil }
        for l in lines where l.contains("积分余额") {
            let ns = NSRange(l.startIndex..., in: l)
            for m in re.matches(in: l, range: ns) {
                guard let r = Range(m.range(at: 1), in: l) else { continue }
                let v = Double(l[r].replacingOccurrences(of: ",", with: ""))
                if let v, v.isFinite, v >= 0 { return v }
            }
        }
        return nil
    }

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

    /// 账户按钮：窗口里最靠下且带非空标题的 AXPopUpButton（左下角昵称按钮，标题随账号变化，用「位置 + 有标题」认；
    /// 右下角「扫码 WorkBuddy 小程序」也是 PopUpButton 但标题为空，必须排除——实测只按 y 最大会误按它）。
    private static func collectPopUpButtons(_ el: AXUIElement, into out: inout [AXUIElement], depth: Int = 0) {
        if depth > AXShared.maxDepth { return }
        if AXShared.axString(el, kAXRoleAttribute) == "AXPopUpButton" {
            let title = AXShared.axString(el, kAXTitleAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !title.isEmpty { out.append(el) }
        }
        var kids: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
           let arr = kids as? [AXUIElement] {
            for k in arr { collectPopUpButtons(k, into: &out, depth: depth + 1) }
        }
    }

    private static func accountButton(_ axApp: AXUIElement) -> AXUIElement? {
        var wins: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &wins) == .success,
              let arr = wins as? [AXUIElement] else { return nil }
        var best: AXUIElement? = nil
        var bestY: CGFloat = -.infinity
        for w in arr {
            var buttons: [AXUIElement] = []
            collectPopUpButtons(w, into: &buttons)
            for b in buttons {
                var pos: CFTypeRef?
                guard AXUIElementCopyAttributeValue(b, kAXPositionAttribute as CFString, &pos) == .success,
                      let v = pos, CFGetTypeID(v) == AXValueGetTypeID() else { continue }
                var p = CGPoint.zero
                guard AXValueGetValue(v as! AXValue, .cgPoint, &p) else { continue }
                if p.y > bestY { bestY = p.y; best = b }
            }
        }
        return best
    }

    /// 读完按 Escape 关弹层（实测 Esc 有效）：直投目标进程，不抢前台焦点。
    private static func sendEscape(to pid: pid_t) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false) else { return }
        down.postToPid(pid)
        usleep(60_000)
        up.postToPid(pid)
    }

    /// 读取积分余额。allowPrompt 仅在用户手动同步或首次同步该连接器时为 true。
    static func collect(accountID: UUID, allowPrompt: Bool = false) -> CollectOutcome {
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

        // 弹层正好开着（或页面本身就有积分行）：直接只读，不导航。
        if let credits = parseCredits(lines: windowLines(axApp)) { return .observation(credits) }

        // 前台使用中不打扰：状态而非错误（同 Kimi/豆包桥）。
        if app.isActive { return .foregroundBusy }
        guard !navigationThrottled(accountID) else { return .throttled }
        markNavigated(accountID)

        // 后台导航：按下账户弹层按钮 → 等弹层渲染 → 重读 → 按 Escape 恢复原状。
        var credits: Double? = nil
        if let button = accountButton(axApp),
           AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
            usleep(popupSettleMicros)
            credits = parseCredits(lines: windowLines(axApp))
            sendEscape(to: app.processIdentifier)
        }
        return credits.map { .observation($0) } ?? .noCredits
    }
}

enum WorkBuddyBridge {
    /// 「去查看」落地的官方站点（积分详情页需在应用内查看，网页端为入口）。
    static let viewURL = "https://www.workbuddy.cn"

    static func snapshot(credits: Double) throws -> UsageSnapshot {
        var s = UsageSnapshot.empty(source: "WorkBuddy 本机读取")
        // 积分不是货币：以 PTS 伪币种进 balances（三位大写 ASCII，过校验），
        // 精确值由此保留（额度环只取 min(积分/1000,1)，大号数字显示原始值）。
        s.balances = [Money(currency: "PTS", value: credits)]
        s.note = "积分制：1000 积分满环，低于按比例 · 经辅助功能只读读取本机账户弹层，读完按 Escape 关闭 · 积分值不写日志"
        try s.validate()
        return s
    }

    static func fetch(_ account: Account, userInitiated: Bool = false) async throws -> ConnectorResult {
        // 积分不是秒级指标：自动轮询 5 分钟节流（手动同步不受限），与既有本机桥一致。
        if !userInitiated, let last = account.lastAttempt, Date().timeIntervalSince(last) < 300 {
            return .status("距上次同步不足 5 分钟，本次沿用上次数据。")
        }
        // 授权弹窗只在用户手动同步或首次同步该连接器时触发，定时轮询不弹窗。
        let allowPrompt = userInitiated || account.lastAttempt == nil
        // AX 遍历含 usleep，卸载到后台队列，不占协作线程池与主线程。
        let accountID = account.id
        let outcome: WorkBuddyAX.CollectOutcome = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: WorkBuddyAX.collect(accountID: accountID, allowPrompt: allowPrompt))
            }
        }
        switch outcome {
        case .notRunning:
            return .status("WorkBuddy 暂未启动。启动本机软件后自动读取积分余额，不预填数值。")
        case .needsPermission:
            // 未授权是可操作的硬状态：走 error 以触发授权引导按钮，上次数据保留。
            throw MonitorError.message("WorkBuddy 本机读取 · 需在「系统设置 - 隐私与安全性 - 辅助功能」中勾选允许「搞词元」，允许后点立即同步即可读取。上次数据已保留。")
        case .foregroundBusy:
            // 设计内跳过，不是失败：状态消息，不触发总览告警与菜单栏红点。
            return .status("WorkBuddy 前台使用中，稍后自动补读；上次数据已保留。")
        case .throttled:
            return .status("距上次自动读取不足 5 分钟，本次沿用上次数据。")
        case .noCredits:
            throw MonitorError.message("未能读取 WorkBuddy 积分余额（页面结构可能已变化）。上次数据已保留。")
        case .observation(let credits):
            return .snapshot(try snapshot(credits: credits))
        }
    }

    // MARK: - 展示辅助（账户卡与悬浮条共用，文案口径唯一来源）

    /// 大号积分文本：千分位 + 最多 2 位小数（如 1,096.36）。
    static func creditsText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).grouping(.automatic))
    }

    /// 悬浮条环下紧凑数字：只许截断不许四舍五入（永远不多报积分）。
    /// ≥100 去小数、<100 一位小数。
    static func compactCredits(_ value: Double) -> String {
        let abs = Swift.abs(value)
        let decimals = abs >= 100 ? 0 : 1
        let factor: Double = decimals == 0 ? 1 : 10
        let truncated = (value * factor).rounded(.towardZero) / factor
        return String(format: "%.\(decimals)f", truncated)
    }
}
