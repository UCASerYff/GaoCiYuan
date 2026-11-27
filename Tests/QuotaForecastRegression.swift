import Foundation

// The fixture compiles the production models with Foundation only.
enum TokenBundle { static let bundle = Bundle.main }
enum AlertRules {
    static func attention(_ account: Account, threshold: Double, at: Date) -> [String] { [] }
}

@main struct QuotaForecastRegression {
    private static let clock = Date(timeIntervalSince1970: 1_800_000_000)
    private static let reset = clock.addingTimeInterval(75 * 60)

    private static func require(_ predicate: @autoclosure () -> Bool, _ message: String) throws {
        guard predicate() else { throw MonitorError.message(message) }
    }

    private static func sample(_ minutes: Double, _ used: Double, reset: Date? = QuotaForecastRegression.reset,
                               duration: Double? = 18_000, id: String = "short") -> UsageSnapshot {
        UsageSnapshot(observedAt: clock.addingTimeInterval(minutes * 60), source: "Fixture export",
                      quotas: [.init(id: id, title: "5 小时", usedPercent: used, resetsAt: reset, windowSeconds: duration)],
                      costs: [], balances: [])
    }

    private static func record(_ sample: UsageSnapshot, into account: inout Account, source: String = "fixture") {
        QuotaForecast.record(account: &account, snapshot: sample, sourceKey: source, now: clock)
        account.snapshot = sample
    }

    private static func makeAccount(_ samples: [UsageSnapshot]) -> Account {
        var account = Account(provider: .openai, kind: .agent, name: "Fixture account", connection: .file)
        for sample in samples { record(sample, into: &account) }
        return account
    }

    private static func row(_ account: Account, now: Date = QuotaForecastRegression.clock) throws -> QuotaWindowForecast {
        guard let forecast = QuotaForecast.evaluate(account: account, now: now).windows.first else {
            throw MonitorError.message("Fixture had no quota result")
        }
        return forecast
    }

