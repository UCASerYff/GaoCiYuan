import Foundation

enum AntigravityUsageReport {
    static let maxBytes = 65_536
    static let manualHint = "请在账户设置手工记录或导入额度。"
    static let standaloneGuide = "https://antigravity.google/docs/cli/commands/usage"
    static let embeddedGuide = "https://support.google.com/gemini/answer/18755601"

    enum ManualWindow: String, CaseIterable {
        case unspecified = "未注明"
        case fiveHour = "5 小时"
        case weekly = "每周"

        var seconds: Double? {
            switch self {
            case .unspecified: return nil
            case .fiveHour: return 18_000
            case .weekly: return 604_800
            }
        }
    }

    struct ManualQuota: Identifiable {
        let id = UUID()
        var title = ""
        var remaining = ""
        var window: ManualWindow = .unspecified
    }

    static let manualQuotaLimit = 4
    private static let maxCLIBuckets = 64

    // This is the CLI's print-mode command envelope, separate from TUI statusline JSON.
    private struct CLIReport: Decodable {
        struct Command: Decodable {
            struct ReportData: Decodable { let groups: [Group] }
            let name: String
            let data: ReportData
        }
        struct Group: Decodable {
            let name: String
            let buckets: [Bucket]
        }
        struct Bucket: Decodable {
            let id: String
            let window: String?
            let remaining_fraction: Double?
            let reset_time: String?
            let disabled: Bool?
        }
        let conversation_id: String
        let status: String
        let num_turns: Int
        let usage: [String: Int]
        let command: Command
        let error: String?
        let finished_reason: String?
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
    private static let bucketID = try! NSRegularExpression(pattern: #"\A[A-Za-z0-9][A-Za-z0-9._-]{0,79}\z"#)
    private static let tokenKeys: Set<String> = ["input_tokens", "output_tokens", "thinking_tokens", "cache_read_tokens", "total_tokens"]
    private static let standardGroups = ["gemini-5h": "Gemini Models", "gemini-weekly": "Gemini Models",
                                         "3p-5h": "Claude and GPT models", "3p-weekly": "Claude and GPT models"]

    static func parseStandalone(_ data: Data, importedAt: Date = Date()) throws -> UsageSnapshot {
        guard data.count <= maxBytes, let text = String(data: data, encoding: .utf8) else { throw invalidReport }
        let plain = text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}").union(.whitespacesAndNewlines))
        if plain.first == "{" { return try parseCLIReport(Data(plain.utf8), importedAt: importedAt) }
        return try parseText(plain, importedAt: importedAt)
    }

    static func recordEmbedded(_ entries: [ManualQuota], importedAt: Date = Date()) throws -> UsageSnapshot {
        guard !entries.isEmpty, entries.count <= manualQuotaLimit else { throw invalidReport }
        var quotas: [Quota] = []
        for (index, entry) in entries.enumerated() {
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = entry.remaining.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty && value.isEmpty { continue }
            guard validTitle(title), let remaining = Double(value), (0...100).contains(remaining) else {
                throw MonitorError.message("请填写额度名称和 0 到 100 的剩余百分比。")
            }
            let caption = entry.window == .unspecified ? title : "\(title) · \(entry.window.rawValue)"
            quotas.append(Quota(id: "gemini-manual-\(index)", title: caption, usedPercent: 100 - remaining,
                                resetsAt: nil, windowSeconds: entry.window.seconds))
        }
        return try historical(quotas, source: UsageSnapshot.embeddedAntigravityEntrySource, importedAt: importedAt)
    }

    private static func parseCLIReport(_ data: Data, importedAt: Date) throws -> UsageSnapshot {
        guard let report = try? JSONDecoder().decode(CLIReport.self, from: data),
              report.status == "SUCCESS", report.conversation_id.isEmpty, report.num_turns == 0,
              report.error == nil, report.finished_reason == nil, report.command.name == "usage",
              tokenKeys.isSubset(of: report.usage.keys), report.usage.values.allSatisfy({ $0 == 0 }),
              report.command.data.groups.count <= maxCLIBuckets else {
            throw MonitorError.message("请选择独立 Antigravity CLI 的 /usage JSON 输出。")
        }
        var quotas: [Quota] = []
        var seen: Set<String> = []
        for group in report.command.data.groups {
            let groupName = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard validTitle(groupName) else { throw invalidReport }
            for bucket in group.buckets {
                let idRange = NSRange(bucket.id.startIndex..., in: bucket.id)
                guard seen.count < maxCLIBuckets, bucketID.firstMatch(in: bucket.id, range: idRange) != nil,
                      seen.insert(bucket.id).inserted else {
                    throw invalidReport
                }
                if bucket.disabled == true || bucket.remaining_fraction == nil { continue }
                let window: Window
                switch bucket.window ?? "" {
                case "5h": window = .fiveHour
                case "weekly": window = .weekly
                default: continue
                }
                if let expected = standardGroups[bucket.id] {
                    guard expected.caseInsensitiveCompare(groupName) == .orderedSame,
                          (bucket.id.hasSuffix("-5h") && window == .fiveHour) || (bucket.id.hasSuffix("-weekly") && window == .weekly) else {
                        throw invalidReport
                    }
                }
                guard let remaining = bucket.remaining_fraction, (0...1).contains(remaining) else { throw invalidReport }
                let reset = try bucket.reset_time.map(parseReset)
                quotas.append(Quota(id: bucket.id, title: "\(groupName) · \(window.title)", usedPercent: (1 - remaining) * 100,
                                    resetsAt: reset, windowSeconds: window.seconds))
            }
        }
        return try historical(quotas, source: UsageSnapshot.standaloneAntigravityJSONSource, importedAt: importedAt)
    }

    private static func parseReset(_ text: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let reset = formatter.date(from: text) { return reset }
        formatter.formatOptions = [.withInternetDateTime]
        guard let reset = formatter.date(from: text) else { throw invalidReport }
        return reset
    }

    private static func validTitle(_ title: String) -> Bool {
        !title.isEmpty && title.count <= 80 && !title.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func parseText(_ text: String, importedAt: Date) throws -> UsageSnapshot {
        let plain = ansiColor.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
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
        guard pendingWindow == nil else { throw invalidReport }
        let ordered = Pool.allCases.flatMap { pool in Window.allCases.compactMap { quotas[id(pool, $0)] } }
        return try historical(ordered, source: UsageSnapshot.standaloneAntigravityManualSource, importedAt: importedAt)
    }

    private static func historical(_ quotas: [Quota], source: String, importedAt: Date) throws -> UsageSnapshot {
        guard !quotas.isEmpty else { throw invalidReport }
        var snapshot = UsageSnapshot.empty(source: source)
        snapshot.observedAt = importedAt
        snapshot.quotas = quotas
        snapshot.isUnverifiedAntigravityReport = true
        snapshot.note = "来源、账号与观测时间未经核实。仅供历史参考。"
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

    private static var invalidReport: MonitorError {
        .message("未读到可确认的 Antigravity 模型组和剩余额度。上次读数已保留。")
    }
}
