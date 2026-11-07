import CoreFoundation
import Foundation

/// Read-only ingestion for a future Grok Bot usage report.
///
/// Grok Bot's own Usage & Billing view is human-readable text. This type does
/// not scrape that view, does not read Cursor or Grok Bot private stores, and
/// does not call a usage endpoint. Nothing here writes the file or schedules a
/// refresh; the account refresh that already exists is what calls `load`.
///
/// Contract, under the home directory:
/// `Library/Application Support/GaoSeries/Token/grokbot-usage.json`
///
/// ```
/// {
///   "schema": 1,
///   "source": "grok-bot-usage-report",
///   "capturedAt": "2026-11-07T01:12:00Z",
///   "plan": "Premium",
///   "weeklyPercentUsed": 19.3,
///   "resetsAt": "2026-11-09T01:00:00Z",
///   "sharedWithOtherApps": true
/// }
/// ```
///
/// `resetsAt` may be JSON null. `weeklyPercentUsed` is the included-usage
/// percent already consumed (0...100), not a remaining amount. On-demand spend
/// is absent: the in-app figure mixes Grok Bot and Cursor, and this contract
/// does not record it. A missing or invalid file is a status, never 0%.
enum GrokBotUsageReport {
    static let schemaVersion = 1
    static let sourceIdentifier = "grok-bot-usage-report"
    static let fileName = "grokbot-usage.json"
    /// A captured report older than this is not a current reading.
    static let staleAfter: TimeInterval = 6 * 60 * 60
    /// `capturedAt` may sit this far ahead of the local clock.
    static let futureSkew: TimeInterval = 60
    static let maximumBytes = 64 * 1024
    static let maximumPlanLength = 64

    struct Snapshot: Equatable {
        var plan: String
        var weeklyPercentUsed: Double
        var resetsAt: Date?
        var capturedAt: Date
        var sharedWithOtherApps: Bool
    }

    enum Freshness: Equatable {
        case current
        case olderThanLimit
        case resetElapsed
    }

    struct Reading: Equatable {
        var snapshot: Snapshot
        var freshness: Freshness
        /// Display line for a current reading. A reset that has already passed
        /// must not be shown with this line: it still says 本周.
        var line: String
        var capturedText: String
    }

    enum Rejection: Equatable, Error {
        case missing
        case unreadable
        case tooLarge
        case invalid(String)
    }

    static func contractFileURL(home: URL) -> URL {
        home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("GaoSeries", isDirectory: true)
            .appendingPathComponent("Token", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static func defaultFileURL(homePath: String = NSHomeDirectory()) -> URL {
        contractFileURL(home: URL(fileURLWithPath: homePath, isDirectory: true))
    }

    static func ingest(_ data: Data, now: Date, timeZone: TimeZone) -> Result<Reading, Rejection> {
        guard data.count <= maximumBytes else { return .failure(.tooLarge) }
        guard !data.isEmpty else { return .failure(.invalid("文件为空")) }
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data) }
        catch { return .failure(.invalid("不是 JSON 对象")) }
        guard let object = root as? [String: Any] else { return .failure(.invalid("不是 JSON 对象")) }
        let keys = Set(object.keys)
        let required: Set<String> = ["schema", "source", "capturedAt", "plan", "weeklyPercentUsed", "resetsAt", "sharedWithOtherApps"]
        guard keys == required else { return .failure(.invalid(keys.isSuperset(of: required) ? "含有未约定的字段" : "缺少约定字段")) }
        // JSON numbers do not keep a difference between 1 and 1.0 after parsing.
        // The raw token must be an integer so a fractional schema cannot pass.
        guard schemaTokenAccepted(data), jsonExactInteger(object["schema"]) == schemaVersion else {
            return .failure(.invalid("schema 必须为整数 1"))
        }
        guard object["source"] as? String == sourceIdentifier else { return .failure(.invalid("source 必须为 grok-bot-usage-report")) }
        guard let capturedText = object["capturedAt"] as? String, let capturedAt = parseDate(capturedText) else {
            return .failure(.invalid("capturedAt 必须为 ISO 8601 时间"))
        }
        guard capturedAt <= now.addingTimeInterval(futureSkew) else { return .failure(.invalid("capturedAt 晚于当前时间")) }
        guard let plan = normalizedPlan(object["plan"]) else { return .failure(.invalid("plan 为空或含控制字符")) }
        guard let used = jsonFiniteNumber(object["weeklyPercentUsed"]), (0...100).contains(used) else {
            return .failure(.invalid("weeklyPercentUsed 必须为 0 到 100 的数字"))
        }
        let resetsAt: Date?
        if object["resetsAt"] is NSNull {
            resetsAt = nil
        } else if let text = object["resetsAt"] as? String, let date = parseDate(text) {
            resetsAt = date
        } else {
            return .failure(.invalid("resetsAt 必须为 ISO 8601 时间或 null"))
        }
        guard let shared = jsonBool(object["sharedWithOtherApps"]) else {
            return .failure(.invalid("sharedWithOtherApps 必须为布尔值"))
        }
        let snapshot = Snapshot(plan: plan, weeklyPercentUsed: used, resetsAt: resetsAt, capturedAt: capturedAt, sharedWithOtherApps: shared)
        let capturedLabel = formatTimestamp(capturedAt, timeZone: timeZone)
        let reading = Reading(
            snapshot: snapshot,
            freshness: freshness(of: snapshot, now: now),
            line: displayLine(snapshot, timeZone: timeZone),
            capturedText: capturedLabel)
        return .success(reading)
    }

