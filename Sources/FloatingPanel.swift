import AppKit
import SwiftUI

// 阶段 4A：屏幕边缘浮动条。移植 Pulse Panel/ 的窗口工程（参考实现 Pulse-main/Sources/Pulse/Panel，
// 思路见 pulse-分析报告窗口工程节；几何与设置在同模块 PanelGeometry.swift，可测纯函数已 Smoke 覆盖）：
// - borderless + nonactivatingPanel，canBecomeKey/Main=false，透明背景无阴影。
// - 窗口尺寸恒定：window 恒为 rail+展开卡最大包围盒，内容在 window 内移动，透明区点击穿透。
// - 位置存比例+显示器 UUID；didChangeScreenParametersNotification 重定位；刘海 safeAreaInsets。
// - 输入三件套：sendEvent 接管拖拽/右键；.activeAlways tracking area 报进入；0.15s 采样报离开。
// - 自动折叠细条 + 有需要留意账户时细条发红光 + hover 展开详情卡。

// MARK: - 显示器身份（CGDirectDisplayID 会重发，UUID 才是同一台物理显示器）

enum PanelScreen {
    static func identifier(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value)) else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }

    /// 名字指的那台显示器；没接着就是 nil（人们会拔显示器），调用方回落到存在的屏。
    static func screen(withIdentifier identifier: String?) -> NSScreen? {
        guard let identifier else { return nil }
        return NSScreen.screens.first { self.identifier(of: $0) == identifier }
    }

    /// 点在哪台屏上。用 frame 不用 visibleFrame：菜单栏与 Dock 也属于这台屏。
    static func containing(_ point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
}

// MARK: - 活跃显示器跟随：指针在哪台屏，面板就在哪台屏

@MainActor
final class ActiveDisplayFollower {
    /// 指针在另一台屏上停稳了。返回 false=现在搬不动（面板正被按住），下一拍再问。
    var onEnter: ((String) -> Bool)?

    /// 慢到不花钱，快到指针越过边框到达任何值得点的东西之前 rail 已经到位。
    private static let interval: TimeInterval = 0.25
    private var timer: Timer?
    private var lastIdentifier: String?
    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate(); timer = nil; lastIdentifier = nil
    }

    /// 显示器阵容变了：忘掉上次所在，下一拍重新报告。
    func forgetLastDisplay() { lastIdentifier = nil }

    private func sample() {
        guard NSScreen.screens.count > 1,
              let screen = PanelScreen.containing(NSEvent.mouseLocation),
              let identifier = PanelScreen.identifier(of: screen),
              identifier != lastIdentifier else { return }
        if onEnter?(identifier) == false { return }
        lastIdentifier = identifier
    }
}

// MARK: - 输入两件套（SwiftUI 手势在非 key 面板上不可靠）

/// 报告指针进入所附视图。.activeAlways：本 app 常年不是 active app，SwiftUI 的 .onHover 会静默。
/// 只报进入——exit 事件在面板自改布局时会乱发，离开由采样器判定。
struct PointerEntryReporter: NSViewRepresentable {
    let onEnter: () -> Void
    func makeNSView(context: Context) -> TrackingView { let v = TrackingView(); v.onEnter = onEnter; return v }
    func updateNSView(_ view: TrackingView, context: Context) { view.onEnter = onEnter }

    final class TrackingView: NSView {
        var onEnter: (() -> Void)?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            guard trackingAreas.isEmpty else { return }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        override func mouseEntered(with event: NSEvent) { onEnter?() }
    }
}

/// 0.15s 采样指针在面板内的位置（SwiftUI 方向，原点在左上），在面板外报 nil。
/// 进出事件会被动画与视图滑动骗出 open/close 死循环；采样永远不会失同步。
struct PanelPointerWatcher: NSViewRepresentable {
    let onChange: (CGPoint?) -> Void
    func makeNSView(context: Context) -> WatcherView { let v = WatcherView(); v.onChange = onChange; return v }
    func updateNSView(_ view: WatcherView, context: Context) { view.onChange = onChange }
    static func dismantleNSView(_ view: WatcherView, coordinator: ()) { view.stop() }

    final class WatcherView: NSView {
        var onChange: ((CGPoint?) -> Void)?
        override var isFlipped: Bool { true }
        private static let interval: TimeInterval = 0.15
        private var timer: Timer?
        private var lastReported: CGPoint??

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window == nil ? stop() : start()
        }
        func stop() { timer?.invalidate(); timer = nil; lastReported = nil }

        private func start() {
            guard timer == nil else { return }
            let timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        private func sample() {
            guard let window else { return }
            let local = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            let point = bounds.contains(local) ? local : nil
            if let lastReported, Self.isSame(lastReported, point) { return }
            lastReported = point
            onChange?(point)
        }
        private static func isSame(_ a: CGPoint?, _ b: CGPoint?) -> Bool {
            switch (a, b) {
            case (nil, nil): true
            case let (a?, b?): abs(a.x - b.x) < 1 && abs(a.y - b.y) < 1
            default: false
            }
        }
    }
}

// MARK: - PanelEdge 的 SwiftUI 方位

extension PanelEdge {
    /// rail 容器钉在面板哪个角（偏移沿面板另算）。
    var railAlignment: Alignment {
        switch self {
        case .left, .top: .topLeading
        case .right: .topTrailing
        }
    }
    /// 停靠时只圆朝内的角；浮动全圆。
    var dockedRadii: RectangleCornerRadii {
        let r: CGFloat = 18
        return switch self {
        case .left: RectangleCornerRadii(topLeading: 0, bottomLeading: 0, bottomTrailing: r, topTrailing: r)
        case .right: RectangleCornerRadii(topLeading: r, bottomLeading: r, bottomTrailing: 0, topTrailing: 0)
        case .top: RectangleCornerRadii(topLeading: 0, bottomLeading: r, bottomTrailing: r, topTrailing: 0)
        }
    }
}

// MARK: - SwiftUI 内容：rail / 细条 / 详情卡

struct PanelRootView: View {
    @EnvironmentObject var store: MonitorStore
    @EnvironmentObject var activity: AgentActivityMonitor
    let placement: PanelPlacement
    @State private var pointer: CGPoint? = nil
    @State private var hoverIndex: Int? = nil
    /// 3.31：单列/双列布局（UserDefaults panelDoubleColumn）；@AppStorage 让切换即时驱动 SwiftUI 重排。
    @AppStorage("panelDoubleColumn", store: TokenBundle.defaults) private var doubleColumn = false
    private var columns: Int { doubleColumn ? 2 : 1 }

