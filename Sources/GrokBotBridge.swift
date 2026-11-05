import AppKit

/// Desktop discovery is independent of GrokAccountBridge's shared CLI account
/// pool. Installation or a running process is not a measured usage snapshot.
enum GrokBotBridge {
    static func status(installed: Bool, running: Bool) -> String {
        if running {
            return "已检测到 Grok Bot（运行中）。尚无可读取用量，等待记录。"
        }
        if installed {
            return "已检测到 Grok Bot（未启动）。尚无可读取用量，等待记录。"
        }
        return "尚未检测到 Grok Bot。安装或启动后会自动重新检测；等待可读取的用量记录。"
    }

    static func fetch() -> ConnectorResult {
        let apps = NSWorkspace.shared.runningApplications
        let running = MemberDiscovery.isAgentRunning(.grok, in: apps)
        let installed = MemberDiscovery.isAgentInstalled(.grok, in: apps)
        return .status(status(installed: installed, running: running))
    }
}
