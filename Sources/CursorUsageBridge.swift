import Foundation
import CryptoKit
import CoreFoundation

/// Account exports are cloud observations, not device-local transcripts. Only
/// hashes, timestamps and numeric usage cross this boundary; no cookies persist.
struct CursorUsageEvent: Codable, Sendable, Equatable {
    var accountKey: String
    var eventID: String
    var conversationID: String
    var model: String
    var timestamp: Date
    var amounts: UsageAmounts

    var sourceID: String {
        let h = Array(accountKey.prefix(32))
        guard h.count == 32 else { return "" }
        return "\(String(h[0..<8]))-\(String(h[8..<12]))-\(String(h[12..<16]))-\(String(h[16..<20]))-\(String(h[20..<32]))"
    }
}

enum CursorUsageFailure: LocalizedError {
    case login, permission, rateLimit, network, malformed, incomplete, oversized, timeout
    var errorDescription: String? {
        switch self {
        case .login: return "Cursor 登录态不可用或已过期，请在 Cursor 编辑器中重新登录。"
        case .permission: return "Cursor 当前账户没有用量导出权限，已有历史保持不变。"
        case .rateLimit: return "Cursor 用量接口限流，请稍后再试。"
        case .network: return "Cursor 官方用量接口连接失败，已有历史保持不变。"
        case .malformed: return "Cursor 用量响应格式无法核验，未保存本次结果。"
        case .incomplete: return "Cursor 分页历史不完整或采集中发生变化，未保存本次结果，请重新采集。"
        case .oversized: return "Cursor 导出超过 64 MB 或 25 万事件，未保存本次结果。"
        case .timeout: return "Cursor 完整历史采集超过 120 秒，已有历史保持不变。"
        }
    }
}

struct CursorUsageBatch: Sendable { var events: [CursorUsageEvent]; var unmeteredEvents: Int }

enum CursorUsageBridge {
    typealias PageFetcher = @Sendable (URLRequest, Int) async throws -> (Data, Int)
    static let endpoint = URL(string: "https://cursor.com/api/dashboard/get-filtered-usage-events")!
    static let notice = "Cursor 默认关闭。启用后仅向 cursor.com 官方用量接口发送编辑器现有登录态，读取当前账户可导出的历史。费用为官方计量价值，可能包含套餐内用量，并非实际扣款；数据可能延迟。"

    static func fetch(onProgress: (@Sendable (String, Int, Int) -> Void)? = nil) async throws -> CursorUsageBatch {
        let cookie = await Task.detached(priority: .utility) { CursorBridge.session()?.cookie }.value
        guard let cookie else { throw CursorUsageFailure.login }
        return try await fetch(cookie: cookie, onProgress: onProgress)
    }

