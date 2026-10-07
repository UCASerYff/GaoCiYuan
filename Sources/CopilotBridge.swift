import Foundation
import SQLite3


// MARK: - GitHub Copilot（设备流登录）

// RFC 8628 设备流：只索取 read:user——端点接受任何 GitHub OAuth token，但 gh CLI 的 token 带
// repo/workflow 权限，为用户画一个百分比而把代码权限交出来不值得。client_id 是 VS Code Copilot
// 插件的公开客户端（每份插件里都有，不是秘密）；设备流本就被设计成无密钥驱动。
// 同意页会显示编辑器名字而非搞词元，这不是官方集成，账户设置里已注明。
enum GitHubDeviceLogin {
    static let clientID = "Iv1.b507a08c87ecfe98"
    static let scope = "read:user"
    // GitHub 的 code 15 分钟有效；提前放弃会在屏幕上的 code 仍有效时报失败。
    static let patience: TimeInterval = 900

    struct Prompt {
        var userCode: String
        // 只放服务自己给出的地址：预填 user_code 的链接正是设备码钓鱼的形态，GitHub 故意不发
        // verification_uri_complete，我们也不自己拼——打字输入才是人对「这台设备」的同意。剪贴板是答案。
        var verificationURL: URL
        var deviceCode: String
        var interval: TimeInterval
    }

    static func start() async throws -> Prompt {
        let reply = try await post(URL(string: "https://github.com/login/device/code")!,
                                   body: ["client_id": clientID, "scope": scope])
        guard let userCode = reply["user_code"] as? String,
              let deviceCode = reply["device_code"] as? String,
              let verification = (reply["verification_uri"] as? String).flatMap(URL.init(string:)) else {
            throw MonitorError.message("GitHub 设备登录应答格式不符，请稍后重试。")
        }
        // 他们的下限不是我们的：比这更快会吃到 slow_down。
        let seconds = min(max(Connectors.number(reply["interval"]) ?? 5, 1), 60)
        return Prompt(userCode: userCode,
                      verificationURL: (reply["verification_uri_complete"] as? String).flatMap(URL.init(string:)) ?? verification,
                      deviceCode: deviceCode, interval: seconds)
    }

