import Foundation

// 自定义 API 计费账户桥（3.3）：GET 用户给的余额查询地址，按点分 JSON 路径（支持 a.b[0].c 数组下标）
// 取余额数字。鉴权：无 / Bearer Token / 自定义请求头；token 与头值只存本机钥匙串（KeyVault），
// 只出现在请求头，绝不落盘、不写日志、不进任何展示文本与错误文案。
enum CustomBridge {

    // MARK: - 点分路径解析（纯函数，便于测试）

    /// 「data.biz_data.normal_wallets[0].balance」→ ["data","biz_data","normal_wallets",0,"balance"]。
    /// 非法路径（空段、下标非负整数以外的内容）抛错，保存表单与取数共用同一校验。
    enum PathSegment: Equatable { case key(String), index(Int) }
    static func parsePath(_ path: String) throws -> [PathSegment] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MonitorError.message("请填写余额字段路径（如 data.balance）。") }
        var segments: [PathSegment] = []
        for part in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            var s = part
            // 尾部的 [n] 下标（可多个连用，如 matrix[0][1]）
            var indexes: [Int] = []
            while s.hasSuffix("]"), let open = s.lastIndex(of: "[") {
                let num = s[s.index(after: open)..<s.index(before: s.endIndex)]
                guard let i = Int(num), i >= 0, i < 100_000 else { throw MonitorError.message("字段路径的数组下标无效：\(path)") }
                indexes.insert(i, at: 0)
                s = s[..<open]
            }
            if !s.isEmpty {
                segments.append(.key(String(s)))
            } else if indexes.isEmpty {
                throw MonitorError.message("字段路径包含空段：\(path)")
            }
            for i in indexes { segments.append(.index(i)) }
        }
        guard !segments.isEmpty else { throw MonitorError.message("请填写余额字段路径（如 data.balance）。") }
        return segments
    }

    /// 按路径在 JSON 对象树里取值；任何一段类型不符即 nil（不编造）。
    static func value(at segments: [PathSegment], in json: Any) -> Any? {
        var current = json
        for seg in segments {
            switch seg {
            case .key(let k):
                guard let dict = current as? [String: Any], let next = dict[k] else { return nil }
                current = next
            case .index(let i):
                guard let arr = current as? [Any], i < arr.count else { return nil }
                current = arr[i]
            }
        }
        return current
    }

    // MARK: - 取数

    static func fetch(_ account: Account, userInitiated: Bool = false, keyOverride: String? = nil) async throws -> ConnectorResult {
        // 与既有本机桥一致：自动轮询 5 分钟节流（手动同步不受限）。
        if !userInitiated, let last = account.lastAttempt, Date().timeIntervalSince(last) < 300 {
            return .status("距上次同步不足 5 分钟，本次沿用上次数据。")
        }
        guard let config = account.customConfig else { throw MonitorError.message("请先在账户设置中完善自定义 API 配置。") }
        guard let url = URL(string: config.url.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme ?? ""), url.host != nil else {
            throw MonitorError.message("余额查询 URL 无效，请在账户设置中检查。上次数据已保留。")
        }
        let segments = try parsePath(config.fieldPath)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if config.auth != "none" {
            let key = keyOverride.flatMap { $0.isEmpty ? nil : $0 } ?? (try? KeyVault.read(account.id))
            guard let key, !key.isEmpty else { throw MonitorError.message("请在账户设置中保存鉴权凭证（token 或请求头值）。上次数据已保留。") }
            if config.auth == "bearer" {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            } else {
                let name = config.headerName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw MonitorError.message("请填写自定义请求头的头名。上次数据已保留。") }
                request.setValue(key, forHTTPHeaderField: name)
            }
        }
        // 走共享会话：NoRedirect 委托（凭证不随重定向外泄）+ 25s/45s 超时。
        let (data, response) = try await Connectors.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Connectors.schemaError }
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401, 403:
                throw MonitorError.message("自定义 API 凭证已被拒绝（HTTP \(http.statusCode)）。请检查 token 或请求头值。上次数据已保留。")
            case 429:
                throw MonitorError.message("接口限流，请稍后刷新（HTTP 429）。上次数据已保留。")
            default:
                throw MonitorError.message("查询失败（HTTP \(http.statusCode)）。上次数据已保留。")
            }
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { throw Connectors.schemaError }
        guard let raw = value(at: segments, in: json), let balance = Connectors.number(raw) else {
            throw MonitorError.message("字段路径未取到数字（路径或响应结构可能有变化）。上次数据已保留。")
        }
        var s = UsageSnapshot.empty(source: "自定义 API")
        s.balances = [Money(currency: account.currency, value: balance)]
        let second = config.secondPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !second.isEmpty, let segs = try? parsePath(second), let raw2 = value(at: segs, in: json), let v2 = Connectors.number(raw2) {
            s.note = "附加余额 \(unitText(config.unit, v2))"
        }
        try s.validate()
        return .snapshot(s)
    }

    // MARK: - 展示辅助（账户卡 / 悬浮条 / 详情卡共用，口径唯一来源）

    /// 单位拼接：货币符号（¥$€£）前缀，其余文本后缀。如 ¥9.99 / 856 积分 / 12.5 tokens。
    static func unitText(_ unit: String, _ value: Double) -> String {
        let u = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = value.formatted(.number.precision(.fractionLength(0...2)).grouping(.automatic))
        if u.isEmpty { return number }
        if u.count <= 2, u.allSatisfy({ "¥$€£₩฿".contains($0) }) { return u + number }
        return number + " " + u
    }

    /// 悬浮条环下紧凑数字（含单位）：只许截断不许四舍五入，永远不多报。
    /// ≥100 去小数、≥10 一位、<10 两位；符号前缀、文字后缀。
    static func compactText(_ unit: String, _ value: Double) -> String {
        let abs = Swift.abs(value)
        let decimals = abs >= 100 ? 0 : abs >= 10 ? 1 : 2
        let factor = pow(10.0, Double(decimals))
        let truncated = (value * factor).rounded(.towardZero) / factor
        let number = String(format: "%.\(decimals)f", truncated)
        let u = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.isEmpty { return number }
        if u.count <= 2, u.allSatisfy({ "¥$€£₩฿".contains($0) }) { return u + number }
        return number + u
    }
}
