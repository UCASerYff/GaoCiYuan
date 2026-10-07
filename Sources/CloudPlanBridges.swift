import Foundation
import SQLite3


// MARK: - 火山方舟 Ark Coding Plan（二手证据：按 CodexBar 公开实现对接，未对真实账号验证）

// 两条独立签名接口并行问，一条被拒不算失败（账号可能只持有一种套餐），都失败才报错。
// 签名是 AWS SigV4 变体（service=ark、region 常量 cn-beijing、终结符 request），见 OfficialExtras.arkRequest。
enum VolcArkBridge {
    static func fetch(id: String, secret: String) async throws -> UsageSnapshot {
        var quotas: [Quota] = []
        var answered = false
        var firstError: Error?
        do {
            quotas += try parseCodingPlan(await Connectors.send(OfficialExtras.arkRequest(id: id, secret: secret, action: "GetCodingPlanUsage")))
            answered = true
        } catch { firstError = error }
        do {
            quotas += try parseAFP(await Connectors.send(OfficialExtras.arkRequest(id: id, secret: secret, action: "GetAFPUsage")))
            answered = true
        } catch { if !answered, firstError == nil { firstError = error } }
        guard answered else { throw firstError ?? Connectors.schemaError }
        var s = UsageSnapshot.empty(source: "火山方舟官方签名 API")
        s.quotas = quotas
        guard !s.quotas.isEmpty else { throw MonitorError.message("火山方舟未返回有效额度窗口（账号可能未开通 Coding Plan / Agent Plan）。上次数据已保留。") }
        s.note = "按公开实现对接，未对真实账号验证。Coding Plan 与 Agent Plan 两条接口独立查询，一条被拒不丢另一条；Quota 为 0 是未开通该窗不是已用满；AFPDaily 不映射。"
        try s.validate()
        return s
    }

    // Result.QuotaUsage[]{Level,Percent,ResetTimestamp}：Percent 是已用（不反转）；
    // 回收的套餐应答带 Status 而无 QuotaUsage——那是「没有可报的」，不是格式错误。
    static func parseCodingPlan(_ body: [String: Any]) throws -> [Quota] {
        if let meta = body["ResponseMetadata"] as? [String: Any], meta["Error"] != nil { throw Connectors.schemaError }
        guard let result = body["Result"] as? [String: Any] else { throw Connectors.schemaError }
        guard let rows = result["QuotaUsage"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let level = row["Level"] as? String, let label = arkWindowLabel(level),
                  let percent = Connectors.number(row["Percent"]) else { return nil }
            let ws: Double? = ["5 小时": 18_000, "每周": 604_800, "每月": 2_592_000][label]
            return Quota(id: "volc-coding-\(label)", title: "方舟 Coding Plan · \(label)",
                         usedPercent: max(0, min(100, percent)),
                         resetsAt: arkTimestamp(row["ResetTimestamp"]), windowSeconds: ws)
        }
    }

    // Result{AFPFiveHour,AFPWeekly,AFPMonthly}{Quota,Used,ResetTime}；AFPDaily 存在但刻意不映射
    // （arkcli 路也不暴露它，两条路不能给出不同答案）。Quota 为 0 是没有该窗，不是满了。
    static func parseAFP(_ body: [String: Any]) throws -> [Quota] {
        if let meta = body["ResponseMetadata"] as? [String: Any], meta["Error"] != nil { throw Connectors.schemaError }
        guard let result = body["Result"] as? [String: Any] else { throw Connectors.schemaError }
        let lanes: [(key: String, id: String, label: String, ws: Double)] = [
            ("AFPFiveHour", "volc-afp-5h", "5 小时", 18_000),
            ("AFPWeekly", "volc-afp-weekly", "每周", 604_800),
            ("AFPMonthly", "volc-afp-monthly", "每月", 2_592_000),
        ]
        return lanes.compactMap { lane in
            guard let node = result[lane.key] as? [String: Any],
                  let quota = Connectors.number(node["Quota"]), quota > 0,
                  let used = Connectors.number(node["Used"]) else { return nil }
            return Quota(id: lane.id, title: "方舟 Agent Plan · \(lane.label)",
                         usedPercent: max(0, min(100, used / quota * 100)),
                         resetsAt: arkTimestamp(node["ResetTime"]), windowSeconds: lane.ws)
        }
    }

