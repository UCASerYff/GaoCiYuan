import AppKit
import SwiftUI
import Charts

/// Actual local usage is deliberately separate from account quota snapshots.
/// Date filters apply to daily records; session/project summaries retain their all-time scope.
struct UsageDashboard: View {
    @EnvironmentObject private var store: UsageAnalyticsStore
    @State private var dailyGrouping = "client"
    @State private var sessionGrouping = "project"
    @State private var expandedSession: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            controls
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).panel()
            }
            if !store.warnings.isEmpty { scanWarnings }
            if store.isRefreshing, let progress = store.progressMessage {
                Label(progress, systemImage: "waveform.path")
                    .font(.caption).foregroundStyle(.secondary)
            }
            summary
            if store.dashboard.days.isEmpty {
                emptyState
            } else {
                UsageDailyTrend(days: store.dashboard.days)
                UsageActivityHeatmap(days: store.dashboard.days)
                dailyBreakdown
            }
            if !store.sessions.rows.isEmpty || store.sessions.totalCount > 0 {
                sessionBreakdown
                sessionList
            }
            footer
        }
        .onAppear { store.reload() }
        .onChange(of: store.selectedRange) { _, _ in store.reload() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("本地用量").font(.title2.weight(.semibold))
                    Text("按工具日志统计，部分来源含估算值；保留已采集的历史。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button { store.showSourceSettings = true } label: {
                    Label("采集设置", systemImage: "slider.horizontal.3")
                }
                Menu {
                    Button("导出 CSV · 当前日期范围") { store.exportUsage(format: .csv) }
                    Button("导出 JSON · 全部历史与设备") { store.exportUsage(format: .json) }
                    Divider()
                    Button("合并其他设备 JSON…") { store.importUsage() }
                } label: { Label("导入与导出", systemImage: "square.and.arrow.up") }
                Button { store.refresh() } label: {
                    HStack(spacing: 6) {
                        if store.isRefreshing { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                        Text(store.isRefreshing ? "采集中" : "采集用量")
                    }
                }
                .disabled(store.isRefreshing)
                .buttonStyle(.borderedProminent)
            }
            HStack(spacing: 14) {
                Picker("统计时间", selection: $store.selectedRange) {
                    ForEach(UsageRange.allCases) { range in Text(range.title).tag(range) }
                }.pickerStyle(.segmented).frame(maxWidth: 500)
                Spacer(minLength: 0)
                if let updated = store.lastScanAt {
                    Text("上次采集 \(updated.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var summary: some View {
        let total = store.dashboard.total
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 180), spacing: 12), count: 3), spacing: 12) {
            UsageMetric(title: "Token 总量", value: UsageFormat.tokens(total.totalTokens), subtitle: "输入、输出、推理与缓存汇总", symbol: "chart.bar.fill", color: Theme.accent)
            UsageMetric(title: "输入", value: UsageFormat.tokens(total.input), subtitle: "本期输入 Token", symbol: "arrow.down.left", color: .indigo)
            UsageMetric(title: "输出与推理", value: UsageFormat.tokens(total.output + total.reasoning), subtitle: "其中推理 \(UsageFormat.tokens(total.reasoning))", symbol: "arrow.up.right", color: Theme.teal)
            UsageMetric(title: "缓存读取", value: UsageFormat.tokens(total.cacheRead), subtitle: cacheSubtitle(total), symbol: "memorychip", color: .orange)
            UsageMetric(title: "缓存写入", value: UsageFormat.tokens(total.cacheWrite), subtitle: "以工具实际记录为准", symbol: "square.and.arrow.down", color: .purple)
            UsageMetric(title: "参考费用 · USD", value: UsageFormat.cost(total.costUSD), subtitle: "模型价估算，不等于实际账单", symbol: "dollarsign.circle", color: Theme.teal)
        }
    }

    private func cacheSubtitle(_ amounts: UsageAmounts) -> String {
        guard let ratio = amounts.cachedInputRatio else { return "未提供可计算的缓存比例" }
        return "缓存输入占比 \((ratio * 100).formatted(.number.precision(.fractionLength(1))))%"
    }

    private var scanWarnings: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(store.warnings.enumerated()), id: \.offset) { item in
                    Text(item.element).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        } label: {
            Label("采集说明 · \(store.warnings.count) 项", systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
        }.panel()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: store.isRefreshing ? "waveform.path" : "chart.bar.xaxis")
                .font(.system(size: 36, weight: .light)).foregroundStyle(Theme.accent)
            Text(store.isRefreshing ? "正在读取本机用量记录" : "这个时间段还没有用量记录")
                .font(.headline)
            Text("使用支持的 AI 工具后采集用量。自定义数据目录可在采集设置中配置。")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !store.isRefreshing {
                Button("立即采集") { store.refresh() }.buttonStyle(.borderedProminent)
            }
        }.frame(maxWidth: .infinity, minHeight: 210).panel()
    }

    private var dailyBreakdown: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("用量分布").font(.headline)
                Text(store.selectedRange.title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("分组", selection: $dailyGrouping) {
                    Text("工具").tag("client")
                    Text("模型").tag("model")
                }.pickerStyle(.segmented).frame(width: 170)
            }
            UsageBreakdownRows(rows: dailyGrouping == "client" ? store.dashboard.byClient : store.dashboard.byModel, prettifyClients: dailyGrouping == "client")
        }.panel()
    }

    private var sessionBreakdown: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("项目与设备").font(.headline)
                    Text("会话全历史 · 不受上方日期筛选影响")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("会话分组", selection: $sessionGrouping) {
                    Text("项目").tag("project")
                    Text("设备").tag("device")
                }.pickerStyle(.segmented).frame(width: 170)
            }
            UsageBreakdownRows(rows: sessionGrouping == "project" ? store.sessionSummary.byProject : store.sessionSummary.byDevice, prettifyClients: false)
        }.panel()
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("会话明细").font(.headline)
                Text("全历史 · 按需加载").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(store.sessions.rows.isEmpty ? 0 : store.sessionOffset + 1)–\(store.sessionOffset + store.sessions.rows.count) / \(store.sessions.totalCount)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Text("同一会话按模型分别统计；展开查看项目、设备和生成速度。")
                .font(.caption).foregroundStyle(.secondary)
            LazyVStack(spacing: 0) {
                ForEach(store.sessions.rows) { item in
                    UsageSessionRowView(item: item, expanded: Binding(
                        get: { expandedSession == item.id },
                        set: { expandedSession = $0 ? item.id : nil }
                    ))
                    Divider().opacity(0.5)
                }
            }
            HStack {
                Text("每页最多 50 条，会话历史完整保留。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if store.isLoadingSessions { ProgressView().controlSize(.small) }
                Button("上一页") { store.loadPreviousSessions() }
                    .disabled(store.sessionOffset == 0 || store.isLoadingSessions)
                Button("下一页") { store.loadNextSessions() }
                    .disabled(store.sessionOffset + store.sessions.rows.count >= store.sessions.totalCount || store.isLoadingSessions)
            }
        }.panel()
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "internaldrive").foregroundStyle(Theme.accent)
            Text("本地保存用量汇总，不收集对话正文。日志删除后，已采集的用量仍会保留；重复采集与同一设备重复导入不会累加。费用不可定价时显示“未定价”。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text("\(store.dashboard.devices.count) 台设备")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 4)
    }
}