    /// rail 满员（12+ 账户）时末位让给「+N」溢出徽标：超容量的账户不再静默消失，点击徽标开主窗口。
    /// 3.3：账户级「悬浮条显示」开关（showInRail）在此统一过滤，几何/命中/点击共用同一份清单。
    private var railVisible: [Account] { store.active.filter(\.showInRail) }
    private var overflowCount: Int { max(0, railVisible.count - RailGeometry.capacity) }
    /// 3.2：按最近一次额度/余额/积分变化倒序（刚消耗的排最前）；与 onClick 命中解析共用同一排序。
    private var accounts: [Account] {
        Array(MonitorStore.recentChangeOrder(railVisible).prefix(overflowCount > 0 ? RailGeometry.capacity - 1 : RailGeometry.capacity))
    }
    private var slotCount: Int { accounts.count + (overflowCount > 0 ? 1 : 0) }
    private var edge: PanelEdge { placement.edge }
    private var axis: PanelEdge.Axis { edge.axis }
    private var panelSize: CGSize { CardLayout.panelSize(for: axis) }
    private var railSize: CGSize { RailGeometry.size(for: slotCount, on: axis) }
    private var railRect: CGRect {
        RailGeometry.railRect(edge: edge, railSize: railSize, panel: panelSize, railTop: placement.railTop, railLeading: placement.railLeading)
    }
    private var stripRect: CGRect {
        RailGeometry.stripRect(edge: edge, railSize: railSize, panel: panelSize, railTop: placement.railTop, railLeading: placement.railLeading)
    }
    /// 展开=指针在 rail 或开着的卡上，或菜单开着、或正被拖动（不能从手底下收走）。
    private var expanded: Bool { placement.isMenuOpen || placement.isDragging || pointer != nil }
    private var attention: Bool { !store.alertAccounts.isEmpty }
    private var settings: PanelSettings { PanelSettings.read() }
    /// 展开动效锚点：rail 与详情卡都从贴屏一侧「长」出来，而不是原地闪现。
    private var revealAnchor: UnitPoint {
        switch edge {
        case .left: return .leading
        case .right: return .trailing
        case .top: return .top
        }
    }

    /// 细条的命中区（比视觉宽，20pt）：收缩态的窗口尺寸。
    private var stripHitRect: CGRect {
        RailGeometry.stripRect(edge: edge, railSize: railSize, panel: panelSize, railTop: placement.railTop, railLeading: placement.railLeading, hit: true)
    }

    var body: some View {
        Group {
            if placement.isShrunken {
                // 3.40 收缩态：窗口只剩细条命中区，画面=细条本体（6pt）焊在屏幕侧。
                // 任何进入窗口的指针都映射回全尺寸面板的细条命中区——进去即展开。
                Color.clear
                    .background(PanelPointerWatcher { point in shrunkPointerChanged(point) })
                    .overlay(alignment: .topLeading) {
                        sliver
                            .offset(x: stripRect.minX - stripHitRect.minX, y: stripRect.minY - stripHitRect.minY)
                    }
                    .frame(width: stripHitRect.width, height: stripHitRect.height)
            } else {
                fullBody
            }
        }
        .animation(.easeOut(duration: 0.18), value: expanded)
        .animation(.easeOut(duration: 0.15), value: hoverIndex)
        // 3.40：initial: true 很关键——启动即收起（无指针）时 expanded 没有「变化」，
        // 不带 initial 的 onChange 不发火，isRailExpanded 停在初始 true，收缩永不启动。
        .onChange(of: expanded, initial: true) { _, v in placement.isRailExpanded = v }
        .onChange(of: accounts.count) { _, _ in placement.railLengthChanged() }
    }

    private func shrunkPointerChanged(_ point: CGPoint?) {
        guard let point else { return }
        pointerChanged(CGPoint(x: stripHitRect.minX + point.x, y: stripHitRect.minY + point.y))
    }

