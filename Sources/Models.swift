import Foundation

enum Provider: String, Codable, CaseIterable, Identifiable {
    case openai, claude, deepseek, grok, gemini, qwen, kimi, doubao, glm, minimax, hy, mimo, cursor, copilot, devin, ollama, commandcode, dsh, workbuddy, custom
    case opencode, cline, factory, zed, kiro, qoder, typesafe, openrouter, trae, alibaba, stepfun, newapi, sub2api
    var id: String { rawValue }
    var company: String {
        switch self {
        case .cursor: return "Cursor"
        case .copilot: return "GitHub"
        case .openai: return "OpenAI"
        case .claude: return "Anthropic"
        case .deepseek: return "DeepSeek"
        case .grok: return "xAI"
        case .gemini: return "Google"
        case .qwen: return "阿里"
        case .kimi: return "月之暗面"
        case .doubao: return "字节"
        case .glm: return "智谱"
        case .minimax: return "MiniMax"
        case .hy: return "腾讯"
        case .mimo: return "小米"
        case .devin: return "Devin"
        case .ollama: return "Ollama"
        case .commandcode: return "Command Code"
        case .dsh: return "DeepSeek"
        case .workbuddy: return "腾讯"
        case .custom: return "自定义"
        default: return integration?.company ?? rawValue
        }
    }
    var platform: String {
        switch self {
        case .cursor: return "Cursor"
        case .copilot: return "Copilot"
        case .openai: return "ChatGPT"

        case .claude: return "Claude"
        case .deepseek: return "DeepSeek"
        case .grok: return "Grok"
        case .gemini: return "Gemini"
        case .qwen: return "通义千问"
        case .kimi: return "Kimi"
        case .doubao: return "豆包"
        case .glm: return "GLM"
        case .minimax: return "MiniMax"
        case .hy: return "混元"
        case .mimo: return "MiMo"
        case .devin: return "Devin"
        case .ollama: return "Ollama Cloud"
        case .commandcode: return "Command Code"
        case .dsh: return "Harness"
        case .workbuddy: return "WorkBuddy"
        case .custom: return "API 计费"
        default: return integration?.name ?? rawValue
        }
    }
    var name: String {
        switch self {
        case .cursor: return "Cursor"
        case .copilot: return "GitHub · Copilot"
        case .openai: return "\(company) · \(platform)"
        case .claude: return "\(company) · \(platform)"
        case .deepseek: return "DeepSeek"
        case .grok: return "\(company) · \(platform)"
        case .gemini: return "\(company) · \(platform)"
        case .qwen: return "\(company) · \(platform)"
        case .kimi: return "\(company) · \(platform)"
        case .doubao: return "\(company) · \(platform)"
        case .glm: return "\(company) · \(platform)"
        case .minimax: return "MiniMax"
        case .hy: return "\(company) · \(platform)"
        case .mimo: return "\(company) · \(platform)"
        case .devin: return "Devin"
        case .ollama: return "Ollama Cloud"
        case .commandcode: return "Command Code"
        case .dsh: return "DeepSeek · Harness"
        case .workbuddy: return "腾讯 · WorkBuddy"
        case .custom: return "自定义 · API 计费"
        default: return integration?.name ?? rawValue
        }
    }
    var agentSoftware: String {
        switch self {
        case .cursor: return "Cursor"
        case .copilot: return "Copilot"
        case .openai: return "Codex"
        case .claude: return "Claude Code"
        case .gemini: return "Antigravity"
        case .grok: return "Grok Bot"
        case .deepseek: return "DeepSeek 桌面端"
        case .kimi: return "Kimi Work"
        case .glm: return "Zcode"
        case .qwen: return "Qwen CLI"
        case .doubao: return "豆包 Work"
        case .minimax: return "MiniMax Code"
        case .hy: return "混元"
        case .mimo: return "MiMo Agent"
        case .devin: return "Devin"
        case .ollama: return "Ollama"
        case .commandcode: return "Command Code"
        case .dsh: return "DeepSeek Harness"
        case .workbuddy: return "WorkBuddy"
        case .custom: return "自定义 API"
        default: return integration?.name ?? rawValue
        }
    }
    // New-account capabilities are separate from Connection.available so saved
    // legacy routes keep decoding and validating without manufacturing duplicates.
    var creationKinds: [AccountKind] {
        if let integration { return [integration.kind] }
        switch self {
        case .qwen, .hy, .deepseek: return [.llm]
        default: return [.agent, .llm]
        }
    }
    var defaultAgentName: String {
        // 自定义账户没有专属软件：默认名不拼「公司 · 平台 · 软件」三段式。
        if self == .custom { return "自定义账户" }
        if let integration { return integration.name }
        return "\(company) · \(platform) · \(agentSoftware)"
    }
    var defaultLLMName: String {
        if let integration { return integration.name + " · 账户" }
        return "\(company) · \(platform) API"
    }
    var mark: String {
        switch self {
        case .cursor: return "▷"
        case .copilot: return "⎇"
        case .openai: return "O"
        case .claude: return "C"
        case .deepseek: return "D"
        case .grok: return "𝕏"
        case .gemini: return "✦"
        case .qwen: return "Q"
        case .kimi: return "K"
        case .doubao: return "豆"
        case .glm: return "Z"
        case .minimax: return "M"
        case .hy: return "元"
        case .mimo: return "mi"
        case .devin: return "◆"
        case .ollama: return "ol"
        case .commandcode: return "⌘"
        case .dsh: return "ds"
        case .workbuddy: return "W"
        case .custom: return "◈"
        default: return integration?.mark ?? rawValue
        }
    }
    var apiURL: String {
        switch self {
        case .cursor: return "https://cursor.com/settings"
        case .copilot: return "https://github.com/settings/copilot"
        case .openai: return "https://platform.openai.com/usage"
        case .claude: return "https://platform.claude.com/usage"
        case .deepseek: return "https://platform.deepseek.com/usage"
        case .grok: return "https://console.x.ai"
        case .gemini: return "https://aistudio.google.com"
        case .qwen: return "https://bailian.console.aliyun.com"
        case .kimi: return "https://platform.moonshot.cn"
        case .doubao: return "https://console.volcengine.com/ark"
        case .glm: return "https://open.bigmodel.cn"
        case .minimax: return "https://platform.minimaxi.com"
        case .hy: return "https://cloud.tencent.com/product/hunyuan"
        case .mimo: return "https://platform.xiaomimimo.com"
        case .devin: return "https://app.devin.ai"
        case .ollama: return "https://ollama.com/settings"
        case .commandcode: return "https://commandcode.ai"
        case .dsh: return "https://harness.deepseek.com/usage"
        case .workbuddy: return "https://www.workbuddy.cn"
        case .custom: return ""
        default: return integration?.url ?? rawValue
        }
    }
    var memberURL: String {
        switch self {
        case .cursor: return "https://cursor.com/settings"
        case .copilot: return "https://github.com/settings/copilot"
        case .openai: return "https://chatgpt.com/codex/settings/usage"
        case .claude: return "https://claude.ai/settings/usage"
        case .deepseek: return "https://chat.deepseek.com"
        case .grok: return "https://grok.com"
        case .gemini: return "https://gemini.google.com"
        case .qwen: return "https://www.qianwen.com"
        case .kimi: return "https://www.kimi.com"
        case .doubao: return "https://www.doubao.com"
        case .glm: return "https://chatglm.cn"
        case .minimax: return "https://agent.minimaxi.com"
        case .hy: return "https://hunyuan.tencent.com"
        case .mimo: return "https://platform.xiaomimimo.com"
        case .devin: return "https://app.devin.ai"
        case .ollama: return "https://ollama.com"
        case .commandcode: return "https://commandcode.ai"
        case .dsh: return "https://harness.deepseek.com/usage"
        case .workbuddy: return "https://www.workbuddy.cn"
        case .custom: return ""
        default: return integration?.url ?? rawValue
        }
    }
    var note: String {
        switch self {
        case .openai: return "Agent（Codex）自动读取本机官方服务；LLM（API）需组织 Admin Key 查询 completions 用量与成本。"
        case .claude: return "Agent（Claude Code）：优先经官方 OAuth 接口读取本机登录的额度窗（5 小时/每周/按模型），登录过期时可用官方状态栏推送（设置里一键连接）；可选 Claude 桌面会话路（默认关，显式选择，需一次钥匙串授权）；LLM（API）需组织 Admin Key 读取 Messages 用量与成本。"
        case .deepseek: return "DeepSeek 按量 API：使用 API Key 查询账户余额。DeepSeek Harness 请使用独立的 Harness 入口。"
        case .kimi: return "Agent（Kimi Work / Kimi Code）：保存 Kimi Code 专用 Key 后自动读取官方额度，或经辅助功能只读读取本机 Kimi 桌面端订阅页（月度额度池，无需 Key），否则检测本机软件状态；LLM（API）支持 Moonshot Key 查询人民币余额与 Kimi Code 额度。"
        case .grok: return "Agent（Grok Bot）自动检测本机软件；LLM（API）需 xAI Management Key 查询本月费用与预付余额。"
        case .gemini: return "Agent（Antigravity）自动检测本机软件环境；LLM（API）支持快照文件同步。"
        case .qwen: return "阿里云百炼 / 通义千问按量 API：查询云账户现金余额。Qoder 和 Alibaba Coding Plan 使用各自独立入口。"
        case .doubao: return "Agent（豆包 桌面端）经辅助功能只读读取「订阅与额度管理」页（头像 › 额度状态，后台导航 + 5 分钟节流 + 读完按返回恢复，前台使用中不打扰）：当前时段与近 7 天已用百分比、剩余重置机会、赠送时长截止；免费档无会员池不编造；LLM（API）支持火山引擎云账号余额自动查询。"
        case .glm: return "Agent（Zcode）自动读取 Coding Plan 额度；LLM（API）支持智谱开放平台 API。"
        case .minimax: return "Agent（MiniMax Code）自动查询 Token Plan 额度；LLM（API）支持按量 API。"
        case .hy: return "混元开放平台 API：支持标准快照文件同步。WorkBuddy 积分余额使用独立的 WorkBuddy 入口。"
        case .mimo: return "Agent（MiMo Agent）自动检测本机软件；LLM（API）支持快照文件同步。"
        case .copilot: return "Agent（GitHub 设备流登录）一键授权 GitHub（仅 read:user 权限，绝不索取 repo 等代码权限），经 Copilot 插件官方内部接口读取 Premium / Chat / Completions 三条月度额度；令牌只存本机钥匙串，不读取 gh CLI 的凭证。"
        case .cursor: return "Agent（Cursor 编辑器登录态）复用本机 Cursor 编辑器已登录的账号，经官方账号接口读取双额度池（Cursor Models / Other Models）与套餐余额；令牌只用于拼一次请求头，不落盘、不读取浏览器 Cookie、不发起模型调用。"
        case .devin: return "Agent（Devin）：本机保存 plan 路只读读取 Devin 应用（前身为 Windsurf）启动时缓存的每日/每周额度与超额余额，无需凭证，观测时间为最近一次启动；账单 API 路粘贴「token 组织」凭证读取实时已用百分比，两路独立互不回退。"
        case .ollama: return "Agent（Ollama）：粘贴浏览器 Cookie 读取 ollama.com 设置页的 Session（5 小时）与 Weekly（每周）用量；按公开实现对接，未对真实账号验证。LLM（API）支持快照文件同步。"
        case .commandcode: return "Agent（Command Code）：粘贴 API Key 或复用本机 command-code CLI 登录，读取美元计价的滚动窗、组织支出上限、套餐月度额度（授权额为公开价目表，估算口径）与余额；按公开实现对接，未对真实账号验证。LLM（API）支持快照文件同步。"
        case .dsh: return "Agent（DeepSeek Harness · dsh）自动检测本机软件与登录凭证，经平台官方接口按量查询钱包余额、赠金与累计消费；凭证只用于拼一次请求头，不落盘、不写日志。LLM（API）支持快照文件同步。"
        case .workbuddy: return "Agent（WorkBuddy）经辅助功能只读读取本机 WorkBuddy 桌面端账户弹层的积分余额：积分制，1000 积分满环、低于按比例；后台读取 + 5 分钟节流，前台使用中不打扰，读完按 Escape 关闭弹层；积分值不写日志。LLM（API）支持快照文件同步。"
        case .custom: return "自定义 API 计费账户：GET 你给的余额查询地址，按点分 JSON 路径取余额；支持 Bearer Token 或自定义请求头鉴权，凭证只存本机钥匙串、不写日志；满环基准值自定，悬浮条圆环按比例填充。"
        default: return integration?.help ?? ""
        }
    }
}
enum AccountKind: String, Codable, CaseIterable {
    case agent = "Agent"
    case llm = "LLM"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if raw == "Agent" || raw == "agent" || raw == "会员额度" || raw == "membership" {
            self = .agent
        } else {
            self = .llm
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
enum Connection: String, Codable, CaseIterable {
    case codex = "本机 Codex"
    case agentLocal = "本机软件自动读取"
    case openai = "OpenAI 管理 API"
    case anthropic = "Claude 管理 API"
    case deepseek = "DeepSeek 余额 API"
    case moonshot = "Kimi 余额 API"
    case xai = "xAI 账单 API"
    case aliyun = "阿里云百炼 / 余额 API"
    case volc = "火山引擎方舟 / 余额 API"
    case glm = "GLM Coding Plan API"
    case minimax = "MiniMax Token Plan API"
    case kimiCoding = "Kimi Code 额度 API"
    case kimiDesktop = "Kimi 桌面订阅页"
    case claudeDesktop = "Claude 桌面会话"
    case cursor = "Cursor 编辑器登录态"
    case copilot = "GitHub 设备流登录"
    case grokAccount = "Grok 账号额度"
    case volcArk = "火山方舟 Coding Plan API"
    case mimoCoding = "小米 MiMo Coding Plan"
    case devinApp = "Devin 本机保存 plan"
    case devinApi = "Devin 账单 API（粘贴凭证）"
    case ollamaCloud = "Ollama Cloud 账号额度"
    case commandCode = "Command Code API"
    case dshHarness = "DeepSeek Harness 本机凭证"
    case workbuddyLocal = "WorkBuddy 积分余额（本机只读）"
    case customAPI = "自定义 API 余额查询（GET）"
    case openCodeQuota = "OpenCode 套餐额度"
    case clineQuota = "Cline 账户额度"
    case factoryQuota = "Factory Droid 账户额度"
    case zedQuota = "Zed 套餐额度"
    case kiroQuota = "Kiro CLI 额度"
    case qoderQuota = "Qoder 积分额度"
    case typeSafeQuota = "TypeSafe 账户余额"
    case openRouterQuota = "OpenRouter Key 额度"
    case traeQuota = "Trae 中国站额度"
    case alibabaPlan = "阿里云 Coding Plan 额度"
    case stepFunQuota = "StepFun 套餐额度"
    case newAPIQuota = "New API / One API 额度"
    case sub2APIQuota = "Sub2API 账户额度"
    case file = "自动读取快照文件"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "本机 Codex": self = .codex
        case "本机页面自动读取", "本机软件自动读取", "手动记录", "screen", "manual": self = .agentLocal
        case "OpenAI 管理 API": self = .openai
        case "Claude 管理 API": self = .anthropic
        case "DeepSeek 余额 API": self = .deepseek
        case "Kimi 余额 API": self = .moonshot
        case "xAI 账单 API": self = .xai
        case "阿里云余额 API", "阿里云百炼 / 余额 API": self = .aliyun
        case "火山引擎余额 API", "火山引擎方舟 / 余额 API": self = .volc
        case "GLM Coding Plan API": self = .glm
        case "MiniMax Token Plan API": self = .minimax
        case "Kimi Code 额度 API": self = .kimiCoding
        case "Kimi 桌面订阅页": self = .kimiDesktop
        case "Claude 桌面会话": self = .claudeDesktop
        case "Cursor 编辑器登录态": self = .cursor
        case "GitHub 设备流登录": self = .copilot
        case "Grok 账号额度": self = .grokAccount
        case "火山方舟 Coding Plan API": self = .volcArk
        case "小米 MiMo Coding Plan": self = .mimoCoding
        case "Devin 本机保存 plan": self = .devinApp
        case "Devin 账单 API（粘贴凭证）": self = .devinApi
        case "Ollama Cloud 账号额度": self = .ollamaCloud
        case "Command Code API": self = .commandCode
        case "DeepSeek Harness 本机凭证": self = .dshHarness
        case "WorkBuddy 积分余额（本机只读）": self = .workbuddyLocal
        case "自定义 API 余额查询（GET）": self = .customAPI
        case "自动读取快照文件": self = .file
        default:
            if let known = Self(rawValue: raw) { self = known }
            else { Self.recordUnknownFallback(raw); self = .agentLocal }
        }
    }