private struct UsageMetric: View {
    let title: String
    let value: String
    let subtitle: String
    let symbol: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: symbol).foregroundStyle(color)
            }
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                .frame(minHeight: 26, alignment: .topLeading)
        }.frame(maxWidth: .infinity, alignment: .leading).panel()
    }
}

private struct UsageChartDay: Identifiable {
    let day: String
    let date: Date
    var input: Int64 = 0
    var output: Int64 = 0
    var cached: Int64 = 0
    var total: Int64 = 0
    var id: String { day }
    static func aggregate(_ rows: [UsageLedgerDay]) -> [UsageChartDay] {
        var points: [String: UsageChartDay] = [:]
        for item in rows {
            let row = item.row
            guard let date = UsageFormat.dayDate(row.day) else { continue }
            var point = points[row.day] ?? UsageChartDay(day: row.day, date: date)
            point.input += row.amounts.input
            point.output += row.amounts.output + row.amounts.reasoning
            point.cached += row.amounts.cacheRead + row.amounts.cacheWrite
            point.total += row.amounts.totalTokens
            points[row.day] = point
        }
        return points.values.sorted { $0.day < $1.day }
    }
}

private struct UsageDailyTrend: View {
    let days: [UsageLedgerDay]
    private var points: [UsageChartDay] { UsageChartDay.aggregate(days) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("每日用量").font(.headline)
                Spacer()
                Text("\(points.count) 个有记录的日期").font(.caption).foregroundStyle(.secondary)
            }
            Chart(points) { point in
                BarMark(x: .value("日期", point.date, unit: .day), y: .value("Token", Double(point.input)))
                    .foregroundStyle(by: .value("类别", "输入"))
                BarMark(x: .value("日期", point.date, unit: .day), y: .value("Token", Double(point.output)))
                    .foregroundStyle(by: .value("类别", "输出与推理"))
                BarMark(x: .value("日期", point.date, unit: .day), y: .value("Token", Double(point.cached)))
                    .foregroundStyle(by: .value("类别", "缓存"))
            }
            .chartForegroundStyleScale(["输入": Theme.accent, "输出与推理": Theme.teal, "缓存": Color.orange.opacity(0.75)])
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel {
                        if let tokens = value.as(Double.self) { Text(UsageFormat.tokens(Int64(tokens))) }
                    }
                }
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 7)) }
            .chartLegend(position: .bottom, alignment: .leading, spacing: 14)
            .frame(height: 215)
        }.panel()
    }
}

