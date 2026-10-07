import Foundation

// DeepSeek Harness（dsh）本机凭证桥：只读 ~/.dsh/.credentials.yaml 中
// records["deepseek-account-platform/default"].payload 的 issuer 与 token 两行
// （缩进块扫描，不引 YAML 库），经平台官方接口按量查询钱包余额、赠金与累计消费。
// token 只出现在请求头，绝不落盘、不写日志、不进任何展示文本。
enum DshBridge {
    struct Credentials {
        var issuer: String
        var token: String
    }

    static let topUpURL = "https://harness.deepseek.com/top_up"

    static var credentialsURL: URL {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home + "/.dsh/.credentials.yaml")
    }

    /// 凭证是否存在且可解析（自动接入检测用；只读文件，不触网）。
    static func credentialsAvailable() -> Bool { (try? readCredentials()) != nil }

    /// 解析凭证文件。失败一律抛 neutral 短语（「未找到本机…」家族）：
    /// 没装/没登录/格式变了都不是故障，不计连续失败。
    static func readCredentials() throws -> Credentials {
        guard let text = try? String(contentsOf: credentialsURL, encoding: .utf8) else {
            throw MonitorError.message("未找到本机 DeepSeek Harness 登录凭证。请安装并登录 DeepSeek Harness 后重试。")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains("deepseek-account-platform/default:") }) else {
            throw MonitorError.message("未找到本机 DeepSeek Harness 登录凭证（凭证文件缺少默认账号记录）。请打开一次 DeepSeek Harness 并登录后重试。")
        }
        let recordIndent = indentation(of: lines[start])
        var issuer: String?, token: String?
        for line in lines.dropFirst(start + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // 缩进回到记录键同级或更浅 = 该记录块结束。
            if indentation(of: line) <= recordIndent { break }
            if issuer == nil { issuer = scalarValue(of: trimmed, key: "issuer") }
            if token == nil { token = scalarValue(of: trimmed, key: "token") }
            if issuer != nil && token != nil { break }
        }
        guard let issuer, let token, !token.isEmpty else {
            throw MonitorError.message("未找到本机 DeepSeek Harness 登录凭证（凭证文件格式无法解析）。请打开一次 DeepSeek Harness 并登录后重试。")
        }
        // issuer 必须指向平台官方 https 主机：凭证文件被改动也不许把 token 发到别处。
        guard let url = URL(string: issuer), url.scheme == "https", url.host == "platform.deepseek.com" else {
            throw MonitorError.message("未找到本机 DeepSeek Harness 登录凭证（凭证中的服务地址不是官方主机）。请重新登录 DeepSeek Harness 后重试。")
        }
        return Credentials(issuer: issuer, token: token)
    }

    private static func indentation(of line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    /// 形如「issuer: https://…」的 YAML 单行标量；值不含空白，取不到为 nil。
    private static func scalarValue(of trimmedLine: String, key: String) -> String? {
        guard trimmedLine.hasPrefix(key + ":") else { return nil }
        let value = trimmedLine.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    // MARK: - 取数

    static func fetch(_ account: Account, userInitiated: Bool = false) async throws -> ConnectorResult {
        // 钱包余额不是秒级指标：自动轮询 5 分钟节流（手动同步不受限），与既有本机桥一致。
        if !userInitiated, let last = account.lastAttempt, Date().timeIntervalSince(last) < 300 {
            return .status("距上次同步不足 5 分钟，本次沿用上次数据。")
        }
        let credentials = try readCredentials()
        let summary = try await get("/api/v0/users/get_user_summary", credentials)
        return .snapshot(try parseSummary(summary))
    }

    /// GET 平台官方接口。请求头：x-dsh-auth-token + Accept + User-Agent（平台对无 UA 请求回 429，实测口径）。
    /// 传输走 Connectors.sendOAuth：https + 官方 host 白名单 + NoRedirect + 瞬时重试；token 只在请求头。
    private static func get(_ path: String, _ credentials: Credentials) async throws -> [String: Any] {
        guard let url = URL(string: credentials.issuer + path) else { throw Connectors.schemaError }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(credentials.token, forHTTPHeaderField: "x-dsh-auth-token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("dsh-desktop/0.1.7", forHTTPHeaderField: "User-Agent")
        let (data, http) = try await Connectors.sendOAuth(request)
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401, 403:
                throw MonitorError.message("DeepSeek Harness 登录已过期或凭证已被拒绝。请在 DeepSeek Harness 中重新登录。（HTTP \(http.statusCode)）。上次数据已保留。")
            case 429:
                throw MonitorError.message("平台限流，请稍后刷新（HTTP 429）。上次数据已保留。")
            default:
                throw MonitorError.message("服务不可用（HTTP \(http.statusCode)）。上次数据已保留。")
            }
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Connectors.schemaError }
        return object
    }

    /// 信封 {code, msg, data:{biz_code, biz_data:{…}}}：余额在 biz_data.normal_wallets，
    /// 赠金 bonus_wallets、累计消费 total_costs；金额是大数字符串，按 Double 解析。
    /// 快照语义：balances 只放正常钱包（「余额」语义纯净）；赠金与累计消费进 note
    /// （balances 有币种唯一约束，赠金同为 CNY 不能并列；累计消费不进 costs——没有统计期）。
    static func parseSummary(_ object: [String: Any]) throws -> UsageSnapshot {
        guard Connectors.number(object["code"]) == 0,
              let data = object["data"] as? [String: Any],
              Connectors.number(data["biz_code"]) == 0,
              let biz = data["biz_data"] as? [String: Any] else { throw Connectors.schemaError }
        guard let normal = biz["normal_wallets"] as? [[String: Any]], !normal.isEmpty else { throw Connectors.schemaError }
        var s = UsageSnapshot.empty(source: "DeepSeek Harness 官方接口")
        s.balances = try normal.map { wallet in
            guard let currency = wallet["currency"] as? String, let value = Connectors.number(wallet["balance"]) else { throw Connectors.schemaError }
            return Money(currency: currency.uppercased(), value: value)
        }
        var parts: [String] = []
        if let bonus = biz["bonus_wallets"] as? [[String: Any]] {
            for wallet in bonus {
                guard let currency = wallet["currency"] as? String, let value = Connectors.number(wallet["balance"]) else { throw Connectors.schemaError }
                parts.append("赠金 \(Money(currency: currency.uppercased(), value: value).text)")
            }
        }
        if let costs = biz["total_costs"] as? [[String: Any]] {
            for wallet in costs {
                guard let currency = wallet["currency"] as? String, let value = Connectors.number(wallet["amount"]) else { throw Connectors.schemaError }
                parts.append("累计消费 \(Money(currency: currency.uppercased(), value: value).text)")
            }
        }
        if !parts.isEmpty { s.note = parts.joined(separator: " · ") }
        try s.validate()
        return s
    }

    // MARK: - 展示辅助（账户卡与悬浮条共用，文案口径唯一来源）

    /// 大号余额文本：¥ + 最多 4 位小数（Money.text 同款精度）。
    static func balanceText(_ money: Money) -> String {
        "¥" + money.value.formatted(.number.precision(.fractionLength(2...4)))
    }

    /// 悬浮条胶囊徽章的紧凑数字：余额只许截断不许四舍五入（永远不多报钱）。
    /// ≥100 去小数、≥10 一位、<10 两位。
    static func compactBalance(_ value: Double) -> String {
        let abs = Swift.abs(value)
        let decimals = abs >= 100 ? 0 : abs >= 10 ? 1 : 2
        let factor = pow(10.0, Double(decimals))
        let truncated = (value * factor).rounded(.towardZero) / factor
        return String(format: "%.\(decimals)f", truncated)
    }

    /// note 按「 · 」拆成展示行（赠金 / 累计消费），账户卡与详情卡逐行渲染。
    static func noteParts(_ note: String?) -> [String] {
        (note ?? "").split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
