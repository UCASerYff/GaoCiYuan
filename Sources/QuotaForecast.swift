import Foundation

enum QuotaForecastStatus: Equatable {
    case available, risk, stable, exhausted, insufficient, excluded
}

enum QuotaForecastReason: Equatable {
    case disabled, manualGrok, nonQuota, noReadings, credential
    case unknownReset, expired, stale, insufficientHistory, lowChange, unstable, beyondEvidence, syncIssue, estimatedPassed
}

enum QuotaForecastConfidence: Equatable {
    case moderate, higher
}

struct AccountQuotaForecast {
    let status: QuotaForecastStatus
    var reason: QuotaForecastReason? = nil
    var windows: [QuotaWindowForecast] = []
}

struct QuotaWindowForecast: Identifiable {
    let id: String
    let title: String
    let observedAt: Date?
    let resetsAt: Date?
    let remainingPercent: Double?
    let source: String
    var status: QuotaForecastStatus = .insufficient
    var reason: QuotaForecastReason? = nil
    var estimatedExhaustedAt: Date? = nil
    var confidence: QuotaForecastConfidence? = nil
    var sampleCount = 0
    var observedSpanSeconds: TimeInterval = 0
    var ratePercentPerHour: Double? = nil
}

struct QuotaForecastHistory: Codable, Equatable {
    var sourceKey: String
    var observations: [QuotaForecastObservation]
}

struct QuotaForecastObservation: Codable, Equatable {
    let observedAt: Date
    let windows: [String: QuotaForecastReading]
}

struct QuotaForecastReading: Codable, Equatable {
    let usedPercent: Double
    let resetsAt: Date
    let windowSeconds: TimeInterval?
}

enum QuotaForecast {
    static let maxObservations = 48
    private static let lookback: TimeInterval = 86_400
    private static let maxGap: TimeInterval = 7_200
    private static let minSpacing: TimeInterval = 300
    private static let minSpan: TimeInterval = 1_800
    private static let maxFitPoints = 12
    private static let derivedBalanceIDs: Set<String> = ["deepseek-budget", "commandcode-monthly", "commandcode-credits"]

    /// Forecast samples keep their real observation timestamps. The regular change history and ledger keep their own rules.
    static func record(account: inout Account, snapshot: UsageSnapshot, sourceKey: String, now: Date = Date()) {
        guard account.kind == .agent, !account.usesGrokBotQuota, !snapshot.isHistoricalAntigravityReading else { return }
        var history: [QuotaForecastObservation] = []
        if let previous = account.quotaForecastHistory, previous.sourceKey == sourceKey {
            history = Array(previous.observations.suffix(maxObservations))
        } else {
            account.quotaForecastHistory = nil
        }
        let observed = snapshot.observedAt
        guard (0...lookback).contains(now.timeIntervalSince(observed)) else { return }
        var windows: [String: QuotaForecastReading] = [:]
        for quota in percentageQuotas(snapshot) {
            windows[quota.id] = reading(quota, observed: observed)
        }
        guard !windows.isEmpty || !history.isEmpty else { return }
        if let latest = history.last, observed <= latest.observedAt {
            if observed < latest.observedAt || windows == latest.windows { return }
            // Different measurements stamped with the same instant cannot establish a rate.
            history.removeAll()
        }
        history.removeAll { observed.timeIntervalSince($0.observedAt) > lookback }
        history.append(.init(observedAt: observed, windows: windows))
        account.quotaForecastHistory = .init(sourceKey: sourceKey, observations: Array(history.suffix(maxObservations)))
    }

    static func evaluate(account: Account, now: Date = Date()) -> AccountQuotaForecast {
        guard account.enabled else { return .init(status: .excluded, reason: .disabled) }
        if account.usesGrokBotQuota { return .init(status: .excluded, reason: .manualGrok) }
        if account.errorIsCredential { return .init(status: .insufficient, reason: .credential) }
        guard let snapshot = account.snapshot, !snapshot.isHistoricalAntigravityReading else {
            return .init(status: .insufficient, reason: .noReadings)
        }
        let quotas = percentageQuotas(snapshot)
        guard !quotas.isEmpty else { return .init(status: .excluded, reason: .nonQuota) }
        let observations = account.quotaForecastHistory?.observations ?? []
        let history: ArraySlice<QuotaForecastObservation> = observations.suffix(maxObservations)
        let syncIssue = account.error != nil || account.statusNote != nil
        let windows: [QuotaWindowForecast] = quotas.map {
            evaluate(window: $0, snapshot: snapshot, history: history, now: now, syncIssue: syncIssue)
        }
        let status: QuotaForecastStatus = windows.contains { $0.status != .insufficient } ? .available : .insufficient
        return .init(status: status, windows: windows)
    }

    private static func percentageQuotas(_ snapshot: UsageSnapshot) -> [Quota] {
        snapshot.historicalChartQuotas.filter { quota in
            // Exclude derived balance rows and positional identities from the retired Antigravity fallback.
            !derivedBalanceIDs.contains(quota.id) && !quota.id.hasPrefix("deepseek-topup-") && !quota.id.hasPrefix("gemini-cascade-")
        }
    }