private struct UsageActivityHeatmap: View {
    let days: [UsageLedgerDay]
    private var points: [UsageChartDay] { UsageChartDay.aggregate(days) }
    private var cells: [UsageHeatmapCell] {
        guard let first = points.first?.date, let last = points.last?.date else { return [] }
        let calendar = Calendar.current
        let earliest = calendar.date(byAdding: .day, value: -363, to: last) ?? first
        let start = max(first, earliest)
        let weekdayOffset = (calendar.component(.weekday, from: start) + 5) % 7
        let beginning = calendar.date(byAdding: .day, value: -weekdayOffset, to: start) ?? start
        let totals = Dictionary(uniqueKeysWithValues: points.map { ($0.day, $0.total) })
        let count = calendar.dateComponents([.day], from: beginning, to: last).day ?? 0
        return (0...max(0, count)).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: beginning) else { return nil }
            return UsageHeatmapCell(date: date, total: totals[UsageFormat.dayKey(date)] ?? 0, included: date >= start)
        }
    }
    var body: some View {
        let allCells = cells
        let maximum = max(allCells.map(\.total).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("活跃日历").font(.headline)
                Spacer()
                Text("按所选时间显示，最长 52 周").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: Array(repeating: GridItem(.fixed(11), spacing: 4), count: 7), spacing: 4) {
                    ForEach(allCells) { cell in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(cell.included ? color(cell.total, maximum: maximum) : Color.clear)
                            .frame(width: 11, height: 11)
                            .help("\(UsageFormat.dayKey(cell.date)) · \(UsageFormat.tokens(cell.total)) Token")
                            .accessibilityLabel("\(UsageFormat.dayKey(cell.date))，\(cell.total) Token")
                    }
                }.frame(height: 101)
            }
            HStack(spacing: 5) {
                Text("少")
                ForEach(0..<5) { level in
                    RoundedRectangle(cornerRadius: 2).fill(Theme.teal.opacity(level == 0 ? 0.09 : Double(level) * 0.22))
                        .frame(width: 10, height: 10)
                }
                Text("多")
                Spacer()
                Text("\(points.filter { $0.total > 0 }.count) 天有用量")
            }.font(.caption2).foregroundStyle(.secondary)
        }.panel()
    }
    private func color(_ value: Int64, maximum: Int64) -> Color {
        guard value > 0 else { return Color.primary.opacity(0.055) }
        let ratio = log1p(Double(value)) / log1p(Double(maximum))
        return Theme.teal.opacity(max(0.2, min(1, ratio)))
    }
}

private struct UsageHeatmapCell: Identifiable {
    let date: Date
    let total: Int64
    let included: Bool
    var id: Date { date }
}

