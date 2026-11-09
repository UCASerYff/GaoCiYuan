import CoreFoundation
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Shared remaining-percent presentation and legacy snapshot decoding.
/// New readings come from GrokBotAX's avatar menu, not this legacy JSON file.
/// Nothing here reads private stores, calls a usage endpoint, or schedules refresh.
///
/// Legacy contract, under the home directory:
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
        var remainingLine: String
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

    static func manualButtonTitle(refreshing: Bool) -> String {
        refreshing ? "正在读取本机额度…" : "读取本机额度"
    }

    static func ingest(_ data: Data, now: Date, timeZone: TimeZone) -> Result<Reading, Rejection> {
        guard data.count <= maximumBytes else { return .failure(.tooLarge) }
        guard !data.isEmpty else { return .failure(.invalid("文件为空")) }
        let tokens: [String: String]
        switch scanTopLevel(data) {
        case .failure(let rejection): return .failure(rejection)
        case .success(let found): tokens = found
        }
        if let usedToken = tokens["weeklyPercentUsed"], !usedTokenIsJSONNumber(usedToken) {
            return .failure(.invalid("weeklyPercentUsed 必须为 0 到 100 的数字"))
        }
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data) }
        catch { return .failure(.invalid("不是 JSON 对象")) }
        guard let object = root as? [String: Any] else { return .failure(.invalid("不是 JSON 对象")) }
        let keys = Set(object.keys)
        let required: Set<String> = ["schema", "source", "capturedAt", "plan", "weeklyPercentUsed", "resetsAt", "sharedWithOtherApps"]
        guard keys == required else { return .failure(.invalid(keys.isSuperset(of: required) ? "含有未约定的字段" : "缺少约定字段")) }
        // JSON numbers do not keep a difference between 1 and 1.0 after parsing.
        // The raw token must be an integer so a fractional schema cannot pass.
        guard tokens["schema"] == "1", jsonExactInteger(object["schema"]) == schemaVersion else {
            return .failure(.invalid("schema 必须为整数 1"))
        }
        guard object["source"] as? String == sourceIdentifier else { return .failure(.invalid("source 必须为 grok-bot-usage-report")) }
        guard let capturedText = object["capturedAt"] as? String, let capturedAt = parseDate(capturedText) else {
            return .failure(.invalid("capturedAt 必须为 ISO 8601 时间"))
        }
        guard capturedAt <= now.addingTimeInterval(futureSkew) else { return .failure(.invalid("capturedAt 晚于当前时间")) }
        guard let plan = normalizedPlan(object["plan"]) else { return .failure(.invalid("plan 为空或含控制字符")) }
        guard let usedToken = tokens["weeklyPercentUsed"], usedTokenIsJSONNumber(usedToken),
              let used = jsonFiniteNumber(object["weeklyPercentUsed"]), (0...100).contains(used) else {
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
            remainingLine: remainingDisplayLine(snapshot, timeZone: timeZone),
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

    static func remainingPercent(used: Double) -> Double {
        max(0, min(100, 100 - used))
    }

    static func displayLine(_ snapshot: Snapshot, timeZone: TimeZone) -> String {
        let share = snapshot.sharedWithOtherApps ? "（与套餐内其他应用共享）" : ""
        let reset = snapshot.resetsAt.map { formatTimestamp($0, timeZone: timeZone) } ?? "平台未提供重置时间"
        let captured = formatTimestamp(snapshot.capturedAt, timeZone: timeZone)
        return "本周已用 \(percentText(snapshot.weeklyPercentUsed))%\(share) · 重置 \(reset) · 数据 \(captured)"
    }

    static func remainingDisplayLine(_ snapshot: Snapshot, timeZone: TimeZone) -> String {
        let remaining = percentText(remainingPercent(used: snapshot.weeklyPercentUsed))
        let used = percentText(snapshot.weeklyPercentUsed)
        let share = snapshot.sharedWithOtherApps ? "（与套餐内其他应用共享）" : ""
        let reset = snapshot.resetsAt.map { formatTimestamp($0, timeZone: timeZone) } ?? "平台未提供重置时间"
        let captured = formatTimestamp(snapshot.capturedAt, timeZone: timeZone)
        return "本周剩余 \(remaining)%（已用 \(used)%）\(share) · 重置 \(reset) · 数据 \(captured)"
    }

    /// Current reports lead with remaining percent and retain the source used
    /// percent. Stale and reset reports remain historical records, never live.
    static func presentation(_ reading: Reading) -> String {
        let lead = "读取最近一次快照（采集于 \(reading.capturedText)）"
        switch reading.freshness {
        case .current:
            return "\(lead) · \(reading.remainingLine)"
        case .olderThanLimit:
            return "\(lead) · 已超过 6 小时，不作为当前读数 · 记录：\(reading.line)"
        case .resetElapsed:
            return "\(lead) · 重置时间已过，不作为本周读数 · 记录：\(reading.line)"
        }
    }

    enum ManualSource: String, Codable {
        case legacySnapshot
        case avatarMenu
    }

    /// Last successful avatar read (or legacy file read). This is not a `UsageSnapshot`:
    /// it never enters history or `displayQuotas`. New optional fields preserve old archives.
    struct ManualReading: Codable, Equatable {
        var weeklyPercentUsed: Double
        var capturedAt: Date
        var resetsAt: Date?
        var sharedWithOtherApps: Bool
        var plan: String? = nil
        var source: ManualSource? = nil
    }

    struct RingFace: Equatable {
        var showsDash: Bool
        var remainingPercent: Double?
        /// 0 when there is no reading. Otherwise the remaining fraction.
        var fill: Double
        var stale: Bool
        var label: String
        var help: String
    }

    static func manualReading(_ reading: Reading) -> ManualReading {
        ManualReading(weeklyPercentUsed: reading.snapshot.weeklyPercentUsed, capturedAt: reading.snapshot.capturedAt, resetsAt: reading.snapshot.resetsAt, sharedWithOtherApps: reading.snapshot.sharedWithOtherApps, plan: reading.snapshot.plan, source: .legacySnapshot)
    }

    static func avatarManualReading(plan: String, weeklyPercentUsed: Double, capturedAt: Date) -> ManualReading {
        ManualReading(weeklyPercentUsed: weeklyPercentUsed, capturedAt: capturedAt, resetsAt: nil, sharedWithOtherApps: false, plan: plan, source: .avatarMenu)
    }

    static func statusLine(_ reading: ManualReading, now: Date, timeZone: TimeZone) -> String {
        if reading.source == .avatarMenu {
            let remaining = percentText(remainingPercent(used: reading.weeklyPercentUsed))
            let used = percentText(reading.weeklyPercentUsed)
            let captured = formatTimestamp(reading.capturedAt, timeZone: timeZone)
            return "Grok Bot 头像栏目（采集于 \(captured)） · 额度剩余 \(remaining)%（已用 \(used)%） · 套餐 \(reading.plan ?? "未显示")"
        }
        return presentation(materialize(reading, now: now, timeZone: timeZone))
    }

    /// Nil means this account is not the Grok Bot route, so the generic ring stays in charge.
    static func dedicatedRingFace(isGrokBotRoute: Bool, reading: ManualReading?, now: Date, timeZone: TimeZone) -> RingFace? {
        guard isGrokBotRoute else { return nil }
        guard let reading else {
            return RingFace(showsDash: true, remainingPercent: nil, fill: 0, stale: false, label: "—", help: "尚未读取 Grok Bot 本机额度")
        }
        let made = materialize(reading, now: now, timeZone: timeZone)
        let stale = made.freshness != .current
        let remaining = remainingPercent(used: reading.weeklyPercentUsed)
        let remainingText = percentText(remaining)
        let usedText = percentText(reading.weeklyPercentUsed)
        let label = remainingText + "%"
        let source = reading.source == .avatarMenu ? "本机头像栏目读数" : "快照"
        let help = (stale ? "\(source)已过期，" : "") + "剩余 \(remainingText)%，由已用 \(usedText)% 换算。采集于 \(made.capturedText)。不是实时读数。"
        return RingFace(showsDash: false, remainingPercent: remaining, fill: min(1, max(0, remaining / 100)), stale: stale, label: label, help: help)
    }

    private static func materialize(_ reading: ManualReading, now: Date, timeZone: TimeZone) -> Reading {
        let snapshot = Snapshot(plan: reading.plan ?? "", weeklyPercentUsed: reading.weeklyPercentUsed, resetsAt: reading.resetsAt, capturedAt: reading.capturedAt, sharedWithOtherApps: reading.sharedWithOtherApps)
        return Reading(snapshot: snapshot, freshness: freshness(of: snapshot, now: now), line: displayLine(snapshot, timeZone: timeZone), remainingLine: remainingDisplayLine(snapshot, timeZone: timeZone), capturedText: formatTimestamp(reading.capturedAt, timeZone: timeZone))
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

    /// Top-level tokens, without entering strings. A repeated key is invalid
    /// even when a JSON parser would keep only one of the values.
    private static func scanTopLevel(_ data: Data) -> Result<[String: String], Rejection> {
        guard let text = String(data: data, encoding: .utf8) else { return .failure(.invalid("不是 UTF-8")) }
        let chars = Array(text)
        var index = 0
        var depth = 0
        var tokens: [String: String] = [:]
        while index < chars.count {
            let character = chars[index]
            if character == "\"" {
                let literal = readJSONString(chars, from: &index)
                if depth == 1 {
                    while index < chars.count, chars[index].isWhitespace { index += 1 }
                    guard index < chars.count, chars[index] == ":" else { return .failure(.invalid("不是 JSON 对象")) }
                    index += 1
                    while index < chars.count, chars[index].isWhitespace { index += 1 }
                    guard index < chars.count else { return .failure(.invalid("不是 JSON 对象")) }
                    let start = index
                    if chars[index] == "\"" || chars[index] == "{" || chars[index] == "[" {
                        // Leave strings and nested values for the JSON parser.
                        // The raw token still starts at this character so a
                        // quoted percent cannot pass the number check.
                    }
                    while index < chars.count {
                        let next = chars[index]
                        if next == "\"" && start == index {
                            _ = readJSONString(chars, from: &index)
                            break
                        }
                        if next == "," || next == "}" || next == "]" || next.isWhitespace { break }
                        index += 1
                    }
                    if tokens[literal] != nil { return .failure(.invalid("字段重复")) }
                    tokens[literal] = String(chars[start..<index])
                }
                continue
            }
            if character == "{" || character == "[" { depth += 1 }
            else if character == "}" || character == "]" { depth -= 1 }
            index += 1
        }
        return .success(tokens)
    }

    private static func usedTokenIsJSONNumber(_ token: String) -> Bool {
        token.range(of: #"^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$"#, options: .regularExpression) != nil
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
    var rootURL: URL
    var maximumBytes: Int
    var timeZone: TimeZone
    /// Called after the file descriptor is open and before its bytes are read.
    /// Tests use it to rename or rewrite the file mid-read.
    var afterOpen: (() -> Void)?
    /// When set, replaces the byte read. Path checks still run first, so a
    /// symlink that leaves `rootURL` never reaches this closure.
    var read: ((URL) throws -> Data)?

    init(fileURL: URL = GrokBotUsageReport.defaultFileURL(),
         rootURL: URL? = nil,
         maximumBytes: Int = GrokBotUsageReport.maximumBytes,
         timeZone: TimeZone = .current,
         afterOpen: (() -> Void)? = nil,
         read: ((URL) throws -> Data)? = nil) {
        self.fileURL = fileURL
        self.rootURL = rootURL ?? fileURL.deletingLastPathComponent()
        self.maximumBytes = maximumBytes
        self.timeZone = timeZone
        self.afterOpen = afterOpen
        self.read = read
    }

    func load(now: Date) -> Result<GrokBotUsageReport.Reading, GrokBotUsageReport.Rejection> {
        let located: String
        switch GrokBotUsageFileAccess.locate(fileURL, root: rootURL) {
        case .failure(let rejection): return .failure(rejection)
        case .success(let value): located = value
        }
        let data: Data
        if let read {
            do { data = try read(URL(fileURLWithPath: located)) }
            catch { return .failure(.unreadable) }
        } else {
            switch GrokBotUsageFileAccess.readStable(located, maximumBytes: maximumBytes, afterOpen: afterOpen) {
            case .failure(let rejection): return .failure(rejection)
            case .success(let value): data = value
            }
        }
        if data.count > maximumBytes { return .failure(.tooLarge) }
        return GrokBotUsageReport.ingest(data, now: now, timeZone: timeZone)
    }
}

enum GrokBotUsageFileAccess {
    /// Opens `file` without following a symlink that resolves outside `root`.
    static func locate(_ file: URL, root: URL) -> Result<String, GrokBotUsageReport.Rejection> {
        let path = file.path
        guard let info = posixStat(path, follow: false) else {
            return errno == ENOENT ? .failure(.missing) : .failure(.unreadable)
        }
        let linked = isType(info, S_IFLNK)
        let candidate: String
        if linked {
            guard let resolved = resolve(path) else { return .failure(.unreadable) }
            guard pathIsInside(resolved, root: root) else { return .failure(.invalid("符号链接指向数据目录之外")) }
            candidate = resolved
        } else {
            guard pathIsInside(path, root: root) else { return .failure(.invalid("符号链接指向数据目录之外")) }
            candidate = path
        }
        guard let final = posixStat(candidate, follow: false) else { return .failure(.unreadable) }
        if isType(final, S_IFDIR) { return .failure(.invalid("路径是目录")) }
        guard isType(final, S_IFREG) else { return .failure(.unreadable) }
        return .success(candidate)
    }

    /// Reads the inode that was opened. A rename onto the path leaves this
    /// descriptor on the previous complete file. A size or identity change
    /// before the read finishes is discarded instead of parsed.
    static func readStable(_ path: String, maximumBytes: Int, afterOpen: (() -> Void)? = nil) -> Result<Data, GrokBotUsageReport.Rejection> {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        if fd < 0 { return .failure(.unreadable) }
        defer { close(fd) }
        var before = stat()
        if fstat(fd, &before) != 0 { return .failure(.unreadable) }
        if before.st_size < 0 || before.st_size > off_t(maximumBytes) { return .failure(.tooLarge) }
        if before.st_size == 0 { return .failure(.invalid("文件为空")) }
        afterOpen?()
        let count = Int(before.st_size)
        var data = Data(count: count)
        let readCount = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return posixRead(fd, base, count)
        }
        if readCount != count { return .failure(.unreadable) }
        var after = stat()
        if fstat(fd, &after) != 0 { return .failure(.unreadable) }
        if after.st_dev != before.st_dev || after.st_ino != before.st_ino || after.st_size != before.st_size {
            return .failure(.unreadable)
        }
        return .success(data)
    }

    private static func posixStat(_ path: String, follow: Bool) -> stat? {
        var info = stat()
        let result = follow ? stat(path, &info) : lstat(path, &info)
        return result == 0 ? info : nil
    }

    private static func isType(_ info: stat, _ kind: mode_t) -> Bool {
        info.st_mode & S_IFMT == kind
    }

    private static func resolve(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    private static func pathIsInside(_ path: String, root: URL) -> Bool {
        let rootPath = resolve(root.path) ?? root.standardizedFileURL.path
        let filePath = resolve(path) ?? URL(fileURLWithPath: path).standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return filePath != rootPath && filePath.hasPrefix(prefix)
    }

    private static func posixRead(_ fd: Int32, _ base: UnsafeMutableRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.read(fd, base, count)
        #elseif canImport(Glibc)
        return Glibc.read(fd, base, count)
        #else
        return -1
        #endif
    }
}
