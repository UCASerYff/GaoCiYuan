import Foundation
import Darwin

// All *.fixture.invalid hosts are fully intercepted here: no DNS or external HTTP.
// Real HTTP is limited to the 127.0.0.1 server in http_budget_server.py.
final class MockRegistry: @unchecked Sendable {
    struct Rule { var status = 200; var headers: [String: String] = [:]; var hold = false; var fail = false }
    struct Snapshot { var requests: Int; var bytes: Int; var active: Int; var maximum: Int; var maximumByHost: [String: Int] }
    static let shared = MockRegistry()
    private let lock = NSLock()
    private var rules: [String: Rule] = [:]
    private var pending: [UUID: MockHTTP] = [:]
    private var activeByHost: [String: Int] = [:]
    private var maximumByHost: [String: Int] = [:]
    private var requests = 0, bytes = 0, maximum = 0
    func reset() { lock.lock(); defer { lock.unlock() }; rules = [:]; pending = [:]; activeByHost = [:]; maximumByHost = [:]; requests = 0; bytes = 0; maximum = 0 }
    func set(_ host: String, _ rule: Rule) { lock.lock(); rules[host] = rule; lock.unlock() }
    func begin(_ proto: MockHTTP) -> Rule {
        lock.lock(); defer { lock.unlock() }
        let host = proto.request.url!.host!
        requests += 1; pending[proto.id] = proto
        activeByHost[host, default: 0] += 1
        maximum = max(maximum, pending.count)
        maximumByHost[host] = max(maximumByHost[host, default: 0], activeByHost[host, default: 0])
        return rules[host] ?? Rule()
    }
    func end(_ proto: MockHTTP, completed: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pending.removeValue(forKey: proto.id) != nil else { return false }
        activeByHost[proto.request.url!.host!, default: 0] -= 1
        if completed { bytes += 2 }
        return true
    }
    func releaseAll() { lock.lock(); let values = Array(pending.values); lock.unlock(); for value in values { value.finish() } }
    func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return .init(requests: requests, bytes: bytes, active: pending.count, maximum: maximum, maximumByHost: maximumByHost) }
}
final class MockHTTP: URLProtocol {
    let id = UUID()
    private var rule = MockRegistry.Rule()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { rule = MockRegistry.shared.begin(self); if !rule.hold { finish() } }
    override func stopLoading() { _ = MockRegistry.shared.end(self, completed: false) }
    func finish() {
        guard MockRegistry.shared.end(self, completed: !rule.fail) else { return }
        if rule.fail { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: rule.status, httpVersion: "HTTP/1.1", headerFields: rule.headers.merging(["Content-Length": "2"]) { current, _ in current })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("ok".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
struct CheckFailure: LocalizedError { let text: String; var errorDescription: String? { text } }
struct ServerStats: Decodable {
    struct Route: Decodable { var requests: Int; var body_bytes_written: Int; var completed: Int; var disconnects: Int }
    var requests: Int; var body_bytes_written: Int; var active: Int; var maximum_active: Int; var routes: [String: Route]
}
struct CaseResult: Codable {
    var name: String; var passed: Bool; var requests: Int; var responseBodyBytesWritten: Int
    var decodedBytesRecorded: Int; var elapsedSeconds: Double; var detail: String
}

@main struct HTTPBudgetRegression {
    static var reports: [CaseResult] = []
    static var controlRequests = 0
    static var controlResponseBytes = 0
    static let runID = UUID().uuidString
    static let registry = MockRegistry.shared
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckFailure(text: message) }
    }
    static func session(mock: Bool = false) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil
        config.connectionProxyDictionary = [:]
        if mock { config.protocolClasses = [MockHTTP.self] }
        return URLSession(configuration: config)
    }
    static func request(_ url: String, credential: String? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpShouldHandleCookies = false
        if let credential { request.setValue(credential, forHTTPHeaderField: "Authorization") }
        return request
    }
    static func expectBudget(_ expected: HTTPBudgetError, _ work: () async throws -> Void) async throws {
        do { try await work(); throw CheckFailure(text: "Expected budget error was not thrown") }
        catch let error as HTTPBudgetError { try check(error == expected, "Wrong budget error: \(error)") }
    }
    static func until(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        throw CheckFailure(text: "Fixture condition timed out")
    }
    static func stats(_ base: String, _ control: URLSession) async throws -> ServerStats {
        let (data, _) = try await control.data(from: URL(string: base + "/stats")!)
        controlRequests += 1; controlResponseBytes += data.count
        return try JSONDecoder().decode(ServerStats.self, from: data)
    }
    static func idle(_ base: String, _ control: URLSession) async throws {
        for _ in 0..<150 { if try await stats(base, control).active == 0 { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw CheckFailure(text: "Loopback server did not become idle after cancellation")
    }
    static func run(_ name: String, base: String, control: URLSession, _ body: () async throws -> String) async {
        await BoundedHTTP.resetForTesting(); registry.reset()
        let before = try? await stats(base, control)
        let started = Date()
        var detail = "", passed = true
        do { detail = try await body(); try await idle(base, control) }
        catch { passed = false; detail = error.localizedDescription; try? await idle(base, control) }
        let after = try? await stats(base, control), mocked = registry.snapshot()
        let traces = await HTTPDiagnostics.shared.snapshot()
        let report = CaseResult(name: name, passed: passed,
            requests: (after?.requests ?? 0) - (before?.requests ?? 0) + mocked.requests,
            responseBodyBytesWritten: (after?.body_bytes_written ?? 0) - (before?.body_bytes_written ?? 0) + mocked.bytes,
            decodedBytesRecorded: traces.reduce(0) { $0 + $1.decodedReceivedBytes },
            elapsedSeconds: Date().timeIntervalSince(started), detail: detail)
        reports.append(report)
        print("\(passed ? "PASS" : "FAIL") \(name): requests=\(report.requests) body_written=\(report.responseBodyBytesWritten) decoded_recorded=\(report.decodedBytesRecorded) seconds=\(String(format: "%.3f", report.elapsedSeconds)) \(detail)")
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { throw CheckFailure(text: "Usage: HTTPBudgetRegression loopbackPort reportPath") }
        setbuf(stdout, nil)
        let base = "http://127.0.0.1:" + CommandLine.arguments[1]
        let direct = session(), mock = session(mock: true), control = session()
        defer { direct.invalidateAndCancel(); mock.invalidateAndCancel(); control.invalidateAndCancel() }

        await run("stream-no-content-length-early-stop", base: base, control: control) {
            try await expectBudget(.responseTooLarge) {
                _ = try await BoundedHTTP.data(for: request(base + "/stream/no-length-\(runID)"), session: direct, maxBytes: 8192, timeout: 2)
            }
            try await idle(base, control)
            let result = try await stats(base, control).routes["/stream/no-length-\(runID)"]!
            let trace = await HTTPDiagnostics.shared.snapshot().last!
            try check(result.requests == 1 && result.body_bytes_written < 65_536 && result.disconnects == 1, "Stream was not cut off early")
            try check(trace.decodedReceivedBytes >= 8192 && trace.decodedReceivedBytes <= 8193, "Partial oversize response is missing from diagnostics")
            return "limit=8192 planned=524288 disconnected=\(result.disconnects)"
        }
        await run("gzip-decoded-size-budget", base: base, control: control) {
            try await expectBudget(.responseTooLarge) {
                _ = try await BoundedHTTP.data(for: request(base + "/gzip/compressed-\(runID)"), session: direct, maxBytes: 4096, timeout: 2)
            }
            let trace = await HTTPDiagnostics.shared.snapshot().last!
            let written = try await stats(base, control).routes["/gzip/compressed-\(runID)"]!.body_bytes_written
            try check(written < 1024 && trace.decodedReceivedBytes >= 4096, "Compressed response was not limited by decoded bytes")
            return "decoded_limit=4096 planned_decoded=131072 compressed_body=\(written)"
        }
        await run("slow-stream-total-deadline", base: base, control: control) {
            let start = Date()
            try await expectBudget(.deadline) {
                _ = try await BoundedHTTP.data(for: request(base + "/slow/deadline-\(runID)"), session: direct, maxBytes: 16_384, timeout: 0.35)
            }
            try check(Date().timeIntervalSince(start) < 1.5, "Deadline was not a whole-operation deadline")
            return "deadline=0.35s planned_stream_duration=9s"
        }
        await run("explicit-cancel-stops-request-count", base: base, control: control) {
            let task = Task { try await BoundedHTTP.data(for: request(base + "/stream/cancelled-\(runID)"), session: direct, maxBytes: 65_536, timeout: 2) }
            for _ in 0..<100 {
                if try await stats(base, control).routes["/stream/cancelled-\(runID)"] != nil { break }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            task.cancel()
            do { _ = try await task.value; throw CheckFailure(text: "Explicit cancellation succeeded unexpectedly") }
            catch is CancellationError {}
            try await idle(base, control)
            let first = try await stats(base, control)
            try await Task.sleep(nanoseconds: 100_000_000)
            let later = try await stats(base, control)
            try check(first.requests == later.requests && first.body_bytes_written == later.body_bytes_written, "Traffic continued after cancellation settled")
            return "requests_after_cancel_100ms=0 new_body_bytes_after_cancel_100ms=0"
        }
        await run("global-host-concurrency-and-queue-cancel", base: base, control: control) {
            let hosts = ["one.fixture.invalid", "one.fixture.invalid", "two.fixture.invalid", "two.fixture.invalid"]
            for host in hosts { registry.set(host, .init(hold: true)) }
            let tasks = hosts.enumerated().map { index, host in
                Task { try await BoundedHTTP.data(for: request("https://" + host + "/hold/\(index)"), session: mock, timeout: 3) }
            }
            try await until { registry.snapshot().active == 4 }
            let queued = Task { try await BoundedHTTP.data(for: request("https://three.fixture.invalid/never-start"), session: mock, timeout: 2) }
            try await Task.sleep(nanoseconds: 70_000_000)
            try check(registry.snapshot().requests == 4, "Global concurrency exceeded four")
            queued.cancel()
            do { _ = try await queued.value; throw CheckFailure(text: "Cancelled queued request succeeded") } catch is CancellationError {}
            registry.releaseAll()
            for task in tasks { _ = try await task.value }
            let same = "same.fixture.invalid"; registry.set(same, .init(hold: true))
            let pair = (0..<2).map { i in Task { try await BoundedHTTP.data(for: request("https://" + same + "/hold/\(i)"), session: mock, timeout: 3) } }
            try await until { registry.snapshot().active == 2 }
            let perHostQueued = Task { try await BoundedHTTP.data(for: request("https://" + same + "/never-start"), session: mock, timeout: 2) }
            try await Task.sleep(nanoseconds: 70_000_000)
            try check(registry.snapshot().requests == 6, "Per-host concurrency exceeded two")
            perHostQueued.cancel(); _ = try? await perHostQueued.value
            registry.releaseAll(); for task in pair { _ = try await task.value }
            let measured = registry.snapshot()
            try check(measured.requests == 6 && measured.maximum == 4 && measured.maximumByHost.values.allSatisfy { $0 <= 2 }, "Admission or queued cancellation failed")
            return "max_global=\(measured.maximum) max_host=\(measured.maximumByHost.values.max() ?? 0) queued_cancelled_unsent=2"
        }
        await run("cancel-all-before-headers-and-while-queued", base: base, control: control) {
            let hosts = ["cancel-one.fixture.invalid", "cancel-one.fixture.invalid", "cancel-two.fixture.invalid", "cancel-two.fixture.invalid"]
            for host in hosts { registry.set(host, .init(hold: true)) }
            let tasks = hosts.enumerated().map { index, host in
                Task { try await BoundedHTTP.data(for: request("https://" + host + "/hold/\(index)"), session: mock, timeout: 2) }
            }
            try await until { registry.snapshot().active == 4 }
            let queued = Task { try await BoundedHTTP.data(for: request("https://cancel-queued.fixture.invalid/never-start"), session: mock, timeout: 2) }
            try await Task.sleep(nanoseconds: 30_000_000)
            BoundedHTTP.cancelAll()
            try await Task.sleep(nanoseconds: 150_000_000)
            let afterCancellation = registry.snapshot()
            // Always clean up fixture requests, including when the cancellation assertion fails.
            for task in tasks { task.cancel() }; queued.cancel()
            for task in tasks { _ = try? await task.value }; _ = try? await queued.value
            registry.releaseAll()
            try check(afterCancellation.active == 0 && afterCancellation.requests == 4, "cancelAll left \(afterCancellation.active) requests waiting for response headers; queued cancellation requests=\(afterCancellation.requests)")
            return "before_header_active_after_cancel_150ms=0 queued_unsent=1"
        }
        await run("request-body-and-body-stream-rejected", base: base, control: control) {
            var large = request("https://request.fixture.invalid/too-large"); large.httpMethod = "POST"; large.httpBody = Data(repeating: 1, count: 262_145)
            try await expectBudget(.requestTooLarge) { _ = try await BoundedHTTP.data(for: large, session: mock) }
            var stream = request("https://request.fixture.invalid/stream"); stream.httpMethod = "POST"; stream.httpBodyStream = InputStream(data: Data([1]))
            try await expectBudget(.requestTooLarge) { _ = try await BoundedHTTP.data(for: stream, session: mock) }
            try check(registry.snapshot().requests == 0, "Over-budget request body was sent")
            return "body_limit=262144 rejected_before_send=2"
        }
        await run("401-auto-lock-credential-change-manual-unlock", base: base, control: control) {
            let host = "auth.fixture.invalid", url = "https://auth.fixture.invalid/v1/balance"
            registry.set(host, .init(status: 401))
            let original = request(url, credential: "Bearer fixture-A")
            let (_, denied) = try await HTTPPolicyContext.$credentialIdentity.withValue("fixed-account-context") {
                try await BoundedHTTP.data(for: original, session: mock)
            }
            try check((denied as? HTTPURLResponse)?.statusCode == 401, "401 fixture did not execute")
            registry.set(host, .init())
            try await expectBudget(.authenticationPaused) {
                _ = try await HTTPPolicyContext.$credentialIdentity.withValue("fixed-account-context") { try await BoundedHTTP.data(for: original, session: mock) }
            }
            _ = try await HTTPPolicyContext.$credentialIdentity.withValue("fixed-account-context") {
                try await BoundedHTTP.data(for: request(url, credential: "Bearer fixture-B"), session: mock)
            }
            _ = try await HTTPPolicyContext.$credentialIdentity.withValue("fixed-account-context") {
                try await BoundedHTTP.data(for: request("https://backup-auth.fixture.invalid/v1/balance", credential: "Bearer fixture-A"), session: mock)
            }
            try check(registry.snapshot().requests == 3, "Changed actual credential or alternate host remained incorrectly paused")
            _ = try await HTTPPolicyContext.$credentialIdentity.withValue("fixed-account-context") {
                try await HTTPPolicyContext.$userInitiated.withValue(true) { try await BoundedHTTP.data(for: original, session: mock) }
            }
            _ = try await HTTPPolicyContext.$credentialIdentity.withValue("fixed-account-context") { try await BoundedHTTP.data(for: original, session: mock) }
            try check(registry.snapshot().requests == 5, "Manual retry did not unlock successfully refreshed original credential")
            return "401=1 blocked_auto_unsent=1 changed_credential=1 alternate_host=1 same_account_context=1 manual_unlock=1 later_auto=1"
        }
        await run("403-auto-lock", base: base, control: control) {
            let host = "forbidden.fixture.invalid", denied = request("https://forbidden.fixture.invalid/v1/usage", credential: "Bearer fixture-C")
            registry.set(host, .init(status: 403))
            _ = try await BoundedHTTP.data(for: denied, session: mock)
            try await expectBudget(.authenticationPaused) { _ = try await BoundedHTTP.data(for: denied, session: mock) }
            registry.set(host, .init())
            _ = try await BoundedHTTP.data(for: request("https://forbidden.fixture.invalid/v1/balance", credential: "Bearer fixture-C"), session: mock)
            try check(registry.snapshot().requests == 2, "403 either continued polling or blocked a different authorized path")
            return "403=1 subsequent_same_endpoint_auto_unsent=1 different_path_allowed=1"
        }
        await run("429-retry-after-no-hidden-retry", base: base, control: control) {
            let host = "limited.fixture.invalid", limited = request("https://limited.fixture.invalid/v1/usage")
            registry.set(host, .init(status: 429, headers: ["Retry-After": "1"]))
            let (_, response) = try await BoundedHTTP.data(for: limited, session: mock)
            try check((response as? HTTPURLResponse)?.statusCode == 429 && registry.snapshot().requests == 1, "429 silently retried")
            registry.set(host, .init())
            try await expectBudget(.deferred) { _ = try await BoundedHTTP.data(for: limited, session: mock) }
            try await Task.sleep(nanoseconds: 1_100_000_000)
            _ = try await BoundedHTTP.data(for: limited, session: mock)
            try check(registry.snapshot().requests == 2, "Retry-After did not bound the deferral")
            return "retry_after_seconds=1 during_deferral_unsent=1 next_explicit_request=1 hidden_retries=0"
        }
        await run("500-network-failure-no-implicit-retries", base: base, control: control) {
            let host = "failure.fixture.invalid", target = request("https://failure.fixture.invalid/v1/usage")
            registry.set(host, .init(status: 500))
            let (_, response) = try await BoundedHTTP.data(for: target, session: mock)
            try check((response as? HTTPURLResponse)?.statusCode == 500 && registry.snapshot().requests == 1, "500 response silently retried")
            try await expectBudget(.networkBackoff) { _ = try await BoundedHTTP.data(for: target, session: mock) }
            registry.set("timeout.fixture.invalid", .init(fail: true))
            let timeout = request("https://timeout.fixture.invalid/v1/usage")
            do { _ = try await BoundedHTTP.data(for: timeout, session: mock); throw CheckFailure(text: "Network fixture unexpectedly succeeded") } catch is URLError {}
            try await expectBudget(.networkBackoff) { _ = try await BoundedHTTP.data(for: timeout, session: mock) }
            try check(registry.snapshot().requests == 2, "Failed operation was implicitly retried")
            return "500_requests=1 timedout_requests=1 automatic_backoff_unsent=2 hidden_retries=0"
        }
        await run("redirect-not-followed", base: base, control: control) {
            let (_, response) = try await BoundedHTTP.data(for: request(base + "/redirect"), session: direct, timeout: 2)
            let observed = try await stats(base, control)
            try check((response as? HTTPURLResponse)?.statusCode == 302 && observed.routes["/redirect-target"] == nil, "Redirect was followed")
            return "302=1 target_requests=0"
        }
        await run("diagnostics-redact-query-header-body-dynamic-path", base: base, control: control) {
            var sensitive = request("https://private.fixture.invalid/v1/users/fixture-dynamic-secret/usage?key=fixture-query-secret", credential: "fixture-header-secret")
            sensitive.httpMethod = "POST"; sensitive.httpBody = Data("fixture-body-secret".utf8)
            _ = try await HTTPPolicyContext.$trigger.withValue("fixture-trigger-secret") { try await BoundedHTTP.data(for: sensitive, session: mock) }
            let exported = try await HTTPDiagnostics.shared.exportedData(), text = String(decoding: exported, as: UTF8.self)
            for secret in ["fixture-dynamic-secret", "fixture-query-secret", "fixture-header-secret", "fixture-body-secret", "fixture-trigger-secret", "private.fixture.invalid"] {
                try check(!text.contains(secret), "Sensitive diagnostic component leaked")
            }
            let trace = await HTTPDiagnostics.shared.snapshot().last!
            try check(trace.pathTemplate == "/v1/users/:segment/usage" && trace.trigger == "unspecified" && trace.host.hasPrefix("private-host-"), "Diagnostic template was not bounded")
            return "path=/v1/users/:segment/usage private_host=hashed trigger=allowlisted payload_fields=counts_only"
        }

        let final = try await stats(base, control)
        let totalBody = reports.reduce(0) { $0 + $1.responseBodyBytesWritten }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(reports).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
        struct Summary: Codable {
            var cases: Int; var passed: Int; var fixtureRequests: Int; var fixtureBodyBytes: Int
            var controlRequests: Int; var controlResponseBytes: Int; var totalResponseBodyBytes: Int; var externalRequests = 0
        }
        let summary = Summary(cases: reports.count, passed: reports.filter(\.passed).count,
            fixtureRequests: reports.reduce(0) { $0 + $1.requests }, fixtureBodyBytes: totalBody,
            controlRequests: controlRequests, controlResponseBytes: controlResponseBytes,
            totalResponseBodyBytes: totalBody + controlResponseBytes)
        try encoder.encode(summary).write(to: URL(fileURLWithPath: CommandLine.arguments[2] + ".summary.json"), options: .atomic)
        print("TOTAL cases=\(summary.cases) passed=\(summary.passed) fixture_requests=\(summary.fixtureRequests) body_written=\(totalBody) server_body_written=\(final.body_bytes_written) control_requests=\(controlRequests) control_response_bytes=\(controlResponseBytes) all_response_body_bytes=\(summary.totalResponseBodyBytes) external_requests=0")
        try check(summary.totalResponseBodyBytes < 5 * 1_048_576, "Regression including measurement controls exceeded 5 MiB total response-body budget")
        try check(reports.allSatisfy(\.passed), "At least one bounded HTTP regression failed; see per-case report")
    }
}
