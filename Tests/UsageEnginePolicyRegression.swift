import Foundation

// Standalone fixture test: no app/browser launch, no real account and no
// external network. URLProtocol owns both fixed public-pricing URLs.
private final class PublicPriceFixture: URLProtocol {
    static let lock = NSLock()
    static var requests = 0
    static var fail = false
    static var malformedLiteLLM = false
    static func reset(fail: Bool = false, malformedLiteLLM: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        requests = 0; self.fail = fail; self.malformedLiteLLM = malformedLiteLLM
    }
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests += 1
        let failing = Self.fail, malformed = Self.malformedLiteLLM
        Self.lock.unlock()
        let litellm = request.url!.host == "raw.githubusercontent.com"
        let body = litellm
            ? (malformed ? #"{"fixture-model":{"input_cost_per_token":-1,"output_cost_per_token":0.000004}}"#
                : #"{"fixture-model":{"input_cost_per_token":0.000002,"output_cost_per_token":0.000004,"cache_read_input_token_cost":0.0000002}}"#)
            : #"{"fixture-provider":{"models":{"fixture-model":{"id":"fixture-model","cost":{"input":2,"output":4,"cache_read":0.2}}}}}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: failing ? 503 : 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct UsageEnginePolicyRegression {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "UsageEnginePolicyRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("gqns-engine-policy-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), config = root.appendingPathComponent("config")
        let transcript = home.appendingPathComponent(".codex/sessions/fixture.json")
        try fm.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        let engine = root.appendingPathComponent("fixture-engine")
        let script = #"""
        #!/usr/bin/python3
        import os, sys, json, time, signal
        args = sys.argv[1:]
        cfg = os.environ["TOKSCALE_CONFIG_DIR"]
        if os.environ.get("TOKSCALE_PRICING_CACHE_ONLY") != "1": sys.exit(91)
        os.makedirs(cfg, exist_ok=True)
        with open(os.path.join(cfg,"calls"),"a") as out: out.write(" ".join(args)+"\n")
        home = args[args.index("--home")+1]
        with open(os.path.join(home,".codex/sessions/fixture.json")) as inp: data=json.load(inp)
        if data.get("cancel"):
            child=os.fork()
            if child==0:
                signal.signal(signal.SIGTERM,signal.SIG_IGN)
                with open(os.path.join(cfg,"child.pid"),"w") as out: out.write(str(os.getpid()))
                while True:
                    with open(os.path.join(cfg,"heartbeat"),"w") as out: out.write(str(time.time_ns()))
                    time.sleep(0.02)
            time.sleep(90)
        n=data.get("tokens",10)
        if "graph" in args:
            result={"contributions":[{"date":"2020-01-01","clients":[{"client":"codex","modelId":"fixture-model","tokens":{"input":n,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0},"cost":0,"messages":1}]}]}
        else:
            result={"entries":[{"client":"codex","model":"fixture-model","sessionId":data.get("session","session-a"),"input":n,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0,"messageCount":1,"cost":0}]}
        print(json.dumps(result))
        """#
        try Data(script.utf8).write(to: engine)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: engine.path)
        func writeSource(session: String = "session-a", tokens: Int = 10, cancel: Bool = false) throws {
            try JSONSerialization.data(withJSONObject: ["session": session, "tokens": tokens, "cancel": cancel])
                .write(to: transcript, options: .atomic)
        }
        func calls(_ directory: URL) -> Int {
            ((try? String(contentsOf: directory.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(separator: "\n").count
        }
        let settings = UsageEngineConfiguration(enabledClientIDs: ["codex"])
        try writeSource()
        let first = try await UsageEngine.scan(configuration: settings, engineURL: engine, configurationDirectory: config, homeDirectory: home)
        try check(calls(config) == 3, "initial fixture must run graph, one day and all-time report")
        try check(first.sessions[0].amounts.costUSD == nil, "cold cache must preserve unknown cost")
        try check(first.warnings.joined().contains("不会自动联网"), "cold-cache offline rule must be visible")
        let repeated = try await UsageEngine.scan(configuration: settings, engineURL: engine, configurationDirectory: config, homeDirectory: home, knownDayFingerprints: first.dayFingerprints)
        try check(calls(config) == 3 && repeated.days.isEmpty, "unchanged source must reuse numeric report without spawning duplicate CLI")
        try check(repeated.capturedAt == first.capturedAt, "cache reuse must not claim a fresh source capture")
        // Same day totals, different session identity: graph alone cannot be
        // the cache key. Also keep the file's size unchanged.
        try writeSource(session: "session-b")
        let changed = try await UsageEngine.scan(configuration: settings, engineURL: engine, configurationDirectory: config, homeDirectory: home, knownDayFingerprints: first.dayFingerprints)
        try check(calls(config) == 5 && changed.sessions[0].sessionID == "session-b", "equal graph aggregates must not hide source-content/session changes")
        try writeSource(session: "session-b", tokens: 11)
        let appended = try await UsageEngine.scan(configuration: settings, engineURL: engine, configurationDirectory: config, homeDirectory: home, knownDayFingerprints: changed.dayFingerprints)
        try check(calls(config) == 8 && appended.days[0].amounts.input == 11, "changed usage must rescan day and preserve real values")

        let headless = home.appendingPathComponent(".config/tokscale/headless/codex/capture.jsonl")
        try fm.createDirectory(at: headless.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("headless-fixture\n".utf8).write(to: headless)
        _ = try await UsageEngine.scan(configuration: settings, engineURL: engine, configurationDirectory: config, homeDirectory: home, knownDayFingerprints: appended.dayFingerprints)
        try check(calls(config) == 10, "default Headless source changes must invalidate report reuse")
        let extra = root.appendingPathComponent("extra-source")
        try fm.createDirectory(at: extra, withIntermediateDirectories: true)
        let extraLog = extra.appendingPathComponent("extra.jsonl")
        try Data("extra-v1\n".utf8).write(to: extraLog)
        try JSONSerialization.data(withJSONObject: ["scanner": ["extraScanPaths": ["codex": [extra.path]]]])
            .write(to: config.appendingPathComponent("settings.json"))
        _ = try await UsageEngine.scan(configuration: settings, engineURL: engine, configurationDirectory: config, homeDirectory: home, knownDayFingerprints: appended.dayFingerprints)
        try Data("extra-v2\n".utf8).write(to: extraLog)
        _ = try await UsageEngine.scan(configuration: settings, engineURL: engine, configurationDirectory: config, homeDirectory: home, knownDayFingerprints: appended.dayFingerprints)
        try check(calls(config) == 14, "scanner.extraScanPaths must participate in source content invalidation")

        // A wide tool root may contain auth files; its mere presence disables
        // the optimization, rather than hashing the app's data folder.
        try fm.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        let conservativeConfig = root.appendingPathComponent("conservative-config")
        let conservativeSettings = UsageEngineConfiguration(enabledClientIDs: ["codex", "copilot"])
        let conservative = try await UsageEngine.scan(configuration: conservativeSettings, engineURL: engine, configurationDirectory: conservativeConfig, homeDirectory: home)
        _ = try await UsageEngine.scan(configuration: conservativeSettings, engineURL: engine, configurationDirectory: conservativeConfig, homeDirectory: home, knownDayFingerprints: conservative.dayFingerprints)
        try check(calls(conservativeConfig) == 5, "unverified tool roots must disable numeric report reuse")

        let parallel = root.appendingPathComponent("parallel-config")
        try await withThrowingTaskGroup(of: UsageEngineScan.self) { tasks in
            for _ in 0..<4 { tasks.addTask { try await UsageEngine.scan(configuration: settings, engineURL: engine, configurationDirectory: parallel, homeDirectory: home) } }
            for try await scan in tasks { try check(scan.sessions[0].amounts.input == 11, "merged scan lost data") }
        }
        try check(calls(parallel) == 3, "overlapping identical scans must share the persisted complete numeric result")

        // A parent and TERM-resistant descendant must stop together.
        let cancelledConfig = root.appendingPathComponent("cancelled-config")
        try writeSource(cancel: true)
        let task = Task { try await UsageEngine.scan(configuration: settings, engineURL: engine, configurationDirectory: cancelledConfig, homeDirectory: home) }
        let childFile = cancelledConfig.appendingPathComponent("child.pid"), heartbeat = cancelledConfig.appendingPathComponent("heartbeat")
        let waitUntil = Date().addingTimeInterval(10)
        while !fm.fileExists(atPath: heartbeat.path), Date() < waitUntil { try await Task.sleep(nanoseconds: 20_000_000) }
        guard let childText = try? String(contentsOf: childFile, encoding: .utf8), Int32(childText) != nil else { task.cancel(); throw NSError(domain: "fixture-child", code: 1) }
        task.cancel()
        var wasCancelled = false
        do { _ = try await task.value } catch is CancellationError { wasCancelled = true }
        try check(wasCancelled, "scan cancellation must propagate as CancellationError")
        try await Task.sleep(nanoseconds: 150_000_000)
        let stoppedHeartbeat = try Data(contentsOf: heartbeat)
        try await Task.sleep(nanoseconds: 150_000_000)
        try check(try Data(contentsOf: heartbeat) == stoppedHeartbeat, "TERM-resistant descendant survived cancellation")

        let network = URLSessionConfiguration.ephemeral
        network.protocolClasses = [PublicPriceFixture.self]
        let session = URLSession(configuration: network)
        defer { session.invalidateAndCancel() }
        let prices = root.appendingPathComponent("prices")
        await BoundedHTTP.resetForTesting(); PublicPriceFixture.reset()
        let refreshed = try await UsageEngine.refreshPublicPrices(configurationDirectory: prices, session: session)
        try check(PublicPriceFixture.requestCount == 2 && refreshed.updatedSources.count == 2, "manual price refresh must issue exactly two fixed-source requests")
        let before = try Data(contentsOf: prices.appendingPathComponent("cache/pricing-litellm.json"))
        let normalized = try JSONSerialization.jsonObject(with: Data(contentsOf: prices.appendingPathComponent("cache/pricing-models-dev.json"))) as! [String: Any]
        let models = normalized["data"] as! [String: [String: Double]]
        try check(models["fixture-provider/fixture-model"]?["input_cost_per_token"] == 0.000002, "models.dev per-million rates must normalize without changing cost units")
        let warm = try await UsageEngine.refreshPublicPrices(configurationDirectory: prices, session: session)
        try check(PublicPriceFixture.requestCount == 2 && warm.message.contains("本次没有联网"), "one-hour effective cache must suppress repeated public-price downloads")
        let traces = await HTTPDiagnostics.shared.snapshot()
        try check(traces.count == 2 && traces.allSatisfy { $0.category == .pricing && $0.trigger == "pricing.manual" }, "public price requests must be measured as explicit pricing traffic")

        // Expire only our fixture update lease, then fail both sources. Never
        // overwrite validated prices or retry every scan/UI click on failure.
        try fm.removeItem(at: prices.appendingPathComponent("pricing-refresh-state.json"))
        await BoundedHTTP.resetForTesting(); PublicPriceFixture.reset(fail: true)
        var failed = false
        do { _ = try await UsageEngine.refreshPublicPrices(configurationDirectory: prices, session: session) } catch { failed = true }
        try check(failed && PublicPriceFixture.requestCount == 2, "price failures must be finite")
        try check(try Data(contentsOf: prices.appendingPathComponent("cache/pricing-litellm.json")) == before, "failed price update changed prior verified cache")
        do { _ = try await UsageEngine.refreshPublicPrices(configurationDirectory: prices, session: session) } catch {}
        try check(PublicPriceFixture.requestCount == 2, "failed manual update must honor persistent 15-minute backoff")

        let partial = root.appendingPathComponent("partial-prices")
        try fm.createDirectory(at: partial.appendingPathComponent("cache"), withIntermediateDirectories: true)
        try before.write(to: partial.appendingPathComponent("cache/pricing-litellm.json"))
        await BoundedHTTP.resetForTesting(); PublicPriceFixture.reset(malformedLiteLLM: true)
        let recovered = try await UsageEngine.refreshPublicPrices(configurationDirectory: partial, session: session)
        try check(recovered.updatedSources == ["models.dev"] && !recovered.warnings.isEmpty, "malformed one-source price data must report a partial update")
        try check(try Data(contentsOf: partial.appendingPathComponent("cache/pricing-litellm.json")) == before, "malformed price data replaced last good table")
        print("Usage engine policy regression passed: cold-cache CLI offline; content-aware persistent reuse; same-total session/Headless/extra-path invalidation; conservative unsupported-root fallback; concurrent scan merge; whole process-group cancellation; two fixed public-price requests; normalized units/receipts; one-hour reuse; finite failure/backoff; malformed-source preservation; pricing diagnostics. No real external requests or app smoke test.")
    }
}