    // 未知连接方式回落记录：解码可能发生在后台线程，加锁保护；由 MonitorStore 读取并提示用户。
    private static let fallbackLock = NSLock()
    private static var unknownFallbackRawValues: [String] = []
    static func recordUnknownFallback(_ raw: String) {
        fallbackLock.lock(); defer { fallbackLock.unlock() }
        unknownFallbackRawValues.append(raw)
        Log.store.error("unknown connection value fell back to agentLocal")
    }
    static func takeUnknownFallbacks() -> [String] {
        fallbackLock.lock(); defer { fallbackLock.unlock() }
        defer { unknownFallbackRawValues.removeAll() }
        return unknownFallbackRawValues
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var displayName: String {
        switch self {
        case .codex, .agentLocal: return "本机软件自动读取"
        default: return rawValue
        }
    }

    var needsKey: Bool { (integration != nil && self != .kiroQuota) || [.openai,.anthropic,.deepseek,.moonshot,.minimax,.glm,.kimiCoding,.xai,.aliyun,.volc,.copilot,.volcArk,.mimoCoding,.devinApi,.ollamaCloud,.commandCode].contains(self) }

    static func available(_ p: Provider, _ k: AccountKind) -> [Connection] {
        if let extra = p.integration { return [extra.connection, .file] }
        if k == .agent {
            var list: [Connection] = []
            if p == .openai {
                list.append(.codex)
            }
            if p == .claude {
                list.append(.claudeDesktop)
            }
            if p == .cursor {
                list.append(.cursor)
            }
            if p == .copilot {
                list.append(.copilot)
            }
            if p == .grok {
                list.append(.grokAccount)
            }
            if p == .mimo {
                list.append(.mimoCoding)
            }
            if p == .devin {
                list.append(.devinApp); list.append(.devinApi)
            }
            if p == .ollama {
                list.append(.ollamaCloud)
            }
            if p == .commandcode {
                list.append(.commandCode)
            }
            if p == .dsh {
                list.append(.dshHarness)
            }
            if p == .workbuddy {
                list.append(.workbuddyLocal)
            }
            if p == .custom {
                list.append(.customAPI)
            }
            if [.minimax, .glm, .kimi].contains(p) {
                list.append(p == .minimax ? .minimax : p == .glm ? .glm : .kimiCoding)
            }
            if p == .kimi { list.append(.kimiDesktop) }
            list.append(.agentLocal)
            list.append(.file)
            return list
        } else {
            var list: [Connection] = []
            switch p {
            case .openai: list.append(.openai)
            case .claude: list.append(.anthropic)
            case .deepseek: list.append(.deepseek)
            case .kimi: list.append(.moonshot); list.append(.kimiCoding)
            case .grok: list.append(.xai)
            case .qwen: list.append(.aliyun)
            case .doubao: list.append(.volc); list.append(.volcArk)
            case .glm: list.append(.glm)
            case .minimax: list.append(.minimax)
            default: break
            }
            list.append(.file)
            return list
        }
    }
}
struct Quota: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var usedPercent: Double
    var resetsAt: Date?
    /// 平台自己裁决的「已用尽」（不是算术推出来的 100）。通知状态机只凭它说 spent；
    /// 余额类窗口的分母是本机观测或自填数字，永远不许标它。旧快照无此键，解码默认 false。
    var exhausted: Bool = false
    /// 窗口长度（秒）：连接器确知才填（官方常量或响应时间戳量出），不知道就是 nil。
    /// 没有它的窗不做 burn-rate 估算——猜出来的窗长比没有估算更误导。旧快照无此键，解码为 nil。
    var windowSeconds: Double? = nil
    var remaining: Double { max(0, min(100, 100 - usedPercent)) }
    func expired(at now: Date = Date()) -> Bool { resetsAt.map { $0 <= now } ?? false }
}
// 自定义解码：旧存档的快照没有 exhausted 字段，decodeIfPresent 兼容；写在 extension 里保留成员级初始化器。
extension Quota {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        usedPercent = try c.decode(Double.self, forKey: .usedPercent)
        resetsAt = try c.decodeIfPresent(Date.self, forKey: .resetsAt)
        exhausted = try c.decodeIfPresent(Bool.self, forKey: .exhausted) ?? false
        windowSeconds = try c.decodeIfPresent(Double.self, forKey: .windowSeconds)
    }
}
struct CreditBalance: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var unit: String
    var value: Double
    var text: String { "\(value.formatted(.number.precision(.fractionLength(0...4)))) \(unit)" }
}
struct Money: Codable, Equatable {
    var currency: String
    var value: Double
    var text: String { "\(currency.uppercased()) \(value.formatted(.number.precision(.fractionLength(2...4))))" }
}
/// 订阅/赠送等到期日（E2）：连接器从官方页面读到才填写，读不到不编造。
struct Deadline: Codable, Equatable {
    var label: String
    var date: Date
}
struct UsageSnapshot: Codable, Equatable {
    var observedAt: Date
    var periodStart: Date?
    var periodEnd: Date?
    var source: String
    var quotas: [Quota]
    var inputTokens: Int64?
    var outputTokens: Int64?
    var costs: [Money]
    var balances: [Money]
    var note: String?
    var deadlines: [Deadline]? = nil
    var creditBalances: [CreditBalance]? = nil
    var totalTokens: Int64? {
        guard let inputTokens, let outputTokens else { return nil }
        let (total, overflow) = inputTokens.addingReportingOverflow(outputTokens)
        return overflow ? nil : total
    }
    var hasMeasuredValues: Bool {
        !quotas.isEmpty || !costs.isEmpty || !balances.isEmpty || !(creditBalances ?? []).isEmpty || totalTokens != nil
    }
    /// 3C：reset 时间已过的窗口全局丢弃不展示（不老化）——旧周期的死数字挂着等于说谎。
    var chartQuotas: [Quota] {
        quotas.filter { !$0.id.contains("status") && !$0.title.contains("运行中") && !$0.title.contains("未启动") && !$0.expired() }
    }
    /// 历史曲线保留观测时数值，不因今天已跨周期而抹去。
    var historicalChartQuotas: [Quota] {
        quotas.filter { !$0.id.contains("status") && !$0.title.contains("运行中") && !$0.title.contains("未启动") }
    }
    static func empty(source: String = "自动同步") -> UsageSnapshot { .init(observedAt: Date(), source: source, quotas: [], costs: [], balances: []) }
    /// 观测值相等比较：排除 observedAt 与统计期时间戳（periodEnd 随刷新时间滚动），用于历史幂等
    /// （额度/Token/费用/余额/来源/口径不变时不追加历史、不刷新观测时间）。
    func sameObservation(as other: UsageSnapshot) -> Bool {
        source == other.source && quotas == other.quotas && inputTokens == other.inputTokens && outputTokens == other.outputTokens
            && costs == other.costs && balances == other.balances && creditBalances == other.creditBalances && note == other.note
    }
    func validate() throws {
        guard (creditBalances?.count ?? 0) <= 30,
              (creditBalances ?? []).allSatisfy({ !$0.id.isEmpty && !$0.title.isEmpty && !$0.unit.isEmpty && $0.value.isFinite }),
              Set((creditBalances ?? []).map(\.id)).count == (creditBalances?.count ?? 0),
              observedAt <= Date().addingTimeInterval(300), quotas.count <= 100,
              quotas.allSatisfy({ $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) && !$0.title.isEmpty }),
              // 窗长必须有限、为正、不超过一年：负值/零/巨值会让倒计时与速率估算说谎。
              quotas.allSatisfy({ $0.windowSeconds.map({ $0.isFinite && $0 > 0 && $0 <= 366 * 86_400 }) ?? true }),
              Set(quotas.map(\.id)).count == quotas.count,
              [inputTokens, outputTokens].compactMap({ $0 }).allSatisfy({ $0 >= 0 && $0 <= Int64.max / 2 }),
              (costs + balances).allSatisfy({ $0.value.isFinite && $0.currency.count == 3 && $0.currency.unicodeScalars.allSatisfy { CharacterSet.uppercaseLetters.contains($0) && $0.isASCII } }),
              Set(costs.map(\.currency)).count == costs.count,
              Set(balances.map(\.currency)).count == balances.count,
              (deadlines?.count ?? 0) <= 20 && (deadlines?.allSatisfy { !$0.label.isEmpty } ?? true) else { throw MonitorError.message("快照包含无效时间、重复项目、百分比或数值。") }
        if let s = periodStart, let e = periodEnd, s > e { throw MonitorError.message("统计起始时间不能晚于结束时间。") }
        if !costs.isEmpty || inputTokens != nil || outputTokens != nil {
            guard periodStart != nil, periodEnd != nil else { throw MonitorError.message("Token 与费用必须注明统计起止时间。") }
        }
    }
}
// 自定义解码：旧存档没有 deadlines 字段，必须 decodeIfPresent，否则升级后解码失败丢库。
// 写在 extension 里以保留成员级初始化器；encode(to:) 仍由编译器合成。
extension UsageSnapshot {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        observedAt = try c.decode(Date.self, forKey: .observedAt)
        periodStart = try c.decodeIfPresent(Date.self, forKey: .periodStart)
        periodEnd = try c.decodeIfPresent(Date.self, forKey: .periodEnd)
        source = try c.decode(String.self, forKey: .source)
        quotas = try c.decodeIfPresent([Quota].self, forKey: .quotas) ?? []
        inputTokens = try c.decodeIfPresent(Int64.self, forKey: .inputTokens)
        outputTokens = try c.decodeIfPresent(Int64.self, forKey: .outputTokens)
        costs = try c.decodeIfPresent([Money].self, forKey: .costs) ?? []
        balances = try c.decodeIfPresent([Money].self, forKey: .balances) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note)
        deadlines = try c.decodeIfPresent([Deadline].self, forKey: .deadlines)
        creditBalances = try c.decodeIfPresent([CreditBalance].self, forKey: .creditBalances)
    }
}
/// DeepSeek 等只有余额接口平台的分母基线（实测口径）：某币种自上次余额上升以来观测到的峰值。
struct BaselineMark: Codable, Equatable {
    var peak: Double
    var setAt: Date
}
/// 自定义 API 计费账户配置（3.3）：GET url 取 JSON，按点分路径（支持 a.b[0].c 数组下标）取余额。
/// token/头值不进此结构——只存钥匙串（KeyVault，键为账户 id），此结构整体随账户入库。
struct CustomAPIConfig: Codable, Equatable {
    /// 鉴权方式：none / bearer / header（header 时用 headerName 作头名）。
    var auth: String = "none"
    var headerName: String = ""
    var url: String = ""
    var fieldPath: String = ""
    /// 满环基准值（同 dsh ¥100 / WorkBuddy 1000 积分口径）：填充 = min(余额/基准, 1)。
    var baseline: Double = 100
    /// 单位符号/短文本（¥、$、积分、tokens…）：符号前缀、文字后缀。
    var unit: String = "¥"
    /// 赠送/第二字段路径（选填）：读到就在账户卡/详情卡多显示一行。
    var secondPath: String = ""
}
struct Account: Codable, Identifiable {
    var id = UUID()
    var provider: Provider
    var kind: AccountKind
    var name: String
    var plan: String = ""
    var connection: Connection
    var filePath: String = ""
    var scopeID: String? = nil
    var region: String? = nil
    var enabled: Bool = true
    var budget: Double? = nil
    var currency: String = "USD"
    var snapshot: UsageSnapshot? = nil
    var lastAttempt: Date? = nil
    var error: String? = nil
    var statusNote: String? = nil // 状态消息（软件运行中/未启动等），不属于额度快照，不进历史
    var balanceBasis: String? = nil // 余额分母模式：sinceTopUp（默认）/ balanceOnly / budget
    var baselines: [String: BaselineMark]? = nil // sinceTopUp 分母：按币种的观测峰值
    var history: [UsageSnapshot] = []
    /// 最近一次额度/余额/积分变化时间（快照观测值变化才更新，3.2 排序键）；nil = 从未变化，排序用首次观测兜底。
    var lastQuotaChangedAt: Date? = nil
    /// 自定义 API 账户配置（3.3，仅 provider == .custom 时非空）。
    var customConfig: CustomAPIConfig? = nil
    /// 是否出现在悬浮条 rail/托盘（3.3，默认开）。
    var showInRail: Bool = true
    /// 3.33：由 agent 自动发现流程创建的账户（账户卡打「自动发现」标签；手动添加的为 false）。
    var autoDiscovered: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, provider, kind, name, plan, connection, filePath, scopeID, region, enabled, budget, currency, snapshot, lastAttempt, error, statusNote, balanceBasis, baselines, history, lastQuotaChangedAt, customConfig, showInRail, autoDiscovered
    }

    init(id: UUID = UUID(), provider: Provider, kind: AccountKind, name: String, plan: String = "", connection: Connection, filePath: String = "", scopeID: String? = nil, region: String? = nil, enabled: Bool = true, budget: Double? = nil, currency: String = "USD", snapshot: UsageSnapshot? = nil, lastAttempt: Date? = nil, error: String? = nil, statusNote: String? = nil, history: [UsageSnapshot] = []) {
        self.id = id
        self.provider = provider
        self.kind = kind
        self.name = name
        self.plan = plan
        self.connection = connection
        self.filePath = filePath
        self.scopeID = scopeID
        self.region = region
        self.enabled = enabled
        self.budget = budget
        self.currency = currency
        self.snapshot = snapshot
        self.lastAttempt = lastAttempt
        self.error = error
        self.statusNote = statusNote
        self.history = history
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        provider = try container.decode(Provider.self, forKey: .provider)
        kind = try container.decode(AccountKind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        plan = try container.decodeIfPresent(String.self, forKey: .plan) ?? ""
        connection = try container.decode(Connection.self, forKey: .connection)
        filePath = try container.decodeIfPresent(String.self, forKey: .filePath) ?? ""
        scopeID = try container.decodeIfPresent(String.self, forKey: .scopeID)
        region = try container.decodeIfPresent(String.self, forKey: .region)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        budget = try container.decodeIfPresent(Double.self, forKey: .budget)
        currency = try container.decodeIfPresent(String.self, forKey: .currency) ?? "USD"
        snapshot = try container.decodeIfPresent(UsageSnapshot.self, forKey: .snapshot)
        lastAttempt = try container.decodeIfPresent(Date.self, forKey: .lastAttempt)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        statusNote = try container.decodeIfPresent(String.self, forKey: .statusNote)
        balanceBasis = try container.decodeIfPresent(String.self, forKey: .balanceBasis)
        baselines = try container.decodeIfPresent([String: BaselineMark].self, forKey: .baselines)
        history = try container.decodeIfPresent([UsageSnapshot].self, forKey: .history) ?? []
        lastQuotaChangedAt = try container.decodeIfPresent(Date.self, forKey: .lastQuotaChangedAt)
        customConfig = try container.decodeIfPresent(CustomAPIConfig.self, forKey: .customConfig)
        showInRail = try container.decodeIfPresent(Bool.self, forKey: .showInRail) ?? true
        autoDiscovered = try container.decodeIfPresent(Bool.self, forKey: .autoDiscovered) ?? false
    }

    var dashboard: String { kind == .agent ? provider.memberURL : provider.apiURL }
    func stale(at date: Date = Date()) -> Bool { snapshot.map { date.timeIntervalSince($0.observedAt) > 900 } ?? true }
    /// 3.31/3.32 失败兜底（Antigravity、Codex）：读取报错（服务未启动/网络失败/端口未响应）时
    /// 保留最后一次成功快照的额度窗，已过期窗口也照常展示——陈旧由 stale() 的灰环/灰字/「历史数据」标签表达，
    /// 额度区块不整块消失。凭证类错误仍走 errorIsCredential 绝不糊旧数；其余账户维持 3C「过期窗口不展示」口径。
    /// 3.32：条件抽成 keepsSnapshotOnError，QuotaRow 的 showExpiredValue 与本判定共用同一口径。
    /// Codex = provider .openai + connection .codex（本机官方服务读取）。
    var keepsSnapshotOnError: Bool {
        error != nil && !errorIsCredential && ((provider == .gemini && kind == .agent) || (provider == .openai && connection == .codex))
    }
    var displayQuotas: [Quota] {
        guard let s = snapshot else { return [] }
        if keepsSnapshotOnError {
            return s.quotas.filter { !$0.id.contains("status") && !$0.title.contains("运行中") && !$0.title.contains("未启动") }
        }
        return s.chartQuotas
    }
    /// 3C：凭证类错误（密钥无效 / 登录或会话过期 / 凭证被拒 / 会话项缺失）。
    /// 这种错旧快照绝不拿来糊——数字属于被拒绝的那个身份，展示它比没有数字更会骗人。
    var errorIsCredential: Bool {
        guard let error else { return false }
        return ["密钥无效", "登录已过期", "登录态已过期", "凭证已被拒绝", "凭据失效", "会话已过期", "缺少会话项"].contains { error.contains($0) }
    }
    /// 3D 文案粗取整：分钟 5 粒度、小时 0.5 粒度、天整天。只有结论时长，没有速率数字。
    static func burnDurationText(_ seconds: TimeInterval) -> String {
        if seconds < 3600 { return "\(max(5, Int((seconds / 300).rounded()) * 5)) 分钟后" }
        if seconds < 86400 {
            let hours = (seconds / 1800).rounded() / 2
            return "\(hours == hours.rounded(.down) ? String(Int(hours)) : String(hours)) 小时后"
        }
        return "\(max(1, Int((seconds / 86400).rounded()))) 天后"
    }
    /// 3D burn-rate（改 V1.8 E1 的滑动窗口最小二乘，参考 pulse-分析报告第 7 节）。
    /// 窗口期累计速率 = 已用份额 ÷ 已逝份额：已逝 <3% 不显示（开局噪声），撑得到重置不显示，
    /// ETA 超 2 小时不显示。余额类窗口（无重置时间）不受 2 小时限制：用观测跨度的端点累计速率
    /// （首点为基线零点），超 730 天不显示。不知道窗长的窗不估算。结果永远标注（估算）。
    func burnEstimate(quotaID: String, now: Date = Date()) -> String? {
        guard !stale(at: now) else { return nil }
        guard let q = snapshot?.quotas.first(where: { $0.id == quotaID }) else { return nil }
        if let reset = q.resetsAt, let ws = q.windowSeconds, ws > 0 {
            let elapsed = now.timeIntervalSince(reset.addingTimeInterval(-ws)) / ws
            guard (0.03...1).contains(elapsed) else { return nil }
            let used = q.usedPercent / 100
            guard used > 0 else { return nil }
            let remaining = (1 - used) / (used / elapsed) * ws
            guard remaining > 0, now.addingTimeInterval(remaining) < reset, remaining <= 7200 else { return nil }
            return "按当前速率约 \(Self.burnDurationText(remaining))耗尽（估算）"
        }
        // Unknown reset semantics cannot support a defensible depletion forecast.
        return nil
    }
    // 语义迁入 AlertRules.attention（阶段 3A）：横幅与系统通知共用同一评估入口，此处仅为兼容转发。
    func warnings(threshold: Double, at date: Date = Date()) -> [String] {
        AlertRules.attention(self, threshold: threshold, at: date)
    }
}
/// 3.36：统一账户健康模型（三态+正常），搞词元模块顶部/聚合条与 app 总览简报共用同一分类与同一份计数。
/// 导出进 usage-summary.json 供主 app 总览读取；nil（旧版导出）按 failed/stale 退化推断。
enum AccountHealth: String, Codable {
    case needsAction   // 需处理：低额度/预算提醒/凭证失效/连续失败——真正要用户行动
    case syncPaused    // 暂时无法同步：服务未启动/单次读取失败（非凭证类），不与「额度不足」同级
    case historical    // 历史数据：有兜底快照但已陈旧
    case ok
}
struct Library: Codable {
    var schema = 1
    var accounts: [Account] = []
    var refreshMinutes = 5
    var warningThreshold: Double = 20
    var autoRefresh = true

