import AppKit

/// Desktop discovery is independent of GrokAccountBridge's shared CLI account
/// pool. Installation or a running process is not a measured usage snapshot.
/// The only numeric reading is a validated grokbot-usage.json report.
enum GrokBotBridge {
    static func status(installed: Bool, running: Bool) -> String {
        GrokBotUsageReport.discoveryStatus(installed: installed, running: running)
    }

    static func isUsageRoute(_ account: Account) -> Bool {
        account.provider == .grok && account.kind == .agent && account.connection == .agentLocal
    }

    static func fetch(now: Date = Date(), userInitiated: Bool = false, provider: GrokBotUsageSnapshotProviding = GrokBotUsageFileProvider()) -> ConnectorResult {
        let apps = NSWorkspace.shared.runningApplications
        let running = MemberDiscovery.isAgentRunning(.grok, in: apps)
        let installed = MemberDiscovery.isAgentInstalled(.grok, in: apps)
        // Periodic refresh keeps the installed/running sentence already shown.
        // It does not open the snapshot, so a manual reading is not replaced.
        guard GrokBotUsageReport.shouldReadOnRefresh(userInitiated: userInitiated) else {
            return .status(status(installed: installed, running: running))
        }
        switch provider.load(now: now) {
        case .success(let reading):
            return .grokBotManual(status: GrokBotUsageReport.presentation(reading), reading: GrokBotUsageReport.manualReading(reading))
        case .failure(let rejection):
            let text = GrokBotUsageReport.connectorStatus(.failure(rejection), installed: installed, running: running)
            return .grokBotManual(status: text, reading: nil)
        }
    }

    static func visibleStatus(_ account: Account, now: Date = Date()) -> String? {
        guard isUsageRoute(account), let reading = account.grokBotManualReading else { return account.statusNote }
        return GrokBotUsageReport.statusLine(reading, now: now, timeZone: .current)
    }
}
