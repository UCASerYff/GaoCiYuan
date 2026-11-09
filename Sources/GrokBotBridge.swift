import AppKit

/// Grok Bot 安装状态与额度分开：只有左下角头像栏目的真实「已用」读数才更新圆环。
enum GrokBotBridge {
    static func status(installed: Bool, running: Bool) -> String {
        GrokBotUsageReport.discoveryStatus(installed: installed, running: running)
    }

    static func isUsageRoute(_ account: Account) -> Bool {
        account.provider == .grok && account.kind == .agent && account.connection == .agentLocal
    }

    static func fetch(_ account: Account, now: Date = Date(), userInitiated: Bool = false) async throws -> ConnectorResult {
        try Task.checkCancellation()
        let accountID = account.id
        // AX 等待放到后台线程；手动允许授权弹窗，自动轮询不打扰用户。
        let outcome: GrokBotAX.CollectOutcome = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: GrokBotAX.collect(
                    accountID: accountID,
                    allowPrompt: userInitiated,
                    allowNavigation: true,
                    userInitiated: userInitiated,
                    now: now))
            }
        }
        try Task.checkCancellation()
        switch outcome {
        case .observation(let observed):
            let reading = GrokBotUsageReport.avatarManualReading(plan: observed.plan, weeklyPercentUsed: observed.weeklyPercentUsed, capturedAt: now)
            let text = GrokBotUsageReport.statusLine(reading, now: now, timeZone: .current)
            return .grokBotManual(status: text, reading: reading)
        case .notRunning:
            let apps = NSWorkspace.shared.runningApplications
            return .status(status(installed: MemberDiscovery.isAgentInstalled(.grok, in: apps), running: false))
        case .needsPermission:
            if !userInitiated { return .status("Grok Bot 自动读取需要辅助功能授权；上次额度已保留。") }
            throw MonitorError.message("Grok Bot 本机读取 · 需在「系统设置 - 隐私与安全性 - 辅助功能」中勾选允许「搞词元」，允许后点读取本机额度。上次数据已保留。")
        case .foregroundBusy:
            return .status("Grok Bot 前台使用中，稍后自动补读；上次额度已保留。")
        case .throttled:
            return .status("距上次 Grok Bot 自动读取不足 5 分钟，本次沿用上次额度。")
        case .unavailable:
            if !userInitiated { return .status("本次未读到 Grok Bot 头像栏目额度，稍后自动重试；上次额度已保留。") }
            throw MonitorError.message("未能读取 Grok Bot 左下角头像栏目中的「套餐 已用百分比」。请确认已登录且应用窗口可用后重试；上次数据已保留。")
        }
    }

    static func visibleStatus(_ account: Account, now: Date = Date()) -> String? {
        guard isUsageRoute(account), let reading = account.grokBotManualReading else { return account.statusNote }
        return GrokBotUsageReport.statusLine(reading, now: now, timeZone: .current)
    }
}