    // Injection is limited to transport for fixtures; production always uses the
    // fixed HTTPS endpoint, ephemeral cookies/cache, and refuses all redirects.
    static func fetch(cookie: String, pageSize: Int = 500, maximumPages: Int = 500,
                      maximumBytes: Int = 64 * 1024 * 1024,
                      onProgress: (@Sendable (String, Int, Int) -> Void)? = nil,
                      pageFetcher: PageFetcher? = nil) async throws -> CursorUsageBatch {
        let marker = "WorkosCursorSessionToken="
        guard cookie.hasPrefix(marker), let separator = cookie.range(of: "%3A%3A"),
              separator.lowerBound > cookie.index(cookie.startIndex, offsetBy: marker.count) else { throw CursorUsageFailure.login }
        let account = String(cookie[cookie.index(cookie.startIndex, offsetBy: marker.count)..<separator.lowerBound])
        let accountKey = digest("cursor-account-v1:" + account)
        let deadline = Date().addingTimeInterval(120)
        var consumed = 0, received = 0, unmetered = 0, advertised: Int?
        var events: [String: CursorUsageEvent] = [:]
        let fetcher = pageFetcher ?? download
        for page in 1...max(1, maximumPages) {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw CursorUsageFailure.timeout }
            onProgress?("正在读取 Cursor 官方用量（第 \(page) 页）", 0, 0)
            var request = URLRequest(url: endpoint); request.httpMethod = "POST"
            request.timeoutInterval = min(remaining, 30)
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["teamId": 0, "page": page, "pageSize": pageSize])
            let (data, status) = try await fetcher(request, max(0, maximumBytes - consumed))
            try Task.checkCancellation()
            guard Date() < deadline else { throw CursorUsageFailure.timeout }
            switch status {
            case 200..<300: break
            case 401: throw CursorUsageFailure.login
            case 403: throw CursorUsageFailure.permission
            case 429: throw CursorUsageFailure.rateLimit
            default: throw CursorUsageFailure.network
            }
            consumed += data.count
            guard consumed <= maximumBytes else { throw CursorUsageFailure.oversized }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = object["usageEventsDisplay"] as? [[String: Any]] else { throw CursorUsageFailure.malformed }
            if let count = object["totalUsageEventsCount"] {
                let total = try integer(count)
                guard total <= 250_000 else { throw CursorUsageFailure.oversized }
                if let advertised, advertised != Int(total) { throw CursorUsageFailure.incomplete }
                advertised = Int(total)
            }
            received += raw.count
            guard received <= 250_000 else { throw CursorUsageFailure.oversized }
            for item in raw {
                // Official exports include failed/free/legacy rows without any
                // token measurements. Keep their absence explicit, never zero.
                if item["tokenUsage"] == nil || item["tokenUsage"] is NSNull { unmetered += 1; continue }
                if let usage = item["tokenUsage"] as? [String: Any],
                   ["inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens"].allSatisfy({ usage[$0] == nil || usage[$0] is NSNull }) { unmetered += 1; continue }
                let event = try decode(item, accountKey: accountKey)
                // An overlapping page cannot silently replace a distinct event
                // and still satisfy the advertised history count.
                if let old = events[event.eventID], old != event { throw CursorUsageFailure.incomplete }
                events[event.eventID] = event
            }
            let completed: Bool
            if let advertised {
                guard received <= advertised else { throw CursorUsageFailure.incomplete }
                if raw.isEmpty && received < advertised { throw CursorUsageFailure.incomplete }
                completed = received == advertised
            } else { completed = raw.count < pageSize }
            if completed {
                guard events.count + unmetered == received else { throw CursorUsageFailure.incomplete }
                return .init(events: events.values.sorted { $0.eventID < $1.eventID }, unmeteredEvents: unmetered)
            }
        }
        throw CursorUsageFailure.incomplete
    }

    static func decode(_ object: [String: Any], accountKey: String) throws -> CursorUsageEvent {
        let timestamp: Date
        if let n = number(object["timestamp"]) { timestamp = Date(timeIntervalSince1970: n / 1000) }
        else if let text = object["timestamp"] as? String,
                let date = isoDate(text) { timestamp = date }
        else { throw CursorUsageFailure.malformed }
        guard timestamp.timeIntervalSince1970 >= 0, timestamp <= Date().addingTimeInterval(86400),
              let sourceModel = object["model"] as? String, !sourceModel.isEmpty, sourceModel.utf8.count <= 300,
              let usage = object["tokenUsage"] as? [String: Any] else { throw CursorUsageFailure.malformed }
        let model = ["auto", "default"].contains(sourceModel.lowercased()) ? "cursor-auto" : sourceModel
        let input = try integer(usage["inputTokens"] ?? 0), output = try integer(usage["outputTokens"] ?? 0)
        let read = try integer(usage["cacheReadTokens"] ?? 0), write = try integer(usage["cacheWriteTokens"] ?? 0)
        let cents = number(usage["totalCents"]).flatMap { $0 >= 0 ? $0 : nil }
            ?? number(object["chargedCents"]).flatMap { $0 >= 0 ? $0 : nil }
        guard cents.map({ $0 <= 100_000_000_000 }) ?? true else { throw CursorUsageFailure.malformed }
        let rawConversation = (object["conversationId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard (rawConversation?.utf8.count ?? 0) <= 4096 else { throw CursorUsageFailure.malformed }
        let conversation = digest(accountKey + ":conversation:" + (rawConversation ?? "unattributed-" + utcDay(timestamp)))
        // Prefer official IDs. Older exports omit them; their immutable numeric
        // event tuple is the fallback. Cost is excluded so later pricing settles
        // onto the same event. Ambiguous identical tuples reject that whole scan.
        let official = ["eventId", "id", "requestId"].compactMap { object[$0] as? String }.first { !$0.isEmpty }
        let identity = official.map { "id:" + $0 } ?? "tuple:\(timestamp.timeIntervalSince1970):\(conversation):\(model):\(input):\(output):\(read):\(write)"
        return .init(accountKey: accountKey, eventID: digest(accountKey + ":event:" + identity),
            conversationID: conversation, model: model, timestamp: timestamp,
            amounts: .init(input: input, output: output, cacheRead: read, cacheWrite: write,
                           costUSD: cents.map { $0 / 100 }, messageCount: 1))
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber {
            guard CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
            return value.doubleValue
        }
        if let value = value as? String, let number = Double(value), number.isFinite { return number }
        return nil
    }
    private static func integer(_ value: Any) throws -> Int64 {
        guard let n = number(value), n >= 0, n <= 1_000_000_000_000, n.rounded() == n else { throw CursorUsageFailure.malformed }
        return Int64(n)
    }
    private static func isoDate(_ value: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    private static func utcDay(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
    static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private static func download(_ request: URLRequest, maximumBytes: Int) async throws -> (Data, Int) {
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.urlCache = nil
        config.httpShouldSetCookies = false; config.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, response.url?.host == "cursor.com" else { throw CursorUsageFailure.network }
            guard response.expectedContentLength <= Int64(maximumBytes) else { throw CursorUsageFailure.oversized }
            if !(200..<300).contains(response.statusCode) { return (Data(), response.statusCode) }
            var data = Data(); data.reserveCapacity(min(maximumBytes, max(0, Int(response.expectedContentLength))))
            for try await byte in bytes {
                guard data.count < maximumBytes else { throw CursorUsageFailure.oversized }
                data.append(byte)
                if data.count.isMultiple(of: 16_384) { try Task.checkCancellation() }
            }
            return (data, response.statusCode)
        } catch is CancellationError { throw CancellationError() }
        catch let error as CursorUsageFailure { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw CursorUsageFailure.network }
    }
}