    // 标签映射表之外的丢弃而不是猜：一个账号可持四种套餐，说不清是哪个窗不如没有。
    static func arkWindowLabel(_ level: String) -> String? {
        switch level.lowercased() {
        case "5h", "5-hour", "five_hour", "session": return "5 小时"
        case "weekly", "week": return "每周"
        case "monthly", "month": return "每月"
        default: return nil
        }
    }

    // 秒与毫秒按量级区分（1e12 秒是公元三万年，1e12 毫秒是 2001 年，真值不会靠近边界）。
    static func arkTimestamp(_ value: Any?) -> Date? {
        guard let n = Connectors.number(value), n > 0 else { return nil }
        return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
    }
}

// MARK: - 小米 MiMo Coding Plan（二手证据：按 CodexBar 公开实现对接，未对真实账号验证）

// 浏览器会话借用（粘贴 Cookie 头）：platform.xiaomimimo.com 控制台自用路由，平台发的 API Key
// 买的是推理，答不了这些路由。信封 {code,message,data} 全走 HTTP 200，code 401/403 与 3xx 都是
// 会话过期（过期登录会把 API 重定向去登录流）。usage 失败=整体失败，detail/balance 失败只少行。
enum XiaomiBridge {
    // 只保留认证所需的名字，其余（分析、偏好、以及网站以后加的任何 cookie）不出进程。
    // 重名取第一个不是错误：浏览器常同时持有 host-only 与 domain 两行。
    static let keptNames = ["api-platform_serviceToken", "userId", "api-platform_ph", "api-platform_slh"]

