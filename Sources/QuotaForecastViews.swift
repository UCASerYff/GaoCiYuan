import SwiftUI

struct QuotaForecastSelection: Identifiable {
    let accountID: UUID
    var quotaID: String? = nil
    var id: UUID { accountID }
}

private enum ForecastCopy {
    static func localized(_ chinese: String, _ english: String) -> String {
        Localization.english ? english : chinese
    }

    static var title: String { localized("额度可用性预测", "Quota availability forecast") }
    static var details: String { localized("预测详情", "Forecast details") }
    static var observedRemaining: String { localized("实测剩余", "Observed remaining") }
    static var estimatedDepletion: String { localized("预计用尽", "Estimated depletion") }

    static func status(_ status: QuotaForecastStatus) -> String {
        switch status {
        case .available: return localized("可查看预测", "Forecast available")
        case .risk: return localized("预计重置前用尽", "Estimated to run out before reset")
        case .stable: return localized("预计可用至重置", "Expected to last until reset")
        case .exhausted: return localized("实测已用尽", "Observed as depleted")
        case .insufficient: return localized("数据不足", "Insufficient data")
        case .excluded: return localized("未纳入预测", "Excluded from forecasts")
        }
    }

    static func reason(_ reason: QuotaForecastReason) -> String {
        switch reason {
        case .disabled:
            return localized("账户已暂停。", "This account is paused.")
        case .manualGrok:
            return localized("Grok Bot 手动读数仅保留最近一次观测，缺少连续的窗口样本。", "The manual Grok Bot reading retains a single observation, so there is no sequence of samples.")
        case .nonQuota:
            return localized("此账户没有可用于预测的周期百分比额度。", "This account has no measured percentage-based quota window.")
        case .noReadings:
            return localized("尚未观测到周期额度。", "A quota window has not been observed yet.")
        case .unknownReset:
            return localized("缺少可用的额度重置时间。", "A usable quota reset time is missing.")
        case .expired:
            return localized("上次观测的额度周期已结束，等待新周期快照。", "The observed quota cycle ended. Waiting for a snapshot in the next cycle.")
        case .stale:
            return localized("最近一次观测已过时，请同步账户。", "The last observation is stale. Sync the account to continue.")
        case .insufficientHistory:
            return localized("同一额度周期的有效快照不足。", "There are too few valid snapshots from the same quota cycle.")
        case .lowChange:
            return localized("样本中的用量变化太小，无法估算。", "The measured change is too small to estimate a trend.")
        case .unstable:
            return localized("观测速率波动较大，无法估算。", "Observed rates vary too much to estimate a trend.")
        case .beyondEvidence:
            return localized("预测跨度超出当前样本可支撑的范围。", "The projected period is too long for the available observations.")
        case .syncIssue:
            return localized("同步未取得新读数，当前显示上次观测。", "The last sync returned no new quota reading. The previous observation is shown.")
        case .estimatedPassed:
            return localized("按上次观测推算的用尽时间已过，等待新快照确认。", "The estimated depletion time has passed. A new reading is needed to confirm.")
        case .credential:
            return L("凭证已失效，重新连接前不展示旧读数。")
        }
    }

    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).locale(Localization.locale))
    }

    static func remaining(_ value: Double?) -> String {
        guard let value else { return "—" }
        return (value / 100).formatted(.percent.precision(.fractionLength(0...2)).locale(Localization.locale))
    }

    static func timestamp(_ date: Date?, timeZone: TimeZone) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Localization.locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func observationSpan(_ seconds: TimeInterval) -> String? {
        guard seconds > 0 else { return nil }
        var calendar = Calendar.current
        calendar.locale = Localization.locale
        let formatter = DateComponentsFormatter()
        formatter.calendar = calendar
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: seconds)
    }
}

private func forecastColor(_ status: QuotaForecastStatus) -> Color {
    switch status {
    case .risk: return .orange
    case .stable: return Theme.teal
    case .exhausted: return .red
    default: return .secondary
    }
}

private struct ForecastRisk: Identifiable {
    let account: Account
    let window: QuotaWindowForecast
    let estimate: Date
    var id: String { account.id.uuidString + "/" + window.id }
}

private struct ForecastOverviewData {
    let risks: [ForecastRisk]
    let hasForecasts: Bool

