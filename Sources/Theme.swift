import SwiftUI
import AppKit

enum Theme {
    static let accent = Color(red:0.20,green:0.46,blue:0.73)
    static let teal = Color(red:0.13,green:0.57,blue:0.47)
    static let canvas = Color(nsColor:.windowBackgroundColor)
    static let panel = Color(nsColor:.controlBackgroundColor)
}
extension Provider {
    var color: Color {
        switch self {
        case .openai: return Theme.teal
        case .claude: return Color(red:0.75,green:0.41,blue:0.29)
        case .deepseek,.qwen,.glm,.dsh: return Theme.accent
        case .gemini,.kimi: return .indigo
        case .grok: return .primary
        case .doubao: return .pink
        case .minimax: return .orange
        case .hy: return Color(red:0.18,green:0.45,blue:0.88)
        case .mimo: return .mint
        case .cursor: return Color(red:0.45,green:0.35,blue:0.85)
        case .copilot: return Color(red:0.35,green:0.35,blue:0.42)
        case .devin: return Color(red:0.55,green:0.45,blue:0.20)
        case .ollama: return Color(red:0.40,green:0.55,blue:0.65)
        case .commandcode: return Color(red:0.50,green:0.30,blue:0.55)
        case .workbuddy: return Color(red:0.05,green:0.72,blue:0.60)
        case .custom: return Color(red:0.45,green:0.50,blue:0.58)
        default: return Theme.accent
        }
    }
}
/// 品牌图标缓存：Token.framework 资源 bundle 里 Resources/ProviderIcons/<provider.rawValue>.png，
/// 由 scripts/build_framework.sh 的 ditto 整目录拷贝带入。加载失败（缺图）返回 nil，ProviderMark 回退自绘样式。
enum ProviderIconCache {
    private static var cache: [Provider: NSImage?] = [:]
    static func image(for provider: Provider) -> NSImage? {
        if let hit = cache[provider] { return hit }
        let image = TokenBundle.bundle.url(forResource: provider.rawValue, withExtension: "png", subdirectory: "ProviderIcons")
            .flatMap { NSImage(contentsOf: $0) }
        cache[provider] = image
        return image
    }
}
struct ProviderMark: View {
    let provider: Provider
    var size: CGFloat = 40
    var body: some View {
        if let image = ProviderIconCache.image(for: provider) {
            // 品牌图标：彩色位图（不设 isTemplate），轻微圆角裁剪，比例沿用旧样式（40pt 时圆角 11）。
            Image(nsImage: image).resizable()
                .frame(width:size,height:size)
                .clipShape(RoundedRectangle(cornerRadius:size * 0.275, style:.continuous))
        } else {
            Text(provider.mark).font(.system(size:size * 0.5,weight:.bold,design:.rounded)).foregroundStyle(provider.color).frame(width:size,height:size).background(provider.color.opacity(0.09),in:RoundedRectangle(cornerRadius:11))
        }
    }
}
extension View {
    func panel() -> some View { self.padding(20).background(Theme.panel,in:RoundedRectangle(cornerRadius:14)).overlay(RoundedRectangle(cornerRadius:14).stroke(Color.primary.opacity(0.07))) }
}
struct Tag: View {
    var text: String
    var color: Color = .secondary
    var body: some View { Text(L(text)).font(.system(size:10,weight:.medium)).padding(.horizontal,8).padding(.vertical,4).foregroundStyle(color).background(color.opacity(0.08),in:Capsule()) }
}
struct StatCard: View {
    let title: String
    let value: String
    let subtitle: String
    let symbol: String
    var color: Color = Theme.accent
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text(L(title)).font(.callout).foregroundStyle(.secondary); Spacer(); Image(systemName:symbol).foregroundStyle(color) }
            Text(L(value)).font(.system(size:28,weight:.semibold,design:.rounded)).monospacedDigit()
            Text(L(subtitle)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }.frame(maxWidth:.infinity,alignment:.leading).panel()
    }
}
// MARK: - 悬浮面板配色（纯追加：既有定义一概不动，其他页面不受影响）
/// 「搞词元」桌面悬浮条专用色板。主色 iris（蓝紫，柔）：收起条渐变、同步按钮、溢出徽标；
/// 额度语义色沿用模块既有约定（健康 teal / 低量橙 / 陈旧灰），与主界面 QuotaRow 一致。
enum PanelTheme {
    /// 深浅色各取一支的动态色（悬浮条常年漂在壁纸上，两种外观都要成立）。
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }))
    }

    /// 面板强调色：同步按钮、溢出徽标、收起条渐变主端。
    static let iris = dynamic(
        light: NSColor(srgbRed: 0.34, green: 0.42, blue: 0.90, alpha: 1),
        dark: NSColor(srgbRed: 0.55, green: 0.62, blue: 1.00, alpha: 1))
    /// 收起条渐变高光端。
    static let irisSoft = dynamic(
        light: NSColor(srgbRed: 0.58, green: 0.65, blue: 0.99, alpha: 1),
        dark: NSColor(srgbRed: 0.70, green: 0.76, blue: 1.00, alpha: 1))
    /// 收起条常态渐变（高光 → 主色）。
    static let sliverIdle: [Color] = [irisSoft, iris]

    /// 留意态渐变：琥珀 → 珊瑚，替代原先刺眼的全红。
    static let warn = dynamic(
        light: NSColor(srgbRed: 1.00, green: 0.62, blue: 0.26, alpha: 1),
        dark: NSColor(srgbRed: 1.00, green: 0.70, blue: 0.38, alpha: 1))
    static let warnDeep = dynamic(
        light: NSColor(srgbRed: 0.94, green: 0.42, blue: 0.28, alpha: 1),
        dark: NSColor(srgbRed: 1.00, green: 0.52, blue: 0.36, alpha: 1))
    /// 收起条留意态渐变。
    static let sliverAttention: [Color] = [warn, warnDeep]

    /// DeepSeek 品牌蓝（鲸鱼 #4D6BFE 系）：dsh 余额徽章常态色，与 iris 同族呼应。
    static let deepseek = dynamic(
        light: NSColor(srgbRed: 0.30, green: 0.42, blue: 1.00, alpha: 1),
        dark: NSColor(srgbRed: 0.47, green: 0.57, blue: 1.00, alpha: 1))

    /// WorkBuddy 品牌青绿（图标渐变主色 #0CC8A3 系）：积分环常态色；浅色稍压深保证壁纸可读性。
    static let workbuddy = dynamic(
        light: NSColor(srgbRed: 0.00, green: 0.62, blue: 0.50, alpha: 1),
        dark: NSColor(srgbRed: 0.20, green: 0.85, blue: 0.68, alpha: 1))

    /// 自定义账户稳定哈希色（3.3）：同一账户永远同一色相，深浅外观各自调明度。
    static func customColor(_ id: UUID) -> Color {
        let hash = id.uuidString.unicodeScalars.reduce(0) { ($0 &+ Int($1.value)) & 0x7fffffff }
        let hue = Double(hash % 360) / 360.0
        return dynamic(
            light: NSColor(calibratedHue: hue, saturation: 0.62, brightness: 0.62, alpha: 1),
            dark: NSColor(calibratedHue: hue, saturation: 0.55, brightness: 0.85, alpha: 1))
    }
}

