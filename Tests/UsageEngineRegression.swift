import Foundation

@main struct UsageEngineRegression {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gqns-engine-fixture-" + UUID().uuidString)
        let home = root.appendingPathComponent("home")
        let configuration = root.appendingPathComponent("configuration")
        let cache = configuration.appendingPathComponent("cache")
        let sessions = home.appendingPathComponent(".codex/sessions/2026/08")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Fresh empty public-price caches make this test completely offline.
        for filename in ["pricing-litellm.json", "pricing-openrouter.json", "pricing-models-dev.json"] {
            let value: [String: Any] = ["timestamp": Int(Date().timeIntervalSince1970), "data": [String: String]()]
            try JSONSerialization.data(withJSONObject: value).write(to: cache.appendingPathComponent(filename))
        }
        func line(_ object: [String: Any]) throws -> String {
            String(data: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), encoding: .utf8)! + "\n"
        }
        func usage(_ timestamp: String, _ input: Int, _ cached: Int, _ output: Int, _ reasoning: Int, previous: [Int] = [0, 0, 0, 0]) -> [String: Any] {
            let counts = ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output, "reasoning_output_tokens": reasoning, "total_tokens": input + output]
            let last = ["input_tokens": input - previous[0], "cached_input_tokens": cached - previous[1], "output_tokens": output - previous[2], "reasoning_output_tokens": reasoning - previous[3], "total_tokens": input + output - previous[0] - previous[2]]
            return ["timestamp": timestamp, "type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": counts, "last_token_usage": last]]]
        }
        let transcript = sessions.appendingPathComponent("rollout-fixture-session.jsonl")
        var source = try line(["timestamp": "2026-08-01T04:00:00.000Z", "type": "session_meta", "payload": ["id": "fixture-session", "cwd": "/fixture/project-alpha", "model_provider": "openai"]])
        source += try line(["timestamp": "2026-08-01T04:00:00.000Z", "type": "turn_context", "payload": ["model": "fixture-model", "cwd": "/fixture/project-alpha"]])
        source += try line(usage("2026-08-01T04:00:01.000Z", 100, 60, 25, 5))
        source += try line(usage("2026-08-01T04:00:02.000Z", 100, 60, 25, 5)) // repeated cumulative snapshot
        source += try line(["timestamp": "2026-08-02T04:00:00.000Z", "type": "turn_context", "payload": ["model": "fixture-model", "cwd": "/fixture/project-alpha"]])
        source += try line(usage("2026-08-02T04:00:01.000Z", 300, 180, 55, 15, previous: [100, 60, 25, 5]))
        try Data(source.utf8).write(to: transcript)
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        let settings = UsageEngineConfiguration(enabledClientIDs: ["codex"], modelPrices: [
            .init(model: "fixture-model", inputPerMillion: 2, outputPerMillion: 10, cacheReadPerMillion: 0.2, cacheWritePerMillion: 0)
        ])
        let first = try await UsageEngine.scan(configuration: settings, engineURL: executable,
            configurationDirectory: configuration, homeDirectory: home)
        require(first.days.count == 2, "session must remain split across two days")
        require(first.sessions.count == 1, "repeated cumulative snapshot must not create another session")
        let total = first.sessions[0].amounts
        require(total.totalTokens == 355, "input/cache/reasoning overlap or cumulative dedup regression: \(total)")
        require(total.input == 120 && total.cacheRead == 180 && total.output == 40 && total.reasoning == 15, "Codex buckets not disjoint")
        require(first.days.reduce(0) { $0 + $1.amounts.totalTokens } == total.totalTokens, "daily and session totals differ")
        require(first.days.allSatisfy { $0.sessionID == first.sessions[0].sessionID }, "day rows lost session identity")
        require(first.sessions[0].projectLabel == "project-alpha", "workspace attribution missing")
        require(total.costUSD != nil && total.costUSD! > 0, "custom pricing must reach rows")
        let persisted = String(data: try JSONEncoder().encode(first), encoding: .utf8)!
        require(!persisted.contains("/fixture/project-alpha"), "raw project path leaked into persisted DTO")
        let second = try await UsageEngine.scan(configuration: settings, engineURL: executable,
            configurationDirectory: configuration, homeDirectory: home, knownDayFingerprints: first.dayFingerprints)
        require(second.days.isEmpty, "unchanged historical days should reuse fingerprints")
        require(second.dayFingerprints == first.dayFingerprints, "fingerprints are nondeterministic")
        source += try line(["timestamp": "2026-08-02T04:00:02.000Z", "type": "turn_context", "payload": ["model": "fixture-model", "cwd": "/fixture/project-alpha"]])
        source += try line(usage("2026-08-02T04:00:03.000Z", 400, 250, 75, 20, previous: [300, 180, 55, 15]))
        try Data(source.utf8).write(to: transcript)
        let third = try await UsageEngine.scan(configuration: settings, engineURL: executable,
            configurationDirectory: configuration, homeDirectory: home, knownDayFingerprints: second.dayFingerprints)
        require(third.days.count == 1 && third.days[0].day == "2026-08-02", "only changed day must be rescanned")
        require(third.sessions[0].amounts.totalTokens == 475, "append refresh missed cumulative delta")
        // Strict decoder checks unknown pricing and rejects missing session IDs.
        let unknown = Data(#"{"entries":[{"client":"claude","model":"unknown","sessionId":"unknown-session","input":10,"output":5,"cacheRead":0,"cacheWrite":0,"reasoning":3,"messageCount":1,"cost":0}]}"#.utf8)
        let decoded = try UsageEngine.decodeReportData(unknown)
        require(decoded[0].amounts.costUSD == nil && decoded[0].amounts.totalTokens == 15, "unknown cost or overlapping reasoning shown as known")
        let workspaceSplit = Data(#"{"entries":[{"client":"claude","model":"m","sessionId":"same","workspaceKey":"a","input":10,"output":5,"cacheRead":0,"cacheWrite":0,"reasoning":0,"messageCount":1,"cost":1},{"client":"claude","model":"m","sessionId":"same","workspaceKey":"b","input":20,"output":10,"cacheRead":0,"cacheWrite":0,"reasoning":0,"messageCount":1,"cost":2}],"workspaces":[{"workspaceKey":"a","label":"a","path":"/fixture/a"},{"workspaceKey":"b","label":"b","path":"/fixture/b"}]}"#.utf8)
        let merged = try UsageEngine.decodeReportData(workspaceSplit)
        require(merged.count == 1 && merged[0].amounts.totalTokens == 45 && merged[0].amounts.costUSD == 3 && merged[0].projectKey == nil, "workspace split must sum into one session snapshot")
        let paidCacheWrite = Data(#"{"entries":[{"client":"claude","model":"cache-model","sessionId":"priced-session","input":0,"output":0,"cacheRead":0,"cacheWrite":10,"reasoning":0,"messageCount":1,"cost":4}]}"#.utf8)
        let incompleteFreePrice = UsageModelPrice(model: "cache-model", inputPerMillion: 0, outputPerMillion: 0, cacheReadPerMillion: 0, cacheWritePerMillion: 0)
        let knownPaid = try UsageEngine.decodeReportData(paidCacheWrite, prices: [incompleteFreePrice])
        require(knownPaid[0].amounts.costUSD == 4, "partial free override must not erase a positive engine cost")
        let noPriceCacheWrite = Data(#"{"entries":[{"client":"claude","model":"cache-model","sessionId":"unpriced-session","input":0,"output":0,"cacheRead":0,"cacheWrite":10,"reasoning":0,"messageCount":1,"cost":0}]}"#.utf8)
        let unknownOneHour = try UsageEngine.decodeReportData(noPriceCacheWrite, prices: [incompleteFreePrice])
        require(unknownOneHour[0].amounts.costUSD == nil, "missing one-hour cache rate must not claim free cache writes")
        var completeFreePrice = incompleteFreePrice; completeFreePrice.cacheWrite1hPerMillion = 0
        let trulyFree = try UsageEngine.decodeReportData(noPriceCacheWrite, prices: [completeFreePrice])
        require(trulyFree[0].amounts.costUSD == 0, "explicit all-bucket zero rates must support free models")
        let paidWithoutTokens = Data(#"{"entries":[{"client":"claude","model":"cache-model","sessionId":"cost-only","input":0,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0,"messageCount":0,"cost":2}]}"#.utf8)
        let costOnly = try UsageEngine.decodeReportData(paidWithoutTokens)
        require(costOnly[0].amounts.costUSD == 2, "zero-token row must not erase known monetary cost")
        let allClients = try await UsageEngine.scan(configuration: UsageEngineConfiguration(modelPrices: settings.modelPrices), engineURL: executable,
            configurationDirectory: configuration, homeDirectory: home)
        require(allClients.sessions.count == 1 && allClients.sessions[0].amounts.totalTokens == 475, "default client catalog rejected or duplicated fixture data")
        print("Usage engine regression passed: isolated actual CLI; 2-day cumulative/cache/reasoning; session identity; custom pricing; unchanged/changed-day fingerprints; full default client list accepted; workspace-split aggregation; no raw project paths.")
    }
}