    private static func reading(_ quota: Quota, observed: Date) -> QuotaForecastReading? {
        guard (0...100).contains(quota.usedPercent), let reset = quota.resetsAt, reset > observed else { return nil }
        if let length = quota.windowSeconds,
           !(0 < length && length <= 366 * 86_400 && reset.timeIntervalSince(observed) <= length) { return nil }
        return .init(usedPercent: quota.usedPercent, resetsAt: reset, windowSeconds: quota.windowSeconds)
    }

    private typealias Point = (date: Date, used: Double)

    private static func recentPoints(_ history: ArraySlice<QuotaForecastObservation>, quota: Quota, observed: Date) -> [Point] {
        guard let target = reading(quota, observed: observed), let latest = history.last,
              latest.observedAt == observed, latest.windows[quota.id] == target else { return [] }
        var points: [Point] = [(observed, target.usedPercent)]
        var previous = points[0]
        for row in history.dropLast().reversed() {
            let gap = previous.date.timeIntervalSince(row.observedAt)
            guard gap > 0, gap <= maxGap, observed.timeIntervalSince(row.observedAt) <= lookback,
                  let measurement = row.windows[quota.id], measurement.resetsAt == target.resetsAt,
                  measurement.windowSeconds == target.windowSeconds, (0...100).contains(measurement.usedPercent),
                  measurement.usedPercent <= previous.used else { break }
            if let length = target.windowSeconds, target.resetsAt.timeIntervalSince(row.observedAt) > length { break }
            previous = (row.observedAt, measurement.usedPercent)
            if let selected = points.last, selected.date.timeIntervalSince(row.observedAt) >= minSpacing {
                points.append(previous)
            }
        }
        return Array(points.reversed())
    }

    private static func evaluate(window: Quota, snapshot: UsageSnapshot, history: ArraySlice<QuotaForecastObservation>,
                                 now: Date, syncIssue: Bool) -> QuotaWindowForecast {
        let observed = snapshot.observedAt
        let remaining = (0...100).contains(window.usedPercent) ? window.remaining : nil
        var result = QuotaWindowForecast(id: window.id, title: window.title, observedAt: observed, resetsAt: window.resetsAt,
                                         remainingPercent: remaining, source: snapshot.source)
        if window.expired(at: now) { result.reason = .expired; return result }
        if !(0...900).contains(now.timeIntervalSince(observed)) { result.reason = .stale; return result }
        if remaining == 0 { result.status = .exhausted; return result }
        guard let reset = window.resetsAt else { result.reason = .unknownReset; return result }
        if syncIssue { result.reason = .syncIssue; return result }

        var points = recentPoints(history, quota: window, observed: observed)
        if points.count > maxFitPoints {
            // Preserve the full span while keeping frequent polling inexpensive.
            let complete = points
            points = (0..<maxFitPoints).map { complete[$0 * (complete.count - 1) / (maxFitPoints - 1)] }
        }
        result.sampleCount = points.count
        if let first = points.first, let last = points.last { result.observedSpanSeconds = last.date.timeIntervalSince(first.date) }
        guard points.count >= 3, let first = points.first, let last = points.last,
              result.observedSpanSeconds >= minSpan else { result.reason = .insufficientHistory; return result }
        guard last.used - first.used >= 1 else { result.reason = .lowChange; return result }

        var rates: [Double] = []
        for index in points.indices.dropLast() {
            for later in points.suffix(from: index + 1) {
                let elapsed = later.date.timeIntervalSince(points[index].date)
                if elapsed >= 2 * minSpacing { rates.append((later.used - points[index].used) / elapsed) }
            }
        }
        guard rates.count >= 3, let remaining else { result.reason = .insufficientHistory; return result }
        rates.sort()
        let lower = percentile(0.25, in: rates), rate = percentile(0.5, in: rates), upper = percentile(0.75, in: rates)
        let untilReset = reset.timeIntervalSince(observed)
        let criticalRate = remaining / untilReset
        guard lower > 0, upper <= lower * 3, !(lower <= criticalRate && criticalRate < upper) else {
            result.reason = .unstable; return result
        }
        let untilEmpty = remaining / rate
        guard min(untilEmpty, untilReset) <= max(10_800, 3 * result.observedSpanSeconds) else {
            result.reason = .beyondEvidence; return result
        }
        result.status = untilEmpty < untilReset ? .risk : .stable
        if result.status == .risk {
            let estimated = observed.addingTimeInterval(untilEmpty)
            result.estimatedExhaustedAt = estimated
            if estimated <= now { result.reason = .estimatedPassed }
        }
        result.confidence = points.count >= 5 && result.observedSpanSeconds >= 3_600 && upper <= lower * 1.5 ? .higher : .moderate
        result.ratePercentPerHour = (rate * 360_000).rounded() / 100
        return result
    }

    private static func percentile(_ fraction: Double, in sorted: [Double]) -> Double {
        let position = Double(sorted.count - 1) * fraction
        let lower = Int(position.rounded(.down)), upper = Int(position.rounded(.up))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }
}
