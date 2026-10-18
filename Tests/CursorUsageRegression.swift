import Foundation

@main struct CursorUsageRegression {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
    static func event(_ id: String, timestamp: String = "2026-08-01T04:00:00.000Z", input: Int = 100, cost: Double? = 2) -> [String: Any] {
        var usage: [String: Any] = ["inputTokens": String(input), "outputTokens": 10, "cacheReadTokens": 50, "cacheWriteTokens": 3]
        if let cost { usage["totalCents"] = cost }
        return ["eventId": id, "conversationId": "private-conversation", "timestamp": timestamp, "model": "default", "chargedCents": 0, "tokenUsage": usage]
    }
    actor Pages {
        var pages: [Data]; var calls = 0; var status: Int
        init(_ pages: [[String: Any]], status: Int = 200) throws { self.pages = try pages.map { try JSONSerialization.data(withJSONObject: $0) }; self.status = status }
        func fetch(_ request: URLRequest, _ cap: Int) throws -> (Data, Int) {
            require(request.url == CursorUsageBridge.endpoint, "fixed official endpoint")
            require(request.value(forHTTPHeaderField: "Origin") == "https://cursor.com", "CSRF origin")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Int]
            require(body["page"] == calls + 1 && body["teamId"] == 0, "page numbering")
            calls += 1
            return (pages[min(calls - 1, pages.count - 1)], status)
        }
    }
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date()
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
        func advance(_ seconds: TimeInterval) { lock.lock(); date.addTimeInterval(seconds); lock.unlock() }
    }
    actor MockHistory {
        var calls = 0
        var batch: CursorUsageBatch
        init(_ batch: CursorUsageBatch) { self.batch = batch }
        func success() async throws -> CursorUsageBatch { calls += 1; try await Task.sleep(nanoseconds: 20_000_000); return batch }
        func lateSuccess() async -> CursorUsageBatch { calls += 1; try? await Task.sleep(nanoseconds: 50_000_000); return batch }
        func denied() throws -> CursorUsageBatch { calls += 1; throw CursorUsageFailure.permission }
        func networkFailure() throws -> CursorUsageBatch { calls += 1; throw CursorUsageFailure.network }
    }
    static func coordinatorRegression(_ batch: CursorUsageBatch, cookie: String) async throws {
        let clock = Clock(), mock = MockHistory(batch)
        let coordinator = CursorHistoryCoordinator(cacheLifetime: 60, clock: { clock.now() })
        async let first = coordinator.fetch(cookie: cookie) { try await mock.success() }
        async let second = coordinator.fetch(cookie: cookie) { try await mock.success() }
        let (a, b) = try await (first, second)
        var calls = await mock.calls
        require(calls == 1 && a.events == b.events, "same-account history single-flight")
        let cached = try await coordinator.fetch(cookie: cookie) { try await mock.success() }
        calls = await mock.calls
        require(calls == 1 && cached.reusedCache && cached.fetchedAt == a.fetchedAt, "only complete cached history reused without forging capture time")
        clock.advance(61)
        do { _ = try await coordinator.fetch(cookie: cookie) { try await mock.networkFailure() }; fatalError("incomplete refresh became a successful cached observation") }
        catch is CursorUsageFailure { }
        do { _ = try await coordinator.fetch(cookie: cookie) { try await mock.success() }; fatalError("history failure cooldown bypassed") }
        catch is CursorUsageFailure { }
        calls = await mock.calls
        require(calls == 2, "failed history round immediately repeated")
        clock.advance(301)
        let recovered = try await coordinator.fetch(cookie: cookie) { try await mock.success() }
        require(recovered.events == a.events && !recovered.reusedCache, "failed round replaced previous complete cache")
        _ = try await coordinator.fetch(cookie: cookie, forceRefresh: true) { try await mock.success() }
        calls = await mock.calls
        require(calls == 4, "explicit refresh could not bypass complete-cache TTL")

        let auth = CursorHistoryCoordinator(cacheLifetime: 0), denied = MockHistory(batch)
        for _ in 0..<2 {
            do { _ = try await auth.fetch(cookie: cookie) { try await denied.denied() }; fatalError("permission accepted") }
            catch is CursorUsageFailure { }
        }
        let deniedCalls = await denied.calls
        require(deniedCalls == 1, "403 credentials kept polling")
        _ = try await auth.fetch(cookie: cookie + "-rotated") { try await denied.success() }
        let rotatedCalls = await denied.calls
        require(rotatedCalls == 2, "new credential fingerprint could not retry")

        let cancelled = CursorHistoryCoordinator(cacheLifetime: 0), slow = MockHistory(batch)
        let task = Task { try await cancelled.fetch(cookie: cookie) { try await slow.success() } }
        defer { task.cancel() }
        let startDeadline = ProcessInfo.processInfo.systemUptime + 3
        while await slow.calls == 0 {
            require(ProcessInfo.processInfo.systemUptime < startDeadline, "history fixture never started")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        task.cancel()
        do { _ = try await task.value; fatalError("cancelled history returned a batch") } catch is CancellationError { }
        _ = try await cancelled.fetch(cookie: cookie) { try await slow.success() }
        let cancelledCalls = await slow.calls
        require(cancelledCalls == 2, "cancellation incorrectly cached a partial result or entered failure backoff")

        let rotating = CursorHistoryCoordinator(cacheLifetime: 0), late = MockHistory(batch)
        let oldCredential = Task { try await rotating.fetch(cookie: cookie) { await late.lateSuccess() } }
        defer { oldCredential.cancel() }
        let rotationDeadline = ProcessInfo.processInfo.systemUptime + 3
        while await late.calls == 0 {
            require(ProcessInfo.processInfo.systemUptime < rotationDeadline, "old credential fixture never started")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        _ = try await rotating.fetch(cookie: cookie + "-new-token") { try await late.success() }
        do { _ = try await oldCredential.value; fatalError("response for replaced credential escaped cancellation") } catch is CancellationError { }
    }
    static func failure(_ pages: Pages, _ message: String, cap: Int = 64 * 1024 * 1024) async {
        do {
            _ = try await CursorUsageBridge.fetch(cookie: "WorkosCursorSessionToken=fixture-account%3A%3Afake", maximumPages: 3, maximumBytes: cap, pageFetcher: { try await pages.fetch($0,$1) })
            fatalError(message)
        } catch { print("PASS rejected: \(message)") }
    }
    static func main() async throws {
        let cookie = "WorkosCursorSessionToken=fixture-account%3A%3Afake"
        let pages = try Pages([["totalUsageEventsCount": 2,"usageEventsDisplay": [event("a")]], ["totalUsageEventsCount": 2,"usageEventsDisplay": [event("b", timestamp: "2026-08-02T04:00:00.000Z", input: 200)]]])
        let batch = try await CursorUsageBridge.fetch(cookie: cookie, pageFetcher: { try await pages.fetch($0,$1) })
        try await coordinatorRegression(batch, cookie: cookie)
        let events = batch.events
        let count = await pages.calls
        require(count == 2 && events.count == 2, "server-clamped short page must continue")
        require(events.allSatisfy { $0.model == "cursor-auto" && $0.amounts.costUSD == 0.02 }, "official metered cost before chargedCents")
        require(events.map(\.amounts.totalTokens).sorted() == [163,263], "disjoint buckets")
        let encoded = String(data: try JSONEncoder().encode(events), encoding: .utf8)!
        require(!encoded.contains("fixture-account") && !encoded.contains("private-conversation") && !encoded.contains("fake"), "only hashes may persist")
        let refreshed = try CursorUsageBridge.decode(event("a"), accountKey: events[0].accountKey)
        require(events.contains { $0.eventID == refreshed.eventID }, "credential refresh stable identity")
        await failure(try Pages([["totalUsageEventsCount": 2,"usageEventsDisplay": [event("a")]], ["totalUsageEventsCount": 2,"usageEventsDisplay": []]]), "truncated pagination")
        await failure(try Pages([["totalUsageEventsCount": 2,"usageEventsDisplay": [event("a")]], ["totalUsageEventsCount": 2,"usageEventsDisplay": [event("a")]]]), "overlapping pages cannot undercount")
        await failure(try Pages([["totalUsageEventsCount": 2,"usageEventsDisplay": [event("a")]], ["totalUsageEventsCount": 3,"usageEventsDisplay": [event("b")]]]), "moving advertised count")
        await failure(try Pages([["totalUsageEventsCount": 0]]), "malformed success")
        await failure(try Pages([[:]], status: 403), "permission denied")
        await failure(try Pages([["usageEventsDisplay": [event("a")]]]), "cumulative response cap", cap: 10)
        let repeatedUnmetered = try Pages([["totalUsageEventsCount": 2,"usageEventsDisplay": [["kind":"legacy"]]]])
        await failure(repeatedUnmetered, "repeated unmetered page rejected before page limit")
        let repeatedCalls = await repeatedUnmetered.calls
        require(repeatedCalls == 2, "repeated page wasted remaining page budget")
        let invalidBudget = try Pages([["usageEventsDisplay": []]])
        do { _ = try await CursorUsageBridge.fetch(cookie: cookie, maximumPages: 0, pageFetcher: { try await invalidBudget.fetch($0,$1) }); fatalError("invalid page budget accepted") }
        catch is CursorUsageFailure { }
        let invalidCalls = await invalidBudget.calls
        require(invalidCalls == 0, "invalid budget issued HTTP request")
        let oversizedPage = try Pages([["usageEventsDisplay": [event("large")]]])
        do { _ = try await CursorUsageBridge.fetch(cookie: cookie, maximumPageBytes: 16, pageFetcher: { request, cap in
            require(cap == 16, "per-page allowance ignored")
            return try await oversizedPage.fetch(request,cap)
        }); fatalError("oversized page accepted") } catch is CursorUsageFailure { }
        let unmeteredPages = try Pages([["totalUsageEventsCount": 4, "usageEventsDisplay": [event("a"), ["tokenUsage": NSNull()], ["kind": "legacy"], ["tokenUsage": [:]]]]])
        let unmetered = try await CursorUsageBridge.fetch(cookie: cookie, pageFetcher: { try await unmeteredPages.fetch($0,$1) })
        require(unmetered.events.count == 1 && unmetered.unmeteredEvents == 3, "unmetered rows explicitly excluded, never zero")
        var unknownRaw = event("unpriced", cost: nil); unknownRaw.removeValue(forKey: "chargedCents")
        let unknown = try CursorUsageBridge.decode(unknownRaw, accountKey: events[0].accountKey)
        let free = try CursorUsageBridge.decode(event("free", cost: 0), accountKey: events[0].accountKey)
        require(unknown.amounts.costUSD == nil && free.amounts.costUSD == 0, "unknown cost differs from explicit zero")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gq-cursor-fixture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = UsageLedger(directory: root.appendingPathComponent("a"), deviceID: "00000000-0000-4000-8000-000000000001", deviceName: "A")
        let b = UsageLedger(directory: root.appendingPathComponent("b"), deviceID: "00000000-0000-4000-8000-000000000002", deviceName: "B")
        func scan(_ events: [CursorUsageEvent]) -> UsageEngineScan { .init(capturedAt: .now, days: [], sessions: [], clients: ["cursor"], warnings: [], cursorEvents: events) }
        try await a.ingest(scan(events))
        try await a.ingest(scan(events))
        try await a.ingest(scan([]))
        var result = try await a.dashboard()
        require(result.total.totalTokens == 426 && result.byClient.count == 1, "repeat scan must not double")
        let c = try CursorUsageBridge.decode(event("c", input: 20), accountKey: events[0].accountKey)
        try await a.ingest(scan([c])) // provider old events no longer exported
        result = try await a.dashboard()
        require(result.total.totalTokens == 509, "server retention cannot swallow new event")
        var summary = try await a.sessionSummary()
        require(summary.total.totalTokens == 509, "conversation total rebuilt from retained events")
        let page = try await a.sessionPage()
        require(page.totalCount == 1, "one conversation across days")
        try await b.ingest(scan(events + [c]))
        let archive = root.appendingPathComponent("export.json")
        try await b.export(to: archive)
        try await a.importFile(archive)
        try await a.importFile(archive)
        result = try await a.dashboard(); summary = try await a.sessionSummary()
        require(result.total.totalTokens == 509 && summary.total.totalTokens == 509, "same cloud account on two devices must deduplicate")
        var repriced = c; repriced.amounts.costUSD = 0.04
        try await a.ingest(scan([repriced]))
        result = try await a.dashboard()
        require(abs((result.total.costUSD ?? 0) - 0.08) < 0.000001, "official cost correction reuses event")
        try await a.importFile(archive)
        result = try await a.dashboard()
        require(abs((result.total.costUSD ?? 0) - 0.08) < 0.000001, "stale device export cannot replace newer official cost")
        require(!UsageClientDefinition.defaultIDs.contains("cursor"), "Cursor must remain explicit opt-in")
        let empty = try await UsageEngine.scan(configuration: .init(enabledClientIDs: ["cursor"]), engineURL: URL(fileURLWithPath: "/fixture/no-binary"),
            configurationDirectory: root.appendingPathComponent("isolated-engine-cache"), homeDirectory: root.appendingPathComponent("empty-home"))
        require(empty.cursorEvents == nil && empty.warnings.contains { $0.contains("Cursor") }, "auth failure is explicit, local history unchanged")
        let source = root.appendingPathComponent("relocated-gemini/antigravity-cli/conversations")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let detected = UsageClientDefinition.detectedIDs(homeDirectory: root.appendingPathComponent("empty-home"), environment: ["GEMINI_CLI_HOME": source.deletingLastPathComponent().deletingLastPathComponent().path])
        require(detected.contains("antigravity"), "environment root detected")
        print("PASS Cursor MockHTTP pagination/budgets/repeated pages, complete-cache TTL/single-flight/auth pause/cancellation, disjoint tokens, anonymous IDs, retained history, conversation sums, cross-device merge, cost correction, opt-in, environment roots")
    }
}
