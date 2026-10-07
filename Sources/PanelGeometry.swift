import Foundation
import CoreGraphics
import Observation

// 阶段 4A：浮动条几何与设置（纯函数层，不进 UI 文件，Smoke 直测）。
// 移植 Pulse Panel/PanelPlacement.swift 的窗口工程（见 pulse-分析报告窗口工程节）：
// - 存 rail 的位置不存 window 的（window 比 rail 宽，跨过屏幕中线时 rail 在 window 内的侧别会翻，
//   存 window 位置会让 rail 在用户手里横跳一张卡的宽度）。
// - 坐标存比例（0...1）不存点：显示器/菜单栏/Dock 变了也能落回 sensible 的地方。
// - 显示器用 UUID 标识（CGDirectDisplayID 每次接入重发，UUID 才是同一台物理显示器）。

/// rail 的背贴着哪条边——也是详情卡展开的反方向。docked 时是贴住的屏幕边；
/// 浮动时是 rail 所在半屏，卡永远朝更宽敞的一侧展开。
enum PanelEdge: String, Sendable {
    case left, right, top

    enum Axis: Sendable { case vertical, horizontal }

    var axis: Axis { self == .top ? .horizontal : .vertical }
    var isVertical: Bool { axis == .vertical }
    var isLeft: Bool { self == .left }
}

/// 面板是贴在屏幕边上还是自由浮动。
enum PanelDock: Equatable, Hashable, Sendable {
    case edge(PanelEdge)
    case floating

    var edge: PanelEdge? { if case .edge(let e) = self { return e }; return nil }
    var isDocked: Bool { edge != nil }
}

/// 面板停放位置与跨启动的记忆。
@Observable
final class PanelPlacement {
    private(set) var dock: PanelDock
    /// 0=rail 贴可用区左缘，1=右缘。仅浮动时有意义。
    private(set) var horizontalRatio: Double
    /// 0=rail 顶在可用区顶，1=底在底。
    private(set) var verticalRatio: Double

    /// rail 顶边在面板内的位置（从面板顶向下量，SwiftUI 方向）。
    /// 面板被钳进可见区时，rail 在面板内走完剩下的路程——没有这个 rail 会在
    /// 距屏幕两端几百 pt 处停死。
    private(set) var railTop: CGFloat = 0
    /// 同理，沿面板另一轴。只有顶部停靠的 rail 会用到。
    private(set) var railLeading: CGFloat = 0

    /// rail 留在哪台显示器上（PanelScreen 的 UUID 命名）。nil=主屏/首台。
    private(set) var display: String?

    /// 正在被拖动（第一帧移动才置位）。
    var isDragging = false
    /// 面板正被按住（mouse-down 到首次移动之间也算）：此间 grab 偏移已测量，任何 re-place 都是跳跃。
    var isPressed = false
    /// 面板自己的右键菜单开着：指针在菜单上=在面板外，没有它菜单一弹出 rail 就收细。
    var isMenuOpen = false
    /// rail 当前是全绘还是收成细条（内容由指针位置决定，window 抓握区要镜像它）。
    var isRailExpanded = true
    /// 3.40：收起时窗口收缩到细条命中区（不再有 420×898 透明挡鼠区），SwiftUI 据此只画细条本体。
    /// 由 FloatingPanelController 的穿透轮询维护（isRailExpanded/isDragging/isPressed/isMenuOpen 的函数）。
    var isShrunken = false

    init(dock: PanelDock = .edge(.right), horizontalRatio: Double = 1, verticalRatio: Double = 0.5, display: String? = nil) {
        self.dock = dock
        self.horizontalRatio = Self.clamp(horizontalRatio)
        self.verticalRatio = Self.clamp(verticalRatio)
        self.display = display
    }

    /// 卡往哪边开：停靠=贴住的边；浮动=所在半屏。
    var edge: PanelEdge { dock.edge ?? (horizontalRatio < 0.5 ? .left : .right) }
    var isDocked: Bool { dock.isDocked }

    // MARK: - 持久化（UserDefaults，比例+显示器 UUID）

