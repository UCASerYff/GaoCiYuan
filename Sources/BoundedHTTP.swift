import Foundation
import CryptoKit

enum HTTPBudgetKind: String, Codable, Sendable {
    case quota, history, updateMetadata, updatePackage, toolDownload, providerPage, pricing
    var maximumBytes: Int {
        switch self {
        case .quota: return 1_048_576
        case .history, .providerPage: return 2_097_152
        case .updateMetadata: return 262_144
        case .pricing: return 16_777_216
        case .updatePackage: return 134_217_728
        case .toolDownload: return 268_435_456
        }
    }
    var deadline: TimeInterval { self == .updatePackage || self == .toolDownload ? 300 : 45 }
    var isLargeDownload: Bool { self == .updatePackage || self == .toolDownload }
}

enum HTTPPolicyContext {
    @TaskLocal static var userInitiated = false
    @TaskLocal static var trigger = "unspecified"
    @TaskLocal static var operationIdentity: String? = nil
    @TaskLocal static var credentialIdentity: String? = nil
}

enum HTTPBudgetError: LocalizedError, Equatable {
    case responseTooLarge, requestTooLarge, deadline, periodBudget, queueFull
    case authenticationPaused, deferred, networkBackoff, invalidRequest
    var errorDescription: String? {
        switch self {
        case .responseTooLarge: return "响应在接收过程中超过大小预算，已中止请求；上次完整数据已保留。"
        case .requestTooLarge: return "请求体超过查询预算，未发送。"
        case .deadline: return "请求超过整轮时间预算，已取消；上次完整数据已保留。"
        case .periodBudget: return "本周期网络预算已用完，暂停查询；上次完整数据已保留。"
        case .queueFull: return "查询队列已满，保留上次数据，请稍后重试。"
        case .authenticationPaused: return "认证已被拒绝，已暂停该凭据的自动查询；更新凭据或手动重试后再检查。"
        case .deferred: return "平台要求稍后重试，已暂停本服务请求并保留上次数据。"
        case .networkBackoff: return "网络暂不可用，正在退避；上次完整数据已保留。"
        case .invalidRequest: return "查询地址或网络预算无效，未发送请求。"
        }
    }
}

/// Metrics describe this process's HTTP only. Decoded bytes are deliberately
/// separate from URLSession transport bytes; neither is a Token count.
struct HTTPTraceRecord: Codable, Sendable {
    var startedAt: Date
    var pid: Int32
    var processIdentity: String
    var category: HTTPBudgetKind
    var trigger: String
    var host: String
    var pathTemplate: String
    var status: Int?
    var decodedReceivedBytes: Int
    var requestBodyBytes: Int
    var wireReceivedBytes: Int64?
    var wireSentBytes: Int64?
    var transactions: Int?
    var seconds: Double
    var peakDecodedBytesPerSecond: Double
    var outcome: String
}

actor HTTPDiagnostics {
    static let shared = HTTPDiagnostics()
    static let identity = UUID().uuidString
    private var records: [HTTPTraceRecord] = []
    private var dropped = 0
    func append(_ record: HTTPTraceRecord) {
        if records.count == 512 { records.removeFirst(); dropped += 1 }
        records.append(record)
    }
    func exportedData() throws -> Data {
        struct Export: Codable {
            var format = 1
            var scope = "本进程最近512条HTTP请求；不含CLI/浏览器流量。decoded与wire分别计量；缺失wire表示系统未提供指标。峰值是应用消费流量的1秒桶，不是网卡瞬时峰值。"
            var droppedRecords: Int
            var records: [HTTPTraceRecord]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Export(droppedRecords: dropped, records: records))
    }
    func snapshot() -> [HTTPTraceRecord] { records }
    func reset() { records = []; dropped = 0 }
}