    private var fullBody: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: panelSize.width, height: panelSize.height)
                .background(PanelPointerWatcher { point in pointerChanged(point) })
            if expanded {
                rail
                    .offset(x: railRect.minX, y: railRect.minY)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: revealAnchor)))
            } else {
                sliver
                    .offset(x: stripRect.minX, y: stripRect.minY)
                    .transition(.opacity)
                    .background(PointerEntryReporter { pointerChanged(CGPoint(x: stripRect.midX, y: stripRect.midY)) })
            }
            if expanded, let i = hoverIndex, i < accounts.count, !placement.isDragging {
                let cardHeight = CardLayout.estimatedHeight(for: accounts[i])
                let rect = CardLayout.cardRect(edge: edge, panel: panelSize, railSize: railSize, railTop: placement.railTop, railLeading: placement.railLeading, height: cardHeight)
                PanelDetailCard(account: accounts[i])
                    .frame(width: CardLayout.width, height: cardHeight, alignment: .topLeading)
                    .offset(x: rect.minX, y: rect.minY)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: revealAnchor)))
            }
        }
        .frame(width: panelSize.width, height: panelSize.height)
    }

    private func pointerChanged(_ point: CGPoint?) {
        if let point {
            if railRect.contains(point) {
                pointer = point
                hoverIndex = RailGeometry.slotIndex(at: point, edge: edge, count: slotCount, railSize: railSize, panel: panelSize, railTop: placement.railTop, railLeading: placement.railLeading)
                return
            }
            if let i = hoverIndex, i < accounts.count {
                let cardHeight = CardLayout.estimatedHeight(for: accounts[i])
                let rect = CardLayout.cardRect(edge: edge, panel: panelSize, railSize: railSize, railTop: placement.railTop, railLeading: placement.railLeading, height: cardHeight)
                // 展开态保持区 = rail ∪ 卡的包围盒：跨过中间 12pt 缝隙不再提前收起。
                if railRect.union(rect).contains(point) { pointer = point; return }
            }
        }
        pointer = nil
        hoverIndex = nil
    }

    // MARK: rail

    /// 3.31 修复：botDot 不得进 railItems——它占网格首格把环位整体挤偏一格，
    /// 与 slotIndex/ringCentreAlong 的几何（不含 botDot）错位，悬停/点击会开错账户；改为 rail overlay。
    @ViewBuilder private var railItems: some View {
        ForEach(accounts) { a in
            PanelRingView(account: a, threshold: store.library.warningThreshold,
                          working: activity.isWorking(AgentActivity.Subject(account: a)))
                .frame(width: axis == .horizontal ? RailGeometry.itemLength(on: axis) : nil,
                       height: axis == .vertical ? RailGeometry.itemLength(on: axis) : nil)
        }
        // 溢出徽标：放不下的账户数，点击开主窗口（点击路由在 FloatingPanel.onClick）。
        if overflowCount > 0 {
            Text("+\(railVisible.count - accounts.count)")
                .font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(PanelTheme.iris)
                .frame(width: RailGeometry.ringDiameter, height: RailGeometry.ringDiameter)
                .background(PanelTheme.iris.opacity(0.12), in: Circle())
                .overlay { Circle().strokeBorder(PanelTheme.iris.opacity(0.25), lineWidth: 0.5) }
                .frame(width: axis == .horizontal ? RailGeometry.itemLength(on: axis) : nil,
                       height: axis == .vertical ? RailGeometry.itemLength(on: axis) : nil)
                .help(L("打开主窗口查看全部账户"))
        }
    }

    @ViewBuilder private var rail: some View {
        Group {
            if columns == 2, axis == .vertical {
                // 双列：环按两列网格排（行优先，与 slotIndex 的 row*2+col 命中解析一致），托盘更宽更矮。
                LazyVGrid(columns: [GridItem(.flexible(), spacing: RailGeometry.columnSpacing),
                                    GridItem(.flexible(), spacing: 0)],
                          spacing: RailGeometry.itemSpacing) { railItems }
                    .padding(.vertical, RailGeometry.endPadding)
            } else if columns == 2 {
                LazyHGrid(rows: [GridItem(.fixed(RailGeometry.itemLength(on: axis)), spacing: RailGeometry.columnSpacing),
                                 GridItem(.fixed(RailGeometry.itemLength(on: axis)), spacing: 0)],
                          spacing: RailGeometry.itemSpacing) { railItems }
                    .padding(.horizontal, RailGeometry.endPadding)
            } else if axis == .vertical {
                VStack(spacing: RailGeometry.itemSpacing) { railItems }
                    .padding(.vertical, RailGeometry.endPadding)
            } else {
                HStack(spacing: RailGeometry.itemSpacing) { railItems }
                    .padding(.horizontal, RailGeometry.endPadding)
            }
        }
        .frame(width: railSize.width, height: railSize.height)
        .background { railBackground }
        // botDot 悬在端部留白（endPadding 区），不占位、不影响 slotIndex 几何；点击走 AppKit 面板级解析，不受 overlay 影响。
        .overlay(alignment: axis == .vertical ? .top : .leading) {
            if settings.botDot { botDot.padding(axis == .vertical ? .top : .leading, 6) }
        }
        // 3.2：排序变化时环位平滑过渡（值驱动，仅在顺序真的变化时动，不闪烁）。
        .animation(.easeInOut(duration: 0.25), value: accounts.map(\.id))
        // 3.31：单列/双列切换即时生效，环位网格重排带动画。
        .animation(.easeInOut(duration: 0.25), value: doubleColumn)
    }

    /// rail 的「玻璃托盘」：超薄材质透出桌面，顶侧一道柔光，0.5pt 描边托起轮廓，远距离软投影。
    @ViewBuilder private var railBackground: some View {
        if placement.isDocked {
            railBackgroundChrome(UnevenRoundedRectangle(cornerRadii: edge.dockedRadii, style: .continuous))
        } else {
            railBackgroundChrome(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func railBackgroundChrome<S: Shape>(_ shape: S) -> some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay {
                shape.fill(LinearGradient(colors: [.white.opacity(0.13), .white.opacity(0.02)],
                                          startPoint: .top, endPoint: .bottom))
            }
            .overlay { shape.stroke(Color.primary.opacity(0.10), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
    }

    /// 简化版机器人标记（不移植 Pulse BotMark 引擎）：随状态变色/脉冲的圆点。
    @ViewBuilder private var botDot: some View {
        let working = !activity.running.isEmpty
        let color = working ? Theme.teal : attention ? Color.orange : Color.secondary.opacity(0.5)
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay { Circle().strokeBorder(.white.opacity(0.45), lineWidth: 0.75) }
            .shadow(color: color.opacity(working || attention ? 0.55 : 0.2), radius: working ? 4 : 2)
            .phaseAnimator([false, true]) { dot, phase in
                dot.opacity(working && phase ? 0.35 : 1)
            } animation: { _ in .easeInOut(duration: 0.9) }
            // 3.34：36×36 外框默认居中会把点推到 y=24 与第一个环上弧重叠（单列竖排实测）；
            // 改为沿 rail 方向贴外框端部，点（10pt）整个落在端部留白（endPadding 24）内。
            .frame(width: RailGeometry.ringDiameter, height: RailGeometry.ringDiameter,
                   alignment: axis == .vertical ? .top : .leading)
            .help(L(working ? "CLI 工作中" : "空闲"))
    }

    // MARK: 细条

    /// 收起态「宝石条」：6pt 胶囊，蓝紫渐变 + 内侧高光描边 + 双层柔影，像一枚嵌在屏幕边的物件。
    /// 有账户需留意时换琥珀 → 珊瑚渐变并发暖光（语义与原红光一致，只是不再刺眼）。
    @ViewBuilder private var sliver: some View {
        let colors = attention ? PanelTheme.sliverAttention : PanelTheme.sliverIdle
        let (start, end): (UnitPoint, UnitPoint) = axis == .vertical ? (.top, .bottom) : (.leading, .trailing)
        Capsule(style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: start, endPoint: end))
            .overlay { Capsule(style: .continuous).strokeBorder(.white.opacity(0.4), lineWidth: 0.5) }
            .shadow(color: colors[1].opacity(attention ? 0.6 : 0.4), radius: attention ? 5 : 3, y: 1)
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .frame(width: stripRect.width, height: stripRect.height)
    }
}

/// rail 上的一个环：最满窗口的剩余量；无读数画空轨道而非 0%；时间弧中性细弧在外侧；颜色只表达用量。
/// dsh（DeepSeek Harness）没有额度窗：同款进度环，填充度=min(余额/100,1)（≥¥100 满环），
/// 环下数字换成余额；鲸鱼图标任何状态都保留原彩色，陈旧只用灰环/灰字表达。
struct PanelRingView: View {
    let account: Account
    let threshold: Double
    let working: Bool

    private var fullest: Quota? { account.displayQuotas.max(by: { $0.usedPercent < $1.usedPercent }) }

    @ViewBuilder var body: some View {
        if account.provider == .dsh {
            dshBadge
        } else if account.provider == .workbuddy {
            workbuddyBadge
        } else if account.provider == .custom {
            customBadge
        } else {
            ring
        }
    }

    /// 自定义 API 余额环（3.3）：与其他环完全同规格；弧 = min(余额/满环基准, 1)；
    /// 中央首字符圆形徽章（稳定哈希色），环下数字带单位缩写（截断不四舍五入）。
    /// 常态账户哈希色、<基准 10% 琥珀、归零珊瑚，陈旧灰。
    private var customBadge: some View {
        let balance = account.snapshot?.balances.first?.value
        let baseline = account.customConfig?.baseline ?? 100
        let unit = account.customConfig?.unit ?? "¥"
        let stale = account.stale() && account.snapshot != nil
        let color: Color = stale || balance == nil ? .secondary
            : balance! <= 0 ? PanelTheme.warnDeep
            : balance! < baseline * 0.1 ? PanelTheme.warn
            : PanelTheme.customColor(account.id)
        return VStack(spacing: RailGeometry.ringToText) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.10), lineWidth: 4)
                if let balance {
                    let fraction = max(0, min(1, balance / baseline))
                    Circle().trim(from: 0, to: fraction)
                        .stroke(AngularGradient(colors: [color.opacity(0.55), color], center: .center,
                                                startAngle: .degrees(0), endAngle: .degrees(min(359.9, 360 * fraction))),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: color.opacity(0.30), radius: 1.5)
                }
                CustomAccountMark(name: account.name, accountID: account.id, size: 18)
            }
            .frame(width: RailGeometry.ringDiameter, height: RailGeometry.ringDiameter)
            .help(L("自定义 API 余额 · 满环基准 \(CustomBridge.unitText(unit, baseline))"))
            Text(balance.map { CustomBridge.compactText(unit, $0) } ?? "—")
                .font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(color)
                .opacity(stale ? 0.5 : 1)
        }
    }

    /// WorkBuddy 积分环：与其他环完全同规格（轨道 + 渐变弧 + 光晕 + 中央品牌标 18pt 原色 + 环下数字）。
    /// 弧 = min(积分/1000, 1)（1000 积分满环）；数字截断不四舍五入，永远不多报积分。
    /// 常态 WorkBuddy 品牌青绿、<100 琥珀、<10 珊瑚，陈旧灰——颜色只落在环与文字，图标永保原色。
    private var workbuddyBadge: some View {
        let credits = account.snapshot?.balances.first?.value
        let stale = account.stale() && account.snapshot != nil
        let color: Color = stale || credits == nil ? .secondary
            : credits! < 10 ? PanelTheme.warnDeep
            : credits! < 100 ? PanelTheme.warn
            : PanelTheme.workbuddy
        return VStack(spacing: RailGeometry.ringToText) {
            ZStack {
                // 轨道永远画；读数只是轨道上的弧。
                Circle().stroke(Color.primary.opacity(0.10), lineWidth: 4)
                if let credits {
                    let fraction = max(0, min(1, credits / 1000))
                    Circle().trim(from: 0, to: fraction)
                        .stroke(AngularGradient(colors: [color.opacity(0.55), color], center: .center,
                                                startAngle: .degrees(0), endAngle: .degrees(min(359.9, 360 * fraction))),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: color.opacity(0.30), radius: 1.5)
                }
                ProviderMark(provider: .workbuddy, size: 18)
            }
            .frame(width: RailGeometry.ringDiameter, height: RailGeometry.ringDiameter)
            .help(L("WorkBuddy 积分余额 · 1000 积分满环"))
            Text(credits.map { WorkBuddyBridge.compactCredits($0) } ?? "—")
                .font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(color)
                .opacity(stale ? 0.5 : 1)
        }
    }

    /// 余额进度环：与其他环完全同规格（轨道 + 渐变弧 + 光晕 + 中央品牌标 18pt + 环下数字）。
    /// 弧 = min(余额/100, 1)；数字截断不四舍五入，永远不多报钱。
    /// 常态 DeepSeek 品牌蓝、<¥5 琥珀、<¥1 珊瑚红，陈旧灰——颜色只落在环与文字，鲸鱼永保原色。
    private var dshBadge: some View {
        let balance = account.snapshot?.balances.first?.value
        let stale = account.stale() && account.snapshot != nil
        let color: Color = stale || balance == nil ? .secondary
            : balance! < 1 ? PanelTheme.warnDeep
            : balance! < 5 ? PanelTheme.warn
            : PanelTheme.deepseek
        return VStack(spacing: RailGeometry.ringToText) {
            ZStack {
                // 轨道永远画；读数只是轨道上的弧。
                Circle().stroke(Color.primary.opacity(0.10), lineWidth: 4)
                if let balance {
                    let fraction = max(0, min(1, balance / 100))
                    Circle().trim(from: 0, to: fraction)
                        .stroke(AngularGradient(colors: [color.opacity(0.55), color], center: .center,
                                                startAngle: .degrees(0), endAngle: .degrees(min(359.9, 360 * fraction))),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: color.opacity(0.30), radius: 1.5)
                }
                ProviderMark(provider: .dsh, size: 18)
            }
            .frame(width: RailGeometry.ringDiameter, height: RailGeometry.ringDiameter)
            .help(L("DeepSeek 钱包余额"))
            Text(balance.map { "¥" + DshBridge.compactBalance($0) } ?? "—")
                .font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(color)
                .opacity(stale ? 0.5 : 1)
        }
    }

    private var ring: some View {
        VStack(spacing: RailGeometry.ringToText) {
            ZStack {
                if let q = fullest, let reset = q.resetsAt, let ws = q.windowSeconds, ws > 0 {
                    let elapsed = min(max(Date().timeIntervalSince(reset.addingTimeInterval(-ws)) / ws, 0), 1)
                    Circle().trim(from: 0, to: elapsed)
                        .stroke(Color.secondary.opacity(0.35), lineWidth: 1.25)
                        .rotationEffect(.degrees(-90))
                        .frame(width: RailGeometry.ringDiameter + 6, height: RailGeometry.ringDiameter + 6)
                }
                // 轨道永远画；读数只是轨道上的弧。
                Circle().stroke(Color.primary.opacity(0.10), lineWidth: 4)
                if let q = fullest {
                    let fraction = max(0, min(1, q.remaining / 100))
                    let color = ringColor(q)
                    // 沿弧渐亮的渐变弧 + 一点点同色光晕；颜色语义不变（健康 teal / 低量橙 / 陈旧灰）。
                    Circle().trim(from: 0, to: fraction)
                        .stroke(AngularGradient(colors: [color.opacity(0.55), color], center: .center,
                                                startAngle: .degrees(0), endAngle: .degrees(min(359.9, 360 * fraction))),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: color.opacity(0.30), radius: 1.5)
                }
                ProviderMark(provider: account.provider, size: 18)
                if working {
                    Circle().fill(Theme.teal).frame(width: 6, height: 6)
                        .shadow(color: Theme.teal.opacity(0.7), radius: 2)
                        .offset(y: -(RailGeometry.ringDiameter / 2))
                        .phaseAnimator([0.0, 360.0]) { dot, angle in
                            dot.rotationEffect(.degrees(angle))
                        } animation: { _ in .linear(duration: 1.2) }
                }
            }
            .frame(width: RailGeometry.ringDiameter, height: RailGeometry.ringDiameter)
            Text(fullest.map { "\(Int($0.remaining))%" } ?? "—")
                .font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(fullest.map { ringColor($0) } ?? .secondary)
                .opacity(account.stale() && account.snapshot != nil ? 0.5 : 1)
        }
    }

    private func ringColor(_ q: Quota) -> Color {
        if account.stale(), account.snapshot != nil { return .secondary }
        return q.remaining <= threshold ? .orange : Theme.teal
    }
}

