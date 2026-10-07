import Foundation
import SQLite3


// MARK: - Grok 账号周池（借 CLI 登录）

// 借 Grok CLI 存在 ~/.grok/auth.json 的 OIDC 登录，问 CLI 自己的代理。这是**账号**的
// SuperGrok/xAI 每周池：2026 年 6 月起付费套餐在全部 Grok 产品（网页聊天/Imagine/语音/
// API/CLI）上花同一个池，应答的 productUsage 把 GrokChat 与 GrokTasks 并列即是证明——
// 没有 CLI 专属数字可画，命名上必须与 Grok Bot（CLI 账单，另一条 provider 路）区分。
// 令牌约 6 小时过期：CLI 使用中自己续期，没人替我们续；过期与从未登录是两种报错，指引不同。
enum GrokAccountBridge {
    static var authFilePath: String = NSHomeDirectory() + "/.grok/auth.json"
    static let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    static let settingsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!

    enum Login {
        case none, expired, usable(String)
    }

    // 文件按 issuer/client 键控，可能多条：取最新的未过期条目。过期条目保留作「登录过但失效」的
    // 证据；无过期时间的条目不是过期——只是未标注，服务自己裁决——作最后手段，且绝不能压过有日期的
    // 条目（停在 distantFuture 会赢得每次比较），distantPast 才是回落该输的样子。
    static func storedLogin(path: String? = nil, now: Date = Date()) -> Login {
        guard let data = FileManager.default.contents(atPath: path ?? authFilePath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .none }
        var sawEntry = false
        var best: (token: String, expiry: Date)?
        for case let entry as [String: Any] in root.values {
            guard let token = entry["key"] as? String, !token.isEmpty else { continue }
            sawEntry = true
            guard let expiry = CursorBridge.isoDate(entry["expires_at"] as? String) else {
                if best == nil { best = (token, .distantPast) }
                continue
            }
            guard expiry > now else { continue }
            if best == nil || expiry > best!.expiry { best = (token, expiry) }
        }
        if let best { return .usable(best.token) }
        return sawEntry ? .expired : .none
    }

    static func request(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // CLI 自己发的头；没有它同一路径会答企业版额度形态——个人套餐全零，
        // 「什么都没有的分母」不是读数。
        request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func fetch() async throws -> UsageSnapshot {
        let token: String
        switch storedLogin() {
        case .none:
            throw MonitorError.message("未找到本机 Grok CLI 登录。请安装并登录 Grok CLI 后重试。")
        case .expired:
            throw MonitorError.message("Grok CLI 登录已过期（令牌约 6 小时有效，使用中自动续期）。请在 Grok CLI 中使用或重新登录后重试。上次数据已保留。")
        case .usable(let found):
            token = found
        }
        let (data, http) = try await Connectors.sendOAuth(request(billingURL, token: token))
        switch http.statusCode {
        case 200: break
        case 401, 403:
            throw MonitorError.message("Grok CLI 登录已过期（令牌约 6 小时有效，使用中自动续期）。请在 Grok CLI 中使用或重新登录后重试。上次数据已保留。")
        case 429:
            throw MonitorError.message("平台限流，请稍后刷新（HTTP 429）。上次数据已保留。")
        default:
            throw MonitorError.message("服务不可用（HTTP \(http.statusCode)）。上次数据已保留。")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = root["config"] as? [String: Any] else { throw Connectors.schemaError }
        var s = try parseBilling(config)
        // 套餐名来自 settings 而不是 billing 应答；短预算的可选增补，失败只少一行名字。
        if let plan = await fetchPlan(token: token) { s.note = plan + " · " + (s.note ?? "") }
        return s
    }

    static func fetchPlan(token: String) async -> String? {
        guard let (data, http) = try? await Connectors.sendOAuth(request(settingsURL, token: token)),
              http.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tier = (root["subscription_tier_display"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tier.isEmpty else { return nil }
        return tier
    }

    // 窗长从周期自己的两个时间戳减出（实测 604800s），不读 type 字符串——枚举是他们改名的自由，
    // 减法不是。proto3 JSON 隐式 presence：缺 usagePercent = 0，但**仅在周期进行中**；
    // 描述已结束周期的应答对下一个周期一无所知，读成 0% 是把空池报成满池。
    static func parseBilling(_ config: [String: Any], now: Date = Date()) throws -> UsageSnapshot {
        let period = config["currentPeriod"] as? [String: Any]
        guard let start = CursorBridge.isoDate((period?["start"] as? String) ?? (config["billingPeriodStart"] as? String)),
              let end = CursorBridge.isoDate((period?["end"] as? String) ?? (config["billingPeriodEnd"] as? String)),
              end > start else { throw MonitorError.message("Grok 未返回进行中的账单周期。请确认账号已开通 SuperGrok 等付费套餐。") }
        guard let percent = Connectors.number(config["creditUsagePercent"]) ?? ((start...end).contains(now) ? 0 : nil) else {
            throw MonitorError.message("Grok 未返回进行中的账单周期。请确认账号已开通 SuperGrok 等付费套餐。")
        }
        let seconds = end.timeIntervalSince(start)
        let label: String
        switch seconds {
        case 6 * 86_400 ... 8 * 86_400: label = "每周"
        case 27 * 86_400 ... 32 * 86_400: label = "每月"
        default: label = "\(Int((seconds / 86_400).rounded())) 天"
        }
        var s = UsageSnapshot.empty(source: "Grok 账号官方接口")
        s.quotas = [.init(id: "grok-account-pool", title: "Grok 账号池 · \(label)", usedPercent: max(0, min(100, percent)), resetsAt: end, windowSeconds: seconds)]
        s.note = "全 Grok 产品共用同一额度池（网页聊天/Imagine/语音/API/CLI），无单产品独立数字；缺失的百分比按周期进行中读作 0。"
        try s.validate()
        return s
    }
}