    static func restored() -> PanelPlacement {
        let d = TokenBundle.defaults
        let dock: PanelDock = d.object(forKey: "panel.floating") as? Bool == true
            ? .floating
            : .edge(d.string(forKey: "panel.edge").flatMap(PanelEdge.init(rawValue:)) ?? .right)
        return PanelPlacement(
            dock: dock,
            horizontalRatio: d.object(forKey: "panel.horizontalRatio") as? Double ?? 1,
            verticalRatio: d.object(forKey: "panel.verticalRatio") as? Double ?? 0.5,
            display: d.string(forKey: "panel.display"))
    }

    /// 非拖动途径改了位置（设置里选边），请 window 移过去。
    var onChange: (() -> Void)?

    /// rail 长短变了（账户增删），不动手时要重排——按住时禁止（grab 偏移已测量）。
    func railLengthChanged() {
        guard !isDragging, !isPressed else { return }
        onChange?()
    }

    /// 把面板搬到另一台显示器，比例原样带过去（它们是一台显示器可用区的分数）。
    func move(toDisplay identifier: String) -> Bool {
        guard !isDragging, !isPressed else { return false }
        guard display != identifier else { return true }
        record(dock: dock, horizontalRatio: horizontalRatio, verticalRatio: verticalRatio, display: identifier)
        onChange?()
        return true
    }

    /// 改位置并请求移动（设置面板用）。
    func update(dock: PanelDock, horizontalRatio: Double? = nil, verticalRatio: Double? = nil) {
        record(dock: dock,
               horizontalRatio: horizontalRatio ?? self.horizontalRatio,
               verticalRatio: verticalRatio ?? self.verticalRatio,
               display: display)
        onChange?()
    }

    /// 记录面板已经在的位置（拖动自己移 window，只存不搬）。
    /// 拖动途中每帧都会到：persist=false 只改内存，松手时 persist() 落盘一次（每帧写 UserDefaults 是浪费）。
    func record(dock: PanelDock, horizontalRatio: Double, verticalRatio: Double, display: String?, persist: Bool = true) {
        self.dock = dock
        self.horizontalRatio = Self.clamp(horizontalRatio)
        self.verticalRatio = Self.clamp(verticalRatio)
        self.display = display
        if persist { writeToDefaults() }
    }

    /// 把记忆中的位置写进 UserDefaults（拖动结束调用一次）。
    func persist() { writeToDefaults() }

    private func writeToDefaults() {
        let d = TokenBundle.defaults
        d.set(!dock.isDocked, forKey: "panel.floating")
        if let edge = dock.edge { d.set(edge.rawValue, forKey: "panel.edge") }
        d.set(horizontalRatio, forKey: "panel.horizontalRatio")
        d.set(verticalRatio, forKey: "panel.verticalRatio")
        d.set(display, forKey: "panel.display")
    }

    func setRailOffset(top: CGFloat, leading: CGFloat) {
        if abs(railTop - top) > 0.5 { railTop = top }
        if abs(railLeading - leading) > 0.5 { railLeading = leading }
    }

    // MARK: - 几何

    /// AppKit 侧摆窗所需的一切：window 的 frame + rail 左上角（屏幕坐标）。
    /// rail 在 window 内的偏移必须在 setFrame 之后、按实际拿到的 frame 量——
    /// frame 是请求不是结果（面板可能比笔记本可用区还高，AppKit 会压它）。
    struct Layout: Equatable {
        let frame: CGRect
        let railOrigin: CGPoint
    }

    /// rail 左上角（屏幕坐标）→ rail 在该 frame 内的偏移；钳制不超出 window。
    static func offsets(forRailTopLeft origin: CGPoint, in frame: CGRect, rail: CGSize) -> (top: CGFloat, leading: CGFloat) {
        (top: min(max(frame.maxY - origin.y, 0), max(frame.height - rail.height, 0)),
         leading: min(max(origin.x - frame.minX, 0), max(frame.width - rail.width, 0)))
    }

