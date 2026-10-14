import Foundation
import UserNotifications

// 阶段 3A：系统通知状态机（移植 Pulse UsageAlerts 的设计，不是抄代码）。
// 规则层 = 纯函数 + Codable 持久化 memory（alerts.json 存数据目录，now 注入可测）。
// 既有「需要留意」横幅与本状态机共用 AlertRules 的评估逻辑与同一刷新评估点。

// MARK: - 设置（UserDefaults；授权只在用户打开任一开关时请求，默认全关）

struct AlertSettings: Equatable {
    /// 已用 % 档位：0=关，75/80/90/95。菜单只给档位不给自由数字——设置的意义是挑一个想知道的时刻。
    var threshold = 0
    var onReset = false
    var onFailure = false
    /// 低余额线（按账户币种），0=关。记录的是阈值数值而非布尔：调高会重报，充值回线自动 re-arm。
    var lowBalance = 0.0

    var wantsAlerts: Bool { threshold > 0 || onReset || onFailure || lowBalance > 0 }

    static func read(_ d: UserDefaults = .standard) -> AlertSettings {
        var s = AlertSettings()
        s.threshold = [75, 80, 90, 95].contains(d.integer(forKey: "notifyThreshold")) ? d.integer(forKey: "notifyThreshold") : 0
        s.onReset = d.bool(forKey: "notifyOnReset")
        s.onFailure = d.bool(forKey: "notifyOnFailure")
        let low = d.double(forKey: "notifyLowBalance")
        s.lowBalance = low.isFinite && low > 0 ? low : 0
        return s
    }
}

// MARK: - 事件（五种；identifier 稳定去重，macOS 替换同键旧通知而不是叠一列）

enum AlertEvent: Equatable {
    /// 越过用户选择的档位。文案是状态而非事件（「已用 92%」，永远为真），所以首次越过也立即报。
    case approaching(windowID: String, title: String, step: Int, resetsAt: Date?)
    /// 平台自己的裁决（Quota.exhausted），不是我们的算术。余额类窗口永远走不到这里。
    case spent(windowID: String, title: String, resetsAt: Date?)
    /// 曾越线的窗口翻篇了。重置时间是事件身份的一部分——两次翻篇是两条新闻。
    case reset(windowID: String, title: String, resetsAt: Date?)
    /// 预付余额跌破用户设的线。钱不是百分比：这些平台没有分母可除。
    case lowBalance(text: String)
    /// 连续若干轮读不到当前数据。reason 为 nil 表示单纯取数失败。
    case unreadable(reason: String?)

    func identifier(account id: UUID) -> String {
        switch self {
        case .approaching(let w, _, let step, _): return "\(id.uuidString)|\(w)|approaching-\(step)"
        case .spent(let w, _, _): return "\(id.uuidString)|\(w)|spent"
        case .reset(let w, _, let resetsAt): return "\(id.uuidString)|\(w)|reset-\(Int(resetsAt?.timeIntervalSince1970 ?? 0))"
        case .lowBalance: return "\(id.uuidString)|-|low-balance"
        case .unreadable: return "\(id.uuidString)|-|unreadable"
        }
    }

    /// 中文源串；L() 在发出时翻译。
    var body: String {
        switch self {
        case .approaching(_, let title, let step, let resetsAt):
            return "\(title) 已用 \(step)%" + Self.resetSuffix(resetsAt)
        case .spent(_, let title, let resetsAt):
            return "\(title) 已用尽" + Self.resetSuffix(resetsAt)
        case .reset(_, let title, _):
            return "\(title) 已重置"
        case .lowBalance(let text):
            return "余额仅剩 \(text)"
        case .unreadable(let reason):
            return reason ?? "最近几次同步都没有成功，显示的是早些时候的数据。"
        }
    }

    private static func resetSuffix(_ resetsAt: Date?) -> String {
        guard let resetsAt else { return "" }
        return "，重置：\(displayDate(resetsAt))"
    }
}

// MARK: - 规则层（纯函数，除 self 外无状态；时钟由调用方注入）

/// 一次刷新尝试的结局，三态而非两态：「没配好/没运行」不是故障，也永远不算是可达性证据。
enum AlertOutcome: Equatable {
    /// 取到当前读数（快照内容另算额度窗与余额）。
    case reading(UsageSnapshot)
    /// 服务应答了，答案就是「没有可报的」（无套餐的完整答复）。一次应答终结一轮故障。
    case answered
    /// 未配置、未登录、软件未运行、推送路由沉默、status 消息。真到有人操作为止，不是新闻。
    case neutral
    /// 原本能读的东西读不到了。reason 是给用户的消毒后错误文本。
    case failure(String?)
}