    /// Age wins only while the recorded window is still open. A passed reset
    /// means the percent belongs to the previous window.
    static func freshness(of snapshot: Snapshot, now: Date) -> Freshness {
        if let resetsAt = snapshot.resetsAt, resetsAt <= now { return .resetElapsed }
        if now.timeIntervalSince(snapshot.capturedAt) > staleAfter { return .olderThanLimit }
        return .current
    }

    static func displayLine(_ snapshot: Snapshot, timeZone: TimeZone) -> String {
        let share = snapshot.sharedWithOtherApps ? "（与套餐内其他应用共享）" : ""
        let reset = snapshot.resetsAt.map { formatTimestamp($0, timeZone: timeZone) } ?? "平台未提供重置时间"
        let captured = formatTimestamp(snapshot.capturedAt, timeZone: timeZone)
        return "本周已用 \(percentText(snapshot.weeklyPercentUsed))%\(share) · 重置 \(reset) · 数据 \(captured)"
    }

    /// User-facing sentence. Current reports use the display line. Stale and
    /// reset reports say so and never describe themselves as live.
    static func presentation(_ reading: Reading) -> String {
        switch reading.freshness {
        case .current:
            return reading.line
        case .olderThanLimit:
            return "用量报告已超过 6 小时，不作为当前读数。记录：\(reading.line)"
        case .resetElapsed:
            return "用量报告的重置时间已过，不作为本周读数。数据 \(reading.capturedText)"
        }
    }

    static func discoveryStatus(installed: Bool, running: Bool) -> String {
        if running { return "已检测到 Grok Bot（运行中）。尚无可读取用量，等待记录。" }
        if installed { return "已检测到 Grok Bot（未启动）。尚无可读取用量，等待记录。" }
        return "尚未检测到 Grok Bot。安装或启动后会自动重新检测；等待可读取的用量记录。"
    }

    static func connectorStatus(_ result: Result<Reading, Rejection>, installed: Bool, running: Bool) -> String {
        switch result {
        case .success(let reading):
            return presentation(reading)
        case .failure(.missing):
            return discoveryStatus(installed: installed, running: running)
        case .failure(let rejection):
            return presencePrefix(installed: installed, running: running) + unavailablePhrase(rejection)
        }
    }

    static func presencePrefix(installed: Bool, running: Bool) -> String {
        if running { return "已检测到 Grok Bot（运行中）。" }
        if installed { return "已检测到 Grok Bot（未启动）。" }
        return "尚未检测到 Grok Bot。"
    }

    static func unavailablePhrase(_ rejection: Rejection) -> String {
        switch rejection {
        case .missing:
            return ""
        case .unreadable:
            return "用量记录无法读取，未显示百分比。"
        case .tooLarge:
            return "用量记录超出大小限制，未显示百分比。"
        case .invalid:
            return "用量记录不符合 grokbot-usage.json 约定，未显示百分比。"
        }
    }

