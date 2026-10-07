import Foundation

// 阶段 3B：自适应刷新（参考 Pulse AdaptiveRefresh 的设计）。
// 固定节奏两头都错：一分钟看一个正在烧的窗太慢，对昨晚就没动过的数字太吵。
// 规则：一切都是等更久的理由，地板只留给有活跃迹象的账户——新信号只会省请求，绝不多花。

enum AdaptivePacer {
    /// 快到额度在眼下动看得出，慢到不算捶服务。
    static let floor: TimeInterval = 120
    static let ceiling: TimeInterval = 1800

    /// 服务端计费类（DeepSeek 余额、云账单）的封顶：钱在平台服务器上花，本机任何信号都
    /// 看不到，它永远落在「什么都没变」——而什么都没变只是因为等得久，是自证循环。
    /// 给 5 分钟而不是地板：这仍是「没有信号」而不是「有信号」。
    static let unwatchedCeiling: TimeInterval = 300

    struct Signals: Equatable {
        /// 读数最近一次真正变化（sameObservation 为 false 的那次写入）。
        var lastChange: Date?
        /// 用户最近一次手动刷新。
        var lastUserAction: Date?
    }

    /// - Parameter isWatched: 本机能否看见这笔钱在被花。agent 账户（软件跑在本机）为 true；
    ///   LLM/API 计费账户为 false，封顶 unwatchedCeiling。
    static func interval(signals: Signals, isWatched: Bool, now: Date = Date()) -> TimeInterval {
        let cap = isWatched ? ceiling : unwatchedCeiling
        let ages = [signals.lastChange, signals.lastUserAction]
            .compactMap { $0.map { now.timeIntervalSince($0) } }
            .filter { $0 >= 0 }
        guard let quiet = ages.min() else { return cap }
        let wait: TimeInterval = switch quiet {
        case ..<(5 * 60): floor
        case ..<(60 * 60): 300
        case ..<(4 * 60 * 60): 900
        default: ceiling
        }
        return min(wait, cap)
    }
}
