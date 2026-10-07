import AppKit
import SwiftUI
import Charts

enum Page: String, CaseIterable, Identifiable {
    // 设置已收拢到 app 级设置中心（TokenSettingsView），模块内不再有「设置」页。
    case overview = "用量总览", agent = "Agent", llm = "LLM", history = "用量记录", analytics = "用量分析", providers = "平台接入"
    var id: String { rawValue }
    var symbol: String { [.overview:"square.grid.2x2",.agent:"cpu",.llm:"curlybraces",.history:"clock.arrow.circlepath",.analytics:"chart.bar.xaxis",.providers:"square.stack.3d.up"][self]! }
    var subtitle: String { [.overview:"每一份额度，都心中有数。",.agent:"各 AI 平台专属本机 Agent 软件。",.llm:"大模型 API 余额、Token 与费用。",.history:"每一次同步，都有迹可循。",.analytics:"按日期、工具、模型与会话分析本地用量。",.providers:"把常用的 AI，放到一起。"][self]! }
}
struct ContentView: View {
    @EnvironmentObject var store: MonitorStore
    @EnvironmentObject var activity: AgentActivityMonitor
    @EnvironmentObject var analytics: UsageAnalyticsStore
    @Environment(\.openWindow) private var openWindow
    @SceneStorage("selectedPage") private var selectedPage = Page.overview.rawValue
    private var page: Page { get { Page(rawValue:selectedPage) ?? .overview } nonmutating set { selectedPage = newValue.rawValue } }
    @State private var edit: Account?
    @State private var search = ""
    @State private var delete: Account?
    @State private var expandedNotes = Set<UUID>()
    /// 通知点击带来的滚动定位目标（账户 id），总览页消费后清空。
    @State private var scrollTarget: UUID?
    /// 完全隐藏侧边栏（统一工具栏契约：与各模块一致，只有标题栏一个切换按钮）。
    /// SceneStorage 为场景级存储，键带模块后缀避免 7 个模块同键互相串扰。
    @SceneStorage("gqns.sidebarHidden.token") private var sidebarHidden = false
    @State private var hoveredPage: Page?
    var body: some View {
        // 侧边栏（V2.2 自绘设计，V2.3 起与其他模块统一为两态）：
        // 品牌头部（徽章+名称+副标题）+ 浮动卡片式选中态导航行 + 细腻 hover + 状态底卡；
        // 显示形态只有 236pt 展开一种；隐藏/显示由标题栏 sidebar.left 按钮或 ⌃⌘S 控制。
        HStack(spacing:0) {
            if !sidebarHidden {
                sidebar
                // 自绘发丝线替代系统 Divider：避免 Tahoe 统一标题栏下系统 separator 冷启动首帧误渲染成灰带
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1).frame(maxHeight: .infinity)
            }
            VStack(spacing:0) {
                header
                Divider().opacity(0.45)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment:.leading,spacing:22) {
                            switch page {
                            case .overview: overview(proxy)
                            case .agent: accountList(kind:.agent)
                            case .llm: accountList(kind:.llm)
                            case .providers: providers
                            case .history: history
                            case .analytics: UsageDashboard()
                            }
                        }.padding(26).frame(maxWidth:1500,alignment:.topLeading).frame(maxWidth:.infinity)
                    }.background(Theme.canvas)
                }
            }
        }.frame(minWidth:1020,minHeight:680)
            .animation(.easeInOut(duration:0.22),value:sidebarHidden)
            .tint(Theme.accent)
            // 统一工具栏契约 leading：恰好一个侧栏切换按钮，sidebar.left 图标，固定 28×28，
            // ⌃⌘S，help 随状态「隐藏侧边栏/显示侧边栏」。隐藏时侧栏+Divider 整体移除、
            // 内容占满全宽，0.22s 动画与系统行为一致。
            .toolbar {
                toolbarItemNoChrome(.navigation) {
                    Button {
                        withAnimation(.easeInOut(duration:0.22)) { sidebarHidden.toggle() }
                    } label: {
                        SidebarToggleIcon()
                    }
                    .buttonStyle(.plain)
                    .help(L(sidebarHidden ? "显示侧边栏" : "隐藏侧边栏"))
                    .keyboardShortcut("s",modifiers:[.control,.command])
                }
            }
            .onAppear {
                if Page(rawValue: selectedPage) == nil { selectedPage = Page.overview.rawValue }
                activity.setMainWindowVisible(true)
            }
            .onDisappear { activity.setMainWindowVisible(false) }
            .onReceive(NotificationCenter.default.publisher(for:Notification.Name("gaociyuan.presentRequested"))) { note in
                // userInfo 可带 page（浮动条菜单「设置…」）与 account（通知点击定位卡片）。
                if let target = note.userInfo?["page"] as? String, Page(rawValue:target) != nil { selectedPage = target }
                if let account = note.userInfo?["account"] as? String, let uuid = UUID(uuidString:account) {
                    selectedPage = Page.overview.rawValue
                    scrollTarget = uuid
                }
                NSApp.activate(ignoringOtherApps:true)
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) ?? NSApp.windows.first(where: { $0.styleMask.contains(.titled) && !($0 is NSPanel) }) {
                    if window.isMiniaturized { window.deminiaturize(nil) }
                    window.makeKeyAndOrderFront(nil)
                } else {
                    openWindow(id:"main")
                }
            }
            .sheet(isPresented: $analytics.showSourceSettings) { UsageSourceSettingsView().environmentObject(analytics) }
            .sheet(item:$edit) { AccountEditor(account:$0).environmentObject(store) }
            .alert(L("提示"),isPresented:Binding(get:{store.notice != nil},set:{if !$0 { store.notice = nil }})) { Button(L("知道了")) { store.notice = nil } } message: { Text(L(store.notice ?? "")) }
            .alert(L("移除账户？"),isPresented:Binding(get:{delete != nil},set:{if !$0 { delete = nil }})) { Button(L("取消"),role:.cancel) { delete = nil }; Button(L("移除"),role:.destructive) { if let a = delete { store.remove(a.id) }; delete = nil } } message: { Text(L("将移除该账户在本机的快照和密钥，不影响平台上的账号。需要保留记录时可先导出备份。")) }
    }
    // MARK: 自绘侧边栏（V2.2 设计，V2.3 起两态统一）：浮动卡片选中态 + hover 反馈 + 状态底卡；显示形态只有 236pt 展开

    private var sidebar: some View {
        VStack(spacing:0) {
            brandHeader
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    sidebarSection(L("词元管理"),pages:[.overview,.analytics,.agent,.llm,.history])
                    sidebarSection(L("连接与偏好"),pages:[.providers])
                }
                .padding(.horizontal,14)
                .padding(.vertical,14)
                .frame(maxWidth:.infinity,alignment:.leading)
            }
            statusFooter
        }
        .frame(width:236)
        .frame(maxHeight:.infinity)
        .background(.regularMaterial)
    }
    private var brandHeader: some View {
        HStack(spacing:10) {
            if let image = NSImage(contentsOf:TokenBundle.bundle.url(forResource:"GaoCiYuanIcon",withExtension:"png") ?? URL(fileURLWithPath:"")) {
                Image(nsImage:image).resizable()
                    .frame(width:38,height:38)
                    .clipShape(RoundedRectangle(cornerRadius:9,style:.continuous))
            }
            VStack(alignment:.leading,spacing:2) {
                Text(L("搞词元")).font(.headline)
                Text(L("AI 额度与用量")).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength:0)
        }
        .padding(.horizontal,14)
        .padding(.top,14)
        .padding(.bottom,10)
        .frame(maxWidth:.infinity)
    }
    @ViewBuilder private func sidebarSection(_ title:String,pages:[Page]) -> some View {
        VStack(alignment:.leading,spacing:4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal,10)
                .padding(.bottom,2)
            ForEach(pages) { sidebarRow($0) }
        }
    }
    private func sidebarRow(_ p:Page) -> some View {
        let selected = page == p
        let hovered = hoveredPage == p
        return Button { page = p } label: {
            HStack(spacing:10) {
                Image(systemName:p.symbol)
                    .font(.callout)
                    .frame(width:20)
                Text(L(p.rawValue))
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength:0)
            }
            .padding(.horizontal,10)
            .frame(maxWidth:.infinity,minHeight:32)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius:9,style:.continuous)
                        .fill(Theme.accent)
                        .shadow(color:Theme.accent.opacity(0.35),radius:5,y:2)
                } else if hovered {
                    RoundedRectangle(cornerRadius:9,style:.continuous)
                        .fill(Color.primary.opacity(0.06))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius:9,style:.continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in hoveredPage = hovering ? p : nil }
        .help(L(p.subtitle))
    }
    private var statusFooter: some View {
        VStack(alignment:.leading,spacing:7) {
            HStack(spacing:7) {
                Circle().fill(store.refreshing.isEmpty ? Theme.teal : Theme.accent).frame(width:7,height:7)
                Text(L(store.refreshing.isEmpty ? "\(store.active.count) 个启用账户" : "正在同步…")).font(.caption)
                Spacer(minLength:0)
            }
            Text(L("本地存储 · 密钥保存在钥匙串")).font(.system(size:10)).foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:12,style:.continuous))
        .padding(.horizontal,14)
        .padding(.vertical,12)
    }
    var header: some View {
        HStack(spacing:14) {
            Image(systemName:page.symbol).font(.title2).foregroundStyle(Theme.accent).frame(width:42,height:42).background(Theme.accent.opacity(0.08),in:RoundedRectangle(cornerRadius:12))
            VStack(alignment:.leading,spacing:5) { Text(L(page.rawValue)).font(.system(size:24,weight:.semibold)); Text(L(page.subtitle)).font(.callout).foregroundStyle(.secondary) }
            Spacer()
            if page != .analytics {
            Button { Task { await store.refreshAll(userInitiated: true) } } label: { Label(L(store.refreshing.isEmpty ? "刷新" : "同步中"),systemImage:"arrow.clockwise") }.disabled(!store.refreshing.isEmpty || store.active.isEmpty)
            Menu { Button(L("导出完整数据…")) { store.exportBackup() }; Button(L("导入数据…")) { store.restoreBackup() }; Divider(); Button(L("导出账户快照 CSV")) { store.exportCSV() } } label: { Image(systemName:"square.and.arrow.up.on.square") }.help(L("导入与导出"))
            Menu {
                Button("选择平台连接…") { page = .providers }
                Button("添加 Agent 账户") { edit = newAccount(.openai, .agent) }
                Button("添加 API 账户") { edit = newAccount(.openai, .llm) }
            } label: { Label("添加账户", systemImage: "plus") }
            }
        }.padding(.horizontal,26).padding(.vertical,22)
    }
    func newAccount(_ p: Provider, _ kind: AccountKind) -> Account { Account(provider:p,kind:kind,name:kind == .agent ? p.defaultAgentName : p.defaultLLMName,connection:Connection.available(p,kind)[0],currency:p.integration?.currency ?? ([.deepseek,.kimi,.qwen,.doubao,.glm,.minimax,.hy,.mimo,.dsh,.workbuddy,.custom].contains(p) ? "CNY" : "USD")) }
    @ViewBuilder func overview(_ proxy: ScrollViewProxy) -> some View {
        Group {
            let health = store.healthCounts
            HStack(alignment:.top,spacing:14) {
                StatCard(title:"已启用账户",value:"\(store.active.count)",subtitle:"\(Set(store.active.map(\.provider).filter { $0 != .custom }).count) / \(Provider.allCases.filter { $0 != .custom }.count) 个平台",symbol:"square.stack.3d.up")
                StatCard(title:"Agent 软件",value:"\(store.active.filter { $0.kind == .agent }.count)",subtitle:"本机 Agent 智能体",symbol:"cpu",color:Theme.teal)
                StatCard(title:"LLM API",value:"\(store.active.filter { $0.kind == .llm }.count)",subtitle:"费用按账户、币种独立核算",symbol:"curlybraces")
                // 3.36：三态分类——「需处理」才是真告警（红），服务没启动/读取失败是「暂时无法同步」（橙），不再同级。
                StatCard(title:"需处理",value:"\(health.needsAction)",subtitle:"低额度、凭证失效或连续失败",symbol:"exclamationmark.circle",color:health.needsAction > 0 ? .red : .orange)
            }
            if store.active.isEmpty { onboarding }
            else {
                HStack { Text(L("我的额度")).font(.title3.weight(.semibold)); Spacer(); Text(L("来源与更新时间始终可见")).font(.caption).foregroundStyle(.secondary) }
                // V2.2：总览复用账户页搜索框；告警账户置顶排序，聚合条定位与置顶后的一致。
                HStack { TextField(L("搜索平台、账户或套餐"),text:$search).textFieldStyle(.roundedBorder).frame(maxWidth:320); Spacer() }
                // 聚合状态条：三态同一条内分行列数，点击滚动定位到第一个「需处理」卡片。
                if health.needsAction + health.syncPaused + health.historical > 0 {
                    Button {
                        if let first = store.alertAccounts.first { withAnimation { proxy.scrollTo(first.id,anchor:.top) } }
                    } label: {
                        HStack(spacing:10) {
                            if health.needsAction > 0 { Label(L("\(health.needsAction) 个需处理"),systemImage:"exclamationmark.circle").foregroundStyle(.red) }
                            if health.syncPaused > 0 { Label(L("\(health.syncPaused) 个暂时无法同步"),systemImage:"pause.circle").foregroundStyle(.orange) }
                            if health.historical > 0 { Label(L("\(health.historical) 个历史数据"),systemImage:"clock").foregroundStyle(.secondary) }
                            Spacer()
                            if store.alertAccounts.first != nil { Text(L("定位 ›")).foregroundStyle(.secondary) }
                        }.font(.callout.weight(.medium))
                    }.buttonStyle(.plain).frame(maxWidth:.infinity,alignment:.leading).panel()
                }
                let alertIDs = Set(store.alertAccounts.map(\.id))
                // 3.2：告警账户置顶不变；其余按「最近一次额度/余额/积分变化时间」倒序（刚消耗的排最上）。
                let shown = MonitorStore.recentChangeOrder(
                    store.active
                        .filter { search.isEmpty || ($0.name + $0.provider.name + $0.plan).localizedCaseInsensitiveContains(search) }
                ).sorted { alertIDs.contains($0.id) && !alertIDs.contains($1.id) }
                LazyVGrid(columns:[GridItem(.adaptive(minimum:330),alignment:.top)],alignment:.leading,spacing:16) { ForEach(shown) { card($0) } }
            }
            HStack(spacing:12) { Image(systemName:"info.circle").foregroundStyle(Theme.accent); Text(L("Agent 百分比、API Token 与账户余额是不同指标。没有数据时显示“—”；快照超过 15 分钟会标记为历史数据。")).font(.caption).foregroundStyle(.secondary) }.padding(.vertical,4)
        }
        // 通知点击定位：目标账户卡片滚到顶（等一帧让总览页先铺开）。
        .onChange(of: scrollTarget) { _, target in
            guard let target else { return }
            scrollTarget = nil
            DispatchQueue.main.async { withAnimation { proxy.scrollTo(target, anchor: .top) } }
        }
    }
    var onboarding: some View {
        VStack(alignment:.leading,spacing:24) {
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:12) {
                    Tag(text:"从第一个账户开始",color:Theme.teal)
                    Text(L("额度不必来回找。\n常用 AI，一处查看。")).font(.system(size:28,weight:.semibold)).lineSpacing(7)
                    Text(L("各 Agent 在运行环境中自动接入并检测剩余额度；\n在此添加 LLM API 账户，跟踪用量、余额与费用。")).font(.callout).foregroundStyle(.secondary).lineSpacing(5)
                }
                Spacer()
                Image(systemName:"chart.bar.xaxis").font(.system(size:86,weight:.ultraLight)).foregroundStyle(Theme.teal.opacity(0.6)).padding(25)
            }
            HStack(spacing:12) {
                Button { edit = newAccount(.openai,.llm) } label: { Label(L("添加 LLM 账户"),systemImage:"plus") }.buttonStyle(.borderedProminent).controlSize(.large)
                Button(L("浏览所有平台")) { page = .providers }.controlSize(.large)
            }
            Divider()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 40))], spacing: 12) { ForEach(Provider.allCases) { ProviderMark(provider:$0,size:32).help(L($0.name)) } }
        }.frame(maxWidth:.infinity,alignment:.leading).padding(12).panel()
    }
    func accountList(kind: AccountKind) -> some View {
        VStack(alignment:.leading,spacing:20) {
            HStack { TextField(L("搜索平台、账户或套餐"),text:$search).textFieldStyle(.roundedBorder).frame(maxWidth:320); Spacer(); Text(L("\(store.library.accounts.filter { $0.kind == kind }.count) 个账户")).foregroundStyle(.secondary).font(.caption) }
            if kind == .llm { Text(L("自动报告按 UTC 自然月统计。各账户独立展示，避免同一组织多个密钥重复汇总；预算是本机提醒，不会限制平台扣费。")).font(.callout).foregroundStyle(.secondary) }
            else { Text(L("自动连接并检测各大 AI 平台的本机 Agent 软件（如 Codex、Claude Code、Antigravity 等），可在平台接入中添加账户并选择连接方式。")).font(.callout).foregroundStyle(.secondary) }
            let accounts = store.library.accounts.filter { $0.kind == kind && (search.isEmpty || ($0.name + $0.provider.name + $0.plan).localizedCaseInsensitiveContains(search)) }
            if accounts.isEmpty {
                VStack(spacing:15) {
                    Image(systemName:kind == .llm ? "curlybraces" : "cpu").font(.largeTitle).foregroundStyle(Theme.accent)
                    Text(L(kind == .llm ? "还没有添加 LLM 账户" : "暂无已接入的 Agent 账户")).font(.headline)
                    if kind == .llm {
                        Button(L("添加 LLM 账户")) { edit = newAccount(.openai,.llm) }
                    } else {
                        Button(L("选择 Agent 平台")) { page = .providers }
                    }
                }.frame(maxWidth:.infinity,minHeight:240).panel()
            }
            LazyVGrid(columns:[GridItem(.adaptive(minimum:330),alignment:.top)],spacing:16) { ForEach(accounts) { card($0) } }
        }
    }
    func card(_ a: Account) -> some View {
        VStack(alignment:.leading,spacing:17) {
            HStack(spacing:11) {
                if a.provider == .custom { CustomAccountMark(name:a.name,accountID:a.id) } else { ProviderMark(provider:a.provider) }
                VStack(alignment:.leading,spacing:4) {
                    HStack(spacing:6) {
                        Text(a.name).font(.headline).lineLimit(1)
                        if activity.isWorking(AgentActivity.Subject(account:a)) {
                            Circle().fill(Theme.teal).frame(width:8,height:8)
                                .shadow(color:Theme.teal.opacity(0.8),radius:4)
                                .phaseAnimator([false,true]) { dot, phase in dot.opacity(phase ? 0.35 : 1) } animation: { _ in .easeInOut(duration:0.9) }
                                .help(L("CLI 工作中"))
                        }
                    }
                    Text(L(a.kind == .agent ? a.provider.agentSoftware : (a.plan.isEmpty ? "API" : a.plan))).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button(L("账户设置")) { edit = a }
                    Button(L("打开官方控制台")) { if let url = URL(string:a.dashboard) { NSWorkspace.shared.open(url) } }
                    Divider()
                    Button(L("移除账户"),role:.destructive) { delete = a }
                } label: { Image(systemName:"ellipsis") }.menuStyle(.borderlessButton).frame(width:22)
            }
            HStack { Tag(text:a.enabled ? a.connection.displayName : "已暂停",color:a.enabled ? Theme.accent : .secondary); if a.autoDiscovered { Tag(text:"自动发现",color:Theme.teal) }; if a.stale(), a.snapshot != nil { Tag(text:"历史数据",color:.orange) }; Spacer() }
            if let s = a.snapshot, !a.errorIsCredential {
                let rows = a.displayQuotas
                if !rows.isEmpty {
                    ForEach(rows) { QuotaRow(quota:$0, stale:a.stale(), threshold:store.library.warningThreshold, burnEstimateText:a.burnEstimate(quotaID:$0.id), showExpiredValue: a.keepsSnapshotOnError) }
                } else if !s.quotas.isEmpty {
                    Text(L("上一计费周期已结束，等待平台新读数。")).font(.caption).foregroundStyle(.secondary)
                } else if a.kind == .agent && s.balances.isEmpty && s.costs.isEmpty && (s.creditBalances ?? []).isEmpty && a.provider != .dsh && a.provider != .workbuddy && a.provider != .custom {
                    VStack(alignment:.leading,spacing:6) {
                        Text(L("— 尚未读取到额度")).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                        Text(L("连接后自动读取真实数据，不预填额度。")).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
                ForEach(s.creditBalances ?? []) { balance in
                    HStack {
                        Text(balance.title).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Text(balance.text).font(.title3.weight(.semibold)).monospacedDigit()
                    }
                }
                if a.kind == .agent && a.provider.integration != nil {
                    ForEach(s.balances, id: \.currency) { balance in
                        HStack { Text("账户余额").font(.caption).foregroundStyle(.secondary); Spacer(); Text(balance.text).font(.title3.weight(.semibold)) }
                    }
                    ForEach(s.costs, id: \.currency) { cost in
                        HStack { Text("统计期费用").font(.caption).foregroundStyle(.secondary); Spacer(); Text(cost.text).font(.callout.weight(.semibold)) }
                    }
                }
                // dsh：钱包余额语义——大号余额 + 赠金/累计消费行 + 去充值，无时间窗、无重置倒计时。
                if a.provider == .dsh {
                    HStack(alignment:.top) {
                        VStack(alignment:.leading,spacing:5) {
                            Text(L("钱包余额")).font(.caption).foregroundStyle(.secondary)
                            if let b = s.balances.first {
                                Text(DshBridge.balanceText(b)).font(.system(size:30,weight:.semibold)).monospacedDigit()
                                    .foregroundStyle(b.value < 1 ? PanelTheme.warnDeep : b.value < 5 ? PanelTheme.warn : Color.primary)
                            } else { Text(L("—")).font(.title2) }
                        }
                        Spacer()
                        Button { if let url = URL(string:DshBridge.topUpURL) { NSWorkspace.shared.open(url) } } label: {
                            Label(L("去充值"),systemImage:"plus.circle")
                        }.buttonStyle(.borderedProminent).controlSize(.small)
                    }
                    ForEach(DshBridge.noteParts(s.note),id:\.self) { Text(L($0)).font(.caption).foregroundStyle(.secondary) }
                    Divider()
                }
                // workbuddy：积分制语义——大号剩余积分 + 口径说明行 + 去查看，无时间窗、无重置倒计时。
                if a.provider == .workbuddy {
                    HStack(alignment:.top) {
                        VStack(alignment:.leading,spacing:5) {
                            Text(L("积分余额")).font(.caption).foregroundStyle(.secondary)
                            if let c = s.balances.first {
                                Text(WorkBuddyBridge.creditsText(c.value)).font(.system(size:30,weight:.semibold)).monospacedDigit()
                                    .foregroundStyle(c.value < 10 ? PanelTheme.warnDeep : c.value < 100 ? PanelTheme.warn : Color.primary)
                            } else { Text(L("—")).font(.title2) }
                        }
                        Spacer()
                        Button { if let url = URL(string:WorkBuddyBridge.viewURL) { NSWorkspace.shared.open(url) } } label: {
                            Label(L("去查看"),systemImage:"safari")
                        }.buttonStyle(.borderedProminent).controlSize(.small)
                    }
                    ForEach(DshBridge.noteParts(s.note),id:\.self) { Text(L($0)).font(.caption).foregroundStyle(.secondary) }
                    Divider()
                }
                // custom（3.3）：自定义 API 余额——大号余额（单位自定）+ 附加字段行，无官方控制台按钮。
                if a.provider == .custom {
                    let baseline = a.customConfig?.baseline ?? 100
                    let unit = a.customConfig?.unit ?? "¥"
                    HStack(alignment:.top) {
                        VStack(alignment:.leading,spacing:5) {
                            Text(L("账户余额")).font(.caption).foregroundStyle(.secondary)
                            if let b = s.balances.first {
                                Text(CustomBridge.unitText(unit, b.value)).font(.system(size:30,weight:.semibold)).monospacedDigit()
                                    .foregroundStyle(b.value <= 0 ? PanelTheme.warnDeep : b.value < baseline * 0.1 ? PanelTheme.warn : Color.primary)
                            } else { Text(L("—")).font(.title2) }
                        }
                        Spacer()
                    }
                    ForEach(DshBridge.noteParts(s.note),id:\.self) { Text(L($0)).font(.caption).foregroundStyle(.secondary) }
                    Text(L("满环基准 \(CustomBridge.unitText(unit, baseline)) · 自定义 API")).font(.caption).foregroundStyle(.secondary)
                    Divider()
                }
                if a.kind == .llm {
                    HStack(alignment:.top) {
                        VStack(alignment:.leading,spacing:5) { Text(L("Token 用量")).font(.caption).foregroundStyle(.secondary); Text(L(compactTokens(s.totalTokens))).font(.title2.weight(.semibold)).monospacedDigit(); Text(L("输入 \(compactTokens(s.inputTokens)) / 输出 \(compactTokens(s.outputTokens))")).font(.system(size:10)).foregroundStyle(.secondary) }
                        Spacer()
                        VStack(alignment:.trailing,spacing:5) { Text(L("统计期费用")).font(.caption).foregroundStyle(.secondary); if s.costs.isEmpty { Text(L("—")).font(.title2) }; ForEach(s.costs,id:\.currency) { Text(L($0.text)).font(.title3.weight(.semibold)).monospacedDigit() } }
                    }
                    Divider()
                    HStack { Text(L("账户余额")).font(.callout).foregroundStyle(.secondary); Spacer(); if s.balances.isEmpty { Text(L("—")).foregroundStyle(.secondary) }; ForEach(s.balances,id:\.currency) { Text(L($0.text)).font(.callout.weight(.semibold)).foregroundStyle($0.value > 0 ? Theme.teal : .orange) } }
                    if let start = s.periodStart, let end = s.periodEnd { Text(L("统计期 \(displayDate(start,time:false)) – \(displayDate(end,time:false))")).font(.system(size:10)).foregroundStyle(.tertiary) }
                    if let budget = a.budget { Text(L("本月预算 \(a.currency) \(budget.formatted()) · 仅本地提醒")).font(.caption).foregroundStyle(.secondary) }
                }
                if let note = s.note, !note.isEmpty, a.provider != .dsh, a.provider != .workbuddy, a.provider != .custom {
                    let expanded = expandedNotes.contains(a.id)
                    Text(expanded || note.count <= 40 ? L(note) : L("采集说明")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                        .lineLimit(expanded ? nil : 1)
                    if note.count > 40 {
                        Button(L(expanded ? "收起 ▾" : "详情 ▸")) { if expanded { expandedNotes.remove(a.id) } else { expandedNotes.insert(a.id) } }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(Theme.accent)
                    }
                }
                Text(L(a.stale() ? "数据截至 \(displayDate(s.observedAt)) · \(s.source)" : "\(s.source) · \(displayDate(s.observedAt))")).font(.caption).foregroundStyle(.secondary)
            } else if a.errorIsCredential {
                Label(L("凭证已失效，重新连接前不展示旧读数。"),systemImage:"key.slash").font(.callout).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true)
            } else {
                VStack(alignment:.leading,spacing:10) { Text(L("—")).font(.system(size:30,weight:.light)).foregroundStyle(.secondary); Text(L("尚未获取用量")).font(.callout); Text(L("连接后自动读取真实数据，不预填额度。")).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth:.infinity,minHeight:95,alignment:.leading)
            }
            if (a.snapshot?.note ?? "").contains("需在「系统设置") || (a.error ?? "").contains("需在「系统设置") || (a.statusNote ?? "").contains("需在「系统设置") {
                Button(L("打开系统设置授权 ↗")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }.buttonStyle(.borderedProminent).controlSize(.small).font(.caption)
            }
            if let status = a.statusNote { Label(L(status),systemImage:"info.circle").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
            if let error = a.error { Label(L(error),systemImage:"exclamationmark.circle").font(.caption).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true) }
            HStack {
                Button { Task { await store.refresh(a.id, userInitiated: true) } } label: { Label(L(store.refreshing.contains(a.id) ? "同步中…" : "立即同步"),systemImage:"arrow.clockwise") }.disabled(store.refreshing.contains(a.id) || !a.enabled)
                Spacer()
                if a.provider != .custom { Button(L("控制台 ↗")) { if let url = URL(string:a.dashboard) { NSWorkspace.shared.open(url) } }.buttonStyle(.plain).foregroundStyle(.secondary).font(.caption) }
            }
        }.frame(maxWidth:.infinity,alignment:.leading).panel()
            .saturation(a.stale() && a.snapshot != nil ? 0.45 : 1)
            .help(a.stale() && a.snapshot != nil ? L("历史数据：最后成功观测于 \(displayDate(a.snapshot?.observedAt ?? Date(),time:true))") : "")
            .id(a.id)
    }
    var providers: some View {
        ProviderCatalogView { provider, kind in edit = newAccount(provider, kind) }
    }
    var history: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack { Text(L("最近同步快照")).font(.headline); Spacer(); Button(L("导出 CSV")) { store.exportCSV() } }
            Text(L("记录的是时点快照，累计月度用量不能跨快照相加。")).font(.callout).foregroundStyle(.secondary)
            ForEach(store.library.accounts) { a in
                if !a.history.isEmpty {
                    VStack(alignment:.leading,spacing:16) {
                        HStack { ProviderMark(provider:a.provider,size:30); Text(a.name).font(.headline); Spacer(); Text(L("\(a.history.count) 份快照")).foregroundStyle(.secondary).font(.caption) }
                        AccountHistoryChart(account: a)
                    }.panel()
                }
            }
            if !store.library.accounts.contains(where:{!$0.history.isEmpty}) { Text(L("成功同步后，会在这里留下记录。")).foregroundStyle(.secondary).frame(maxWidth:.infinity,minHeight:220).panel() }
        }
    }
}