    /// topEdge：顶部停靠的 rail 顶边该在的位置——面板画在菜单栏之上时到屏幕物理顶，
    /// 有刘海则止于刘海线（那条线谁也画不进去）。
    func layout(in visible: CGRect, topEdge: CGFloat, panel: CGSize, rail: CGSize) -> Layout {
        // 顶部停靠：自由坐标是横向，面板从 rail 向下垂（卡只能朝那个方向展开）。
        if case .edge(.top) = dock {
            let railX = min(
                max(visible.minX + CGFloat(horizontalRatio) * max(visible.width - rail.width, 0), visible.minX),
                max(visible.maxX - rail.width, visible.minX))
            let windowX = min(
                max(railX + rail.width / 2 - panel.width / 2, visible.minX),
                max(visible.maxX - panel.width, visible.minX))
            let windowY = max(topEdge - panel.height, visible.minY)
            return Layout(frame: CGRect(x: windowX, y: windowY, width: panel.width, height: panel.height),
                          railOrigin: CGPoint(x: railX, y: topEdge))
        }

        let railX: CGFloat = switch dock {
        case .edge(.left): visible.minX
        case .edge(.right): visible.maxX - rail.width
        case .edge(.top): visible.minX // 上面已处理，到不了这里
        case .floating:
            // 浮动=不贴边：存的还是停靠位时切到浮动，rail 不该再贴着屏幕边装浮动。
            min(max(visible.minX + CGFloat(horizontalRatio) * max(visible.width - rail.width, 0),
                    visible.minX + Self.dockDistance),
                max(visible.maxX - rail.width - Self.dockDistance, visible.minX + Self.dockDistance))
        }
        // 屏幕坐标自下而上：比例 0（rail 在顶）是最大的 y。
        let railY = visible.minY + CGFloat(1 - verticalRatio) * max(visible.height - rail.height, 0)
        let windowX = edge.isLeft ? railX : railX + rail.width - panel.width
        let windowY = min(max(railY + rail.height / 2 - panel.height / 2, visible.minY),
                          max(visible.maxY - panel.height, visible.minY))
        return Layout(frame: CGRect(x: windowX, y: windowY, width: panel.width, height: panel.height),
                      railOrigin: CGPoint(x: railX, y: railY + rail.height))
    }

    /// 把 rail 左下原点（屏幕坐标）换算回两个比例。
    static func ratios(forRailAt origin: CGPoint, in visible: CGRect, rail: CGSize) -> (h: Double, v: Double) {
        let across = max(visible.width - rail.width, 0)
        let down = max(visible.height - rail.height, 0)
        return (across > 0 ? Double((origin.x - visible.minX) / across) : 0.5,
                down > 0 ? 1 - Double((origin.y - visible.minY) / down) : 0.5)
    }

    /// rail 离屏幕边多近算吸附：好刻意贴上，也好刻意停在边上不贴。
    static let dockDistance: CGFloat = 32

    private static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
}

// MARK: - rail 与细条的几何（与 SwiftUI 绘制共享同一组数，命中测试才不会和画面漂移）

enum RailGeometry {
    /// 3.31：单列/双列布局开关（panelDoubleColumn）。厚度随列数参数化：侧向 padding 14 + 每列 36 + 列距 8。
    /// 面板恒宽模型不变——窗口尺寸一律按 maxThickness（双列上限）留位，切换布局不动 window。
    static var columns: Int { TokenBundle.defaults.bool(forKey: "panelDoubleColumn") ? 2 : 1 }
    static let crossPadding: CGFloat = 14
    static let columnSpacing: CGFloat = 8
    static var thickness: CGFloat { crossPadding * 2 + ringDiameter * CGFloat(columns) + columnSpacing * CGFloat(columns - 1) }
    static let maxThickness: CGFloat = crossPadding * 2 + ringDiameter * 2 + columnSpacing
    static let ringDiameter: CGFloat = 36
    static let ringToText: CGFloat = 6
    static let percentHeight: CGFloat = 16
    static let itemSpacing: CGFloat = 14
    static let endPadding: CGFloat = 24
    /// 面板按这个容量留位：窗口尺寸恒定模型的前提（多于 12 个账户时面板整体放大，重排不在动画中）。
    static let capacity = 12