struct AlertMemory: Codable, Equatable {
    struct Window: Codable, Equatable {
        /// 当前这扇窗已报过的最高档（只升不降）；翻篇证据出现时清零。
        var announced = 0
        /// 上一轮看到的读数，翻篇判定用。
        var fraction = 0.0
        var resetsAt: Date?
    }
    struct Record: Codable, Equatable {
        var windows: [String: Window] = [:]
        /// 连续多少轮拿不出当前读数。
        var failures = 0
        /// 这一轮故障是否已报过——每次故障只报一次，首个成功读数清零。
        var reportedFailure = false
        /// 已报过的低余额阈值数值（不是布尔）：调高线重报，余额回线清零。
        var lowBalanceWarnedFor: Double?
    }

    var accounts: [String: Record] = [:]

    /// 间隔 2~30 分钟下，3 次是 6 分钟到 1 个半小时的沉默。一次失败不是新闻（限流、
    /// 断网下一轮自己答），连续三次是不会自愈的事。
    static let failuresBeforeSaying = 3

    @discardableResult
    mutating func evaluate(account id: UUID, currency: String, outcome: AlertOutcome,
                           settings: AlertSettings, now: Date) -> [AlertEvent] {
        var record = accounts[id.uuidString] ?? Record()
        var produced: [AlertEvent] = []

        switch outcome {
        case .reading, .answered:
            record.failures = 0
            record.reportedFailure = false
        case .neutral:
            break
        case .failure(let reason):
            record.failures += 1
            if settings.onFailure, record.failures >= Self.failuresBeforeSaying, !record.reportedFailure {
                record.reportedFailure = true
                produced.append(.unreadable(reason: reason))
            }
        }

        guard case .reading(let snapshot) = outcome else {
            accounts[id.uuidString] = record
            return produced
        }

        // 低余额：记录阈值数值；回线（充值或调低线）即 re-arm。
        if settings.lowBalance > 0, let balance = snapshot.balances.first(where: { $0.currency == currency }) {
            if balance.value < settings.lowBalance {
                if record.lowBalanceWarnedFor != settings.lowBalance {
                    record.lowBalanceWarnedFor = settings.lowBalance
                    produced.append(.lowBalance(text: balance.text))
                }
            } else {
                record.lowBalanceWarnedFor = nil
            }
        }

        // 额度窗：只升不降记最高档；翻篇证据才清零；重置已过的窗不评（属于已不存在的窗口）。
        for quota in snapshot.quotas {
            guard quota.resetsAt.map({ $0 > now }) ?? true else { continue }
            var memory = record.windows[quota.id] ?? Window()
            if let seen = record.windows[quota.id],
               AlertRules.hasTurnedOver(quota, seenFraction: seen.fraction, seenResetsAt: seen.resetsAt) {
                // 只报曾越线的窗口：从没过线的窗翻篇是不值得打扰的新闻。
                if settings.onReset, seen.announced > 0 {
                    produced.append(.reset(windowID: quota.id, title: quota.title, resetsAt: quota.resetsAt))
                }
                memory.announced = 0
            }
            if let step = AlertRules.step(for: quota, threshold: settings.threshold), step > memory.announced {
                memory.announced = step
                produced.append(step >= 100
                    ? .spent(windowID: quota.id, title: quota.title, resetsAt: quota.resetsAt)
                    : .approaching(windowID: quota.id, title: quota.title, step: step, resetsAt: quota.resetsAt))
            }
            memory.fraction = quota.usedPercent / 100
            memory.resetsAt = quota.resetsAt
            record.windows[quota.id] = memory
        }

        accounts[id.uuidString] = record
        return produced
    }
}

// MARK: - 规则表（分类、档位、翻篇证据；横幅与通知共用）

enum AlertRules {
    /// 推送式路由：沉默是「没人用」，不是「读不到」。这些连接的失败一律不计入连续失败。
    static let silentConnections: [Connection] = [.agentLocal, .claudeDesktop, .kimiDesktop, .geminiApp]

