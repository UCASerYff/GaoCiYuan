import Foundation

enum AntigravityUsageReport {
    static let maxBytes = 65_536
    static let embeddedSource = "Gemini App 中的 Antigravity · /usage"
    static let importedSource = "Antigravity /usage 手动报告"
    static let manualHint = "请在 Gemini 的 Antigravity 或官方 Antigravity CLI 中运行 /usage。可在账户设置导入额度报告。"

    private enum Pool: String, CaseIterable {
        case gemini = "gemini-models"
        case claudeAndGPT = "claude-gpt-models"

        var title: String {
            switch self {
            case .gemini: return "Gemini Models"
            case .claudeAndGPT: return "Claude and GPT models"
            }
        }
    }

    private enum Window: String, CaseIterable {
        case fiveHour = "five-hour"
        case weekly = "weekly"

        var label: String { self == .fiveHour ? "Five Hour Limit Remaining" : "Weekly Limit Remaining" }
        var title: String { self == .fiveHour ? "5 小时" : "每周" }
        var seconds: Double { self == .fiveHour ? 18_000 : 604_800 }
    }

    private static let percent = try! NSRegularExpression(pattern: #"^([0-9]{1,3}(?:\.[0-9]+)?)\s*%$"#)
    private static let ansiColor = try! NSRegularExpression(pattern: "\u{001B}\\[[0-9;]*m")

    static func supportsHeadlessUsage(_ help: Data) -> Bool {
        guard let text = decoded(help), text.contains("--prompt") else { return false }
        return text.range(of: #"(?m)^[ \t]*/usage(?:[ \t]|$)"#, options: .regularExpression) != nil
    }

    static func parse(_ data: Data, source: String, observedAt: Date) throws -> UsageSnapshot {
        guard let plain = decoded(data) else { throw invalidReport }
        var pool: Pool?
        var pendingWindow: Window?
        var quotas: [String: Quota] = [:]
        for raw in plain.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "│ ").union(.whitespaces))
            if line.isEmpty { continue }
            let lower = line.lowercased()
            if let heading = Pool.allCases.first(where: { lower == $0.title.lowercased() || lower == $0.title.lowercased() + ":" }) {
                guard pendingWindow == nil else { throw invalidReport }
                pool = heading
                continue
            }
            guard let currentPool = pool else { continue }
            if let window = Window.allCases.first(where: { lower.hasPrefix($0.label.lowercased()) }) {
                guard pendingWindow == nil else { throw invalidReport }
                let value = String(line.dropFirst(window.label.count)).trimmingCharacters(in: .whitespaces)
                if value.isEmpty || value == ":" {
                    pendingWindow = window
                } else {
                    let value = value.hasPrefix(":") ? String(value.dropFirst()).trimmingCharacters(in: .whitespaces) : value
                    try add(value, pool: currentPool, window: window, to: &quotas)
                }
            } else if let window = pendingWindow {
                try add(line, pool: currentPool, window: window, to: &quotas)
                pendingWindow = nil
            } else {
                // A different heading may introduce another pool. Do not lend it the previous pool's identity.
                pool = nil
            }
        }
        guard pendingWindow == nil, !quotas.isEmpty else { throw invalidReport }
        var snapshot = UsageSnapshot.empty(source: source)
        snapshot.observedAt = observedAt
        snapshot.quotas = Pool.allCases.flatMap { pool in Window.allCases.compactMap { quotas[id(pool, $0)] } }
        snapshot.note = "额度按 /usage 报告中的模型组共享。当前登录账号和重置时刻可在 Antigravity 中核对。"
        try snapshot.validate()
        return snapshot
    }

    private static func add(_ text: String, pool: Pool, window: Window, to quotas: inout [String: Quota]) throws {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = percent.firstMatch(in: text, range: range), let value = Range(match.range(at: 1), in: text),
              let remaining = Double(text[value]), (0...100).contains(remaining) else { throw invalidReport }
        let key = id(pool, window)
        guard quotas[key] == nil else { throw invalidReport }
        quotas[key] = Quota(id: key, title: "\(pool.title) · \(window.title)", usedPercent: 100 - remaining,
                            resetsAt: nil, windowSeconds: window.seconds)
    }

    private static func id(_ pool: Pool, _ window: Window) -> String { "antigravity-\(pool.rawValue)-\(window.rawValue)" }

    private static func decoded(_ data: Data) -> String? {
        guard data.count <= maxBytes, let text = String(data: data, encoding: .utf8) else { return nil }
        return ansiColor.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    private static var invalidReport: MonitorError {
        .message("未读到可确认的 Antigravity 模型组和剩余额度。上次读数已保留。")
    }
}
