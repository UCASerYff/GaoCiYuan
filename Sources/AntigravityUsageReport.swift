import Foundation

enum AntigravityUsageReport {
    static let maxBytes = 65_536
    static let manualHint = "请在账户设置导入 Antigravity 额度报告。"
    static let standaloneGuide = "https://antigravity.google/docs/cli/commands/usage"
    static let embeddedGuide = "https://support.google.com/gemini/answer/18755601"

    enum Source {
        case embedded, standalone

        var title: String {
            switch self {
            case .embedded: return UsageSnapshot.embeddedAntigravityManualSource
            case .standalone: return UsageSnapshot.standaloneAntigravityManualSource
            }
        }
    }

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

    private static let percent = try! NSRegularExpression(pattern: #"^(?:[░▒▓█■□━─]+\s*)?([0-9]{1,3}(?:\.[0-9]{1,6})?)\s*%$"#)
    private static let ansiColor = try! NSRegularExpression(pattern: "\u{001B}\\[[0-9;:]*m")
    private static let cellEdges = CharacterSet(charactersIn: "│┃|\u{FEFF}").union(.whitespaces)
    private static let border = CharacterSet(charactersIn: "╭╮╰╯┌┐└┘├┤┬┴┼┏┓┗┛━─═+ -")

    static func parse(_ data: Data, source: Source, importedAt: Date = Date()) throws -> UsageSnapshot {
        guard let plain = decoded(data) else { throw invalidReport }
        var pool: Pool?
        var pendingWindow: Window?
        var quotas: [String: Quota] = [:]
        var seen: Set<String> = []
        for raw in plain.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: cellEdges)
            if line.isEmpty || (line != "-" && line.unicodeScalars.allSatisfy { border.contains($0) }) { continue }
            let lower = line.lowercased()
            if let heading = Pool.allCases.first(where: { lower == $0.title.lowercased() || lower == $0.title.lowercased() + ":" }) {
                guard pendingWindow == nil else { throw invalidReport }
                pool = heading
                continue
            }
            guard let currentPool = pool else { continue }
            if let window = Window.allCases.first(where: { window in
                let label = window.label.lowercased()
                guard lower.hasPrefix(label) else { return false }
                return lower.dropFirst(label.count).first.map { $0.isWhitespace || ":│┃|".contains($0) } ?? true
            }) {
                guard pendingWindow == nil else { throw invalidReport }
                let value = String(line.dropFirst(window.label.count)).trimmingCharacters(in: cellEdges)
                if value.isEmpty || value == ":" {
                    pendingWindow = window
                } else {
                    let value = value.hasPrefix(":") ? String(value.dropFirst()).trimmingCharacters(in: cellEdges) : value
                    try add(value, pool: currentPool, window: window, seen: &seen, to: &quotas)
                }
            } else if let window = pendingWindow {
                try add(line, pool: currentPool, window: window, seen: &seen, to: &quotas)
                pendingWindow = nil
            } else {
                // A different heading may introduce another pool. Do not lend it the previous pool's identity.
                pool = nil
            }
        }
        guard pendingWindow == nil, !quotas.isEmpty else { throw invalidReport }
        var snapshot = UsageSnapshot.empty(source: source.title)
        snapshot.observedAt = importedAt
        snapshot.quotas = Pool.allCases.flatMap { pool in Window.allCases.compactMap { quotas[id(pool, $0)] } }
        snapshot.isUnverifiedAntigravityReport = true
        snapshot.note = "账号、观测时间与重置时刻未经核实。仅供历史参考。"
        try snapshot.validate()
        return snapshot
    }

    private static func add(_ text: String, pool: Pool, window: Window, seen: inout Set<String>, to quotas: inout [String: Quota]) throws {
        let key = id(pool, window)
        guard seen.insert(key).inserted else { throw invalidReport }
        if ["n/a", "unknown", "unavailable", "—", "-"].contains(text.lowercased()) { return }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = percent.firstMatch(in: text, range: range), let value = Range(match.range(at: 1), in: text),
              let remaining = Double(text[value]), (0...100).contains(remaining) else { throw invalidReport }
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
