import AppKit
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case overview = "总览", agent = "Agent 软件", analytics = "用量分析", providers = "平台接入"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .agent: return "desktopcomputer"
        case .analytics: return "chart.xyaxis.line"
        case .providers: return "square.stack.3d.up"
        }
    }
    var subtitle: String {
        switch self {
        case .overview: return "Agent 额度与状态，一眼看清"
        case .agent: return "只记录本机 Agent 软件"
        case .analytics: return "按日期、工具、模型与会话分析本地用量"
        case .providers: return "发现软件、连接额度、管理采集"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: MonitorStore
    @EnvironmentObject var activity: AgentActivityMonitor
    @EnvironmentObject var analytics: UsageAnalyticsStore
    @Environment(\.openWindow) private var openWindow
    @SceneStorage("selectedPage") private var selectedPage = Page.overview.rawValue
    private var page: Page {
        get { Page(rawValue: selectedPage) ?? .overview }
        nonmutating set { selectedPage = newValue.rawValue }
    }
    @State private var edit: Account?
    @State private var search = ""
    @State private var delete: Account?
    @State private var expandedNotes = Set<UUID>()
    @State private var scrollTarget: UUID?

    var body: some View {
        VStack(spacing: 0) {
            navigation
            Divider().opacity(0.35)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        pageHeading
                        switch page {
                        case .overview: overview(proxy)
                        case .agent: accountList
                        case .analytics: UsageDashboard()
                        case .providers: providers
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 1320, alignment: .topLeading)
                    .frame(maxWidth: .infinity)
                }
                .background(Theme.canvas)
            }
        }
        .frame(minWidth: 880, minHeight: 560)
        .background(Theme.canvas)
        .tint(Theme.accent)
        .onAppear {
            if Page(rawValue: selectedPage) == nil { selectedPage = Page.overview.rawValue }
            activity.setMainWindowVisible(true)
        }
        .onDisappear { activity.setMainWindowVisible(false) }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("gaociyuan.presentRequested"))) { note in
            if let target = note.userInfo?["page"] as? String, Page(rawValue: target) != nil { selectedPage = target }
            if let account = note.userInfo?["account"] as? String, let uuid = UUID(uuidString: account) {
                selectedPage = Page.overview.rawValue
                scrollTarget = uuid
            }
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) ?? NSApp.windows.first(where: { $0.styleMask.contains(.titled) && !($0 is NSPanel) }) {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: "main")
            }
        }
        .sheet(isPresented: $analytics.showSourceSettings) { UsageSourceSettingsView().environmentObject(analytics) }
        .sheet(item: $edit) { AccountEditor(account: $0).environmentObject(store) }
        .alert(L("提示"), isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button(L("知道了")) { store.notice = nil }
        } message: { Text(L(store.notice ?? "")) }
        .alert(L("移除 Agent 软件？"), isPresented: Binding(get: { delete != nil }, set: { if !$0 { delete = nil } })) {
            Button(L("取消"), role: .cancel) { delete = nil }
            Button(L("移除"), role: .destructive) { if let a = delete { store.remove(a.id) }; delete = nil }
        } message: { Text(L("将移除该软件在本机的额度快照和专属凭据，不影响平台上的账号。")) }
    }

    private var navigation: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                if let image = NSImage(contentsOf: TokenBundle.bundle.url(forResource: "GaoCiYuanIcon", withExtension: "png") ?? URL(fileURLWithPath: "")) {
                    Image(nsImage: image).resizable().frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                Text(L("搞词元")).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
            }
            .frame(width: 112, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(Page.allCases) { item in
                    Button { page = item } label: {
                        Label(L(item.rawValue), systemImage: item.symbol)
                            .font(.system(size: 12, weight: page == item ? .semibold : .regular))
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .foregroundStyle(page == item ? Theme.accent : Theme.ink.opacity(0.72))
                            .background(page == item ? Theme.accent.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 8)
            Circle().fill(store.refreshing.isEmpty ? Theme.teal : Theme.accent).frame(width: 6, height: 6)
            Text(L(store.refreshing.isEmpty ? "\(store.active.count) 个 Agent" : "正在同步"))
                .font(.caption).foregroundStyle(.secondary).fixedSize()
            Button { Task { await store.refreshAll(userInitiated: true) } } label: {
                Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain).disabled(!store.refreshing.isEmpty || store.active.isEmpty).help(L("刷新全部 Agent"))
            Menu {
                Button(L("选择 Agent 平台")) { page = .providers }
                Button(L("添加 Agent 软件")) { edit = newAccount(.openai) }
                Divider()
                Button(L("导出账户快照 CSV")) { store.exportCSV() }
            } label: { Image(systemName: "plus").frame(width: 28, height: 28) }
            .buttonStyle(.plain).help(L("添加与导出"))
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(Theme.panel)
    }

    private var pageHeading: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L(page.rawValue)).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(L(page.subtitle)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if page == .analytics {
                Button(L("采集设置")) { analytics.showSourceSettings = true }.controlSize(.small)
            }
        }
    }

    func newAccount(_ provider: Provider) -> Account {
        Account(provider: provider, kind: .agent, name: provider.defaultAgentName,
                connection: Connection.available(provider, .agent)[0],
                currency: provider.integration?.currency ?? "USD")
    }

    @ViewBuilder func overview(_ proxy: ScrollViewProxy) -> some View {
        Group {
            let health = store.healthCounts
            HStack(alignment: .top, spacing: 10) {
                StatCard(title: "已启用 Agent", value: "\(store.active.count)", subtitle: "\(Set(store.active.map(\.provider)).count) 个软件平台", symbol: "desktopcomputer")
                StatCard(title: "已接入平台", value: "\(Set(store.library.accounts.map(\.provider)).count)", subtitle: "账户与自动发现合并统计", symbol: "square.stack.3d.up", color: Theme.teal)
                StatCard(title: "需处理", value: "\(health.needsAction)", subtitle: health.needsAction == 0 ? "当前没有必须处理项" : "低额度、凭据或连续失败", symbol: "exclamationmark.circle", color: health.needsAction > 0 ? .red : Theme.teal)
            }
            if store.library.accounts.isEmpty { onboarding }
            else {
                HStack(spacing: 10) {
                    TextField(L("搜索软件、账户或套餐"), text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                    if health.needsAction + health.syncPaused + health.historical > 0 {
                        Button {
                            if let first = store.alertAccounts.first { withAnimation { proxy.scrollTo(first.id, anchor: .top) } }
                        } label: {
                            HStack(spacing: 10) {
                                if health.needsAction > 0 { Label("\(health.needsAction) 需处理", systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                                if health.syncPaused > 0 { Label("\(health.syncPaused) 暂未同步", systemImage: "pause.circle").foregroundStyle(.orange) }
                                if health.historical > 0 { Label("\(health.historical) 历史数据", systemImage: "clock").foregroundStyle(.secondary) }
                            }.font(.caption)
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }
                let alertIDs = Set(store.alertAccounts.map(\.id))
                let shown = MonitorStore.recentChangeOrder(
                    store.active.filter { search.isEmpty || ($0.name + $0.provider.name + $0.plan).localizedCaseInsensitiveContains(search) }
                ).sorted { alertIDs.contains($0.id) && !alertIDs.contains($1.id) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(shown) { card($0) }
                }
            }
        }
        .onChange(of: scrollTarget) { _, target in
            guard let target else { return }
            scrollTarget = nil
            DispatchQueue.main.async { withAnimation { proxy.scrollTo(target, anchor: .top) } }
        }
    }

    var onboarding: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Tag(text: "从第一个 Agent 开始", color: Theme.teal)
                Text(L("常用 AI 软件，一处查看。")).font(.system(size: 22, weight: .semibold))
                Text(L("自动发现本机 Agent，读取真实额度与本地用量；不再记录大模型 API 账户。"))
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button { page = .providers } label: { Label(L("浏览 Agent 平台"), systemImage: "arrow.right") }.buttonStyle(.borderedProminent)
                    Button(L("添加 Codex")) { edit = newAccount(.openai) }
                }.padding(.top, 4)
            }
            Spacer()
            Image(systemName: "desktopcomputer").font(.system(size: 58, weight: .ultraLight)).foregroundStyle(Theme.teal.opacity(0.55))
        }
        .frame(maxWidth: .infinity, alignment: .leading).panel()
    }

    var accountList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(L("搜索软件、账户或套餐"), text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Spacer()
                Text(L("\(store.library.accounts.count) 个 Agent 账户")).foregroundStyle(.secondary).font(.caption)
                Button { page = .providers } label: { Label(L("添加"), systemImage: "plus") }.controlSize(.small)
            }
            let accounts = store.library.accounts.filter { search.isEmpty || ($0.name + $0.provider.name + $0.plan).localizedCaseInsensitiveContains(search) }
            if accounts.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "desktopcomputer").font(.largeTitle).foregroundStyle(Theme.accent)
                    Text(L(search.isEmpty ? "暂无已接入的 Agent 软件" : "没有匹配的 Agent 软件")).font(.headline)
                    if search.isEmpty { Button(L("选择 Agent 平台")) { page = .providers } }
                }.frame(maxWidth: .infinity, minHeight: 180).panel()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), alignment: .top)], spacing: 12) {
                ForEach(accounts) { card($0) }
            }
        }
    }

    func card(_ a: Account) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if a.provider == .custom { CustomAccountMark(name: a.name, accountID: a.id, size: 34) } else { ProviderMark(provider: a.provider, size: 34) }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(a.name).font(.headline).lineLimit(1)
                        if activity.isWorking(AgentActivity.Subject(account: a)) {
                            Circle().fill(Theme.teal).frame(width: 7, height: 7)
                                .phaseAnimator([false, true]) { dot, phase in dot.opacity(phase ? 0.35 : 1) } animation: { _ in .easeInOut(duration: 0.9) }
                                .help(L("CLI 工作中"))
                        }
                    }
                    Text(L(a.provider.agentSoftware)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button(L("账户设置")) { edit = a }
                    Button(L("打开官方控制台")) { if let url = URL(string: a.dashboard) { NSWorkspace.shared.open(url) } }
                    Divider()
                    Button(L("移除账户"), role: .destructive) { delete = a }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22)
            }
            HStack {
                Tag(text: a.enabled ? a.connection.displayName : "已暂停", color: a.enabled ? Theme.accent : .secondary)
                if a.autoDiscovered { Tag(text: "自动发现", color: Theme.teal) }
                if a.stale(), a.snapshot != nil { Tag(text: "历史数据", color: .orange) }
                Spacer()
            }
            if let s = a.snapshot, !a.errorIsCredential {
                let rows = a.displayQuotas
                if !rows.isEmpty {
                    ForEach(rows) { QuotaRow(quota: $0, stale: a.stale(), threshold: store.library.warningThreshold, burnEstimateText: a.burnEstimate(quotaID: $0.id), showExpiredValue: a.keepsSnapshotOnError) }
                } else if !s.quotas.isEmpty {
                    Text(L("上一计费周期已结束，等待平台新读数。")).font(.caption).foregroundStyle(.secondary)
                } else if s.balances.isEmpty && s.costs.isEmpty && (s.creditBalances ?? []).isEmpty && a.provider != .dsh && a.provider != .workbuddy {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("— 尚未读取到额度")).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                        Text(L("连接后读取真实数据，不预填额度。")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(s.creditBalances ?? []) { balance in
                    HStack { Text(balance.title).font(.callout).foregroundStyle(.secondary); Spacer(); Text(balance.text).font(.title3.weight(.semibold)).monospacedDigit() }
                }
                if a.provider.integration != nil {
                    ForEach(s.balances, id: \.currency) { balance in HStack { Text("账户余额").font(.caption).foregroundStyle(.secondary); Spacer(); Text(balance.text).font(.title3.weight(.semibold)) } }
                    ForEach(s.costs, id: \.currency) { cost in HStack { Text("统计期费用").font(.caption).foregroundStyle(.secondary); Spacer(); Text(cost.text).font(.callout.weight(.semibold)) } }
                }
                if a.provider == .dsh {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("钱包余额")).font(.caption).foregroundStyle(.secondary)
                            if let b = s.balances.first { Text(DshBridge.balanceText(b)).font(.system(size: 26, weight: .semibold)).monospacedDigit().foregroundStyle(b.value < 1 ? PanelTheme.warnDeep : b.value < 5 ? PanelTheme.warn : Color.primary) }
                            else { Text(L("—")).font(.title2) }
                        }
                        Spacer()
                        Button { if let url = URL(string: DshBridge.topUpURL) { NSWorkspace.shared.open(url) } } label: { Label(L("去充值"), systemImage: "plus.circle") }.buttonStyle(.borderedProminent).controlSize(.small)
                    }
                    ForEach(DshBridge.noteParts(s.note), id: \.self) { Text(L($0)).font(.caption).foregroundStyle(.secondary) }
                }
                if a.provider == .workbuddy {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("积分余额")).font(.caption).foregroundStyle(.secondary)
                            if let c = s.balances.first { Text(WorkBuddyBridge.creditsText(c.value)).font(.system(size: 26, weight: .semibold)).monospacedDigit().foregroundStyle(c.value < 10 ? PanelTheme.warnDeep : c.value < 100 ? PanelTheme.warn : Color.primary) }
                            else { Text(L("—")).font(.title2) }
                        }
                        Spacer()
                        Button { if let url = URL(string: WorkBuddyBridge.viewURL) { NSWorkspace.shared.open(url) } } label: { Label(L("去查看"), systemImage: "safari") }.buttonStyle(.borderedProminent).controlSize(.small)
                    }
                    ForEach(DshBridge.noteParts(s.note), id: \.self) { Text(L($0)).font(.caption).foregroundStyle(.secondary) }
                }
                if let note = s.note, !note.isEmpty, a.provider != .dsh, a.provider != .workbuddy {
                    let expanded = expandedNotes.contains(a.id)
                    Text(expanded || note.count <= 40 ? L(note) : L("采集说明")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineLimit(expanded ? nil : 1)
                    if note.count > 40 { Button(L(expanded ? "收起 ▾" : "详情 ▸")) { if expanded { expandedNotes.remove(a.id) } else { expandedNotes.insert(a.id) } }.buttonStyle(.plain).font(.caption).foregroundStyle(Theme.accent) }
                }
                Text(L(a.stale() ? "数据截至 \(displayDate(s.observedAt)) · \(s.source)" : "\(s.source) · \(displayDate(s.observedAt))")).font(.caption2).foregroundStyle(.secondary)
            } else if a.errorIsCredential {
                Label(L("凭证已失效，重新连接前不展示旧读数。"), systemImage: "key.slash").font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("—")).font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
                    Text(L("尚未获取额度")).font(.callout)
                    Text(L("连接后读取真实数据，不预填额度。")).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            }
            if (a.snapshot?.note ?? "").contains("需在「系统设置") || (a.error ?? "").contains("需在「系统设置") || (a.statusNote ?? "").contains("需在「系统设置") {
                Button(L("打开系统设置授权 ↗")) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }.buttonStyle(.borderedProminent).controlSize(.small).font(.caption)
            }
            if let status = GrokBotBridge.visibleStatus(a) { Label(L(status), systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let error = a.error { Label(L(error), systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button { Task { await store.refresh(a.id, userInitiated: true) } } label: {
                    Label(L(GrokBotBridge.isUsageRoute(a) ? GrokBotUsageReport.manualButtonTitle(refreshing: store.refreshing.contains(a.id)) : (store.refreshing.contains(a.id) ? "同步中…" : "立即同步")), systemImage: "arrow.clockwise")
                }.disabled(store.refreshing.contains(a.id) || !a.enabled).controlSize(.small)
                Spacer()
                if a.provider != .custom { Button(L("控制台 ↗")) { if let url = URL(string: a.dashboard) { NSWorkspace.shared.open(url) } }.buttonStyle(.plain).foregroundStyle(.secondary).font(.caption) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).panel()
        .saturation(a.stale() && a.snapshot != nil ? 0.45 : 1)
        .help(a.stale() && a.snapshot != nil ? L("历史数据：最后成功观测于 \(displayDate(a.snapshot?.observedAt ?? Date(), time: true))") : "")
        .id(a.id)
    }

    var providers: some View {
        ProviderCatalogView { provider, _ in edit = newAccount(provider) }
    }
}
