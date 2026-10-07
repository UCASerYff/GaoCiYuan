import Foundation
import SQLite3


// MARK: - Devin（本机保存 plan + 账单 API，两路独立绝不交叉回退）

// Devin 是 Cognition 的 agent，Devin.app 即改名后的 Windsurf 编辑器（bundle id 仍是
// com.exafunction.windsurf，所有键仍以 windsurf. 开头）。本机路读它启动时写入
// state.vscdb 的套餐缓存：报的是**剩余**百分比。API 路报的是**已用**百分比——两条路
// 方向相反，绝不能共用解析。凭证路属于一个组织，缓存路只属于一个用户、说不出组织，
// 所以两路是账户设置里两个独立连接，失败绝不向对方回退。按公开实现对接，未对真实账号验证。
enum DevinBridge {
    // 测试可注入的支持目录根；生产是 ~/Library/Application Support。
    static var supportRoot: String = NSHomeDirectory() + "/Library/Application Support"
    // 改名前后的两个目录名都在找；都存在时取 state.vscdb 修改时间较新的。
    static let supportDirectoryNames = ["Devin", "Windsurf"]
    // 当前键在前；旧名（CodexBar 笔记里的形态）用 LIKE 顺带查，成本为零。
    static let planKeyPatterns = ["windsurf.reactSettings.cachedPlanInfoData%", "windsurf.settings.cachedPlanInfo%"]
    // 缓存行只在应用启动时写入：超过 24 小时的观测不报，缺写入时间也不报。
    static let snapshotMaxAge: TimeInterval = 24 * 3600

    struct Plan {
        var planName: String?
        var dailyRemainingPercent: Double?
        var weeklyRemainingPercent: Double?
        var dailyResetAtUnix: Double?
        var weeklyResetAtUnix: Double?
        var hideDailyQuota = false
        var hideWeeklyQuota = false
        var remainingMessages: Int?
        var totalMessages: Int?
        var overageBalanceMicros: Double?
        var endTimestamp: Double?

        init?(json data: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            planName = (object["planName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            dailyRemainingPercent = Connectors.number(object["dailyRemainingPercent"])
            weeklyRemainingPercent = Connectors.number(object["weeklyRemainingPercent"])
            dailyResetAtUnix = Connectors.number(object["dailyResetAtUnix"])
            weeklyResetAtUnix = Connectors.number(object["weeklyResetAtUnix"])
            hideDailyQuota = object["hideDailyQuota"] as? Bool ?? false
            hideWeeklyQuota = object["hideWeeklyQuota"] as? Bool ?? false
            remainingMessages = Connectors.number(object["remainingMessages"]).map(Int.init)
            totalMessages = Connectors.number(object["totalMessages"]).map(Int.init)
            overageBalanceMicros = Connectors.number(object["overageBalanceMicros"])
            endTimestamp = Connectors.number(object["endTimestamp"])
        }
    }

    static func supportDirectory(root: String? = nil) -> URL? {
        let base = URL(fileURLWithPath: root ?? supportRoot)
        let manager = FileManager.default
        return supportDirectoryNames
            .map { base.appendingPathComponent($0) }
            .filter { manager.fileExists(atPath: $0.appendingPathComponent("User/globalStorage/state.vscdb").path) }
            .max { (modified($0) ?? .distantPast) < (modified($1) ?? .distantPast) }
    }

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    // 只读就地打开（应用可能在运行，journal 属于它）。多行取 endTimestamp 最大者——
    // 活跃套餐总比已失效的行看得远。
    static func plan(in file: URL) -> Plan? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }
        var found: [Plan] = []
        for pattern in planKeyPatterns {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "SELECT value FROM ItemTable WHERE key LIKE ?", -1, &statement, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(statement, 1, pattern, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let bytes = sqlite3_column_text(statement, 0),
                      let parsed = Plan(json: Data(String(cString: bytes).utf8)) else { continue }
                found.append(parsed)
            }
            sqlite3_finalize(statement)
            if !found.isEmpty { break }
        }
        return found.max { ($0.endTimestamp ?? 0) < ($1.endTimestamp ?? 0) }
    }

    // 观测时间取 logs/ 下目录名（每次启动建一个，名字即本地墙钟启动时间 20260914T092003）。
    // 不用数据库修改时间：文件里其他键一直在写，会把早晨的读数伪装成上一秒的。
    static func lastLaunch(in support: URL) -> Date? {
        let logs = support.appendingPathComponent("logs")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: logs, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        return entries.compactMap { entry -> Date? in
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            return launchStamp(entry.lastPathComponent)
        }.max()
    }

    static func launchStamp(_ name: String) -> Date? {
        guard name.count == 15 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.isLenient = false
        guard let date = formatter.date(from: name), formatter.string(from: date) == name else { return nil }
        return date
    }