/// hover 展开的详情卡：全窗口分解 + reset 倒计时。
/// 排版：标题区（品牌标+账户名）→ 各窗口额度（标题 / 大数字 / 渐变胶囊条 / 重置倒计时）→ 操作区。
/// 高度预算与 CardLayout.estimatedHeight 逐项对齐（padding 13、行距 9、额度块 ≤37/条），不溢出命中框。
struct PanelDetailCard: View {
    @EnvironmentObject var store: MonitorStore
    @EnvironmentObject var activity: AgentActivityMonitor
    let account: Account

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    if account.provider == .custom { CustomAccountMark(name: account.name, accountID: account.id, size: 22) } else { ProviderMark(provider: account.provider, size: 22) }
                    Text(account.name).font(.callout.weight(.semibold)).lineLimit(1)
                    if activity.isWorking(AgentActivity.Subject(account: account)) {
                        Circle().fill(Theme.teal).frame(width: 7, height: 7)
                            .shadow(color: Theme.teal.opacity(0.7), radius: 2)
                    }
                    Spacer()
                }
                if let s = account.snapshot, !account.errorIsCredential {
                    if account.provider == .dsh {
                        // dsh 钱包语义：大号余额 + 赠金/累计消费行，无额度窗、无重置倒计时。
                        if let b = s.balances.first {
                            HStack {
                                Text(L("钱包余额")).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(DshBridge.balanceText(b))
                                    .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                                    .foregroundStyle(b.value < 1 ? PanelTheme.warnDeep : b.value < 5 ? PanelTheme.warn : PanelTheme.iris)
                            }
                        }
                        ForEach(DshBridge.noteParts(s.note), id: \.self) { Text(L($0)).font(.caption).foregroundStyle(.secondary) }
                    } else if account.provider == .workbuddy {
                        // workbuddy 积分语义：大号剩余积分 + 口径说明行，无额度窗、无重置倒计时。
                        if let c = s.balances.first {
                            HStack {
                                Text(L("积分余额")).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(WorkBuddyBridge.creditsText(c.value))
                                    .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                                    .foregroundStyle(c.value < 10 ? PanelTheme.warnDeep : c.value < 100 ? PanelTheme.warn : PanelTheme.workbuddy)
                            }
                        }
                        ForEach(DshBridge.noteParts(s.note), id: \.self) { Text(L($0)).font(.caption).foregroundStyle(.secondary) }
                    } else if account.provider == .custom {
                        // custom 余额语义（3.3）：大号余额（单位自定）+ 附加字段行，无额度窗、无重置倒计时。
                        let baseline = account.customConfig?.baseline ?? 100
                        let unit = account.customConfig?.unit ?? "¥"
                        if let b = s.balances.first {
                            HStack {
                                Text(L("账户余额")).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(CustomBridge.unitText(unit, b.value))
                                    .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                                    .foregroundStyle(b.value <= 0 ? PanelTheme.warnDeep : b.value < baseline * 0.1 ? PanelTheme.warn : PanelTheme.customColor(account.id))
                            }
                        }
                        ForEach(DshBridge.noteParts(s.note), id: \.self) { Text(L($0)).font(.caption).foregroundStyle(.secondary) }
                    } else {
                        if account.displayQuotas.isEmpty && !s.quotas.isEmpty {
                            Text(L("上一计费周期已结束，等待平台新读数。")).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(account.displayQuotas) { q in quotaRow(q) }
                        ForEach(s.creditBalances ?? []) { credit in Text(credit.title + " " + credit.text).font(.caption).foregroundStyle(.secondary) }
                        ForEach(s.balances, id: \.currency) { Text(L("余额 \($0.text)")).font(.caption).foregroundStyle(.secondary) }
                        ForEach(s.costs, id: \.currency) { Text(L("统计期费用 \($0.text)")).font(.caption).foregroundStyle(.secondary) }
                    }
                    if account.stale() {
                        Text(L("数据截至 \(displayDate(s.observedAt))")).font(.system(size: 9)).foregroundStyle(.orange)
                    }
                } else if account.errorIsCredential {
                    Label(L("凭证已失效，重新连接前不展示旧读数。"), systemImage: "key.slash").font(.caption).foregroundStyle(.orange)
                } else {
                    Text(L("尚未获取用量")).font(.caption).foregroundStyle(.secondary)
                }
                if let status = account.statusNote { Text(L(status)).font(.system(size: 9)).foregroundStyle(.secondary) }
                if let error = account.error { Text(L(error)).font(.system(size: 9)).foregroundStyle(.orange).lineLimit(2) }
                HStack {
                    Button { Task { await store.refresh(account.id, userInitiated: true) } } label: {
                        Label(L(store.refreshing.contains(account.id) ? "同步中…" : "立即同步"), systemImage: "arrow.clockwise")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .foregroundStyle(PanelTheme.iris)
                            .background(PanelTheme.iris.opacity(0.12), in: Capsule())
                            .overlay { Capsule().strokeBorder(PanelTheme.iris.opacity(0.22), lineWidth: 0.5) }
                    }
                    .buttonStyle(.plain)
                    .disabled(store.refreshing.contains(account.id) || !account.enabled)
                    .opacity(store.refreshing.contains(account.id) || !account.enabled ? 0.5 : 1)
                    if account.provider == .dsh {
                        Button { if let url = URL(string: DshBridge.topUpURL) { NSWorkspace.shared.open(url) } } label: {
                            Label(L("去充值"), systemImage: "plus.circle")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10).padding(.vertical, 3)
                                .foregroundStyle(PanelTheme.iris)
                                .background(PanelTheme.iris.opacity(0.12), in: Capsule())
                                .overlay { Capsule().strokeBorder(PanelTheme.iris.opacity(0.22), lineWidth: 0.5) }
                        }
                        .buttonStyle(.plain)
                    }
                    if account.provider == .workbuddy {
                        Button { if let url = URL(string: WorkBuddyBridge.viewURL) { NSWorkspace.shared.open(url) } } label: {
                            Label(L("去查看"), systemImage: "safari")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10).padding(.vertical, 3)
                                .foregroundStyle(PanelTheme.iris)
                                .background(PanelTheme.iris.opacity(0.12), in: Capsule())
                                .overlay { Capsule().strokeBorder(PanelTheme.iris.opacity(0.22), lineWidth: 0.5) }
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            }
            .padding(13)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0.02)],
                                                 startPoint: .top, endPoint: .bottom))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
            }
        }
    }

    /// 一条额度：标题与大数字同排，渐变胶囊条表达剩余量，9pt 重置倒计时垫底。
    /// 历史数据不着阈值色：过期读数染成色是假装它仍然新鲜。
    private func quotaRow(_ q: Quota) -> some View {
        let fresh = !account.stale()
        let color: Color = fresh ? (q.remaining <= store.library.warningThreshold ? .orange : Theme.teal) : .secondary
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(L(q.title)).font(.caption.weight(.medium)).lineLimit(1)
                Spacer()
                Text("\(Int(q.remaining))%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: [color.opacity(0.7), color], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, geo.size.width * max(0, min(1, q.remaining / 100))))
                }
            }
            .frame(height: 5)
            HStack {
                if let reset = q.resetsAt {
                    Text(L("重置：\(displayDate(reset)) · \(Countdown.text(to: reset))"))
                } else { Text(L("平台未提供重置时间")) }
                Spacer()
            }.font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - 面板本体（NSPanel 子类，自己拥有拖拽）

