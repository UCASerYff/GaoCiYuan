import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry { let date: Date; let snapshot: GaoCiYuanWidgetSnapshot? }

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { .init(date:Date(),snapshot:nil) }
    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) { completion(read()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        completion(Timeline(entries:[read()],policy:.after(Date().addingTimeInterval(300))))
    }
    private func read() -> UsageEntry {
        for url in GaoCiYuanWidgetSnapshot.candidateURLs {
            if let data = try? Data(contentsOf:url) {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                if let value = try? decoder.decode(GaoCiYuanWidgetSnapshot.self,from:data) {
                    return .init(date:Date(),snapshot:value)
                }
            }
        }
        return .init(date:Date(),snapshot:nil)
    }
}

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry
    var body: some View {
        Group {
            if let snapshot = entry.snapshot, !snapshot.accounts.isEmpty { content(snapshot) }
            else {
                VStack(alignment:.leading,spacing:8) {
                    HStack { Text("词").font(.title2); Text("搞词元").font(.headline) }
                    Text("请先打开搞词元并同步一次。\nOpen GaoCiYuan to sync.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.center)
            }
        }.containerBackground(for:.widget) { Color(nsColor:.windowBackgroundColor) }
    }
    @ViewBuilder private func content(_ snapshot: GaoCiYuanWidgetSnapshot) -> some View {
        if family == .systemSmall { compact(snapshot) } else { overview(snapshot) }
    }
    private func compact(_ snapshot: GaoCiYuanWidgetSnapshot) -> some View {
        let urgent = snapshot.accounts.compactMap { account in account.eligibleQuotas.first.map { (account,$0) } }.min(by:{$0.1.remaining < $1.1.remaining})
        let stamp = urgent.flatMap { $0.0.observedAt } ?? snapshot.updatedAt
        return VStack(alignment:.leading,spacing:7) {
            HStack { Text("词").font(.headline); Text(snapshot.english ? "Lowest quota" : "最低额度").font(.caption.weight(.semibold)); Spacer() }
            if let urgent {
                Text(urgent.0.name).font(.headline).lineLimit(1)
                Text(urgent.1.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text("\(Int(urgent.1.remaining.rounded()))%").font(.system(size:30,weight:.semibold,design:.rounded)).monospacedDigit().foregroundStyle(urgent.0.stale ? .secondary : color(urgent.1.remaining,snapshot.warningThreshold))
                ProgressView(value:urgent.1.remaining,total:100).tint(urgent.0.stale ? Color.secondary : color(urgent.1.remaining,snapshot.warningThreshold))
            } else { Text(snapshot.english ? "No quota data" : "暂无额度数据").font(.caption).foregroundStyle(.secondary); Spacer() }
            Text(stamp,style:.time).font(.system(size:9)).foregroundStyle(.tertiary)
        }
    }
    private func overview(_ snapshot: GaoCiYuanWidgetSnapshot) -> some View {
        let limit = family == .systemLarge ? 7 : 3
        let lastObserved = snapshot.accounts.compactMap(\.observedAt).max() ?? snapshot.updatedAt
        return VStack(alignment:.leading,spacing:7) {
            HStack { Text("词").font(.headline); Text(snapshot.english ? "Token overview" : "词元总览").font(.headline); Spacer(); Text(lastObserved,style:.time).font(.caption2).foregroundStyle(.secondary) }
            ForEach(Array(snapshot.accounts.prefix(limit))) { account in
                HStack(spacing:8) {
                    Text(account.mark).font(.caption.weight(.bold)).frame(width:22,height:22).background(.teal.opacity(0.13),in:Circle())
                    VStack(alignment:.leading,spacing:2) {
                        Text(account.name).font(.caption.weight(.semibold)).lineLimit(1)
                        Text(detail(account,snapshot.english)).font(.caption2).foregroundStyle(account.failed ? .orange : .secondary).lineLimit(1)
                    }
                    Spacer(minLength:4)
                    if let remaining = account.lowestRemaining { Text("\(Int(remaining.rounded()))%").font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(account.stale ? .secondary : color(remaining,snapshot.warningThreshold)) }
                }
            }
            if snapshot.accounts.count > limit { Text(snapshot.english ? "+\(snapshot.accounts.count-limit) more accounts" : "另有 \(snapshot.accounts.count-limit) 个账户").font(.caption2).foregroundStyle(.secondary) }
        }
    }
    private func detail(_ account: GaoCiYuanWidgetSnapshot.AccountItem, _ english: Bool) -> String {
        if account.failed { return english ? "Sync failed" : "同步失败" }
        if let quota = account.eligibleQuotas.first { return quota.title }
        if let balance = account.balances.first { return (english ? "Balance " : "余额 ") + balance }
        if let tokens = account.totalTokens { return "Token " + compact(tokens) }
        return english ? "Waiting for usage" : "等待用量"
    }
    private func compact(_ value: Int64) -> String { value >= 1_000_000 ? String(format:"%.2f M",Double(value)/1_000_000) : value >= 1_000 ? String(format:"%.1f K",Double(value)/1_000) : "\(value)" }
    private func color(_ remaining: Double, _ threshold: Double) -> Color { remaining <= threshold ? .orange : .teal } // 与应用内统一两档，不私设红档
}

struct GaoCiYuanUsageWidget: Widget {
    let kind = "GaoCiYuanUsageWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind:kind,provider:UsageProvider()) { UsageWidgetView(entry:$0).widgetURL(URL(string:"gaociyuan://overview")) }
            .configurationDisplayName("搞词元 · 额度总览")
            .description("在桌面或通知中心查看会员额度、API 余额与 Token 用量。")
            .supportedFamilies([.systemSmall,.systemMedium,.systemLarge])
    }
}

@main struct GaoCiYuanWidgets: WidgetBundle { var body: some Widget { GaoCiYuanUsageWidget(); ActualTokenUsageWidget() } }

struct ActualTokenEntry: TimelineEntry { let date: Date; let snapshot: ActualTokenWidgetSnapshot? }
struct ActualTokenProvider: TimelineProvider {
    func placeholder(in context: Context) -> ActualTokenEntry { .init(date: .now, snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (ActualTokenEntry) -> Void) { completion(read()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ActualTokenEntry>) -> Void) {
        completion(.init(entries: [read()], policy: .after(Date().addingTimeInterval(300))))
    }
    private func read() -> ActualTokenEntry {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let snapshot = ActualTokenWidgetSnapshot.fileURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? decoder.decode(ActualTokenWidgetSnapshot.self, from: $0) }
        return .init(date: .now, snapshot: snapshot)
    }
}
struct ActualTokenWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ActualTokenEntry
    private func compact(_ n: Int64) -> String {
        n >= 1_000_000 ? String(format: "%.2fM", Double(n)/1_000_000) : n >= 1000 ? String(format: "%.1fK", Double(n)/1000) : "\(n)"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Image(systemName: "chart.bar.xaxis").foregroundStyle(.teal); Text("本地词元").font(.headline); Spacer() }
            if let s = entry.snapshot {
                HStack(alignment: .firstTextBaseline) {
                    Text(compact(s.totalTokens)).font(.system(size: 30, weight: .semibold, design: .rounded)).minimumScaleFactor(0.6)
                    if family != .systemSmall { Spacer(); Text("缓存读取 " + compact(s.cacheRead)).font(.caption).foregroundStyle(.secondary) }
                }
                Text(s.day + " · 估算 " + (s.estimatedUSD.map { String(format: "$%.2f", $0) } ?? "费用待定")).font(.caption2).foregroundStyle(.secondary)
                let ceiling = max(1, s.days.map(\.tokens).max() ?? 1)
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(s.days) { d in
                        RoundedRectangle(cornerRadius: 2).fill(.teal.opacity(d.tokens == 0 ? 0.12 : 0.7)).frame(maxWidth: .infinity).frame(height: max(3, 32 * Double(d.tokens) / Double(ceiling)))
                    }
                }.frame(height: 32, alignment: .bottom)
                HStack { Text("近 14 天"); Spacer(); Text(s.updatedAt, style: .time) }.font(.system(size: 9)).foregroundStyle(.tertiary)
            } else {
                Text("打开搞词元 → 用量分析\n完成首次本机日志扫描").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }.containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
    }
}
struct ActualTokenUsageWidget: Widget {
    let kind = "ActualTokenUsageWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ActualTokenProvider()) { ActualTokenWidgetView(entry: $0).widgetURL(URL(string: "gaociyuan://analytics")) }
            .configurationDisplayName("搞词元 · 本地用量")
            .description("本机日志与已导入设备的今日词元、缓存读取和近 14 天趋势。部分来源含估算，费用为 API 等价估算。")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
