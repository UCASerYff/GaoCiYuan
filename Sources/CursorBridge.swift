import Foundation
import SQLite3



// 阶段 2 新平台桥接集中处：Cursor（编辑器登录态）。只读路线，不发起模型调用、不修改订阅。
enum CursorBridge {
    // Cursor 是 VS Code 系编辑器，自己的 OAuth token 存在 VS Code 全局状态 SQLite 里；
    // 网站用 Cookie 认证而 Cookie 无处可读——它由 token 拼出：账号 id（token sub 的 | 尾段）+ "::" + token。
    // 令牌只用于拼一次请求头，绝不写盘、落日志或展示。测试可注入数据库路径。
    static var databasePath: String = NSHomeDirectory() + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    private static let tokenKey = "cursorAuth/accessToken"
    // 一分钟过期余量：请求飞行中过期的 token 只会被拒，而这里无法续期（Cursor 下次使用时会自己续）。
    private static let expiryHeadroom: TimeInterval = 60

    struct Session { var cookie: String }

    static func session(now: Date = Date()) -> Session? { accessToken().flatMap { session(from: $0, now: now) } }
    static func hasStoredToken() -> Bool { accessToken() != nil }

    // 只读就地打开：Cursor 通常在运行，数据库处于 WAL 模式；拷贝会丢失 journal 里的最新写入，可写打开会动别人的目录。
    static func accessToken(path: String? = nil) -> String? {
        let dbPath = path ?? databasePath
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT value FROM ItemTable WHERE key = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, tokenKey, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        switch sqlite3_column_type(statement, 0) {
        case SQLITE_TEXT:
            return sqlite3_column_text(statement, 0).map { String(cString: $0) }
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(statement, 0) else { return nil }
            return text(in: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
        default:
            return nil
        }
    }

    // 行通常是 TEXT，也见过 BLOB：那是无 BOM 的 UTF-16；按 UTF-8 读会变成每个字符后带一个 NUL，
    // 解析不出任何东西。ASCII 字符第二字节为 0 是识别特征。
    static func text(in data: Data) -> String? {
        if data.count >= 2, data.count.isMultiple(of: 2), data[data.startIndex] != 0,
           data[data.index(after: data.startIndex)] == 0,
           let wide = String(data: data, encoding: .utf16LittleEndian) {
            return wide
        }
        return String(data: data, encoding: .utf8)
    }

    // "auth0|user_abc" —— 账号 id 是竖线后一半；没有竖线的 sub 本身已是 id。
    // %3A%3A 是 :: 的编码，即网站自己设置 Cookie 时的形态。
    static func session(from token: String, now: Date = Date()) -> Session? {
        guard let claims = claims(in: token),
              let subject = claims["sub"] as? String,
              let expiry = Connectors.number(claims["exp"]),
              Date(timeIntervalSince1970: expiry).timeIntervalSince(now) > expiryHeadroom,
              let account = subject.split(separator: "|").last.map(String.init),
              !account.isEmpty else { return nil }
        return Session(cookie: "WorkosCursorSessionToken=\(account)%3A%3A\(token)")
    }

    // JWT 中段：base64URL 且无填充，Data(base64Encoded:) 两种都不直接接受。
    static func claims(in token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var encoded = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return claims
    }

    static func fetch() async throws -> UsageSnapshot {
        // 同步开 sqlite 读编辑器登录态：卸载后台队列，不堵调用方 actor。
        let found = await Task.detached(priority: .userInitiated) { (session(), hasStoredToken()) }.value
        guard let session = found.0 else {
            throw MonitorError.message(found.1
                ? "Cursor 登录态已过期，请打开 Cursor 编辑器完成登录后重试。上次数据已保留。"
                : "未找到本机 Cursor 编辑器登录。请在 Cursor 中登录账号后重试。")
        }
        var request = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
        request.timeoutInterval = 20
        request.setValue(session.cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, http) = try await Connectors.sendOAuth(request)
        switch http.statusCode {
        case 200:
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Connectors.schemaError }
            return try parseUsageSummary(root)
        case 401, 403:
            throw MonitorError.message("Cursor 登录态已被拒绝，请打开 Cursor 编辑器重新登录。上次数据已保留。")
        case 429:
            throw MonitorError.message("平台限流，请稍后刷新（HTTP 429）。上次数据已保留。")
        default:
            throw MonitorError.message("服务不可用（HTTP \(http.statusCode)）。上次数据已保留。")
        }
    }

    static func isoDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }

    // 套餐含两个独立额度池而非一个：autoPercentUsed 是 Cursor 自家模型（Composer、Cursor Grok），
    // apiPercentUsed 是其他模型；第一池花超会吃第二池。**字段是百分比不是分数**：0.0267 是 0.0267%。
    // plan.used/limit 是另一种分母（套餐现金价值），只在完全无池时兜底，绝不与双池并列。
    // plan.remaining 是真余额（美分），不是额度；团队账号 pooled/onDemand 对应个人 plan/onDemand。
    static func parseUsageSummary(_ root: [String: Any]) throws -> UsageSnapshot {
        var s = UsageSnapshot.empty(source: "Cursor 官方账号接口")
        let resets = isoDate(root["billingCycleEnd"] as? String)
        let individual = root["individualUsage"] as? [String: Any]
        let team = root["teamUsage"] as? [String: Any]
        let plan = (individual?["plan"] ?? team?["pooled"]) as? [String: Any]
        let onDemand = (individual?["onDemand"] ?? team?["onDemand"]) as? [String: Any]

        func pool(_ key: String, id: String, title: String) {
            guard let percent = Connectors.number(plan?[key]) else { return }
            s.quotas.append(.init(id: id, title: title, usedPercent: max(0, min(100, percent)), resetsAt: resets, windowSeconds: 2_592_000))
        }
        pool("autoPercentUsed", id: "cursor-models", title: "Cursor Models · 每月")
        pool("apiPercentUsed", id: "cursor-other", title: "Other Models · 每月")

        // 完全无池的账号形态仍有钱：套餐价值与已花。仅兜底使用——有池时它是另一种分母，并列会自相矛盾。
        if s.quotas.isEmpty, let plan,
           let used = Connectors.number(plan["used"]), let limit = Connectors.number(plan["limit"]), limit > 0 {
            s.quotas.append(.init(id: "cursor-plan", title: "Cursor 套餐 · 每月", usedPercent: max(0, min(100, used / limit * 100)), resetsAt: resets, windowSeconds: 2_592_000))
        }
        // 套餐外花费：账号未开启时不画——「0% of nothing」不如没有这一行。
        if let onDemand, onDemand["enabled"] as? Bool != false,
           let used = Connectors.number(onDemand["used"]), let limit = Connectors.number(onDemand["limit"]), limit > 0 {
            s.quotas.append(.init(id: "cursor-ondemand", title: "Cursor · 额外用量", usedPercent: max(0, min(100, used / limit * 100)), resetsAt: resets, windowSeconds: 2_592_000))
        }
        // plan.remaining 是美分计的真余额（Cursor 以美元计价）。
        if let remaining = Connectors.number(plan?["remaining"]) {
            s.balances = [.init(currency: "USD", value: remaining / 100)]
        }
        guard !s.quotas.isEmpty else { throw MonitorError.message("Cursor 未返回可用额度窗口。请确认账号已开通套餐。") }
        s.note = "双额度池与账单周期同步重置；套餐余额为美分换算的真余额，与额度池分母不同不并列。额度比例不等同于固定 Token 余额。"
        try s.validate()
        return s
    }
}