    /// 一个账户位沿 rail 的长度：侧栏=环+百分比文字；顶栏只有环（文字是菜单栏下第二行字）。
    static func itemLength(on axis: PanelEdge.Axis) -> CGFloat {
        axis == .vertical ? ringDiameter + ringToText + percentHeight : ringDiameter
    }
    static func length(for count: Int, on axis: PanelEdge.Axis, columns cols: Int? = nil) -> CGFloat {
        let c = cols ?? columns
        let rows = max(1, Int(ceil(Double(max(count, 1)) / Double(c))))
        let n = CGFloat(rows)
        return endPadding * 2 + itemLength(on: axis) * n + itemSpacing * (n - 1)
    }
    static func size(for count: Int, on axis: PanelEdge.Axis, columns cols: Int? = nil) -> CGSize {
        let along = length(for: count, on: axis, columns: cols)
        let c = CGFloat(cols ?? columns)
        let thick = crossPadding * 2 + ringDiameter * c + columnSpacing * (c - 1)
        return axis == .vertical ? CGSize(width: thick, height: along) : CGSize(width: along, height: thick)
    }
    /// 第 i 个环中心沿 rail 的位置（从 rail 的 top/leading 端起）；双列时按行推进。
    static func ringCentreAlong(_ i: Int, on axis: PanelEdge.Axis) -> CGFloat {
        endPadding + itemLength(on: axis) / 2 + CGFloat(i / columns) * (itemLength(on: axis) + itemSpacing)
    }

    // MARK: 命中区域（面板自身坐标，原点在左上，与 SwiftUI 一致）

    /// rail 在面板里的位置：贴边停靠焊在屏幕侧；顶部停靠焊在顶；浮动时 rail 在面板内的侧别由 edge 决定。
    static func railRect(edge: PanelEdge, railSize: CGSize, panel: CGSize, railTop: CGFloat, railLeading: CGFloat) -> CGRect {
        switch edge {
        case .left: return CGRect(x: 0, y: railTop, width: railSize.width, height: railSize.height)
        case .right: return CGRect(x: panel.width - railSize.width, y: railTop, width: railSize.width, height: railSize.height)
        case .top: return CGRect(x: railLeading, y: 0, width: railSize.width, height: railSize.height)
        }
    }

    /// 收起的细条：6×96，焊在屏幕侧、沿 rail 居中。
    static let collapsedWidth: CGFloat = 6
    static let collapsedLength: CGFloat = 96
    /// 细条的跟踪区比画得宽——从内侧靠近不用精确到达。
    static let collapsedHitWidth: CGFloat = 20

    static func stripRect(edge: PanelEdge, railSize: CGSize, panel: CGSize, railTop: CGFloat, railLeading: CGFloat, hit: Bool = false) -> CGRect {
        let rail = railRect(edge: edge, railSize: railSize, panel: panel, railTop: railTop, railLeading: railLeading)
        let w = hit ? collapsedHitWidth : collapsedWidth
        // 细条不长过 rail 本身（单账户的顶栏比 96 还短），否则它逃出 rail 的命中区。
        switch edge.axis {
        case .vertical:
            let x = edge == .left ? rail.minX : rail.maxX - w
            let len = min(collapsedLength, rail.height)
            return CGRect(x: x, y: rail.midY - len / 2, width: w, height: len)
        case .horizontal:
            let len = min(collapsedLength, rail.width)
            return CGRect(x: rail.midX - len / 2, y: rail.minY, width: len, height: w)
        }
    }

    /// 细条必须够得着且不离开 rail 的命中区，否则藏与显互相追逐。几何事实，可断言。
    /// 3.32：单/双列两种厚度都验（双列 rail 更宽，细条仍焊在屏幕侧一端）。
    static func stripIsContainedInRail() -> Bool {
        for edge in [PanelEdge.left, .right, .top] {
            for cols in [1, 2] {
                for count in [1, 5, capacity] {
                    let size = size(for: count, on: edge.axis, columns: cols)
                    let panel = CGSize(width: max(size.width, 400), height: max(size.height, 500))
                    let rail = railRect(edge: edge, railSize: size, panel: panel, railTop: 40, railLeading: 40)
                    let strip = stripRect(edge: edge, railSize: size, panel: panel, railTop: 40, railLeading: 40)
                    let hitStrip = stripRect(edge: edge, railSize: size, panel: panel, railTop: 40, railLeading: 40, hit: true)
                    guard rail.contains(strip), hitStrip.contains(strip) else { return false }
                }
            }
        }
        return true
    }

