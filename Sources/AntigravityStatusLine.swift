import CryptoKit
import Darwin
import Foundation

enum AntigravityStatusLine {
    static let modeArgument = "--capture-antigravity-status"
    private static let accountArgument = "--antigravity-account"
    static let guide = "https://antigravity.google/docs/cli/statusline/"
    static let source = "Antigravity 独立 CLI · 状态栏推送"
    static let waiting = "等待已绑定 Google 账号的 Antigravity 状态栏更新。"
    static let freshFor: TimeInterval = 15 * 60
    private static let maxBytes = 256 * 1024
    private static let maxBuckets = 64
    private static let longestReset: TimeInterval = 366 * 86_400

    private struct Status: Decodable {
        struct Bucket: Decodable {
            let remaining_fraction: Double?
            let reset_time: String?
            let reset_in_seconds: Double?
            let disabled: Bool?
        }
        let product: String
        let email: String
        let agent_state: String?
        let quota: [String: Bucket]
    }

    private struct Capture: Codable {
        let accountDigest: String
        let observedAt: Date
        let quotas: [Quota]
    }

    private static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GaoSeries/Token/antigravity-statusline", isDirectory: true)
    }

    static func canonicalEmail(_ value: String) -> String? {
        let email = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.utf8.count <= 254,
              email.range(of: #"^[a-z0-9.!#$%&'*+/=?^_`{|}~-]{1,64}@[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$"#,
                          options: .regularExpression) != nil else { return nil }
        return email
    }

    static func configuration(executable: String, email: String) -> String? {
        guard executable.hasPrefix("/"), executable.rangeOfCharacter(from: .newlines) == nil,
              let digest = digest(for: email) else { return nil }
        let escaped = executable.replacingOccurrences(of: "'", with: "'\\''")
        let command = "'\(escaped)' \(modeArgument) \(accountArgument) \(digest)"
        let config: [String: Any] = ["statusLine": ["type": "command", "command": command, "stack_with_default": true]]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func run(arguments: [String]) {
        guard let flag = arguments.firstIndex(of: accountArgument), flag + 1 < arguments.count else { return }
        let expectedDigest = arguments[flag + 1]
        guard expectedDigest.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { return }
        do {
            var input = Data()
            while input.count <= maxBytes {
                guard let chunk = try FileHandle.standardInput.read(upToCount: min(16_384, maxBytes + 1 - input.count)),
                      !chunk.isEmpty else { break }
                input.append(chunk)
            }
            try capture(input, expectedDigest: expectedDigest)
        } catch { return }
    }

    static func capture(_ data: Data, expectedDigest: String, directory: URL? = nil, now: Date = Date()) throws {
        guard data.count <= maxBytes, let status = try? JSONDecoder().decode(Status.self, from: data),
              status.product == "antigravity", let digest = digest(for: status.email), digest == expectedDigest,
              !["authenticating", "initializing", "error"].contains(status.agent_state ?? ""),
              (1...maxBuckets).contains(status.quota.count) else { return }
        let quotas = status.quota.sorted { $0.key < $1.key }.compactMap { key, bucket -> Quota? in
            guard key.utf8.count <= 100, key.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9._-]*$"#, options: .regularExpression) != nil,
                  bucket.disabled != true, let remaining = bucket.remaining_fraction,
                  remaining.isFinite, (0...1).contains(remaining) else { return nil }
            let reset = resetDate(bucket, now: now)
            guard reset.map({ $0 > now }) ?? true else { return nil }
            return Quota(id: "antigravity-\(key)", title: title(for: key), usedPercent: 100 * (1 - remaining), resetsAt: reset,
                         exhausted: remaining == 0, windowSeconds: window(for: key))
        }
        guard !quotas.isEmpty else { return }
        let folder = directory ?? defaultDirectory
        let target = folder.appendingPathComponent(digest + ".json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockFile = folder.appendingPathComponent(digest + ".lock")
        let lock = open(lockFile.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        guard lock >= 0 else { return }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return }
        if let previous = read(target), previous.accountDigest == digest {
            let interval = now.timeIntervalSince(previous.observedAt)
            if interval < 0 || (interval < 60 && previous.quotas == quotas) { return }
        }
        let record = Capture(accountDigest: digest, observedAt: now, quotas: quotas)
        try JSONEncoder().encode(record).write(to: target, options: .atomic)
    }

    static func snapshot(email: String, directory: URL? = nil, now: Date = Date()) -> UsageSnapshot? {
        guard let digest = digest(for: email) else { return nil }
        let target = (directory ?? defaultDirectory).appendingPathComponent(digest + ".json")
        guard let record = read(target), record.accountDigest == digest,
              (0...freshFor).contains(now.timeIntervalSince(record.observedAt)) else { return nil }
        var result = UsageSnapshot.empty(source: source)
        result.observedAt = record.observedAt
        result.quotas = record.quotas.filter { !$0.expired(at: now) }
        guard !result.quotas.isEmpty, (try? result.validate()) != nil else { return nil }
        return result
    }

    private static func read(_ target: URL) -> Capture? {
        guard let metadata = try? target.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              metadata.isRegularFile == true, metadata.isSymbolicLink != true, let size = metadata.fileSize,
              size <= maxBytes, let data = try? Data(contentsOf: target), data.count <= maxBytes else { return nil }
        return try? JSONDecoder().decode(Capture.self, from: data)
    }

    static func digest(for value: String) -> String? {
        guard let email = canonicalEmail(value) else { return nil }
        return SHA256.hash(data: Data(email.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func resetDate(_ bucket: Status.Bucket, now: Date) -> Date? {
        if let text = bucket.reset_time {
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fractional = parser.date(from: text)
            parser.formatOptions = [.withInternetDateTime]
            if let reset = fractional ?? parser.date(from: text), reset.timeIntervalSince(now) <= longestReset { return reset }
            return .distantPast
        }
        guard let seconds = bucket.reset_in_seconds else { return nil }
        guard seconds.isFinite, (0...longestReset).contains(seconds) else { return .distantPast }
        return now.addingTimeInterval(seconds)
    }

    private static func window(for key: String) -> Double? {
        if key.hasSuffix("-weekly") { return 604_800 }
        if key.hasSuffix("-5h") { return 18_000 }
        return nil
    }

    private static func title(for key: String) -> String {
        let known = ["gemini-weekly": "Gemini Models · 每周", "gemini-5h": "Gemini Models · 5 小时",
                     "3p-weekly": "Claude and GPT models · 每周", "3p-5h": "Claude and GPT models · 5 小时",
                     "gemini-argon-wtu-weekly": "Gemini 4 Argon · 每周"]
        return known[key] ?? key
    }
}