    // 付费形态：remaining 型百分比 → used = 100 − x；−1 是「不适用」不是数字，丢弃。
    // 重置已过的窗属于已不存在的窗口，丢弃而不是展示。隐藏标志由套餐自己声明。
    static func quotas(from plan: Plan, now: Date = Date()) -> [Quota] {
        var quotas: [Quota] = []
        func window(id: String, title: String, remaining: Double?, resetAt: Double?, seconds: Double) -> Quota? {
            guard let remaining, remaining >= 0 else { return nil }
            let resets = resetAt.map { Date(timeIntervalSince1970: $0) }
            guard (resets ?? .distantFuture) > now else { return nil }
            return Quota(id: id, title: title, usedPercent: max(0, min(100, 100 - remaining)), resetsAt: resets, windowSeconds: seconds)
        }
        if !plan.hideDailyQuota,
           let q = window(id: "devin-daily", title: "Devin · 每日", remaining: plan.dailyRemainingPercent, resetAt: plan.dailyResetAtUnix, seconds: 86_400) { quotas.append(q) }
        if !plan.hideWeeklyQuota,
           let q = window(id: "devin-weekly", title: "Devin · 每周", remaining: plan.weeklyRemainingPercent, resetAt: plan.weeklyResetAtUnix, seconds: 604_800) { quotas.append(q) }
        // 免费形态：消息额度。任一端为负是付费套餐的「不适用」标记，不是计数。
        if let total = plan.totalMessages, let remaining = plan.remainingMessages, total > 0, remaining >= 0 {
            quotas.append(Quota(id: "devin-messages", title: "Devin 消息额度",
                                usedPercent: max(0, min(100, Double(total - remaining) / Double(total) * 100)), resetsAt: nil))
        }
        return quotas
    }

    static func fetchLocal(now: Date = Date()) throws -> UsageSnapshot {
        guard let support = supportDirectory() else {
            throw MonitorError.message("未找到本机 Devin 应用数据。请确认已安装并登录过 Devin（或 Windsurf）。")
        }
        let database = support.appendingPathComponent("User/globalStorage/state.vscdb")
        guard let plan = plan(in: database) else {
            throw MonitorError.message("未能读取 Devin 保存的套餐缓存。请打开一次 Devin 后重试。上次数据已保留。")
        }
        guard let launched = lastLaunch(in: support), launched <= now,
              now.timeIntervalSince(launched) <= snapshotMaxAge else {
            throw MonitorError.message("Devin 套餐缓存缺少可靠的写入时间或已超过 24 小时。请打开一次 Devin 后重试。上次数据已保留。")
        }
        var s = UsageSnapshot.empty(source: "Devin 本机缓存")
        s.observedAt = launched
        s.quotas = quotas(from: plan, now: now)
        if let micros = plan.overageBalanceMicros {
            s.balances = [.init(currency: "USD", value: micros / 1_000_000)]
        }
        guard !s.quotas.isEmpty || !s.balances.isEmpty else {
            throw MonitorError.message("Devin 缓存未报告任何额度窗口。上次数据已保留。")
        }
        s.note = "\((plan.planName?.isEmpty == false ? plan.planName! + " · " : ""))缓存为 Devin 启动时写入的快照，观测时间即最近一次启动；重置已过的窗口已丢弃；缓存报剩余已反转为已用。按公开实现对接，未对真实账号验证。"
        try s.validate()
        return s
    }

    // MARK: 账单 API（粘贴凭证）

    // 一个字段空白分隔「token 组织」：兼容整行 Authorization: Bearer … 头与
    // app.devin.ai 组织设置页地址。org_…/org-… 是内部 id → organizations/<id>，其余是
    // 地址栏里的 slug → org/<slug>；两种拼法轮流试，token 被拒（401/403）不重试。
    struct Credential {
        var token: String
        var organization: String?