    init(accounts: [Account], now: Date) {
        var risks: [ForecastRisk] = []
        var hasForecasts = false
        for account in accounts {
            let forecast = QuotaForecast.evaluate(account: account, now: now)
            for window in forecast.windows {
                if window.status == .risk || window.status == .stable { hasForecasts = true }
                if window.status == .risk, let estimate = window.estimatedExhaustedAt {
                    risks.append(ForecastRisk(account: account, window: window, estimate: estimate))
                }
            }
        }
        self.risks = risks.sorted { left, right in
            if left.estimate == right.estimate { return left.id < right.id }
            return left.estimate < right.estimate
        }
        self.hasForecasts = hasForecasts
    }
}

struct QuotaForecastOverview: View {
    let accounts: [Account]
    let hasAccounts: Bool
    let now: Date
    let showDetail: (QuotaForecastSelection) -> Void

    var body: some View {
        let data = ForecastOverviewData(accounts: accounts, now: now)
        VStack(alignment: .leading, spacing: 12) {
            heading
            Divider()
            riskHeading(count: data.risks.count)
            riskContent(data)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(ForecastCopy.title, systemImage: "chart.xyaxis.line")
                .font(.headline).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text(ForecastCopy.localized("根据同一额度周期的本机历史快照估算。", "Estimated from local snapshots in the same quota cycle."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func riskHeading(count: Int) -> some View {
        let countText = ForecastCopy.localized("\(count) 个额度窗口预计重置前用尽",
                                              count == 1 ? "1 window at risk" : "\(count) windows at risk")
        return HStack {
            Text(ForecastCopy.localized("风险清单", "Risk list")).font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if count > 0 { Text(countText).font(.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func riskContent(_ data: ForecastOverviewData) -> some View {
        if data.risks.isEmpty {
            emptyRiskList(hasForecasts: data.hasForecasts)
        } else {
            let lastID = data.risks.last?.id
            VStack(spacing: 0) {
                ForEach(data.risks) { risk in
                    ForecastRiskRow(risk: risk, showDetail: showDetail)
                        .padding(.vertical, 7)
                    if risk.id != lastID { Divider() }
                }
            }
        }
    }

    private func emptyRiskList(hasForecasts: Bool) -> some View {
        let title = hasForecasts
            ? ForecastCopy.localized("符合估算条件的额度窗口中，未发现重置前用尽的风险。", "No eligible quota window is estimated to run out before reset.")
            : ForecastCopy.localized("暂无可估算的额度窗口。", "No quota window can be estimated yet.")
        let detail = !accounts.isEmpty
            ? ForecastCopy.localized("可在账户预测详情中查看各窗口的样本或排除原因。", "Forecast details show the samples or exclusion reason for each window.")
            : hasAccounts
                ? ForecastCopy.localized("启用账户并获取周期额度后可以查看预测。", "Enable an account and collect a quota window to see forecasts.")
                : ForecastCopy.localized("接入支持周期额度的 Agent 后可以查看预测。", "Connect an Agent with quota windows to see forecasts.")
        return VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "info.circle").font(.callout)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct ForecastRiskRow: View {
    @Environment(\.timeZone) private var timeZone
    let risk: ForecastRisk
    let showDetail: (QuotaForecastSelection) -> Void

    var body: some View {
        Button {
            showDetail(QuotaForecastSelection(accountID: risk.account.id, quotaID: risk.window.id))
        } label: {
            label
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(ForecastCopy.details))
    }

    private var label: some View {
        HStack(alignment: .center, spacing: 12) {
            ProviderMark(provider: risk.account.provider, size: 28).accessibilityHidden(true)
            accountLabel
            ForecastMetric(title: ForecastCopy.observedRemaining,
                           value: ForecastCopy.remaining(risk.window.remainingPercent))
            ForecastMetric(title: ForecastCopy.estimatedDepletion,
                           value: ForecastCopy.timestamp(risk.estimate, timeZone: timeZone), color: .orange)
            ForecastMetric(title: ForecastCopy.localized("下次重置", "Next reset"),
                           value: ForecastCopy.timestamp(risk.window.resetsAt, timeZone: timeZone))
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var accountLabel: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(risk.account.name).font(.callout.weight(.semibold)).lineLimit(1)
            Text(L(risk.window.title)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct QuotaForecastAccountEntry: View {
    @Environment(\.timeZone) private var timeZone
    let forecast: AccountQuotaForecast
    let showDetail: () -> Void

    private var highlightedWindow: QuotaWindowForecast? {
        let risks: [QuotaWindowForecast] = forecast.windows.filter { $0.status == .risk }
        if let firstRisk = risks.min(by: { left, right in
            let firstDate = left.estimatedExhaustedAt ?? Date.distantFuture
            let secondDate = right.estimatedExhaustedAt ?? Date.distantFuture
            return firstDate < secondDate
        }) {
            return firstRisk
        }
        if let exhausted = forecast.windows.first(where: { $0.status == .exhausted }) { return exhausted }
        if let stable = forecast.windows.first(where: { $0.status == .stable }) { return stable }
        return forecast.windows.first
    }

    var body: some View {
        let highlighted = highlightedWindow
        let status: QuotaForecastStatus = forecast.status == .excluded ? .excluded : (highlighted?.status ?? forecast.status)
        let reason = forecast.reason ?? highlighted?.reason

        VStack(alignment: .leading, spacing: 6) {
            heading
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) { summary(status: status, highlighted: highlighted) }
                VStack(alignment: .leading, spacing: 4) { summary(status: status, highlighted: highlighted) }
            }
            if let reason {
                Text(ForecastCopy.reason(reason))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 7))
    }

    private var heading: some View {
        HStack(spacing: 6) {
            Label(ForecastCopy.localized("额度可用性预测", "Quota forecast"), systemImage: "chart.xyaxis.line")
                .font(.caption.weight(.semibold)).foregroundStyle(Theme.ink)
            Spacer(minLength: 4)
            Button(ForecastCopy.details, action: showDetail).controlSize(.small)
        }
    }

    @ViewBuilder private func summary(status: QuotaForecastStatus, highlighted: QuotaWindowForecast?) -> some View {
        Tag(text: ForecastCopy.status(status), color: forecastColor(status))
        if let highlighted {
            Text(L(highlighted.title)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if status == .risk, let estimate = highlighted.estimatedExhaustedAt {
                Text(ForecastCopy.timestamp(estimate, timeZone: timeZone))
                    .font(.caption).monospacedDigit().foregroundStyle(.orange)
            }
        }
    }
}

struct QuotaForecastDetail: View {
    @EnvironmentObject private var store: MonitorStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.timeZone) private var timeZone
    @AccessibilityFocusState private var focusedWindow: String?
    let selection: QuotaForecastSelection

    var body: some View {
        let account: Account? = store.library.accounts.first { $0.id == selection.accountID }
        VStack(spacing: 0) {
            heading(accountName: account?.name)
            Divider()
            TimelineView(.periodic(from: .now, by: 30)) { context in
                timelineContent(account: account, now: context.date)
            }
            .background(Theme.canvas)
        }
        .frame(width: 650, height: 530)
        .background(Theme.panel)
    }

    private func heading(accountName: String?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(ForecastCopy.title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                if let accountName { Text(accountName).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer()
            Button(L("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(18)
    }

    @ViewBuilder private func timelineContent(account: Account?, now: Date) -> some View {
        if let account {
            let forecast = QuotaForecast.evaluate(account: account, now: now)
            detailContent(forecast)
        } else {
            Text(ForecastCopy.localized("此账户已移除。", "This account has been removed."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailContent(_ forecast: AccountQuotaForecast) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                forecastSections(forecast)
            }
            .onAppear {
                guard let target = selection.quotaID, forecast.windows.contains(where: { $0.id == target }) else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(target, anchor: .top)
                    focusedWindow = target
                }
            }
        }
    }

    private func forecastSections(_ forecast: AccountQuotaForecast) -> some View {
        let hasEstimates = forecast.windows.contains { $0.status == .risk || $0.status == .stable }
        let zoneLabel = ForecastCopy.localized("显示时区", "Display time zone") + " · " + timeZone.identifier
        return VStack(alignment: .leading, spacing: 12) {
            Text(zoneLabel).font(.caption).foregroundStyle(.secondary)
            if let reason = forecast.reason {
                reasonPanel(status: forecast.status, reason: reason)
            }
            ForEach(forecast.windows) { window in
                windowRow(window)
            }
            if hasEstimates {
                Text(ForecastCopy.localized("后续使用速率变化时，预计时间会随新观测更新。", "Estimated times update as new observations reflect changes in usage."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18)
    }

    private func reasonPanel(status: QuotaForecastStatus, reason: QuotaForecastReason) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Tag(text: ForecastCopy.status(status), color: forecastColor(status))
            Text(ForecastCopy.reason(reason)).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).panel()
    }

    private func windowRow(_ window: QuotaWindowForecast) -> some View {
        ForecastWindowDetail(window: window, timeZone: timeZone)
            .id(window.id)
            .accessibilityElement(children: .contain)
            .accessibilityFocused($focusedWindow, equals: window.id)
    }
}

private struct ForecastWindowDetail: View {
    let window: QuotaWindowForecast
    let timeZone: TimeZone

    private var hasEstimate: Bool { window.status == .risk || window.status == .stable }
    private var hasEvidence: Bool { window.confidence != nil || window.sampleCount > 0 || window.reason == .insufficientHistory }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading
            observations
            if hasEstimate {
                Divider()
                estimate
            }
            if let reason = window.reason {
                Text(ForecastCopy.reason(reason))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if hasEvidence {
                Divider()
                evidence
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private var heading: some View {
        HStack {
            Text(L(window.title)).font(.headline).accessibilityAddTraits(.isHeader)
            Spacer()
            Tag(text: ForecastCopy.status(window.status), color: forecastColor(window.status))
        }
    }

    private var observations: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ForecastCopy.localized("实测", "Observed")).font(.subheadline.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    ForecastMetric(title: ForecastCopy.observedRemaining, value: ForecastCopy.remaining(window.remainingPercent))
                    ForecastMetric(title: ForecastCopy.localized("观测时间", "Observed at"),
                                   value: ForecastCopy.timestamp(window.observedAt, timeZone: timeZone))
                }
                GridRow {
                    if let reset = window.resetsAt {
                        ForecastMetric(title: ForecastCopy.localized("记录的重置时间", "Recorded reset"),
                                       value: ForecastCopy.timestamp(reset, timeZone: timeZone))
                    }
                    if !window.source.isEmpty {
                        ForecastMetric(title: L("来源"), value: L(window.source))
                    }
                }
            }
        }
    }

    private var estimate: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ForecastCopy.localized("趋势估算", "Trend estimate")).font(.subheadline.weight(.semibold))
            if let date = window.estimatedExhaustedAt {
                ForecastMetric(title: ForecastCopy.estimatedDepletion,
                               value: ForecastCopy.timestamp(date, timeZone: timeZone), color: .orange)
            } else {
                Text(ForecastCopy.status(window.status)).font(.callout).foregroundStyle(Theme.teal)
            }
        }
    }

    private var evidence: some View {
        let count = window.sampleCount
        let sampleCount = ForecastCopy.localized("\(count) 次观测", count == 1 ? "1 observation" : "\(count) observations")
        let span = ForecastCopy.observationSpan(window.observedSpanSeconds)
        return VStack(alignment: .leading, spacing: 6) {
            Text(ForecastCopy.localized("估算依据", "Estimate basis")).font(.subheadline.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    if let confidence = window.confidence {
                        confidenceMetric(confidence)
                    }
                    ForecastMetric(title: ForecastCopy.localized("样本", "Samples"), value: sampleCount)
                }
                GridRow {
                    if let span {
                        ForecastMetric(title: ForecastCopy.localized("观测跨度", "Observation span"), value: span)
                    }
                    if let rate = window.ratePercentPerHour {
                        rateMetric(rate)
                    }
                }
            }
        }
    }

    private func confidenceMetric(_ confidence: QuotaForecastConfidence) -> ForecastMetric {
        let value = confidence == .higher ? ForecastCopy.localized("较高", "Higher") : ForecastCopy.localized("中等", "Moderate")
        return ForecastMetric(title: ForecastCopy.localized("置信度", "Confidence"), value: value)
    }

    private func rateMetric(_ rate: Double) -> ForecastMetric {
        let value = ForecastCopy.number(rate)
        let rateText = ForecastCopy.localized("\(value) 个百分点/小时", "\(value) percentage points/hour")
        return ForecastMetric(title: ForecastCopy.localized("观测速率", "Observed rate"), value: rateText)
    }
}

private struct ForecastMetric: View {
    let title: String
    let value: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold)).foregroundStyle(color).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