struct AccountHistoryChart: View {
    let account: Account
    var body: some View {
        if account.kind == .agent {
            Chart {
                ForEach(Array(account.history.suffix(100).enumerated()), id: \.offset) { entry in
                    let date: Date = entry.element.observedAt
                    ForEach(entry.element.historicalChartQuotas) { q in
                        let title: String = q.title
                        let remaining: Double = q.remaining
                        LineMark(x: .value("时间", date), y: .value("剩余 %", remaining))
                            .foregroundStyle(by: .value("窗口", title))
                            .symbol(Circle())
                    }
                }
            }
            .chartYScale(domain: 0...100)
            .frame(height: 170)
        } else {
            // V2.2：LLM 账户历史不再空白——Token 与费用两条折线，量纲不同分两张图。
            let entries = Array(account.history.suffix(100))
            let costs = entries.compactMap { snap -> (Date, Double)? in
                guard let cost = snap.costs.first(where: { $0.currency == account.currency }) else { return nil }
                return (snap.observedAt, cost.value)
            }
            VStack(alignment: .leading, spacing: 12) {
                if entries.contains(where: { $0.totalTokens != nil }) {
                    Text(L("Token 用量")).font(.caption).foregroundStyle(.secondary)
                    Chart {
                        ForEach(Array(entries.enumerated()), id: \.offset) { entry in
                            if let total = entry.element.totalTokens {
                                LineMark(x: .value("时间", entry.element.observedAt), y: .value("Token", Double(total)))
                                    .foregroundStyle(Theme.accent)
                                    .symbol(Circle())
                            }
                        }
                    }
                    .frame(height: 130)
                }
                if !costs.isEmpty {
                    Text(L("统计期费用")).font(.caption).foregroundStyle(.secondary)
                    Chart {
                        ForEach(Array(costs.enumerated()), id: \.offset) { entry in
                            LineMark(x: .value("时间", entry.element.0), y: .value(account.currency, entry.element.1))
                                .foregroundStyle(Theme.teal)
                                .symbol(Circle())
                        }
                    }
                    .frame(height: 110)
                }
                if !entries.contains(where: { $0.totalTokens != nil }), costs.isEmpty {
                    Text(L("历史快照里没有可画图的 Token 或费用序列。")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - 工具栏项 chrome 隐藏（macOS 26 起工具栏项带 sharedBackground 玻璃胶囊，
// 自绘的侧栏切换按钮与固定宽 360 trailing 容器会被罩上多余色块；只去底色，不改几何与交互）
@ToolbarContentBuilder
private func toolbarItemNoChrome<Content: View>(
    _ placement: ToolbarItemPlacement,
    @ViewBuilder content: @escaping () -> Content
) -> some ToolbarContent {
    if #available(macOS 26.0, *) {
        ToolbarItem(placement: placement, content: content)
            .sharedBackgroundVisibility(.hidden)
    } else {
        ToolbarItem(placement: placement, content: content)
    }
}

/// 侧栏切换按钮图标：chrome 隐藏后补轻量 hover 底色，保证图标清晰、反馈合理。
private struct SidebarToggleIcon: View {
    @State private var hovering = false
    var body: some View {
        Image(systemName: "sidebar.left")
            .frame(width: 28, height: 28)
            .background(
                Color.primary.opacity(hovering ? 0.08 : 0),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}