private struct UsageBreakdownRows: View {
    let rows: [UsageLedgerBreakdown]
    var prettifyClients = false
    @State private var showAll = false
    private var maximum: Int64 { max(rows.map { $0.amounts.totalTokens }.max() ?? 0, 1) }
    private var visibleRows: [UsageLedgerBreakdown] { showAll ? rows : Array(rows.prefix(8)) }
    var body: some View {
        VStack(spacing: 13) {
            if rows.isEmpty { Text("尚无可归类的记录").font(.callout).foregroundStyle(.secondary) }
            ForEach(visibleRows) { row in
                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        Text(prettifyClients ? UsageFormat.client(row.label) : row.label)
                            .font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle).help(row.label)
                        Spacer(minLength: 12)
                        Text(UsageFormat.tokens(row.amounts.totalTokens)).font(.callout.weight(.semibold)).monospacedDigit()
                        Text(UsageFormat.cost(row.amounts.costUSD)).font(.caption).foregroundStyle(.secondary)
                            .monospacedDigit().frame(width: 92, alignment: .trailing)
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.04))
                            Capsule().fill(Theme.accent.opacity(0.75))
                                .frame(width: max(3, geometry.size.width * CGFloat(Double(row.amounts.totalTokens) / Double(maximum))))
                        }
                    }.frame(height: 5)
                }
            }
            if rows.count > 8 {
                Button(showAll ? "收起" : "显示全部 \(rows.count) 项") { showAll.toggle() }.font(.caption)
            }
        }
    }
}

private struct UsageSessionRowView: View {
    let item: UsageLedgerSession
    @Binding var expanded: Bool
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            detail.padding(.leading, 20).padding(.bottom, 12)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.row.projectLabel ?? "未识别项目")
                        .font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Text("\(UsageFormat.client(item.row.client)) · \(item.row.model)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 10)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(UsageFormat.tokens(item.row.amounts.totalTokens)).font(.callout.weight(.semibold)).monospacedDigit()
                    Text(UsageFormat.cost(item.row.amounts.costUSD)).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 10)
        }
    }
    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("设备", value: item.deviceName)
            if let project = item.row.projectKey { LabeledContent("项目标识", value: project) }
            LabeledContent("会话", value: item.row.sessionID)
            if let first = item.row.firstActive { LabeledContent("首次活动", value: first.formatted(date: .abbreviated, time: .shortened)) }
            if let last = item.row.lastActive { LabeledContent("最近活动", value: last.formatted(date: .abbreviated, time: .shortened)) }
            HStack(spacing: 14) {
                Text("输入 \(UsageFormat.tokens(item.row.amounts.input))")
                Text("输出 \(UsageFormat.tokens(item.row.amounts.output))")
                Text("推理 \(UsageFormat.tokens(item.row.amounts.reasoning))")
                Text("缓存读取 \(UsageFormat.tokens(item.row.amounts.cacheRead))")
                Text("缓存写入 \(UsageFormat.tokens(item.row.amounts.cacheWrite))")
            }
            if item.row.timedDurationMS > 0, item.row.timedTokens > 0 {
                let speed = Double(item.row.timedTokens) / (Double(item.row.timedDurationMS) / 1_000)
                Text("有计时记录的生成速度 \(speed.formatted(.number.precision(.fractionLength(1)))) Token/s")
            }
        }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
    }
}

private enum UsageFormat {
    static func tokens(_ value: Int64) -> String {
        let number = Double(value)
        if abs(number) >= 1_000_000_000 { return String(format: "%.2fB", number / 1_000_000_000) }
        if abs(number) >= 1_000_000 { return String(format: "%.2fM", number / 1_000_000) }
        if abs(number) >= 10_000 { return String(format: "%.1fK", number / 1_000) }
        return value.formatted()
    }
    static func cost(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "未定价" }
        return value.formatted(.currency(code: "USD").precision(.fractionLength(2...4)))
    }
    static func dayDate(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
    static func dayKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
    static func client(_ value: String) -> String {
        let names = ["claude": "Claude Code", "codex": "Codex", "opencode": "OpenCode", "openclaw": "OpenClaw", "cursor": "Cursor", "antigravity": "Antigravity", "gemini": "Gemini CLI", "copilot": "GitHub Copilot", "commandcode": "Command Code", "lmstudio": "LM Studio", "cherrystudio": "Cherry Studio", "qodercn": "Qoder", "kimi": "Kimi Code", "qwen": "Qwen Code", "workbuddy": "WorkBuddy", "codebuddy": "CodeBuddy"]
        return names[value.lowercased()] ?? value
    }
}