/// 拖拽放在 sendEvent：它见到 window server 发给本窗的一切事件，先于 SwiftUI 命中测试。
/// 拖的是 rail 不是 window——window 比 rail 宽，跨过屏幕中线时 rail 在 window 内的侧别会翻。
private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 能抓住什么（面板坐标，原点左上）：rail 展开时是 rail，收起时是细条。
    var grabArea: (() -> CGRect)?
    /// rail 当前的 rect——收起时抓的是细条，但放置的仍是 rail（存的位置是 rail 的）。
    var railFrame: (() -> CGRect)?
    /// 目标边上的 rail 尺寸：拖到另一条轴时 rail 边走边转向。
    var railSize: ((PanelEdge) -> CGSize)?
    var onClick: ((CGPoint) -> Void)?
    var contextMenu: (() -> NSMenu)?
    /// 3.40：收缩态窗口只有细条大——按下/右键前由控制器恢复全尺寸 frame，再按全局指针重测坐标。
    var onBeforeInteraction: (() -> Void)?
    var placement: PanelPlacement?

    /// 顶部停靠的 rail 顶边位置：屏幕物理顶减去刘海；不用 visibleFrame.maxY（那是菜单栏下缘）。
    static func topEdge(of screen: NSScreen) -> CGFloat {
        let notch = screen.safeAreaInsets.top
        guard notch > 0 else { return screen.frame.maxY }
        return min(screen.frame.maxY - notch, screen.visibleFrame.maxY)
    }

    /// 仅吸顶时高于菜单栏（.statusBar），其余 .floating 在菜单栏之下。
    func applyLevel(for dock: PanelDock) {
        level = dock.edge == .top ? .statusBar : .floating
    }

    private var grab: CGSize?
    private var pressedAt: CGPoint?
    private var didDrag = false

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        // control-click 就是右键：先查菜单，别当拖拽起点。
        case .rightMouseDown where showMenu(event): return
        case .leftMouseDown where event.modifierFlags.contains(.control) && showMenu(event): return
        case .leftMouseDown where begin(event): return
        case .leftMouseDragged where carry(): return
        case .leftMouseUp where finish(): return
        default: super.sendEvent(event)
        }
    }

    private func showMenu(_ event: NSEvent) -> Bool {
        onBeforeInteraction?()
        guard let area = grabArea?(), let menu = contextMenu?(), let view = contentView, area.contains(localFromGlobal(NSEvent.mouseLocation)) else { return false }
        // popUp 自己跑跟踪循环：菜单开着期间 rail 不许收细。
        placement?.isMenuOpen = true
        menu.popUp(positioning: nil, at: view.convert(convertPoint(fromScreen: NSEvent.mouseLocation), from: nil), in: view)
        placement?.isMenuOpen = false
        return true
    }

    private func begin(_ event: NSEvent) -> Bool {
        onBeforeInteraction?()
        let location = localFromGlobal(NSEvent.mouseLocation)
        guard let area = grabArea?(), let rail = railFrame?(), area.contains(location) else { return false }
        // 抓住点相对 rail 左下原点的偏移（屏幕坐标自下而上）。
        let origin = CGPoint(x: frame.minX + rail.minX, y: frame.maxY - rail.maxY)
        let pointer = NSEvent.mouseLocation
        grab = CGSize(width: pointer.x - origin.x, height: pointer.y - origin.y)
        pressedAt = location
        didDrag = false
        placement?.isPressed = true
        return true
    }

    private func carry() -> Bool {
        guard let grab, let placement, let railFrame = railFrame?() else { return false }
        let pointer = NSEvent.mouseLocation
        // 用指针所在的屏，不用 window 所在的屏——否则永远跨不过第二台显示器。
        guard let screen = PanelScreen.containing(pointer) ?? self.screen ?? NSScreen.main else { return false }
        let visible = screen.visibleFrame
        let rail = railFrame.size
        if !didDrag { didDrag = true; placement.isDragging = true }

        let wanted = CGPoint(
            x: min(max(pointer.x - grab.width, visible.minX), visible.maxX - rail.width),
            y: min(max(pointer.y - grab.height, visible.minY), visible.maxY - rail.height))

        // 停靠在拖动途中判定（松手才吸附会把面板从指针下抽走）。
        // 顶部测试看指针不看 rail：立起来的 rail 多半屏高，一抬手顶边就到顶了——
        // 把指针摔向屏幕顶才是那个刻意手势（和够菜单栏同一个手势）。
        let dock: PanelDock = if visible.maxY - pointer.y <= PanelPlacement.dockDistance {
            .edge(.top)
        } else if wanted.x - visible.minX <= PanelPlacement.dockDistance {
            .edge(.left)
        } else if visible.maxX - (wanted.x + rail.width) <= PanelPlacement.dockDistance {
            .edge(.right)
        } else {
            .floating
        }

        // rail 过轴时边走边转向：从这一刻起按即将成为的朝向量。
        let landing: PanelEdge = if let docked = dock.edge {
            docked
        } else if placement.edge.axis == .horizontal {
            pointer.x < visible.midX ? .left : .right
        } else {
            placement.edge
        }
        let landingRail = railSize?(landing) ?? rail
        let landingPanel = FloatingPanelController.Layout.size(for: landing)
        let turned = landing.axis != placement.edge.axis

        let origin: CGPoint
        if turned {
            // 转向：grab 偏移不能转着带过去，重测在指针正下。
            origin = CGPoint(x: pointer.x - landingRail.width / 2, y: pointer.y - landingRail.height / 2)
            self.grab = CGSize(width: landingRail.width / 2, height: landingRail.height / 2)
        } else {
            origin = wanted
        }

        let ratios = PanelPlacement.ratios(forRailAt: origin, in: visible, rail: landingRail)
        // 拖动途中只改内存：每帧写 UserDefaults 是纯浪费，松手时 finish() 落盘一次。
        placement.record(dock: dock, horizontalRatio: ratios.h, verticalRatio: ratios.v, display: PanelScreen.identifier(of: screen), persist: false)

        let layout = placement.layout(in: visible, topEdge: Self.topEdge(of: screen), panel: landingPanel, rail: landingRail)
        applyLevel(for: dock)
        setFrame(layout.frame, display: true)
        // frame 是请求不是结果：按实际拿到的 frame 量 rail 偏移。
        let offsets = PanelPlacement.offsets(forRailTopLeft: layout.railOrigin, in: frame, rail: landingRail)
        placement.setRailOffset(top: offsets.top, leading: offsets.leading)
        return true
    }

    private func finish() -> Bool {
        guard grab != nil else { return false }
        let click = didDrag ? nil : pressedAt
        let dragged = didDrag
        grab = nil; pressedAt = nil; didDrag = false
        placement?.isDragging = false
        placement?.isPressed = false
        if dragged { placement?.persist() }
        if let click { onClick?(click) }
        return true
    }

    /// 事件位置换算到面板坐标（原点左上，与 SwiftUI 一致）。
    private func local(_ event: NSEvent) -> CGPoint {
        CGPoint(x: event.locationInWindow.x, y: frame.height - event.locationInWindow.y)
    }

    /// 全局指针换算到面板坐标：onBeforeInteraction 可能刚改过 frame（收缩→恢复），
    /// 事件自带的位置已过期，全局坐标永远新鲜。
    private func localFromGlobal(_ global: CGPoint) -> CGPoint {
        CGPoint(x: global.x - frame.minX, y: frame.maxY - global.y)
    }
}