private actor HTTPAdmission {
    static let shared = HTTPAdmission()
    private var active = 0
    private var hosts: [String: Int] = [:]
    private var waiting = 0
    private var authPaused = Set<String>()
    private var forbiddenScopes = Set<String>()
    private var manualOperations: [String: String] = [:]
    private var hostDeferred: [String: Date] = [:]
    private var failures: [String: (count: Int, until: Date)] = [:]
    private var windowStarted = Date()
    private var received = 0
    private var requests = 0
    private var largeStarted = Date()
    private var largeReceived = 0
    private var largeRequests = 0
    private var historyStarted = Date()
    private var historyRequests = 0

    func acquire(host: String, credential: String, scope: String, manual: Bool, operation: String?, large: Bool, history: Bool, cancelled: @Sendable () -> Bool) async throws {
        guard waiting < 64 else { throw HTTPBudgetError.queueFull }
        waiting += 1
        defer { waiting -= 1 }
        while true {
            try Task.checkCancellation()
            if cancelled() { throw CancellationError() }
            let now = Date()
            if let until = hostDeferred[host], until > now { throw HTTPBudgetError.deferred }
            if manual, let operation, manualOperations[credential] != operation {
                authPaused.remove(credential); forbiddenScopes.remove(scope); manualOperations[credential] = operation
            }
            if (authPaused.contains(credential) || forbiddenScopes.contains(scope)) && (!manual || operation != nil) { throw HTTPBudgetError.authenticationPaused }
            if !manual, let failed = failures[credential], failed.until > now { throw HTTPBudgetError.networkBackoff }
            rotate(now)
            guard large ? largeRequests < 4 : (history ? historyRequests < 500 : requests < 120) else { throw HTTPBudgetError.periodBudget }
            if active < 4 && hosts[host, default: 0] < 2 {
                active += 1; hosts[host, default: 0] += 1
                if large { largeRequests += 1 } else if history { historyRequests += 1 } else { requests += 1 }
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }
    func release(host: String) { active -= 1; hosts[host, default: 0] -= 1 }
    func consume(_ count: Int, large: Bool) throws {
        rotate(Date())
        // Shared period budgets include every HTTP entry point and account.
        if large {
            guard largeReceived <= 512 * 1_048_576 - count else { throw HTTPBudgetError.periodBudget }
            largeReceived += count
        } else {
            guard received <= 64 * 1_048_576 - count else { throw HTTPBudgetError.periodBudget }
            received += count
        }
    }
    func response(_ http: HTTPURLResponse, host: String, credential: String, scope: String) {
        let code = http.statusCode
        if code == 401 && !["127.0.0.1", "localhost", "::1"].contains(host) { authPaused.insert(credential) }
        else if code == 403 && !["127.0.0.1", "localhost", "::1"].contains(host) { forbiddenScopes.insert(scope) }
        else if (200..<300).contains(code) { authPaused.remove(credential); forbiddenScopes.remove(scope); failures[credential] = nil }
        if code == 429 {
            let seconds = Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After"))
            hostDeferred[host] = Date().addingTimeInterval(seconds)
        } else if (500...599).contains(code) { failure(credential: credential) }
    }
    func failure(credential: String) {
        let count = min(8, (failures[credential]?.count ?? 0) + 1)
        failures[credential] = (count, Date().addingTimeInterval(min(900, 15 * pow(2, Double(count - 1))) + Double.random(in: 0...3)))
    }
    private func rotate(_ now: Date) {
        if now.timeIntervalSince(windowStarted) >= 60 { windowStarted = now; received = 0; requests = 0 }
        if now.timeIntervalSince(largeStarted) >= 900 { largeStarted = now; largeReceived = 0; largeRequests = 0 }
        if now.timeIntervalSince(historyStarted) >= 120 { historyStarted = now; historyRequests = 0 }
        hostDeferred = hostDeferred.filter { $0.value > now }
        // State contains digests only and cannot grow without a bound.
        if failures.count > 512 { failures = failures.filter { $0.value.until > now } }
        if manualOperations.count > 512 { manualOperations = [:] }
    }
    static func retryAfter(_ raw: String?) -> TimeInterval {
        if let raw, let seconds = TimeInterval(raw), seconds.isFinite, seconds >= 0 { return max(1, min(seconds, 86_400)) }
        if let raw {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            if let date = f.date(from: raw) { return max(1, min(date.timeIntervalSinceNow, 86_400)) }
        }
        return 60
    }
    func reset() { authPaused = []; forbiddenScopes = []; manualOperations = [:]; failures = [:]; hostDeferred = [:]; received = 0; requests = 0; largeReceived = 0; largeRequests = 0; historyRequests = 0 }
}

private final class HTTPMetricCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var value: (Int64, Int64, Int)?
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let incoming = metrics.transactionMetrics.reduce(Int64(0)) { $0 + max(0, $1.countOfResponseBodyBytesReceived) + max(0, $1.countOfResponseHeaderBytesReceived) }
        let outgoing = metrics.transactionMetrics.reduce(Int64(0)) { $0 + max(0, $1.countOfRequestBodyBytesSent) + max(0, $1.countOfRequestHeaderBytesSent) }
        lock.lock(); value = (incoming, outgoing, metrics.transactionMetrics.count); lock.unlock()
    }
    func snapshot() -> (Int64, Int64, Int)? { lock.lock(); defer { lock.unlock() }; return value }
}