    /// 面板内一点命中第几个账户位；不在任何环位上为 nil（空白仍归拖动）。3.31：双列时按行×列解析。
    static func slotIndex(at point: CGPoint, edge: PanelEdge, count: Int, railSize: CGSize, panel: CGSize, railTop: CGFloat, railLeading: CGFloat) -> Int? {
        let rail = railRect(edge: edge, railSize: railSize, panel: panel, railTop: railTop, railLeading: railLeading)
        guard rail.contains(point), count > 0 else { return nil }
        let axis = edge.axis
        let along = (axis == .vertical ? point.y - rail.minY : point.x - rail.minX) - endPadding
        guard along >= 0 else { return nil }
        let step = itemLength(on: axis) + itemSpacing
        let row = Int(along / step)
        guard along.truncatingRemainder(dividingBy: step) <= itemLength(on: axis) else { return nil }
        let cols = columns
        var col = 0
        if cols > 1 {
            // 3.32 修复：LazyVGrid/LazyHGrid 双列铺满 rail 横截向（两端没有 crossPadding 留白，
            // flexible 列宽=(厚度-列距)/2，环心约在 1/4 与 3/4 处），旧几何按 crossPadding+环径切列带，
            // 列界与画面差了十几 pt——悬停/点击开错列。列界改为 rail 中线，与画面一致。
            let cross = axis == .vertical ? point.x - rail.minX : point.y - rail.minY
            let width = axis == .vertical ? railSize.width : railSize.height
            col = min(cols - 1, max(0, Int(cross * CGFloat(cols) / max(width, 1))))
        }
        let index = row * cols + col
        guard index < count else { return nil }
        return index
    }
}

// MARK: - 详情卡布局常量（与 AppKit 面板尺寸同源）

enum CardLayout {
    static let width: CGFloat = 300
    static let maximumHeight: CGFloat = 460
    static let gap: CGFloat = 12

    /// 面板尺寸恒定模型：window 恒为 rail+展开卡最大包围盒，卡开合不动 window
    /// （动 window 会移动 SwiftUI 坐标空间，rail 在动画里横跳——Pulse FloatingPanelController 的教训）。
    /// 3.31：宽度按双列上限 maxThickness 留位，单列/双列切换同样不动 window。
    static func panelSize(for axis: PanelEdge.Axis, capacity: Int = RailGeometry.capacity) -> CGSize {
        let railMax = RailGeometry.length(for: capacity, on: axis, columns: 1)
        switch axis {
        case .vertical:
            return CGSize(width: RailGeometry.maxThickness + gap + width,
                          height: max(railMax, maximumHeight))
        case .horizontal:
            return CGSize(width: max(railMax, width),
                          height: RailGeometry.maxThickness + gap + maximumHeight)
        }
    }

    /// 详情卡在面板内的位置（面板坐标，原点在左上）。
    static func cardRect(edge: PanelEdge, panel: CGSize, railSize: CGSize, railTop: CGFloat, railLeading: CGFloat, height: CGFloat) -> CGRect {
        let rail = RailGeometry.railRect(edge: edge, railSize: railSize, panel: panel, railTop: railTop, railLeading: railLeading)
        let h = min(height, maximumHeight)
        switch edge {
        case .left:
            return CGRect(x: rail.maxX + gap, y: clampedCentre(rail.midY, height: h, limit: panel.height), width: width, height: h)
        case .right:
            return CGRect(x: rail.minX - gap - width, y: clampedCentre(rail.midY, height: h, limit: panel.height), width: width, height: h)
        case .top:
            return CGRect(x: clampedCentre(rail.midX, height: width, limit: panel.width), y: rail.maxY + gap, width: width, height: h)
        }
    }

    private static func clampedCentre(_ centre: CGFloat, height: CGFloat, limit: CGFloat) -> CGFloat {
        min(max(centre - height / 2, 0), max(limit - height, 0))
    }

