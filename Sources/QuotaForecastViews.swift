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

struct QuotaForecastOverview: View {
    @Environment(\.timeZone) private var timeZone
    let accounts: [Account]
    let hasAccounts: Bool
    let now: Date
    let showDetail: (QuotaForecastSelection) -> Void

    var body: some View {
        let evaluated = accounts.map { account in
            (account, QuotaForecast.evaluate(account: account, now: now))
        }
        let risks = evaluated.flatMap { account, forecast in
            forecast.windows.compactMap { window -> ForecastRisk? in
                guard window.status == .risk, let estimate = window.estimatedExhaustedAt else { return nil }
                return ForecastRisk(account: account, window: window, estimate: estimate)
            }
        }.sorted { $0.estimate == $1.estimate ? $0.id < $1.id : $0.estimate < $1.estimate }
        let hasForecasts = evaluated.contains { _, forecast in
            forecast.windows.contains { $0.status == .risk || $0.status == .stable }
        }

        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Label(ForecastCopy.title, systemImage: "chart.xyaxis.line")
                    .font(.headline).foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(ForecastCopy.localized("根据同一额度周期的本机历史快照估算。", "Estimated from local snapshots in the same quota cycle."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text(ForecastCopy.localized("风险清单", "Risk list")).font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !risks.isEmpty {
                    Text(ForecastCopy.localized("\(risks.count) 个额度窗口预计重置前用尽",
                                                risks.count == 1 ? "1 window at risk" : "\(risks.count) windows at risk"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if risks.isEmpty {
                emptyRiskList(hasForecasts: hasForecasts)
            } else {
                VStack(spacing: 0) {
                    ForEach(risks) { risk in
                        riskRow(risk).padding(.vertical, 7)
                        if risk.id != risks.last?.id { Divider() }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
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

    private func riskRow(_ risk: ForecastRisk) -> some View {
        Button {
            showDetail(QuotaForecastSelection(accountID: risk.account.id, quotaID: risk.window.id))
        } label: {
            HStack(alignment: .center, spacing: 12) {
                ProviderMark(provider: risk.account.provider, size: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(risk.account.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(L(risk.window.title)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
        .buttonStyle(.plain)
        .accessibilityHint(Text(ForecastCopy.details))
    }
}

struct QuotaForecastAccountEntry: View {
    @Environment(\.timeZone) private var timeZone
    let forecast: AccountQuotaForecast
    let showDetail: () -> Void

    var body: some View {
        let risk = forecast.windows.filter { $0.status == .risk }.min {
            ($0.estimatedExhaustedAt ?? .distantFuture) < ($1.estimatedExhaustedAt ?? .distantFuture)
        }
        let highlighted = risk ?? forecast.windows.first { $0.status == .exhausted }
            ?? forecast.windows.first { $0.status == .stable } ?? forecast.windows.first
        let status = forecast.status == .excluded ? .excluded : (highlighted?.status ?? forecast.status)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(ForecastCopy.localized("额度可用性预测", "Quota forecast"), systemImage: "chart.xyaxis.line")
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.ink)
                Spacer(minLength: 4)
                Button(ForecastCopy.details, action: showDetail).controlSize(.small)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) { summary(status: status, highlighted: highlighted) }
                VStack(alignment: .leading, spacing: 4) { summary(status: status, highlighted: highlighted) }
            }
            if let reason = forecast.reason ?? highlighted?.reason {
                Text(ForecastCopy.reason(reason))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 7))
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
        let account = store.library.accounts.first { $0.id == selection.accountID }
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(ForecastCopy.title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    if let account { Text(account.name).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer()
                Button(L("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(18)
            Divider()
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if let account {
                    detailContent(QuotaForecast.evaluate(account: account, now: context.date))
                } else {
                    Text(ForecastCopy.localized("此账户已移除。", "This account has been removed."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Theme.canvas)
        }
        .frame(width: 650, height: 530)
        .background(Theme.panel)
    }

    private func detailContent(_ forecast: AccountQuotaForecast) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(ForecastCopy.localized("显示时区", "Display time zone") + " · " + timeZone.identifier)
                        .font(.caption).foregroundStyle(.secondary)
                    if let reason = forecast.reason {
                        VStack(alignment: .leading, spacing: 6) {
                            Tag(text: ForecastCopy.status(forecast.status), color: forecastColor(forecast.status))
                            Text(ForecastCopy.reason(reason)).font(.callout).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).panel()
                    }
                    ForEach(forecast.windows) { window in
                        ForecastWindowDetail(window: window, timeZone: timeZone)
                            .id(window.id)
                            .accessibilityElement(children: .contain)
                            .accessibilityFocused($focusedWindow, equals: window.id)
                    }
                    if forecast.windows.contains(where: { $0.status == .risk || $0.status == .stable }) {
                        Text(ForecastCopy.localized("后续使用速率变化时，预计时间会随新观测更新。", "Estimated times update as new observations reflect changes in usage."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(18)
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
}

private struct ForecastWindowDetail: View {
    let window: QuotaWindowForecast
    let timeZone: TimeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L(window.title)).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Tag(text: ForecastCopy.status(window.status), color: forecastColor(window.status))
            }
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
            if window.status == .risk || window.status == .stable {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text(ForecastCopy.localized("趋势估算", "Trend estimate")).font(.subheadline.weight(.semibold))
                    if let estimate = window.estimatedExhaustedAt {
                        ForecastMetric(title: ForecastCopy.estimatedDepletion,
                                       value: ForecastCopy.timestamp(estimate, timeZone: timeZone), color: .orange)
                    } else {
                        Text(ForecastCopy.status(window.status)).font(.callout).foregroundStyle(Theme.teal)
                    }
                }
            }
            if let reason = window.reason {
                Text(ForecastCopy.reason(reason))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if window.confidence != nil || window.sampleCount > 0 || window.reason == .insufficientHistory {
                Divider()
                evidence
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private var evidence: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ForecastCopy.localized("估算依据", "Estimate basis")).font(.subheadline.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    if let confidence = window.confidence {
                        ForecastMetric(title: ForecastCopy.localized("置信度", "Confidence"),
                                       value: confidence == .higher ? ForecastCopy.localized("较高", "Higher") : ForecastCopy.localized("中等", "Moderate"))
                    }
                    ForecastMetric(title: ForecastCopy.localized("样本", "Samples"),
                                   value: ForecastCopy.localized("\(window.sampleCount) 次观测",
                                                                  window.sampleCount == 1 ? "1 observation" : "\(window.sampleCount) observations"))
                }
                GridRow {
                    if let span = ForecastCopy.observationSpan(window.observedSpanSeconds) {
                        ForecastMetric(title: ForecastCopy.localized("观测跨度", "Observation span"), value: span)
                    }
                    if let rate = window.ratePercentPerHour {
                        let value = ForecastCopy.number(rate)
                        ForecastMetric(title: ForecastCopy.localized("观测速率", "Observed rate"),
                                       value: ForecastCopy.localized("\(value) 个百分点/小时", "\(value) percentage points/hour"))
                    }
                }
            }
        }
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