private final class HTTPStreamState: @unchecked Sendable {
    let lock = NSLock()
    var task: URLSessionTask?
    var cancelled = false
    var received = 0
    var response: HTTPURLResponse?
    var peak: Double = 0
    var bucketStarted = ProcessInfo.processInfo.systemUptime
    var bucketBytes = 0
    func install(_ task: URLSessionTask) {
        lock.lock(); self.task = task; let cancel = cancelled; lock.unlock()
        if cancel { task.cancel() }
    }
    func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
    func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func update(received: Int, response: HTTPURLResponse) {
        lock.lock(); defer { lock.unlock() }
        self.response = response
        bucketBytes += received - self.received; self.received = received
        let elapsed = ProcessInfo.processInfo.systemUptime - bucketStarted
        if elapsed >= 1 { peak = max(peak, Double(bucketBytes) / elapsed); bucketStarted = ProcessInfo.processInfo.systemUptime; bucketBytes = 0 }
    }
    func snapshot() -> (Int, HTTPURLResponse?, Double) {
        lock.lock(); defer { lock.unlock() }
        return (received, response, max(peak, Double(bucketBytes) / max(1, ProcessInfo.processInfo.systemUptime - bucketStarted)))
    }
}

private final class HTTPActiveRequests: @unchecked Sendable {
    static let shared = HTTPActiveRequests()
    private let lock = NSLock()
    private var states: [UUID: HTTPStreamState] = [:]
    func add(_ state: HTTPStreamState, id: UUID) { lock.lock(); states[id] = state; lock.unlock() }
    func remove(_ id: UUID) { lock.lock(); states[id] = nil; lock.unlock() }
    func cancelAll() { lock.lock(); let pending = Array(states.values); lock.unlock(); for state in pending { state.cancel() } }
}

enum BoundedHTTP {
    static func data(for request: URLRequest, session: URLSession = .shared, maxBytes: Int? = nil,
                     timeout: TimeInterval? = nil, category: HTTPBudgetKind = .quota,
                     progress: (@Sendable (Int64, Int64?) -> Void)? = nil) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        guard let url = request.url, let host = url.host, ["http", "https"].contains(url.scheme ?? ""),
              url.user == nil, url.password == nil else { throw HTTPBudgetError.invalidRequest }
        let limit = min(maxBytes ?? category.maximumBytes, category.maximumBytes)
        let seconds = timeout ?? category.deadline
        guard limit > 0, seconds.isFinite, seconds > 0, seconds <= 600 else { throw HTTPBudgetError.invalidRequest }
        guard (request.httpBody?.count ?? 0) <= 262_144, request.httpBodyStream == nil else { throw HTTPBudgetError.requestTooLarge }
        // Includes all headers so custom authentication also gets an in-memory
        // credential boundary; nothing from the header or query is recorded.
        let requestHeaders = (request.allHTTPHeaderFields ?? [:]).sorted { $0.key < $1.key }.map { $0.key.lowercased() + ":" + $0.value }.joined(separator: "\n")
        let configuration = HTTPPolicyContext.credentialIdentity ?? ((url.query ?? "") + (request.httpBody?.base64EncodedString() ?? ""))
        let identity = (url.scheme ?? "") + ":" + host + ":" + String(url.port ?? 0) + ":" + requestHeaders + ":" + configuration
        let credential = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let scope = credential + ":" + (request.httpMethod ?? "GET") + ":" + SHA256.hash(data: Data(url.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let started = Date(), uptime = ProcessInfo.processInfo.systemUptime
        let state = HTTPStreamState(), metrics = HTTPMetricCollector()
        let requestID = UUID()
        HTTPActiveRequests.shared.add(state, id: requestID)
        defer { HTTPActiveRequests.shared.remove(requestID) }
        do {
            let result: (Data, URLResponse) = try await withThrowingTaskGroup(of: HTTPResult.self) { group in
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    throw HTTPBudgetError.deadline
                }
                // cancelAll may arrive before URLSession exposes its task at
                // the response headers. Wake the race so cancellation reaches
                // the suspended bytes(for:) call as Task cancellation as well.
                group.addTask {
                    while true {
                        try Task.checkCancellation()
                        if state.isCancelled() { throw CancellationError() }
                        try await Task.sleep(nanoseconds: 25_000_000)
                    }
                }
                group.addTask {
                    try await HTTPAdmission.shared.acquire(host: host, credential: credential, scope: scope, manual: HTTPPolicyContext.userInitiated, operation: HTTPPolicyContext.operationIdentity, large: category.isLargeDownload, history: category == .history, cancelled: { state.isCancelled() })
                    do {
                        let result = try await withTaskCancellationHandler(operation: {
                            try Task.checkCancellation()
                            let (bytes, response) = try await session.bytes(for: request, delegate: metrics)
                            state.install(bytes.task)
                            defer { bytes.task.cancel() }
                            guard let http = response as? HTTPURLResponse else { throw HTTPBudgetError.invalidRequest }
                            state.update(received: 0, response: http)
                            await HTTPAdmission.shared.response(http, host: host, credential: credential, scope: scope)
                            if response.expectedContentLength > Int64(limit) { throw HTTPBudgetError.responseTooLarge }
                            let expected = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
                            var data = Data(); data.reserveCapacity(min(limit, 65_536))
                            var delivered = 0
                            defer { state.update(received: delivered, response: http) }
                            var accounted = 0
                            for try await byte in bytes {
                                delivered += 1
                                if data.count == limit { throw HTTPBudgetError.responseTooLarge }
                                data.append(byte)
                                if data.count - accounted >= 16_384 {
                                    try Task.checkCancellation()
                                    state.update(received: data.count, response: http)
                                    try await HTTPAdmission.shared.consume(data.count - accounted, large: category.isLargeDownload)
                                    accounted = data.count; progress?(Int64(data.count), expected)
                                }
                            }
                            try Task.checkCancellation()
                            state.update(received: data.count, response: http)
                            try await HTTPAdmission.shared.consume(data.count - accounted, large: category.isLargeDownload)
                            progress?(Int64(data.count), expected)
                            return HTTPResult(data: data, response: response)
                        }, onCancel: { state.cancel() })
                        await HTTPAdmission.shared.release(host: host)
                        return result
                    } catch {
                        await HTTPAdmission.shared.release(host: host)
                        throw error
                    }
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw CancellationError() }
                return (first.data, first.response)
            }
            await record(request, category, started, uptime, state, metrics, "completed")
            return result
        } catch {
            state.cancel()
            if error is URLError, (error as? URLError)?.code != .cancelled { await HTTPAdmission.shared.failure(credential: credential) }
            let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
            await record(request, category, started, uptime, state, metrics, cancelled ? "cancelled" : (error is HTTPBudgetError ? "budget-or-backoff" : "network-error"))
            if cancelled { throw CancellationError() }
            throw error
        }
    }