    /// 卡高按内容估算：命中区与绘制用同一个数，两者才不会漂移。
    /// 居此文件（而非 FloatingPanel.swift）方能进 Smoke 编译清单被直测；余额按行计、错误行按可折两行计。
    static func estimatedHeight(for account: Account) -> CGFloat {
        // dsh（DeepSeek Harness）钱包语义：大号余额行 + 赠金/累计消费行 + 同步/去充值按钮行，无额度块。
        if account.provider == .dsh {
            var h: CGFloat = 56 // 头部
            if let s = account.snapshot, !account.errorIsCredential {
                if !s.balances.isEmpty { h += 34 } // 大号余额行
                // 赠金/累计消费行：note 按「·」拆行，与 PanelDetailCard 的渲染一一对应
                // （这里内联拆分而不调 DshBridge.noteParts：保持本文件只依赖 Models，Smoke 清单不用改）。
                let noteRows = (s.note ?? "").split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.count
                h += CGFloat(noteRows) * 23
            } else {
                h += 46 // 凭证失效提示 / 「尚未获取用量」占位（与 max(quotas,1)*46 同预算）
            }
            if account.stale(), account.snapshot != nil { h += 16 }
            if account.error != nil { h += 28 }
            if account.statusNote != nil { h += 14 }
            h += 30 // 同步 + 去充值按钮行 + padding
            return min(h, maximumHeight)
        }
        // workbuddy 积分语义：大号积分行 + 口径说明行 + 同步/去查看按钮行，无额度块。
        if account.provider == .workbuddy {
            var h: CGFloat = 56 // 头部
            if let s = account.snapshot, !account.errorIsCredential {
                if !s.balances.isEmpty { h += 34 } // 大号积分行
                // 口径说明行：note 按「·」拆行，与 PanelDetailCard 的渲染一一对应
                // （这里内联拆分而不调 DshBridge.noteParts：保持本文件只依赖 Models，Smoke 清单不用改）。
                let noteRows = (s.note ?? "").split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.count
                h += CGFloat(noteRows) * 23
            } else {
                h += 46 // 凭证失效提示 / 「尚未获取用量」占位（与 max(quotas,1)*46 同预算）
            }
            if account.stale(), account.snapshot != nil { h += 16 }
            if account.error != nil { h += 28 }
            if account.statusNote != nil { h += 14 }
            h += 30 // 同步 + 去查看按钮行 + padding
            return min(h, maximumHeight)
        }
        // custom（3.3）自定义 API 余额：大号余额行 + 附加字段行 + 同步按钮行，无额度块。
        if account.provider == .custom {
            var h: CGFloat = 56 // 头部
            if let s = account.snapshot, !account.errorIsCredential {
                if !s.balances.isEmpty { h += 34 } // 大号余额行
                let noteRows = (s.note ?? "").split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.count
                h += CGFloat(noteRows) * 23
            } else {
                h += 46 // 凭证失效提示 / 「尚未获取用量」占位
            }
            if account.stale(), account.snapshot != nil { h += 16 }
            if account.error != nil { h += 28 }
            if account.statusNote != nil { h += 14 }
            h += 30 // 同步按钮行 + padding
            return min(h, maximumHeight)
        }
        var h: CGFloat = 56 // 头部
        let quotas = account.displayQuotas.count
        h += CGFloat(max(quotas, 1)) * 46
        if let s = account.snapshot, !s.balances.isEmpty { h += CGFloat(s.balances.count) * 23 }
        if account.stale(), account.snapshot != nil { h += 16 }
        if account.error != nil { h += 28 }
        if account.statusNote != nil { h += 14 }
        h += 30 // 同步按钮 + padding
        return min(h, maximumHeight)
    }
}

// MARK: - reset 倒计时文案（粗粒度：天+小时 / 小时+分钟 / 分钟）

enum Countdown {
    static func text(to reset: Date, now: Date = Date()) -> String {
        let s = max(0, reset.timeIntervalSince(now))
        if s >= 86_400 { return "\(Int(s / 86_400)) 天 \(Int(s) / 3600 % 24) 小时" }
        if s >= 3_600 { return "\(Int(s / 3_600)) 小时 \(Int(s) / 60 % 60) 分钟" }
        if s >= 60 { return "\(Int(s / 60)) 分钟" }
        return "不到 1 分钟"
    }
}

// MARK: - 浮动条设置（UserDefaults；布尔默认 true 的项用 object-for-key 区分未设置）

struct PanelSettings {
    var enabled = true
    var botDot = true
    var hideInFullScreen = false
    var followsActiveDisplay = false
    /// 3.31：悬浮条双列布局（默认单列）。
    var doubleColumn = false

    static func read() -> PanelSettings {
        let d = TokenBundle.defaults
        return PanelSettings(
            enabled: d.object(forKey: "panelEnabled") as? Bool ?? true,
            botDot: d.object(forKey: "panelBotDot") as? Bool ?? true,
            hideInFullScreen: d.object(forKey: "panelHideFullScreen") as? Bool ?? false,
            followsActiveDisplay: d.object(forKey: "panelFollowDisplay") as? Bool ?? false,
            doubleColumn: d.bool(forKey: "panelDoubleColumn"))
    }
}