        init?(pasted: String?) {
            var text = pasted?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return nil }
            if let colon = text.firstIndex(of: ":"),
               text[text.startIndex..<colon].lowercased() == "authorization" {
                text = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if text.lowercased().hasPrefix("bearer ") {
                text = String(text.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let first = parts.first, !first.isEmpty else { return nil }
            token = first
            organization = parts.dropFirst().first.flatMap(Self.normalize)
        }

        static func isInternalID(_ value: String) -> Bool {
            value.hasPrefix("org_") || value.hasPrefix("org-")
        }

        static func normalize(_ raw: String) -> String? {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            if let url = URL(string: value), let host = url.host()?.lowercased(),
               host == "devin.ai" || host.hasSuffix(".devin.ai") {
                let segments = url.path.split(separator: "/").map(String.init)
                if segments.count >= 2, segments[0] == "org" || segments[0] == "organizations" {
                    value = "\(segments[0])/\(segments[1])"
                }
            }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !value.isEmpty else { return nil }
            if value.hasPrefix("org/") || value.hasPrefix("organizations/") { return value }
            return isInternalID(value) ? "organizations/\(value)" : "org/\(value)"
        }

        var internalID: String? {
            guard let organization, organization.hasPrefix("organizations/") else { return nil }
            return String(organization.dropFirst("organizations/".count))
        }

        // 路径段的确切形状是这条未文档化接口里最不确定的部分：一种拼法 404 换下一个，
        // 而不是直接报「无配额」。
        var paths: [String] {
            guard let organization else { return [] }
            var paths = [organization]
            if let internalID { paths.insert(internalID, at: 0) }
            if organization.hasPrefix("org/") {
                let slug = String(organization.dropFirst(4))
                paths.append(slug)
                if Self.isInternalID(slug) { paths.append("organizations/\(slug)") }
            }
            var seen = Set<String>()
            return paths.filter { seen.insert($0).inserted }
        }
    }

    // 应答与本机缓存**方向相反**：daily_percentage/weekly_percentage 是已用（不反转），
    // snake_case 命名；has_quota_allocation == false 是什么都不画（旧额度套餐或已失效）。
    static func parseQuotaUsage(_ root: [String: Any], now: Date = Date()) throws -> UsageSnapshot {
        guard (root["has_quota_allocation"] as? Bool ?? true) else {
            throw MonitorError.message("该 Devin 账号无配额分配（旧额度套餐或已失效），没有可显示的窗口。上次数据已保留。")
        }
        func epoch(_ value: Any?) -> Date? {
            if let text = value as? String {
                if let date = CursorBridge.isoDate(text) { return date }
                return Double(text).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 > 10_000_000_000 ? $0 / 1000 : $0) : nil }
            }
            guard let n = Connectors.number(value), n > 0 else { return nil }
            return Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
        }
        var s = UsageSnapshot.empty(source: "Devin 账单 API")
        if root["hide_daily_quota"] as? Bool != true, let used = Connectors.number(root["daily_percentage"]) {
            s.quotas.append(.init(id: "devin-daily", title: "Devin · 每日", usedPercent: max(0, min(100, used)), resetsAt: epoch(root["daily_reset_at"]), windowSeconds: 86_400))
        }
        if root["hide_weekly_quota"] as? Bool != true, let used = Connectors.number(root["weekly_percentage"]) {
            s.quotas.append(.init(id: "devin-weekly", title: "Devin · 每周", usedPercent: max(0, min(100, used)), resetsAt: epoch(root["weekly_reset_at"]), windowSeconds: 604_800))
        }
        if let balance = Connectors.number(root["overage_balance"]) ?? Connectors.number(root["overage_balance_cents"]).map({ $0 / 100 }) {
            s.balances = [.init(currency: "USD", value: balance)]
        }
        guard !s.quotas.isEmpty || !s.balances.isEmpty else {
            throw MonitorError.message("Devin 未返回可用额度窗口。上次数据已保留。")
        }
        let plan = ["plan_name", "planName", "plan", "tier"].lazy.compactMap { root[$0] as? String }.first.flatMap { $0.isEmpty ? nil : $0 }
        s.note = "\((plan.map { $0 + " · " }) ?? "")接口报已用百分比（与本机缓存报的剩余相反，勿混用）。按公开实现对接，未对真实账号验证。"
        try s.validate()
        return s
    }

    static func fetchAPI(pasted: String) async throws -> UsageSnapshot {
        guard let credential = Credential(pasted: pasted) else {
            throw MonitorError.message("Devin 凭证格式应为「token 组织」（可粘贴整行 Authorization 头与组织设置页地址）。")
        }
        guard !credential.paths.isEmpty else {
            throw MonitorError.message("Devin 凭证缺少组织。请补充组织名或组织设置页地址。")
        }
        var lastStatus = 0
        for path in credential.paths {
            guard let url = URL(string: "https://app.devin.ai/api/\(path)/billing/quota/usage") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let internalID = credential.internalID {
                request.setValue(internalID, forHTTPHeaderField: "x-cog-org-id")
            }
            let (data, http) = try await Connectors.sendOAuth(request)
            switch http.statusCode {
            case 200:
                guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Connectors.schemaError }
                return try parseQuotaUsage(root)
            case 401, 403:
                throw MonitorError.message("Devin 凭证已被拒绝，请重新复制。上次数据已保留。")
            case 429:
                throw MonitorError.message("平台限流，请稍后刷新（HTTP 429）。上次数据已保留。")
            default:
                lastStatus = http.statusCode
            }
        }
        throw MonitorError.message("服务不可用（HTTP \(lastStatus)）。上次数据已保留。")
    }
}