    private struct HTTPResult: @unchecked Sendable { var data: Data; var response: URLResponse }
    private static func record(_ request: URLRequest, _ category: HTTPBudgetKind, _ started: Date, _ uptime: Double,
                               _ state: HTTPStreamState, _ metrics: HTTPMetricCollector, _ outcome: String) async {
        let (count, response, peak) = state.snapshot(), wire = metrics.snapshot()
        let host = request.url?.host ?? "unknown"
        let publicHosts = ["api.openai.com", "chatgpt.com", "api.anthropic.com", "claude.ai", "cursor.com", "api.github.com", "github.com", "raw.githubusercontent.com", "models.dev", "openrouter.ai", "api.deepseek.com", "api.moonshot.cn"]
        let safeHost = publicHosts.contains(host) || host == "127.0.0.1" || host == "localhost" ? host : "private-host-" + SHA256.hash(data: Data(host.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let allowedSegments = Set(["api", "v1", "v2", "me", "users", "user", "organizations", "organization", "usage", "costs", "completions", "messages", "backend-api", "wham", "models", "balance", "credits", "key", "report", "export", "events", "subscriptions", "current", "billing", "token", "usage-summary", "model_prices_and_context_window.json", "api.json"])
        let path = "/" + (request.url?.path.split(separator: "/").map { allowedSegments.contains(String($0)) ? String($0) : ":segment" }.joined(separator: "/") ?? "")
        let triggers = Set(["unspecified", "quota.manual", "quota.automatic", "history.manual", "history.automatic", "update.check", "update.download", "pricing.manual", "connection.manual"])
        let reason = triggers.contains(HTTPPolicyContext.trigger) ? HTTPPolicyContext.trigger : "unspecified"
        await HTTPDiagnostics.shared.append(.init(startedAt: started, pid: ProcessInfo.processInfo.processIdentifier,
            processIdentity: HTTPDiagnostics.identity, category: category, trigger: reason, host: safeHost,
            pathTemplate: path, status: response?.statusCode, decodedReceivedBytes: count,
            requestBodyBytes: request.httpBody?.count ?? 0, wireReceivedBytes: wire?.0, wireSentBytes: wire?.1,
            transactions: wire?.2, seconds: ProcessInfo.processInfo.systemUptime - uptime,
            peakDecodedBytesPerSecond: peak, outcome: outcome))
    }
    static func cancelAll() { HTTPActiveRequests.shared.cancelAll() }
    static func resetForTesting() async { await HTTPAdmission.shared.reset(); await HTTPDiagnostics.shared.reset() }
}