    static func cookieHeader(from pasted: String) throws -> String {
        var text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("cookie:") { text = String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        var found: [String: String] = [:]
        for pair in text.split(separator: ";") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let name = pair[..<eq].trimmingCharacters(in: .whitespaces)
            let value = String(pair[pair.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard keptNames.contains(name), found[name] == nil else { continue }
            // 值里带控制字符就是头部注入，整个拒绝而不是修剪。
            guard !value.isEmpty, value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
                throw MonitorError.message("Cookie 值含有非法字符，请重新复制。")
            }
            found[name] = value
        }
        guard found["api-platform_serviceToken"] != nil, found["userId"] != nil else {
            throw MonitorError.message("Cookie 缺少必需项 api-platform_serviceToken 或 userId。请在 platform.xiaomimimo.com 登录后重新复制完整 Cookie 头。")
        }
        return keptNames.compactMap { name in found[name].map { "\(name)=\( $0)" } }.joined(separator: "; ")
    }

    static func get(_ path: String, cookie: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "https://platform.xiaomimimo.com/api/v1/\(path)")!)
        request.timeoutInterval = 20
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await Connectors.sendOAuth(request)
    }

    static func fetch(cookieHeader: String) async throws -> UsageSnapshot {
        // usage 是额度的来源，它的失败就是整体的失败。
        let (usageData, usageHTTP) = try await get("tokenPlan/usage", cookie: cookieHeader)
        let usage = try envelope(usageData, http: usageHTTP)
        var s = try parseUsage(usage)
        // detail 带重置时间与套餐名，缺了行照样画。
        if let (data, http) = try? await get("tokenPlan/detail", cookie: cookieHeader),
           let detail = try? envelope(data, http: http) {
            apply(detail, to: &s)
        }
        if s.quotas.first?.resetsAt == nil, s.note == nil { s.note = "按公开实现对接，未对真实账号验证。" }
        // balance 只是卡上的一行钱，它的失败只少这一行。
        if let (data, http) = try? await get("balance", cookie: cookieHeader),
           let body = try? envelope(data, http: http),
           let balance = body["data"] as? [String: Any],
           let value = Connectors.number(balance["balance"]),
           let currency = (balance["currency"] as? String)?.uppercased(), currency.count == 3 {
            s.balances = [.init(currency: currency, value: value)]
        }
        try s.validate()
        return s
    }

    // 信封在 200 里回答：3xx 与 code 401/403 都是会话过期；其余非零 code 是服务故障，
    // 读成「无套餐」会把服务器毛病报成订阅状态。
    static func envelope(_ data: Data, http: HTTPURLResponse) throws -> [String: Any] {
        if (300..<400).contains(http.statusCode) || http.statusCode == 401 || http.statusCode == 403 {
            throw MonitorError.message("小米 MiMo 会话已过期，请重新登录 platform.xiaomimimo.com 并更新 Cookie。上次数据已保留。")
        }
        guard http.statusCode == 200, let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Connectors.schemaError }
        if let code = Connectors.number(body["code"]) {
            if code == 401 || code == 403 {
                throw MonitorError.message("小米 MiMo 会话已过期，请重新登录 platform.xiaomimimo.com 并更新 Cookie。上次数据已保留。")
            }
            guard code == 0 else { throw MonitorError.message("小米 MiMo 服务暂不可用（状态码 \(Int(code))）。上次数据已保留。") }
        }
        return body
    }

    // monthUsage.items 第一桶是套餐额度；空列表是「按量付费、无套餐」的完整答案，不是故障，
    // 画成 0% 等于报一个没人拥有的满月。
    static func parseUsage(_ body: [String: Any]) throws -> UsageSnapshot {
        guard let data = body["data"] as? [String: Any],
              let month = data["monthUsage"] as? [String: Any],
              let items = month["items"] as? [[String: Any]] else { throw Connectors.schemaError }
        guard let first = items.first else {
            throw MonitorError.message("该小米账号没有 MiMo Coding Plan（按 Token 按量付费的账号）。上次数据已保留。")
        }
        let usedPercent: Double
        if let limit = Connectors.number(first["limit"]), limit > 0, let used = Connectors.number(first["used"]) {
            usedPercent = max(0, min(100, used / limit * 100))
        } else if let percent = Connectors.number(first["percent"]) {
            usedPercent = max(0, min(100, percent))
        } else { throw Connectors.schemaError }
        var s = UsageSnapshot.empty(source: "小米 MiMo 官方控制台接口")
        s.quotas = [.init(id: "mimo-coding-monthly", title: "MiMo Coding Plan · 每月", usedPercent: usedPercent, resetsAt: nil, windowSeconds: 2_592_000)]
        s.note = "按公开实现对接，未对真实账号验证。"
        return s
    }

    // detail：planCode 作套餐名；currentPeriodEnd（"2026-10-01 00:00:00" 本地墙钟）作重置；
    // expired 的套餐会一直报上月数字——那不是当前额度，什么都不画。
    static func apply(_ body: [String: Any], to s: inout UsageSnapshot) {
        guard let data = body["data"] as? [String: Any] else { return }
        if data["expired"] as? Bool == true {
            s.quotas = []
            s.note = "MiMo Coding Plan 已过期，显示的上月数字不是当前额度。按公开实现对接，未对真实账号验证。"
            return
        }
        if let end = data["currentPeriodEnd"] as? String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            if let date = f.date(from: end) { s.quotas = s.quotas.map { Quota(id: $0.id, title: $0.title, usedPercent: $0.usedPercent, resetsAt: date, windowSeconds: $0.windowSeconds) } }
        }
        if let plan = (data["planCode"] as? String)?.trimmingCharacters(in: .whitespaces), !plan.isEmpty {
            s.note = "\(plan) · 按公开实现对接，未对真实账号验证。"
        }
    }
}