    static func main() throws {
        let times: [Double] = [-82, -62, -42, -22, -2]
        let readings = zip(times, [50.0, 60, 70, 80, 90]).map { sample($0.0, $0.1) }
        let highRisk = makeAccount(readings)
        let risk = try row(highRisk)
        try require(risk.status == .risk && risk.confidence == .higher && risk.sampleCount == 5, "Risk needs five matching verified observations")
        try require(risk.remainingPercent == 10 && risk.ratePercentPerHour == 30 && risk.observedSpanSeconds == 4_800, "Measured percentage and evidence must remain separate")
        try require(abs((risk.estimatedExhaustedAt ?? .distantPast).timeIntervalSince(clock) - 1_080) < 1 && risk.resetsAt == reset, "Incorrect exhaustion estimate")

        let stable = try row(makeAccount(zip(times, [60.0, 61, 62, 63, 64]).map { sample($0.0, $0.1) }))
        try require(stable.status == .stable && stable.remainingPercent == 36 && stable.estimatedExhaustedAt == nil, "Stable estimates stop at reset")
        let passed = try row(makeAccount([sample(-72, 67), sample(-42, 82), sample(-12, 97)]))
        try require(passed.status == .risk && passed.reason == .estimatedPassed && passed.remainingPercent == 3, "A passed estimate does not become measured depletion")

        let cases: [([UsageSnapshot], QuotaForecastReason)] = [
            ([sample(-6, 30), sample(-4, 40), sample(-2, 50)], .insufficientHistory),
            ([sample(-250, 30, duration: nil), sample(-130, 40, duration: nil), sample(-2, 50, duration: nil)], .insufficientHistory),
            ([sample(-62, 60), sample(-32, 60.2), sample(-2, 60.4)], .lowChange),
            ([sample(-62, 20), sample(-42, 21), sample(-22, 22), sample(-2, 70)], .unstable),
            ([sample(-16, 90)], .stale),
            ([sample(1, 90)], .stale),
            ([sample(-2, 90, reset: clock.addingTimeInterval(-60))], .expired),
            ([sample(-2, 90, reset: nil)], .unknownReset),
            ([sample(-62, 20, reset: clock.addingTimeInterval(259_200), duration: nil),
              sample(-32, 21, reset: clock.addingTimeInterval(259_200), duration: nil),
              sample(-2, 22, reset: clock.addingTimeInterval(259_200), duration: nil)], .beyondEvidence),
        ]
        for (samples, reason) in cases {
            let observed = try row(makeAccount(samples))
            try require(observed.status == .insufficient && observed.reason == reason && observed.estimatedExhaustedAt == nil,
                        "Ineligible observations must not yield an ETA")
            try require(observed.remainingPercent == samples.last?.quotas.first?.remaining, "Ineligible data must keep the measured amount")
        }

        for latest in [sample(-2, 10), sample(-2, 90, reset: reset.addingTimeInterval(300)),
                       sample(-2, 90, duration: 36_000)] {
            let changed = try row(makeAccount(Array(readings.dropLast()) + [latest]))
            try require(changed.sampleCount == 1 && changed.reason == .insufficientHistory, "A replenishment or altered reset window starts a new segment")
        }
        var sourceChanged = highRisk
        record(sample(-1, 91), into: &sourceChanged, source: "other-exporter")
        let newOrigin = try row(sourceChanged)
        try require(newOrigin.sampleCount == 1 && newOrigin.reason == .insufficientHistory, "Source changes must sever the trend")
        var conflicted = highRisk
        QuotaForecast.record(account: &conflicted, snapshot: readings[4], sourceKey: "fixture", now: clock)
        QuotaForecast.record(account: &conflicted, snapshot: sample(-20, 84), sourceKey: "fixture", now: clock)
        try require(conflicted.quotaForecastHistory?.observations.count == 5, "Duplicate and out-of-order instants must be ignored")
        record(sample(-2, 95), into: &conflicted)
        let conflicting = try row(conflicted)
        try require(conflicting.sampleCount == 1, "Conflicting same-instant observations invalidate old evidence")

        var failed = highRisk
        failed.error = "Fixture timeout"
        let failedSync = try row(failed)
        try require(failedSync.reason == .syncIssue && failedSync.remainingPercent == 10, "Sync issues keep the last observed quota")
        failed.error = "登录已过期"
        try require(QuotaForecast.evaluate(account: failed, now: clock).windows.isEmpty, "Expired credentials must mask old quota")
        let depleted = try row(makeAccount([sample(-2, 100, reset: nil)]))
        try require(depleted.status == .exhausted && depleted.estimatedExhaustedAt == nil, "Measured exhaustion must stay a measurement")

        var grok = Account(provider: .grok, kind: .agent, name: "Grok Bot", connection: .agentLocal)
        record(sample(-2, 90), into: &grok)
        try require(QuotaForecast.evaluate(account: grok, now: clock).reason == .manualGrok && grok.quotaForecastHistory == nil,
                    "Grok Bot must never build forecast evidence")
        let balance = makeAccount([sample(-2, 100, reset: nil, id: "deepseek-topup-CNY")])
        try require(QuotaForecast.evaluate(account: balance, now: clock).reason == .nonQuota, "Balance ratios are not period quotas")
        let estimatedGrant = makeAccount(zip(times, [50.0, 60, 70, 80, 90]).map { sample($0.0, $0.1, id: "commandcode-monthly") })
        try require(QuotaForecast.evaluate(account: estimatedGrant, now: clock).reason == .nonQuota,
                    "A reset timestamp cannot turn a derived monetary grant into a measured quota")

        var legacy = highRisk
        legacy.quotaForecastHistory = nil
        legacy.history = readings
        let oldData = try JSONCoding.encoder.encode(legacy)
        let decodedLegacy = try JSONCoding.decoder.decode(Account.self, from: oldData)
        let unverified = try row(decodedLegacy)
        try require(decodedLegacy.history == readings && unverified.reason == .insufficientHistory, "Legacy history remains intact without assuming provenance")
        let roundTrip = try JSONCoding.decoder.decode(Account.self, from: JSONCoding.encoder.encode(highRisk))
        let restoredRisk = try row(roundTrip)
        try require(restoredRisk.status == .risk && restoredRisk.sampleCount == 5, "Verified evidence must survive reopening")
        guard var damaged = try JSONSerialization.jsonObject(with: oldData) as? [String: Any] else {
            throw MonitorError.message("Fixture JSON was not an object")
        }
        damaged["quotaForecastHistory"] = ["unexpected": true]
        let decodedDamaged = try JSONCoding.decoder.decode(Account.self, from: JSONSerialization.data(withJSONObject: damaged))
        try require(decodedDamaged.history == readings && decodedDamaged.quotaForecastHistory == nil, "Damaged optional evidence must not block account loading")

        var bounded = makeAccount([])
        for minute in -60 ... -1 { record(sample(Double(minute), Double(minute + 60)), into: &bounded) }
        try require(bounded.quotaForecastHistory?.observations.count == QuotaForecast.maxObservations, "Evidence must remain bounded")
        print("Quota forecast regression passed with isolated synthetic snapshots.")
    }
}