    // Legacy libraries and module backups may contain removed game fields.
    // The keyed decoder ignores those fields without changing business records.
    enum CodingKeys: String, CodingKey { case schema, accounts, refreshMinutes, warningThreshold, autoRefresh }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        accounts = try c.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        refreshMinutes = try c.decodeIfPresent(Int.self, forKey: .refreshMinutes) ?? 5
        warningThreshold = try c.decodeIfPresent(Double.self, forKey: .warningThreshold) ?? 20
        autoRefresh = try c.decodeIfPresent(Bool.self, forKey: .autoRefresh) ?? true
    }
}
enum MonitorError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let s): return s } }
}
/// 连接器读取结果：真实额度快照，或仅状态消息（如"软件运行中/暂未启动/使用中稍后补读"）。
/// 状态消息绝不写入 snapshot 与 history，账户已有真实额度快照时回退绝不覆盖。
enum ConnectorResult {
    case snapshot(UsageSnapshot)
    case status(String)
}
/// 本机 Agent 软件状态（可用性 + 展示文案），不是额度数据。
struct AgentStatus {
    var available: Bool // 软件运行中或 CLI 已安装
    var message: String
}
enum JSONCoding {
    static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted,.sortedKeys]; return e }
    static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .custom { decoder in
        let text = try decoder.singleValueContainer().decode(String.self)
        let f = ISO8601DateFormatter()
        if let v = f.date(from: text) { return v }
        f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        if let v = f.date(from: text) { return v }
        throw MonitorError.message("日期需为 ISO 8601 格式：\(text)")
    }; return d }
}
func compactTokens(_ n: Int64?) -> String {
    guard let n else { return "—" }
    if n >= 1_000_000 { return String(format: "%.2f M", Double(n) / 1_000_000) }
    if n >= 1000 { return String(format: "%.1f K", Double(n) / 1000) }
    return "\(n)"
}
// 版本号口径：整合版统一读主 app Bundle.main（CFBundleShortVersionString）；
// 独立运行/测试环境回退模块 bundle 与 CWD 的 VERSION 文件。
enum AppInfo {
    static var version: String {
        if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, !v.isEmpty { return v }
        if let v = TokenBundle.bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, !v.isEmpty { return v }
        if let v = try? String(contentsOfFile: "VERSION", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        return "0.0.0"
    }
    static var build: String {
        if let b = TokenBundle.bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String { return b }
        let parts = version.split(separator: ".").compactMap { Int($0) }
        return parts.count >= 2 ? "\(parts[0] * 10 + parts[1])" : ""
    }
}
