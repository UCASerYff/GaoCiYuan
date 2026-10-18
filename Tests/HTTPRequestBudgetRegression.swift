import Foundation
import Darwin

// Complete URLProtocol interception: fixture.invalid never reaches DNS or HTTP.
// 620 one-byte responses exercise counters without spending the 64 MiB byte budget.
private final class RequestBudgetMeter: @unchecked Sendable {
    static let shared = RequestBudgetMeter()
    private let lock = NSLock()
    private var count = 0
    private var bodyBytes = 0
    func sent() { lock.lock(); count += 1; bodyBytes += 1; lock.unlock() }
    func snapshot() -> (requests: Int, responseBodyBytes: Int) { lock.lock(); defer { lock.unlock() }; return (count, bodyBytes) }
}
private final class RequestBudgetMockHTTP: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        RequestBudgetMeter.shared.sent()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "1"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([1]))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private struct RequestBudgetFailure: LocalizedError { var text: String; var errorDescription: String? { text } }
@main struct HTTPRequestBudgetRegression {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw RequestBudgetFailure(text: message) }
    }
    static func expectPeriodBudget(_ work: () async throws -> Void) async throws {
        do { try await work(); throw RequestBudgetFailure(text: "Expected periodBudget was not thrown") }
        catch let error as HTTPBudgetError { try check(error == .periodBudget, "Wrong budget error") }
    }
    static func main() async throws {
        setbuf(stdout, nil)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RequestBudgetMockHTTP.self]
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        await BoundedHTTP.resetForTesting()
        let started = Date()
        for page in 1...500 {
            let request = URLRequest(url: URL(string: "https://budget.fixture.invalid/history/\(page)")!)
            let (data, response) = try await BoundedHTTP.data(for: request, session: session, maxBytes: 16, timeout: 2, category: .history)
            try check(data == Data([1]) && (response as? HTTPURLResponse)?.statusCode == 200, "History page \(page) failed before the 500-page budget")
        }
        let afterHistory = RequestBudgetMeter.shared.snapshot()
        try check(afterHistory.requests == 500, "History counter did not admit exactly 500 requests")
        try await expectPeriodBudget {
            _ = try await BoundedHTTP.data(for: URLRequest(url: URL(string: "https://budget.fixture.invalid/history/501")!), session: session, maxBytes: 16, timeout: 2, category: .history)
        }
        try check(RequestBudgetMeter.shared.snapshot().requests == 500, "501st history request was sent")
        print("PASS history: admitted=500 denied=501st denied_requests_sent=0 response_body_bytes=500")

        // Deliberately do not reset admission. Ordinary quota has an independent
        // 120-request window after all 500 historical requests have completed.
        for index in 1...120 {
            let (data, _) = try await BoundedHTTP.data(for: URLRequest(url: URL(string: "https://budget.fixture.invalid/quota/\(index)")!), session: session, maxBytes: 16, timeout: 2, category: .quota)
            try check(data == Data([1]), "Quota request \(index) was incorrectly consumed by history")
        }
        try await expectPeriodBudget {
            _ = try await BoundedHTTP.data(for: URLRequest(url: URL(string: "https://budget.fixture.invalid/quota/121")!), session: session, maxBytes: 16, timeout: 2, category: .quota)
        }
        let measured = RequestBudgetMeter.shared.snapshot()
        try check(measured.requests == 620 && measured.responseBodyBytes == 620, "Request count caps sent extra requests")
        try check(Date().timeIntervalSince(started) < 60, "Test crossed a request-budget window")
        print("PASS quota after history without reset: admitted=120 denied=121st denied_requests_sent=0 response_body_bytes=120")

        // Shared-byte cap is audited structurally to avoid generating 64 MiB of
        // test traffic. This is source verification, not a runtime cap test.
        let sourcePath = CommandLine.arguments.dropFirst().first ?? "Sources/BoundedHTTP.swift"
        let source = try String(contentsOfFile: sourcePath, encoding: .utf8)
        let compact = source.filter { !$0.isWhitespace }
        try check(compact.contains("guardreceived<=64*1_048_576-countelse{throwHTTPBudgetError.periodBudget}"), "Shared 64 MiB consume guard changed")
        try check(compact.contains("HTTPAdmission.shared.consume(data.count-accounted,large:category.isLargeDownload)"), "Response accounting bypasses shared consume")
        try check(compact.contains("varisLargeDownload:Bool{self==.updatePackage||self==.toolDownload}"), "History no longer maps to shared ordinary-byte budget")
        try check(compact.contains("now.timeIntervalSince(historyStarted)>=120") && compact.contains("now.timeIntervalSince(windowStarted)>=60"), "History/quota windows changed")
        print("PASS source audit only: history consume uses large=false and shares 64MiB/60s byte cap; history request window=500/120s; quota=120/60s. Runtime byte-cap exhaustion intentionally not exercised.")
        print("TOTAL fixture_requests=\(measured.requests) response_body_bytes=\(measured.responseBodyBytes) seconds=\(String(format: "%.3f", Date().timeIntervalSince(started))) external_requests=0")
    }
}
