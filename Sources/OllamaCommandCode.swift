import Foundation
import SQLite3


// MARK: - Ollama Cloud（粘贴 Cookie 读设置页；按公开实现对接，未对真实账号验证）

// 读 https://ollama.com/settings 的 Session usage（5 小时）与 Weekly usage（每周）两个总计。
// 两个窗都必须出现且各只出现一次，歧义/坏百分比 fail closed；缺时间戳保持未知。
// Cookie 只保留认证名，其余（分析、偏好）不出进程；浏览器自动读 cookie 不做（Safari 要
// 完全磁盘访问、Chromium 要泛化 safeStorage），粘贴入口是唯一路线。
enum OllamaBridge {
    static let settingsURL = URL(string: "https://ollama.com/settings")!
    static let maximumBytes = 2 * 1024 * 1024
    // 认证 cookie 名单：wos-session、legacy __Secure-session、NextAuth session-token 及其
    // 编号分块（.0/.1…）。重名保留第一个不是错误：浏览器常同时持有 host-only 与 domain 两行。
    static let keptNames = ["wos-session", "__Secure-session", "__Secure-next-auth.session-token", "next-auth.session-token"]

    static func cookieHeader(from pasted: String) throws -> String {
        guard !pasted.unicodeScalars.contains(where: { $0.value < 32 || $0.value > 126 }) else {
            throw MonitorError.message("Cookie 含有非法字符，请重新复制。")
        }
        var header = pasted.trimmingCharacters(in: .whitespaces)
        if header.lowercased().hasPrefix("cookie:") {
            header = String(header.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        guard !header.isEmpty, header.utf8.count <= 32_768 else {
            throw MonitorError.message("Cookie 格式无法解析，请复制完整的 Cookie 头。")
        }
        var found: [String] = []
        var seen = Set<String>()
        for pair in header.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                throw MonitorError.message("Cookie 格式无法解析，请复制完整的 Cookie 头。")
            }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            let recognized = keptNames.contains { base in
                name == base || (name.hasPrefix(base + ".")
                    && !name.dropFirst(base.count + 1).isEmpty
                    && name.dropFirst(base.count + 1).allSatisfy(\.isNumber))
            }
            guard recognized else { continue }
            guard !value.isEmpty, !value.contains("\""), !value.contains("\\"), !value.contains(" ") else {
                throw MonitorError.message("Cookie 含有非法字符，请重新复制。")
            }
            guard seen.insert(name).inserted else { continue }
            found.append("\(name)=\(value)")
        }
        guard !found.isEmpty else {
            throw MonitorError.message("Cookie 缺少会话项（wos-session 等）。请在 ollama.com 登录后重新复制完整 Cookie 头。")
        }
        return found.joined(separator: "; ")
    }

    static let pageError = MonitorError.message("Ollama 设置页格式不符（需要同时出现 Session 与 Weekly 用量）。页面可能已改版或尚未加载。上次数据已保留。")