    /// 错误文本 → 三态。清单里全是连接器自己抛的固定串：neutral = 没配好/没运行；
    /// answered = 服务明确回答「没有可报的」；其余一律 failure（限流/网络/凭证被拒/格式变更）。
    static func standing(connection: Connection, error: String) -> AlertOutcome {
        // 凭证类错误即使在沉默路由上也要放行 failure：401 不是「没人用」，是不会自愈的故障
        // （agentLocal 链路的 kimi/glm/minimax 用本机凭证调官方接口，被拒必须计入连续失败）。
        let credentialPhrases = ["密钥无效或登录已过期", "凭证已失效", "凭证已被拒绝", "登录已过期", "会话已过期", "Cookie 已失效"]
        if credentialPhrases.contains(where: { error.contains($0) }) { return .failure(error) }
        if silentConnections.contains(connection) { return .neutral }
        let neutralPhrases = [
            "请在账户设置中保存 API 密钥", "未找到本机", "请安装并登录", "未找到 Command Code 凭证",
            "Cookie 缺少会话项", "Cookie 格式无法解析", "凭证格式应为", "凭证缺少组织",
            "请选择快照 JSON 文件", "套餐缓存缺少可靠的写入时间", "未能读取 Devin 保存的套餐缓存",
            "未找到运行中的 Gemini", "未找到运行中的 Antigravity",
        ]
        if neutralPhrases.contains(where: { error.contains($0) }) { return .neutral }
        let answeredPhrases = [
            "没有 MiMo Coding Plan", "无配额分配", "未返回可用额度窗口", "未返回可显示的额度窗口",
            "未返回 Copilot 额度车道", "未返回有效额度窗口", "没有进行中的 Coding Plan 订阅",
        ]
        if answeredPhrases.contains(where: { error.contains($0) }) { return .answered }
        return .failure(error)
    }

    /// 窗口档位：100 是平台的原话（exhausted），算术永远只到 99——我们说「已用尽」
    /// 而窗口里还有东西，是最坏时刻的发明。余额类分母是我们自己的观测或用户自填数字，
    /// 同样不许算术推 100。
    static func step(for quota: Quota, threshold: Int) -> Int? {
        let reached = quota.exhausted ? 100 : min(99, Int(quota.usedPercent.rounded(.down)))
        if reached >= 100 { return 100 }
        if threshold > 0, reached >= threshold { return threshold }
        return nil
    }

    /// 翻篇证据（与 Pulse 同一规则）：平台报了一个更晚的重置边界（60 秒余量防抖——
    /// 重置时间常取整，一秒的抖动不是新窗口）；或读数一次回落 40 个点——滚动窗几点
    /// 几点的下滑不是翻篇（95→89→93 的震荡不清档），掉 40 点是翻了不是滑了。
    /// 无重置时间的窗（DeepSeek 余额环、预算环）不存在翻篇：那是预付的钱或自填分母。
    static func hasTurnedOver(_ quota: Quota, seenFraction: Double, seenResetsAt: Date?) -> Bool {
        guard quota.resetsAt != nil else { return false }
        let movedOn = quota.resetsAt.flatMap { new in seenResetsAt.map { new.timeIntervalSince($0) > 60 } } ?? false
        return movedOn || seenFraction - quota.usedPercent / 100 >= 0.4
    }

    /// 「需要留意」横幅项：阈值 + 预算 + 余额不足 + 到期，与通知状态机同一评估入口。
    /// （语义即 V1.8 Account.warnings，原样迁入。）
    static func attention(_ account: Account, threshold: Double, at date: Date = Date()) -> [String] {
        guard account.enabled, let s = account.snapshot else { return [] }
        var result = s.quotas.filter { !$0.expired(at: date) && $0.remaining <= threshold }.map { "\($0.title)剩余 \(Int($0.remaining))%" }
        if let budget = account.budget, budget > 0, let start = s.periodStart, let end = s.periodEnd,
           Calendar.current.isDate(start, equalTo: date, toGranularity: .month), Calendar.current.isDate(end, equalTo: date, toGranularity: .month),
           let cost = s.costs.first(where: { $0.currency == account.currency }), cost.value >= budget * (1 - threshold / 100) {
            result.append("\(account.currency) 本月预算已使用 \(String(format: "%.0f", cost.value / budget * 100))%")
        }
        result += s.balances.filter { $0.value <= 0 }.map { "\($0.currency) 余额不足" }
        // dsh 钱包余额：¥1 以下即进「需要留意」（>0 且 <1，避免与上方 ≤0 规则重复计）。
        if account.provider == .dsh {
            result += s.balances.filter { $0.value > 0 && $0.value < 1 }.map { "\($0.currency) 余额不足" }
        }
        // WorkBuddy 积分：10 积分以下即进「需要留意」（>0 且 <10，对齐悬浮条珊瑚色阈值；≤0 已由上方规则覆盖）。
        if account.provider == .workbuddy {
            result += s.balances.filter { $0.value > 0 && $0.value < 10 }.map { _ in "积分不足 10" }
        }
        // custom 自定义余额：低于满环基准 5% 即进「需要留意」（>0 且 <基准×5%，≤0 已由上方规则覆盖）。
        if account.provider == .custom {
            let baseline = account.customConfig?.baseline ?? 100
            result += s.balances.filter { $0.value > 0 && $0.value < baseline * 0.05 }.map { _ in "余额不足（低于满环基准 5%）" }
        }
        for d in s.deadlines ?? [] where d.date.timeIntervalSince(date) <= 3 * 86400 {
            result.append("\(d.label) 将于 \(displayDate(d.date, time: false)) 到期")
        }
        return result
    }
}