// MARK: - 控制器

@MainActor
final class FloatingPanelController {
    /// 面板尺寸推导自 SwiftUI 层的布局常量，AppKit frame 与 SwiftUI 内容永不漂移。
    /// **面板恒为这个尺寸——卡开合不改它。**改 window 宽度会移动 SwiftUI 坐标空间，
    /// rail 在其中横跳一张卡的宽度；恒尺寸的面板不可能甩飞动画，透明区点击穿透免费。
    enum Layout {
        static func size(for edge: PanelEdge) -> CGSize { CardLayout.panelSize(for: edge.axis) }
    }

    private let panel: FloatingPanel
    private let store: MonitorStore
    private let placement: PanelPlacement
    private let displayFollower = ActiveDisplayFollower()
    nonisolated(unsafe) private var screenObserver: (any NSObjectProtocol)?
    /// 3.32：透明区穿透轮询。面板恒尺寸（420×898），透明区若不穿透会吞掉下方窗口的点击。
    /// ignoresMouseEvents 是全窗开关做不到区域级，故按全局指针位置轮询开关；轮询读 NSEvent.mouseLocation
    /// 不依赖窗口事件，ignores=true 时也能把指针迎回来，无死锁。
    nonisolated(unsafe) private var hitTimer: Timer?

    init(store: MonitorStore, activity: AgentActivityMonitor, placement: PanelPlacement) {
        self.store = store
        self.placement = placement

        // 细条必须够得着且不离开 rail 的命中区——几何事实，在尺寸最终确定的这里断言。
        assert(RailGeometry.stripIsContainedInRail(), "collapsed sliver escapes the rail's hit area")

        let initialSize = Layout.size(for: placement.edge)
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: initialSize.width, height: initialSize.height),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configurePanel()