    // 纯字符串解析（不引 XML 解析器）：先去 script/style/template，再按文本节点找标签。
    // 标签必须是独立文本节点且全页唯一；百分比从标签之后、另一个标签之前的区域里找
    // 「N% used」独立文本节点，恰好一个才采信。
    static func parsePage(_ data: Data) throws -> UsageSnapshot {
        guard data.count <= maximumBytes, var html = String(data: data, encoding: .utf8),
              !html.localizedCaseInsensitiveContains("<!ENTITY") else { throw pageError }
        if let tidy = try? NSRegularExpression(pattern: #"(?is)<(script|style|template)\b.*?</\1>"#) {
            html = tidy.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "")
        }
        if html.range(of: #"(?i)<form[^>]*action="[^"]*(signin|login)"#, options: .regularExpression) != nil {
            throw MonitorError.message("Ollama 会话已过期，请重新登录 ollama.com 并更新 Cookie。上次数据已保留。")
        }
        var s = UsageSnapshot.empty(source: "Ollama 设置页")
        s.quotas = [
            try window("Session usage", other: "Weekly usage", in: html, id: "ollama-session", title: "Ollama · 5 小时", seconds: 18_000),
            try window("Weekly usage", other: "Session usage", in: html, id: "ollama-weekly", title: "Ollama · 每周", seconds: 604_800),
        ]
        s.note = "读取 ollama.com 设置页的显式总计（% used），两个窗都必须出现；缺重置时间保持未知。按公开实现对接，未对真实账号验证。"
        try s.validate()
        return s
    }

    // 文本节点切分：>(...)< 之间的可见文字。标签与百分比都以独立文本节点为准。
    static func textNodes(in html: String) -> [(text: String, range: Range<String.Index>)] {
        guard let expression = try? NSRegularExpression(pattern: #">([^<]+)<"#) else { return [] }
        return expression.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: html) else { return nil }
            return (String(html[range]), range)
        }
    }

    static func window(_ label: String, other: String, in html: String, id: String, title: String, seconds: Double? = nil) throws -> Quota {
        let nodes = textNodes(in: html)
        let labels = nodes.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == label }
        guard labels.count == 1, let labelNode = labels.first else { throw pageError }
        // 区域：本标签之后，到另一个窗的标签之前（若它更靠后），否则到页尾。
        let regionStart = labelNode.range.upperBound
        let regionEnd = nodes.first(where: {
            $0.range.lowerBound >= regionStart && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == other
        })?.range.lowerBound ?? html.endIndex
        let region = String(html[regionStart..<regionEnd])
        // data-time 至多一个，出现就必须能解析。
        var reset: Date?
        if let timeExpression = try? NSRegularExpression(pattern: #"data-time="([^"]+)""#) {
            let times = timeExpression.matches(in: region, range: NSRange(region.startIndex..., in: region))
                .compactMap { Range($0.range(at: 1), in: region).map { String(region[$0]) } }
            guard times.count <= 1 else { throw pageError }
            if let stamp = times.first {
                guard let date = CursorBridge.isoDate(stamp) else { throw pageError }
                reset = date
            }
        }
        guard let percentExpression = try? NSRegularExpression(
            pattern: #"^\s*([0-9]+(?:\.[0-9]+)?)\s*%\s*used\s*$"#, options: .caseInsensitive) else { throw pageError }
        var values: [Double] = []
        for node in textNodes(in: region) {
            if let match = percentExpression.firstMatch(in: node.text, range: NSRange(node.text.startIndex..., in: node.text)),
               let range = Range(match.range(at: 1), in: node.text), let number = Double(node.text[range]) {
                guard number.isFinite, (0...100).contains(number) else { throw pageError }
                values.append(number)
            }
        }
        guard values.count == 1 else { throw pageError }
        return Quota(id: id, title: title, usedPercent: values[0], resetsAt: reset, windowSeconds: seconds)
    }

    static func fetch(cookieHeader pasted: String) async throws -> UsageSnapshot {
        let cookie = try cookieHeader(from: pasted)
        var request = URLRequest(url: settingsURL)
        request.timeoutInterval = 20
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, http) = try await Connectors.sendOAuth(request)
        switch http.statusCode {
        case 200: break
        case 300..<400, 401, 403:
            throw MonitorError.message("Ollama 会话已过期，请重新登录 ollama.com 并更新 Cookie。上次数据已保留。")
        case 429:
            throw MonitorError.message("平台限流，请稍后刷新（HTTP 429）。上次数据已保留。")
        default:
            throw MonitorError.message("服务不可用（HTTP \(http.statusCode)）。上次数据已保留。")
        }
        return try parsePage(data)
    }
}

// MARK: - Command Code（美元计价账单接口；按公开实现对接，未对真实账号验证）

// api.commandcode.ai 四条 Bearer 路由，与 command-code CLI 自己的 /usage 同序：
// whoami（先单独问，失败即终止）→ credits（失败=整体失败）→ subscriptions（可容忍失败）
// → usage/summary（可容忍；since 原样透传套餐周期起点）。凭证：粘贴 key 优先，
// 其次 ~/.commandcode/auth.json 的 apiKey（不读环境变量、不读 staging/local 变体）。
enum CommandCodeBridge {
    static var authFilePath: String = NSHomeDirectory() + "/.commandcode/auth.json"
    static let host = "https://api.commandcode.ai"

    // 套餐月度授权额（美元/月）：应答只报剩余月度额度、从不报授权额本身，唯一分母来源是
    // 公开价目表（CLI 与 CodexBar 内嵌同一张表）。匹配不上的套餐什么都不画，绝不落余额池兜底。
    static let monthlyCreditsUSD: [String: Double] = [
        "individual-go": 10, "individual-provider": 15, "individual-pro": 30,
        "teams-pro": 40, "individual-pro-v1": 80, "individual-goat": 70,
        "individual-max": 150, "individual-ultra": 300,
    ]

    static func grant(forPlan id: String?) -> Double? {
        guard let id else { return nil }
        return monthlyCreditsUSD[id.lowercased().replacingOccurrences(of: "_", with: "-")]
    }

