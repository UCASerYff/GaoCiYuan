import Foundation

/// Account limits are separate from local token-log collection. Credentials stay
/// in KeyVault; adding a catalogue entry never reads another application's login.
struct ProviderIntegration {
    let name: String
    let company: String
    let mark: String
    let url: String
    let connection: Connection
    let kind: AccountKind
    let credentialLabel: String
    let help: String
    var currency: String = "USD"

    static let entries: [Provider: Self] = [
        .opencode: .init(name: "OpenCode", company: "Anomaly", mark: "Oc", url: "https://opencode.ai", connection: .openCodeQuota, kind: .agent, credentialLabel: "Zen 会话 Cookie / Go API Key", help: "Zen 使用 opencode.ai 控制台的 auth Cookie，可选填写 wrk_ 开头的工作区 ID；Go 使用独立套餐 API Key。两种套餐分别查询，不合并额度。"),
        .cline: .init(name: "Cline", company: "Cline", mark: "Cl", url: "https://app.cline.bot", connection: .clineQuota, kind: .agent, credentialLabel: "Cline API Key / workos: 令牌", help: "粘贴 Cline API Key，或保留 workos: 前缀的 Cline 登录令牌。读取套餐窗口、Credits 积分余额与本月付费用量；第三方模型供应商的 API Key 不适用，免费模型不算费用。"),
        .factory: .init(name: "Factory Droid", company: "Factory", mark: "Fd", url: "https://app.factory.ai", connection: .factoryQuota, kind: .agent, credentialLabel: "Factory Key / 访问令牌", help: "粘贴 Factory 的 API Key 或访问令牌，读取标准/核心额度池及账户余额。"),
        .zed: .init(name: "Zed", company: "Zed", mark: "Z", url: "https://dashboard.zed.dev/", connection: .zedQuota, kind: .agent, credentialLabel: "zed.session Cookie", help: "在 dashboard.zed.dev 的账单请求中复制 Cookie；仅向 cloud.zed.dev 发送 zed.session 及已识别的必要辅助 Cookie。显示模型用量与编辑预测额度，不限量项目单独注明。"),
        .kiro: .init(name: "Kiro", company: "AWS", mark: "Ki", url: "https://kiro.dev", connection: .kiroQuota, kind: .agent, credentialLabel: "", help: "需要已安装并登录的 kiro-cli。只运行固定的 /usage 查询，不调用模型；CLI 路径留空时查找常见安装位置。"),
        .qoder: .init(name: "Qoder", company: "Qoder", mark: "Qd", url: "https://qoder.com", connection: .qoderQuota, kind: .agent, credentialLabel: "Qoder 控制台 Cookie", help: "复制所选地区 Qoder 控制台的 Cookie，读取总积分、共享积分与重置日期。地区必须与登录网站一致。", currency: "CNY"),
        .typesafe: .init(name: "TypeSafe", company: "TypeSafe", mark: "Ts", url: "https://console.typesafe.ai", connection: .typeSafeQuota, kind: .llm, credentialLabel: "TypeSafe 控制台 Cookie", help: "使用 console.typesafe.ai 登录 Cookie 读取余额和已用量；依赖控制台接口，登录过期后需重新粘贴。"),
        .openrouter: .init(name: "OpenRouter", company: "OpenRouter", mark: "Or", url: "https://openrouter.ai/settings/keys", connection: .openRouterQuota, kind: .llm, credentialLabel: "OpenRouter API Key", help: "读取当前 Key 的费用与额度上限；无上限的 Key 显示费用，不编造百分比。账户总余额仅在凭据有权限时显示。"),
        .trae: .init(name: "Trae CN", company: "字节", mark: "Tr", url: "https://www.trae.cn", connection: .traeQuota, kind: .agent, credentialLabel: "Cloud-IDE-JWT / Access Token", help: "使用 Trae 中国站账户的访问令牌，可选填写 Device ID。查询套餐剩余额度；与国际版账户不通用。", currency: "CNY"),
        .alibaba: .init(name: "Alibaba Coding Plan", company: "阿里云", mark: "Ali", url: "https://bailian.console.aliyun.com", connection: .alibabaPlan, kind: .agent, credentialLabel: "阿里云控制台 Cookie", help: "使用百炼控制台额度请求中的 Cookie，按国内/国际、团队/个人套餐读取 Token Plan 额度。此处凭据与云账户余额的 AccessKey 不同。", currency: "CNY"),
        .stepfun: .init(name: "StepFun", company: "阶跃星辰", mark: "St", url: "https://platform.stepfun.com", connection: .stepFunQuota, kind: .llm, credentialLabel: "Oasis-Token", help: "从 StepFun 平台用量请求中复制 Oasis-Token，查询 Coding Plan 额度窗口。", currency: "CNY"),
        .newapi: .init(name: "New API / One API", company: "第三方服务", mark: "Na", url: "", connection: .newAPIQuota, kind: .llm, credentialLabel: "API Key / 账户访问令牌", help: "填入自己的 HTTPS 服务地址。API Key 模式查询该 Key 的额度；账户模式使用控制台访问令牌及用户 ID。额度单位以服务端配置为准。"),
        .sub2api: .init(name: "Sub2API", company: "第三方服务", mark: "S2", url: "", connection: .sub2APIQuota, kind: .llm, credentialLabel: "账户访问令牌", help: "填入自己的 HTTPS 服务地址与控制台访问令牌，查询账户余额和统计用量。模型调用 Key 不适用。")
    ]
}

extension Provider {
    var integration: ProviderIntegration? { ProviderIntegration.entries[self] }
    var preferredAccountKind: AccountKind { integration?.kind ?? .agent }
}

extension Connection {
    var integration: ProviderIntegration? { ProviderIntegration.entries.values.first { $0.connection == self } }
    var credentialLabel: String? { integration?.credentialLabel }
    var toolBridgeID: String? {
        switch self {
        case .openCodeQuota: return "opencode"
        case .clineQuota: return "cline"
        case .factoryQuota: return "factory"
        case .zedQuota: return "zed"
        case .kiroQuota: return "kiro"
        case .qoderQuota: return "qoder"
        default: return nil
        }
    }
}