    static func percentText(_ value: Double) -> String {
        let scaled = (value * 10_000).rounded() / 10_000
        var text = String(format: "%.4f", scaled)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Weekday names are fixed so the Chinese display line does not depend on
    /// the host's locale data. The clock is the supplied time zone.
    static func formatTimestamp(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.weekday, .month, .day, .hour, .minute], from: date)
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let weekday = names.indices.contains((parts.weekday ?? 0) - 1) ? names[(parts.weekday ?? 1) - 1] : ""
        return "\(weekday) \(parts.month ?? 0)月\(parts.day ?? 0)日 \(String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0))"
    }

    private static func normalizedPlan(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let plan = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plan.isEmpty, plan.count <= maximumPlanLength else { return nil }
        guard plan.unicodeScalars.allSatisfy({ !$0.properties.isJoinControl && !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return plan
    }

    private static func parseDate(_ text: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        if let date = parser.date(from: text) { return date }
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: text)
    }

    /// Top-level `schema` must be the integer token `1`. A fractional token is
    /// rejected even though JSON numbers collapse `1` and `1.0` after parsing.
    /// The scan stays outside strings, so a plan name can mention the word.
    private static func schemaTokenAccepted(_ data: Data) -> Bool {
        guard let token = topLevelToken(data, key: "schema") else { return false }
        return token == "1"
    }

    private static func topLevelToken(_ data: Data, key: String) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let chars = Array(text)
        var index = 0
        var depth = 0
        while index < chars.count {
            let character = chars[index]
            if character == "\"" {
                let literal = readJSONString(chars, from: &index)
                if depth == 1, literal == key {
                    while index < chars.count, chars[index].isWhitespace { index += 1 }
                    guard index < chars.count, chars[index] == ":" else { return nil }
                    index += 1
                    while index < chars.count, chars[index].isWhitespace { index += 1 }
                    let start = index
                    while index < chars.count {
                        let next = chars[index]
                        if next == "," || next == "}" || next == "]" || next.isWhitespace { break }
                        index += 1
                    }
                    return String(chars[start..<index])
                }
                continue
            }
            if character == "{" || character == "[" { depth += 1 }
            else if character == "}" || character == "]" { depth -= 1 }
            index += 1
        }
        return nil
    }

    private static func readJSONString(_ chars: [Character], from index: inout Int) -> String {
        var value = ""
        index += 1
        var escape = false
        while index < chars.count {
            let character = chars[index]
            if escape {
                value.append(character)
                escape = false
            } else if character == "\\" {
                escape = true
            } else if character == "\"" {
                index += 1
                return value
            } else {
                value.append(character)
            }
            index += 1
        }
        return value
    }

    private static func jsonBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func jsonExactInteger(_ value: Any?) -> Int? {
        guard let number = jsonFiniteNumber(value) else { return nil }
        guard number.rounded() == number, number >= Double(Int.min), number <= Double(Int.max) else { return nil }
        return Int(number)
    }

    private static func jsonFiniteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite else { return nil }
        return double
    }
}

protocol GrokBotUsageSnapshotProviding {
    func load(now: Date) -> Result<GrokBotUsageReport.Reading, GrokBotUsageReport.Rejection>
}

/// Reads one JSON file. It does not create directories, write bytes, or watch the path.
struct GrokBotUsageFileProvider: GrokBotUsageSnapshotProviding {
    var fileURL: URL
    var maximumBytes: Int
    var timeZone: TimeZone
    var read: (URL) throws -> Data

    init(fileURL: URL = GrokBotUsageReport.defaultFileURL(),
         maximumBytes: Int = GrokBotUsageReport.maximumBytes,
         timeZone: TimeZone = .current,
         read: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) }) {
        self.fileURL = fileURL
        self.maximumBytes = maximumBytes
        self.timeZone = timeZone
        self.read = read
    }

    func load(now: Date) -> Result<GrokBotUsageReport.Reading, GrokBotUsageReport.Rejection> {
        var directory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &directory) else {
            return .failure(.missing)
        }
        if directory.boolValue { return .failure(.invalid("路径是目录")) }
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        guard let size else { return .failure(.unreadable) }
        if size > maximumBytes { return .failure(.tooLarge) }
        let data: Data
        do { data = try read(fileURL) }
        catch { return .failure(.unreadable) }
        if data.count > maximumBytes { return .failure(.tooLarge) }
        return GrokBotUsageReport.ingest(data, now: now, timeZone: timeZone)
    }
}