    // 轮询直到用户在浏览器完成；取消立即解开（Task.sleep 可取消），按取消不会留下仍在跑的尝试。
    static func awaitToken(_ prompt: Prompt, sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) async throws -> String {
        let deadline = Date().addingTimeInterval(patience)
        var wait = prompt.interval
        while Date() < deadline {
            try await sleep(wait)
            try Task.checkCancellation()
            let reply = try await post(URL(string: "https://github.com/login/oauth/access_token")!, body: [
                "client_id": clientID, "device_code": prompt.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            if let token = reply["access_token"] as? String, !token.isEmpty { return token }
            // 规范自己的用词，GitHub 在这里确实使用。
            switch reply["error"] as? String {
            case "authorization_pending", nil:
                continue
            case "slow_down":
                wait = min(max(Connectors.number(reply["interval"]) ?? 10, 1), 60)
            case "access_denied":
                throw MonitorError.message("GitHub 登录已被取消。")
            case "expired_token":
                throw MonitorError.message("浏览器没有及时完成登录，代码已过期。请重新发起登录。")
            case .some(let code):
                // error_description 是服务端自由文本不透传（可能夹带原文细节）；code 是规范枚举串，可展示。
                Log.connectors.error("github device login refused: \(code, privacy: .public)")
                throw MonitorError.message("GitHub 拒绝了设备登录（\(code)）。请重新发起登录。")
            }
        }
        throw MonitorError.message("浏览器没有及时完成登录，已超时。请重新发起登录。")
    }

    static func post(_ url: URL, body: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // 没有这个头 GitHub 会答 form 编码，解析不出任何东西。
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20
        let (data, http) = try await Connectors.sendOAuth(request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        // 状态先于 body 读：HTML 错误页也有很多话要说，先解析会把它们全丢掉。
        guard http.statusCode < 400 else {
            // body 里的 error_description 是服务端自由文本不透传；状态码与日志足以定位。
            Log.connectors.error("github device login http \(http.statusCode, privacy: .public)")
            throw MonitorError.message("GitHub 设备登录失败（HTTP \(http.statusCode)）。请重新发起登录。")
        }
        guard let json else { throw MonitorError.message("GitHub 设备登录应答无法解析。") }
        return json
    }
}

// GET api.github.com/copilot_internal/user：编辑器插件自己用的端点（非公开，可能无预警变动）。
// 应答报的是**剩余**：percent_remaining 90 是用了 10%，与 MiniMax/Antigravity 同向，在这里反转。
// 三条车道 completions / chat / premium_interactions，账号实际有哪几条取决于套餐。
enum CopilotBridge {
    static let endpoint = URL(string: "https://api.github.com/copilot_internal/user")!

    static func fetch(token: String) async throws -> UsageSnapshot {
        var request = URLRequest(url: endpoint)
        // "token" 而非 "Bearer"：这个端点要 GitHub 老式 scheme，另一种会被拒。
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2025-04-01", forHTTPHeaderField: "X-Github-Api-Version")
        // 它应答插件，就以插件身份问；有报告称去掉这些头会改变应答。
        request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
        request.timeoutInterval = 20
        let (data, http) = try await Connectors.sendOAuth(request)
        switch http.statusCode {
        case 200: break
        case 401, 403: throw MonitorError.message("GitHub 登录已失效，请重新登录。上次数据已保留。")
        case 429: throw MonitorError.message("平台限流，请稍后刷新（HTTP 429）。上次数据已保留。")
        default: throw MonitorError.message("服务不可用（HTTP \(http.statusCode)）。上次数据已保留。")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Connectors.schemaError }
        return try parseUsage(root)
    }

    static func parseUsage(_ root: [String: Any]) throws -> UsageSnapshot {
        let snapshots = root["quota_snapshots"] as? [String: Any] ?? [:]
        // 整个账号一个重置日（落在每月 1 号），不是每条车道一个：per-snapshot 的 quota_reset_at 恒为 0。
        let resets = (root["quota_reset_date_utc"] as? String).flatMap(resetDate)
            ?? (root["quota_reset_date"] as? String).flatMap(resetDate)
        var s = UsageSnapshot.empty(source: "GitHub Copilot 官方插件接口")
        let lanes: [(key: String, id: String, title: String)] = [
            ("premium_interactions", "copilot-premium", "Copilot Premium · 每月"),
            ("chat", "copilot-chat", "Copilot Chat · 每月"),
            ("completions", "copilot-completions", "Copilot Completions · 每月"),
        ]
        for lane in lanes {
            guard let snapshot = snapshots[lane.key] as? [String: Any] else { continue }
            let entitlement = Connectors.number(snapshot["entitlement"]) ?? 0
            let unlimited = snapshot["unlimited"] as? Bool ?? false
            // 套餐不含的车道丢弃而不是画 100%：它带 has_quota:false、零配额、percent_remaining 0，
            // 照字面读是给从没拥有过的东西画满红环。老应答没这个标志时靠组合特征识别——
            // 单看零计数不够：用完的车道同样没剩余，而那正是最该告警的时刻。
            if let hasQuota = snapshot["has_quota"] as? Bool, !hasQuota { continue }
            if snapshot["has_quota"] == nil, !unlimited, entitlement <= 0,
               (Connectors.number(snapshot["remaining"]) ?? 0) <= 0,
               (Connectors.number(snapshot["percent_remaining"]) ?? 0) >= 100 { continue }
            // 无限车道没有份额可画，与其他平台无限车道同一规则。
            guard !unlimited, let remaining = Connectors.number(snapshot["percent_remaining"]) else { continue }
            var used = max(0, min(100, 100 - remaining))
            // 花完 ≠ 超额：允许超额的车道过了包含份额还能用（按量计费），Copilot 自己的客户端
            // 以 used >= quota && !overageEnabled && !unlimited 判定耗尽。overage_count > 0 反而是
            // 「已经这样花过」的计数，读成已用会给主动付费继续的人画红环。
            // Copilot 自己的客户端以「剩余为 0 且未开超额」判定车道耗尽——平台的裁决语义，标 exhausted。
            let laneExhausted = remaining <= 0 && !(snapshot["overage_permitted"] as? Bool ?? false)
            if laneExhausted { used = 100 }
            s.quotas.append(.init(id: lane.id, title: lane.title, usedPercent: used, resetsAt: resets, exhausted: laneExhausted, windowSeconds: 2_592_000))
        }
        guard !s.quotas.isEmpty else { throw MonitorError.message("该账号未返回 Copilot 额度车道，请确认已开通 Copilot。") }
        let plan = planName(root["copilot_plan"] as? String)
        s.note = "\(plan.map { "\($0) · " } ?? "")接口报剩余已反转为已用；三条车道每月随账号统一重置；允许超额付费的车道剩余为 0 不算耗尽。"
        try s.validate()
        return s
    }

    // GitHub 内部套餐名整理；不认识的透传而不是抹掉——未知名字仍胜过没有。
    static func planName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "individual": return "Individual"
        case "free": return "Free"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        default: return raw
        }
    }

    // "2026-10-01T00:00:00.000Z"，或老应答的裸 "2026-10-01"。
    static func resetDate(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: text) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: text) { return d }
        let plain = DateFormatter()
        plain.locale = Locale(identifier: "en_US_POSIX")
        plain.timeZone = TimeZone(identifier: "UTC")
        plain.dateFormat = "yyyy-MM-dd"
        return plain.date(from: text)
    }
}