// MARK: - 投递层（唯一接触 UNUserNotificationCenter 的地方；无 app bundle 的测试/命令行构建完全围栏）

@MainActor final class AlertCenter {
    /// 没有 bundle 时 UNUserNotificationCenter.current() 不是失败而是直接崩——所有入口都过这道栏。
    static var isSupported: Bool { TokenBundle.bundle.bundleIdentifier != nil }

    private(set) var memory: AlertMemory
    let memoryFile: URL

    init(directory: URL) {
        memoryFile = directory.appendingPathComponent("alerts.json")
        memory = (try? Data(contentsOf: memoryFile)).flatMap { try? JSONDecoder().decode(AlertMemory.self, from: $0) } ?? AlertMemory()
    }

    /// 一次刷新尝试落地。memory 无论是否有通知权限都更新——否则拒绝授权的用户哪天开了开关，
    /// 会把睡过去的每一次越线一次性补报出来。
    func observe(account: Account, outcome: AlertOutcome, now: Date = Date()) {
        let settings = AlertSettings.read()
        let before = memory
        let events = memory.evaluate(account: account.id, currency: account.currency, outcome: outcome, settings: settings, now: now)
        if memory != before { save() }
        guard settings.wantsAlerts, Self.isSupported, !events.isEmpty else { return }
        for event in events { post(event, account: account) }
    }

    /// 删除账户时同步清掉它的告警记忆：不留越线档位与连续失败计数的孤魂。
    func forget(account id: UUID) {
        if memory.accounts.removeValue(forKey: id.uuidString) != nil { save() }
    }

    /// 授权只在用户打开开关时请求——启动时弹权限框是拿到永久拒绝的最短路径。
    static func requestAuthorization() async -> Bool {
        guard isSupported else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    private func post(_ event: AlertEvent, account: Account) {
        let content = UNMutableNotificationContent()
        content.title = account.name
        content.body = L(event.body)
        // 点击定位用：通知是谁的，打开主窗口就滚动到谁的卡片。
        content.userInfo["account"] = account.id.uuidString
        // 一律默认声音：不发声音的通知是静默送达，系统开关只能拿走声音不能补回——
        // 选择从来不是安静或吵，而是系统设置里有一个可用的静音开关，或根本没有。
        content.sound = .default
        let request = UNNotificationRequest(identifier: event.identifier(account: account.id), content: content, trigger: nil)
        Task {
            do { try await UNUserNotificationCenter.current().add(request) }
            catch { Log.store.error("notification delivery failed") }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(memory) else { return }
        try? FileManager.default.createDirectory(at: memoryFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: memoryFile, options: .atomic)
    }
}

// MARK: - 点击通知打开主窗口

extension Notification.Name { static let gaoOpenMainWindow = Notification.Name("gaociyuan.openMainWindow") }

/// completion-handler 形式而非 async 形式，刻意如此：这些是可选协议方法，签名差一个字母
/// 不是编译错误，而是方法永远不会被调用——点了没反应的点击看起来和没接线一模一样。
final class NotificationOpener: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationOpener()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        // 带上账户 id：打开主窗口后滚动定位到对应卡片，而不是只开窗。
        var info: [String: Any] = [:]
        if let account = response.notification.request.content.userInfo["account"] as? String { info["account"] = account }
        NotificationCenter.default.post(name: .gaoOpenMainWindow, object: nil, userInfo: info)
        completionHandler()
    }
}