        let root = PanelRootView(placement: placement).environmentObject(store).environmentObject(activity)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: initialSize.width, height: initialSize.height)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        placement.onChange = { [weak self] in self?.placePanel() }

        // 透明区穿透轮询（见 hitTimer 注释）。0.12s 足够跟手：指针进细条到展开本来就要停一拍。
        let hitTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHitPassthrough() }
        }
        RunLoop.main.add(hitTimer, forMode: .common)
        self.hitTimer = hitTimer

        // 显示器来来去去：任何变化都可能把面板留在不存在的空间里，变了就重排（拖动中除外）。
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.placement.isDragging else { return }
                self.displayFollower.forgetLastDisplay()
                self.placePanel()
            }
        }

        displayFollower.onEnter = { [placement] identifier in placement.move(toDisplay: identifier) }

        panel.placement = placement
        panel.railFrame = { [store, placement] in
            RailGeometry.railRect(edge: placement.edge,
                                  railSize: RailGeometry.size(for: Self.shownCount(store), on: placement.edge.axis),
                                  panel: Layout.size(for: placement.edge),
                                  railTop: placement.railTop, railLeading: placement.railLeading)
        }
        panel.railSize = { [store] edge in RailGeometry.size(for: Self.shownCount(store), on: edge.axis) }
        panel.grabArea = { [store, placement, weak panel] in
            let size = RailGeometry.size(for: Self.shownCount(store), on: placement.edge.axis)
            let panelSize = Layout.size(for: placement.edge)
            // 3.40：收缩态窗口就是细条命中区本身，整个窗口可抓。
            if placement.isShrunken, let panel { return CGRect(origin: .zero, size: panel.frame.size) }
            return placement.isRailExpanded
                ? RailGeometry.railRect(edge: placement.edge, railSize: size, panel: panelSize, railTop: placement.railTop, railLeading: placement.railLeading)
                : RailGeometry.stripRect(edge: placement.edge, railSize: size, panel: panelSize, railTop: placement.railTop, railLeading: placement.railLeading, hit: true)
        }
        // 3.40：收缩态下的按下/右键先把窗口恢复全尺寸再测量（事件坐标按全局指针重算）。
        panel.onBeforeInteraction = { [weak self] in self?.restoreFullFrame() }
        panel.onClick = { [store, placement] point in
            guard placement.isRailExpanded else { return }
            let visible = store.active.filter(\.showInRail)
            let overflow = visible.count > RailGeometry.capacity
            let accounts = Array(MonitorStore.recentChangeOrder(visible).prefix(overflow ? RailGeometry.capacity - 1 : RailGeometry.capacity))
            let slots = accounts.count + (overflow ? 1 : 0)
            guard let index = RailGeometry.slotIndex(at: point, edge: placement.edge, count: slots,
                                                     railSize: RailGeometry.size(for: slots, on: placement.edge.axis),
                                                     panel: Layout.size(for: placement.edge),
                                                     railTop: placement.railTop, railLeading: placement.railLeading) else { return }
            // 末位溢出徽标：打开主窗口看全部账户。
            if index >= accounts.count {
                NotificationCenter.default.post(name: .gaoOpenMainWindow, object: nil)
                return
            }
            let id = accounts[index].id
            Task { await store.refresh(id, userInitiated: true) }
        }
    }

    deinit { if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }; hitTimer?.invalidate() }

    /// 指针离开面板矩形才穿透给下方窗口；面板矩形内恒可点。
    /// 3.32 教训：区域级穿透（strip/railRect 细判定）在 statusBar 层窗口（顶部停靠）上会把
    /// ignoresMouseEvents 卡死在 true——hover/右键/菜单全部落空，事件直透主窗口。保守版没有状态面：
    /// 窗外穿透（面板不再全天候遮挡下方窗口），窗内维持一贯行为。
    /// 3.40：收起时直接把窗口缩到细条命中区（本函数兼管收缩/恢复）——
    /// 透明挡鼠区在物理上不存在，比任何穿透判定都可靠。
    private func updateHitPassthrough() {
        // 收缩判定镜像 SwiftUI 的 expanded（isMenuOpen/isDragging/指针）并叠加按住态：
        // 拖动/按住/菜单期间绝不动窗口尺寸。
        let shrink = !placement.isRailExpanded && !placement.isDragging && !placement.isPressed && !placement.isMenuOpen
        if shrink != placement.isShrunken {
            placement.isShrunken = shrink
            if shrink { panel.setFrame(stripScreenRect(), display: true) } else { placePanel() }
        }
        let outside = !panel.frame.contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = outside && !placement.isDragging && !placement.isPressed && !placement.isMenuOpen
    }

    /// 细条命中区（hit:true，20pt 宽）的屏幕坐标——收缩态的窗口 frame。
    private func stripScreenRect() -> CGRect {
        let edge = placement.edge
        let railSize = RailGeometry.size(for: Self.shownCount(store), on: edge.axis)
        let hit = RailGeometry.stripRect(edge: edge, railSize: railSize, panel: Layout.size(for: edge),
                                         railTop: placement.railTop, railLeading: placement.railLeading, hit: true)
        let frame = panel.frame
        // 面板坐标原点左上（SwiftUI），屏幕原点左下：y 轴翻转。
        return CGRect(x: frame.minX + hit.minX, y: frame.maxY - hit.maxY, width: hit.width, height: hit.height)
    }

    /// 交互（按下/右键）来临前恢复全尺寸 frame：事件测量、抓握偏移、菜单定位都按全尺寸几何来。
    func restoreFullFrame() {
        guard placement.isShrunken else { return }
        placement.isShrunken = false
        placePanel()
    }

    var isVisible: Bool { panel.isVisible }

    /// rail 右键菜单：由外面（Manager）供给——它知道打开主窗口、退出这些与控制器无关的动作。
    var contextMenu: (() -> NSMenu)? {
        get { panel.contextMenu }
        set { panel.contextMenu = newValue }
    }

    private static func shownCount(_ store: MonitorStore) -> Int {
        min(store.active.filter(\.showInRail).count, RailGeometry.capacity)
    }

    func show() {
        // 摆一次、显示、再摆一次：没 order 进屏幕的 window 还没被 constrainFrameRect 钳过，
        // 第二次按钳完的真实 frame 量 rail 偏移才算数。
        placePanel()
        panel.orderFrontRegardless()
        placePanel()
        applyDisplayFollowing()
    }

    func hide() {
        panel.orderOut(nil)
        applyDisplayFollowing()
    }

    /// 设置刚改过：开关、全屏行为、跟随显示器。
    func settingsChanged() {
        applyCollectionBehavior()
        if PanelSettings.read().enabled {
            if !panel.isVisible { show() }
            placePanel()
        } else {
            panel.orderOut(nil)
        }
        applyDisplayFollowing()
    }

    private func configurePanel() {
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.applyLevel(for: placement.dock)
        applyCollectionBehavior()
    }

    /// canJoinAllSpaces 常驻普通桌面 Space；全屏 Space 是否跟随是设置项
    /// （.fullScreenAuxiliary=跟，.fullScreenNone=不跟，无需任何权限与轮询）。
    private func applyCollectionBehavior() {
        panel.collectionBehavior = [.canJoinAllSpaces, PanelSettings.read().hideInFullScreen ? .fullScreenNone : .fullScreenAuxiliary, .stationary]
    }

    private func applyDisplayFollowing() {
        guard PanelSettings.read().enabled, PanelSettings.read().followsActiveDisplay, panel.isVisible else {
            displayFollower.stop(); return
        }
        displayFollower.forgetLastDisplay()
        displayFollower.start()
    }

    /// 把面板摆到记录的位置。存的显示器不在了回落到存在的屏，不留进看不见的空间。
    private func placePanel() {
        guard let screen = PanelScreen.screen(withIdentifier: placement.display) ?? panel.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let edge = placement.edge
        let railSize = RailGeometry.size(for: Self.shownCount(store), on: edge.axis)
        let layout = placement.layout(in: screen.visibleFrame, topEdge: FloatingPanel.topEdge(of: screen), panel: Layout.size(for: edge), rail: railSize)
        panel.applyLevel(for: placement.dock)
        panel.setFrame(layout.frame, display: true)
        // 按实际拿到的 frame 量 rail 偏移（面板可能比可用区高，AppKit 会压）。
        let offsets = PanelPlacement.offsets(forRailTopLeft: layout.railOrigin, in: panel.frame, rail: railSize)
        placement.setRailOffset(top: offsets.top, leading: offsets.leading)
        // 3.40：重排发生在收缩态时（换屏/设置变更），立刻缩回细条，不留全尺寸闪现。
        if placement.isShrunken { panel.setFrame(stripScreenRect(), display: true) }
    }
}