    static func storedKey(path: String? = nil) -> String? {
        guard let data = FileManager.default.contents(atPath: path ?? authFilePath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = root["apiKey"] as? String, !key.isEmpty else { return nil }
        return key
    }

    // 周期边界可能是 ISO 字符串或 epoch 数字：字符串原样透传；数字按 1e11 界分秒/毫秒，
    // 整数不添小数点。query 是回传给服务的原文，date 是本侧展示用。
    static func stamp(_ value: Any?) -> (query: String, date: Date?)? {
        if let text = value as? String {
            return (text, CursorBridge.isoDate(text))
        }
        guard let n = Connectors.number(value) else { return nil }
        let date = Date(timeIntervalSince1970: abs(n) > 100_000_000_000 ? n / 1000 : n)
        let whole = n == n.rounded() && abs(n) < 9e18
        return (whole ? String(Int64(n)) : String(n), date)
    }

    enum RouteError: Error { case refused, limited, server(Int), unreachable }

    static func get(_ path: String, query: [URLQueryItem], key: String) async throws -> [String: Any] {
        var components = URLComponents(string: host + path)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, http): (Data, HTTPURLResponse)
        do { (data, http) = try await Connectors.sendOAuth(request) }
        catch { throw RouteError.unreachable }
        switch http.statusCode {
        case 200:
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RouteError.unreachable }
            return root
        case 401, 403: throw RouteError.refused
        case 429: throw RouteError.limited
        default: throw RouteError.server(http.statusCode)
        }
    }

    static func message(for error: Error) -> MonitorError {
        switch error as? RouteError {
        case .refused: return MonitorError.message("Command Code 凭证已被拒绝，请检查 API Key 或重新登录 CLI。上次数据已保留。")
        case .limited: return MonitorError.message("平台限流，请稍后刷新（HTTP 429）。上次数据已保留。")
        case .server(let status): return MonitorError.message("服务不可用（HTTP \(status)）。上次数据已保留。")
        default: return MonitorError.message("网络连接失败，请检查网络后重试。上次数据已保留。")
        }
    }

    static func fetch(enteredKey: String?) async throws -> UsageSnapshot {
        guard let key = enteredKey.flatMap({ $0.isEmpty ? nil : $0 }) ?? storedKey() else {
            throw MonitorError.message("未找到 Command Code 凭证。请粘贴 API Key，或在本机用 command-code CLI 登录（cmd auth login）。")
        }
        // whoami 先单独问：它最廉价、裁决 key 好坏，org.id 是其余三路的范围。失败即终止。
        let whoami: [String: Any]
        do { whoami = try await get("/alpha/whoami", query: [.init(name: "limits", value: "1")], key: key) }
        catch { throw message(for: error) }
        let org = (whoami["org"] as? [String: Any])?["id"] as? String
        let orgQuery = org.map { [URLQueryItem(name: "orgId", value: $0)] } ?? []

        // credits 是读数本身，它的失败就是整体的失败。
        let credits: [String: Any]
        do { credits = try await get("/alpha/billing/credits", query: orgQuery, key: key) }
        catch { throw message(for: error) }
        // 无套餐不是失败：按量余额是完整答案，此路允许空手而归。
        let subscription = try? await get("/alpha/billing/subscriptions", query: orgQuery, key: key)
        var summaryQuery = orgQuery
        if let since = stamp((subscription?["data"] as? [String: Any])?["currentPeriodStart"])?.query {
            summaryQuery.append(.init(name: "since", value: since))
        }
        let summary = try? await get("/alpha/usage/summary", query: summaryQuery, key: key)

        return try snapshot(whoami: whoami, credits: credits, subscription: subscription, summary: summary)
    }

    static func snapshot(whoami: [String: Any], credits: [String: Any],
                         subscription: [String: Any]?, summary: [String: Any]?) throws -> UsageSnapshot {
        var s = UsageSnapshot.empty(source: "Command Code 官方接口")
        let creditsNode = credits["credits"] as? [String: Any]
        let subscriptionNode = subscription?["data"] as? [String: Any]
        let periodEnd = stamp(subscriptionNode?["currentPeriodEnd"])?.date

        // 滚动窗：仅 limited == true 才画；used/cap 已是美元花费比（不反转）；resetAt 是 epoch 毫秒。
        if let limits = credits["windowLimits"] as? [String: Any], limits["limited"] as? Bool == true {
            func rolling(_ key: String, id: String, title: String, seconds: Double) -> Quota? {
                guard let node = limits[key] as? [String: Any],
                      let cap = Connectors.number(node["cap"]), cap > 0,
                      let used = Connectors.number(node["used"]) else { return nil }
                let reset = Connectors.number(node["resetAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
                return Quota(id: id, title: title, usedPercent: max(0, min(100, used / cap * 100)), resetsAt: reset, exhausted: used >= cap, windowSeconds: seconds)
            }
            if let q = rolling("fiveHour", id: "commandcode-five-hour", title: "Command Code · 5 小时（$）", seconds: 18_000) { s.quotas.append(q) }
            if let q = rolling("weekly", id: "commandcode-weekly", title: "Command Code · 每周（$）", seconds: 604_800) { s.quotas.append(q) }
        }

        // 组织支出上限（whoami）：spent/limit 美元；limit <= 0 或缺失丢弃（-1 通常是无限，
        // 读成已达上限会给没碰过的账号画满红）；exceeded == true 是账号自己的裁决，钉 100。
        var seen: [String: Int] = [:]
        for case let limit as [String: Any] in (whoami["orgLimits"] as? [Any]) ?? [] {
            guard let ceiling = Connectors.number(limit["limit"]), ceiling > 0,
                  let spent = Connectors.number(limit["spent"]) else { continue }
            let scope = limit["scope"] as? String
            let named = ((limit["modelLabel"] as? String) ?? (limit["model"] as? String))?.trimmingCharacters(in: .whitespaces)
            let model = scope == "model" ? named.flatMap { $0.isEmpty ? nil : $0 } : nil
            let interval = limit["resetInterval"] as? String
            let identity = [scope ?? "org", limit["model"] as? String, interval].compactMap { $0 }.joined(separator: ".")
            let occurrence = seen[identity, default: 0]
            seen[identity] = occurrence + 1
            let exceeded = limit["exceeded"] as? Bool == true
            s.quotas.append(Quota(
                id: "commandcode-org.\(identity)\(occurrence == 0 ? "" : ".\(occurrence)")",
                title: model.map { "\($0) · 支出上限" } ?? "Command Code 组织支出上限",
                usedPercent: exceeded ? 100 : max(0, min(100, spent / ceiling * 100)),
                resetsAt: (limit["resetAt"] as? String).flatMap(CursorBridge.isoDate), exhausted: exceeded))
        }

        // 月度行二选一（绝不并列）：在套餐→授权表估算；不在→三桶余额池，两半都报了才画。
        let planID = [subscriptionNode?["planId"] as? String, creditsNode?["planId"] as? String]
            .compactMap { $0 }.first { !$0.isEmpty }
        let onPlan: Bool
        if subscription == nil {
            onPlan = planID != nil
        } else if subscriptionNode == nil {
            onPlan = false
        } else if let status = subscriptionNode?["status"] as? String {
            onPlan = status.lowercased() == "active"
        } else {
            onPlan = true
        }
        if onPlan {
            // 授权额是公开价目表（估算口径）；匹配不上什么都不画。monthlyCredits 缺失=没有分子不画。
            if let grant = grant(forPlan: planID), grant > 0,
               let reported = Connectors.number(creditsNode?["monthlyCredits"]) {
                let remaining = min(max(reported, 0), grant)
                let used = reported <= 0 ? 100 : max(0, min(100, (grant - remaining) / grant * 100))
                s.quotas.append(.init(id: "commandcode-monthly", title: "Command Code · 每月额度（$·估算）",
                                      usedPercent: used, resetsAt: periodEnd, exhausted: reported <= 0, windowSeconds: 2_592_000))
            }
        } else if let node = creditsNode {
            let pots = [node["monthlyCredits"], node["purchasedCredits"], node["freeCredits"]]
            if pots.contains(where: { Connectors.number($0) != nil }),
               let reportedSpend = Connectors.number(summary?["totalCost"]) {
                let remaining = pots.compactMap { Connectors.number($0) }.reduce(0) { $0 + max(0, $1) }
                let spent = max(0, reportedSpend)
                let pool = remaining + spent
                if pool > 0 {
                    s.quotas.append(.init(id: "commandcode-credits", title: "Command Code 余额池（$）",
                                          usedPercent: remaining <= 0 ? 100 : max(0, min(100, spent / pool * 100)),
                                          resetsAt: periodEnd, exhausted: remaining <= 0, windowSeconds: 2_592_000))
                }
            }
        }

        // 余额：三桶和（美元），任一桶报了才算。
        if let node = creditsNode {
            let pots = [node["monthlyCredits"], node["purchasedCredits"], node["freeCredits"]]
            if pots.contains(where: { Connectors.number($0) != nil }) {
                s.balances = [.init(currency: "USD", value: pots.compactMap { Connectors.number($0) }.reduce(0) { $0 + max(0, $1) })]
            }
        }
        guard !s.quotas.isEmpty else {
            throw MonitorError.message("Command Code 未返回可显示的额度窗口。上次数据已保留。")
        }
        s.note = "\(planID.map { planName($0) + " · " } ?? "")美元计价；月度授权额来自公开价目表（估算口径），匹配不上的套餐不画月度行；exceeded 为真钉满。按公开实现对接，未对真实账号验证。"
        try s.validate()
        return s
    }

    // individual-pro → "Individual Pro"：分词首字母大写，不认识的 id 透传——未知名字仍胜过没有。
    static func planName(_ id: String) -> String {
        id.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }
}