/// 自定义账户首字符圆形徽章（无品牌图标的占位）：账户名首字符 + 稳定哈希色，账户卡与悬浮条共用。
struct CustomAccountMark: View {
    let name: String
    let accountID: UUID
    var size: CGFloat = 40
    var body: some View {
        let color = PanelTheme.customColor(accountID)
        Text(String(name.trimmingCharacters(in: .whitespacesAndNewlines).first ?? "◈"))
            .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.12), in: Circle())
            .overlay { Circle().strokeBorder(color.opacity(0.28), lineWidth: 0.5) }
    }
}

struct QuotaRow: View {
    let quota: Quota
    var stale = false
    var threshold: Double = 20
    var burnEstimateText: String? = nil
    /// 3.31：Antigravity 失败兜底模式——窗口已过期也显示最后一次成功读数的百分比，
    /// 不再换成「待刷新」；陈旧观感仍由 stale 灰与「历史数据」标签表达。
    var showExpiredValue = false
    private var maskExpired: Bool { quota.expired() && !showExpiredValue }
    var body: some View {
        VStack(alignment:.leading,spacing:7) {
            HStack {
                Text(L(quota.title)).font(.callout).lineLimit(1).help(L(quota.title))
                Spacer()
                Text(L(maskExpired ? "待刷新" : "\(Int(quota.remaining))% 剩余")).font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(quota.expired() || stale ? Color.secondary : quota.remaining <= threshold ? .orange : Theme.teal)
            }
            ProgressView(value:quota.remaining,total:100).tint(quota.remaining <= threshold ? .orange : Theme.teal).opacity(quota.expired() || stale ? 0.3 : 1)
            HStack {
                if let reset = quota.resetsAt {
                    Text(L(maskExpired ? "重置时间已到，等待新数据" : "重置：\(displayDate(reset))"))
                } else { Text(L("平台未提供重置时间")) }
                Spacer()
                if stale { Text(L("历史数据")).foregroundStyle(.orange) }
            }.font(.system(size:10)).foregroundStyle(.tertiary)
            if let estimate = burnEstimateText {
                Text(L(estimate)).font(.system(size:10)).foregroundStyle(.secondary)
            }
        }
        // 陈旧快照视觉降级：整行降饱和，与实时数据拉开视觉权重
        .saturation(stale ? 0.4 : 1)
    }
}