// MARK: - 单例管理器：生命周期、右键菜单、设置联动

@MainActor
final class FloatingPanelManager: NSObject {
    static let shared = FloatingPanelManager()

    private var controller: FloatingPanelController?
    private(set) var placement: PanelPlacement?
    private weak var store: MonitorStore?
    private weak var activity: AgentActivityMonitor?

    /// 应用启动时挂一次。SwiftUI App 的 init 里拿不到 @StateObject，由 FloatingPanelSetup 在首个 onAppear 调。
    func attach(store: MonitorStore, activity: AgentActivityMonitor) {
        guard controller == nil else { return }
        self.store = store
        self.activity = activity
        let placement = PanelPlacement.restored()
        let controller = FloatingPanelController(store: store, activity: activity, placement: placement)
        controller.contextMenu = { [weak self] in self?.buildMenu() ?? NSMenu() }
        self.controller = controller
        self.placement = placement
        activity.setPanelVisible(PanelSettings.read().enabled)
        if PanelSettings.read().enabled { controller.show() }
    }

    /// 设置面板里任何浮动条开关变更后调用。
    func settingsChanged() {
        controller?.settingsChanged()
        activity?.setPanelVisible(PanelSettings.read().enabled)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: L("打开主窗口"), action: #selector(openMainWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("全部同步"), action: #selector(refreshAll), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("设置…"), action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("检查更新…"), action: #selector(checkUpdates), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let dockMenu = NSMenu()
        for (title, dock) in [(L("左"), PanelDock.edge(.left)), (L("右"), PanelDock.edge(.right)), (L("顶部"), PanelDock.edge(.top)), (L("浮动"), PanelDock.floating)] as [(String, PanelDock)] {
            let item = NSMenuItem(title: title, action: #selector(setDock(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dock
            item.state = placement?.dock == dock ? .on : .off
            dockMenu.addItem(item)
        }
        let dockItem = NSMenuItem(title: L("停靠位置"), action: nil, keyEquivalent: "")
        dockItem.submenu = dockMenu
        menu.addItem(dockItem)
        // 3.31：单列/双列布局快捷切换（与设置中心同一开关，打勾=双列）。
        let colItem = NSMenuItem(title: L("双列布局"), action: #selector(toggleColumns), keyEquivalent: "")
        colItem.target = self
        colItem.state = PanelSettings.read().doubleColumn ? .on : .off
        menu.addItem(colItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: L("隐藏浮动条"), action: #selector(hidePanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("退出搞词元"), action: #selector(quit), keyEquivalent: "").target = self
        return menu
    }

    @objc private func openMainWindow() {
        NotificationCenter.default.post(name: .gaoOpenMainWindow, object: nil)
    }
    @objc private func openSettings() {
        // 设置已收拢到 app 级设置中心：打开主窗口并请主 app 打开设置（无监听时仅打开主窗口）。
        NotificationCenter.default.post(name: .gaoOpenMainWindow, object: nil)
        NotificationCenter.default.post(name: Notification.Name("GaoSeries.app.openSettings"), object: nil)
    }
    @objc private func checkUpdates() {
        Task { await UpdateChecker.shared.checkNow(userInitiated: true) }
    }
    @objc private func refreshAll() {
        guard let store else { return }
        Task { await store.refreshAll(userInitiated: true) }
    }
    @objc private func setDock(_ sender: NSMenuItem) {
        guard let dock = sender.representedObject as? PanelDock else { return }
        placement?.update(dock: dock)
    }
    @objc private func hidePanel() {
        TokenBundle.defaults.set(false, forKey: "panelEnabled")
        settingsChanged()
    }
    @objc private func toggleColumns() {
        TokenBundle.defaults.set(!PanelSettings.read().doubleColumn, forKey: "panelDoubleColumn")
        settingsChanged()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// App 场景里挂浮动条：@StateObject 在 App.init 里拿不到，首个 onAppear 才真正 attach。
struct FloatingPanelSetup: ViewModifier {
    let store: MonitorStore
    let activity: AgentActivityMonitor
    func body(content: Content) -> some View {
        content.onAppear { FloatingPanelManager.shared.attach(store: store, activity: activity) }
    }
}
