import CommonCrypto
import Foundation
import Security
import SQLite3

// V1.9 1C：Claude Code 全链接入。四层链：OAuth 官方端点 → 可选桌面会话路（默认关，显式选择）→
// 状态栏推送钩子 → 旧本地记录/缓存。设计思路借鉴 Pulse（Apache 2.0），代码为本项目重写。
// 安全约定：token 只从用户自己的钥匙串/凭证文件读，只发往白名单 host（api.anthropic.com / claude.ai），
// NoRedirect + 错误消毒走 Connectors.sendOAuth；token 不落日志；桌面路只读 sessionKey/sessionKeyV3 与 lastActiveOrg。

// MARK: - 身份比对：桌面端与 CLI 是否同一个人
enum ClaudeIdentity {
    // 只取标识字段（账号/组织/邮箱的小写集合），不存姓名等无关信息。
    struct Fingerprint: Equatable, Codable {
        var accounts: Set<String> = []
        var organizations: Set<String> = []
        var emails: Set<String> = []
        var isEmpty: Bool { accounts.isEmpty && organizations.isEmpty && emails.isEmpty }
    }
    enum Verdict { case same, different, unknown }

    static func fingerprint(fromProfile root: [String: Any]) -> Fingerprint {
        let account = root["account"] as? [String: Any] ?? root
        let organization = root["organization"] as? [String: Any]
        return Fingerprint(
            accounts: ids(account["uuid"], account["id"]),
            organizations: ids(organization?["uuid"], organization?["id"]),
            emails: ids(account["email_address"], account["email"])
        )
    }
    static func fingerprint(fromBootstrap root: [String: Any]) -> Fingerprint {
        let account = root["account"] as? [String: Any] ?? [:]
        let organizations = (account["memberships"] as? [[String: Any]] ?? []).compactMap { $0["organization"] as? [String: Any] }
        var found = Fingerprint(accounts: ids(account["uuid"], account["id"]), emails: ids(account["email_address"], account["email"]))
        // 账号的全部组织都收录：CLI 可能停在该人另一个组织里，仍是同一个人。
        found.organizations = Set(organizations.flatMap { ids($0["uuid"], $0["id"]) })
        return found
    }
    private static func ids(_ values: Any?...) -> Set<String> {
        Set(values.compactMap { ($0 as? String)?.lowercased() }.filter { !$0.isEmpty })
    }

    // 跨启动记忆 CLI 端登录身份：profile 的 token 几小时就过期，而比对可能几天后才需要。
    static func remember(_ fingerprint: Fingerprint) {
        guard !fingerprint.isEmpty, let data = try? JSONEncoder().encode(fingerprint) else { return }
        TokenBundle.defaults.set(data, forKey: key)
    }
    static var remembered: Fingerprint? {
        guard let data = TokenBundle.defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Fingerprint.self, from: data)
    }
    private static let key = "claudeCode.accountFingerprint"

    // 同类字段与同类字段比；一类字段两侧都非空才算可比。任一类一致即同一人。
    static func compare(_ one: Fingerprint, _ other: Fingerprint) -> Verdict {
        var comparable = false
        for (left, right) in [(one.accounts, other.accounts), (one.organizations, other.organizations), (one.emails, other.emails)] where !left.isEmpty && !right.isEmpty {
            comparable = true
            if !left.isDisjoint(with: right) { return .same }
        }
        return comparable ? .different : .unknown
    }
    // 一侧为空不算不匹配：只用桌面端的人可能从未有过可用 CLI token，严格拒绝会让这条路对目标用户失效。
    static func maySubstitute(_ desktop: Fingerprint) -> Bool {
        guard let known = remembered else { return true }
        return compare(known, desktop) != .different
    }
}

// MARK: - OAuth 官方端点（主路）
enum ClaudeOAuth {
    static var keychainService = "Claude Code-credentials"
    static var credentialsFile: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/.credentials.json")
    static let usageEndpoint = "https://api.anthropic.com/api/oauth/usage"
    static let profileEndpoint = "https://api.anthropic.com/api/oauth/profile"

    enum Outcome {
        case success(UsageSnapshot)
        case needsFreshCredentials // 401/403 或无未过期 token：走回落链
        case failed(Error) // 已消毒
    }

    // 钥匙串优先（经 /usr/bin/security，与 CLI 自身同级访问；首次读取可能弹授权框，拒绝则回落），
    // 备选 ~/.claude/.credentials.json。
    static func storedCredentials() -> [String: Any]? {
        readKeychainCredentials() ?? readCredentialsFile()
    }
    private static func readKeychainCredentials() -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    private static func readCredentialsFile() -> [String: Any]? {
        guard let data = try? Data(contentsOf: credentialsFile) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    // 过期（expiresAt 毫秒）按无 token 处理：这里没有任何东西替我们续期，拿过期 token 只会换回 401。
    static func unexpiredAccessToken(_ credentials: [String: Any], now: Date = Date()) -> String? {
        guard let oauth = credentials["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        if let expiresAt = Connectors.number(oauth["expiresAt"]), Date(timeIntervalSince1970: expiresAt / 1000) <= now { return nil }
        return token
    }

    static func usage(token: String) async -> Outcome {
        var request = URLRequest(url: URL(string: usageEndpoint)!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-cli (external, cli)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, http) = try await Connectors.sendOAuth(request)
            switch http.statusCode {
            case 200:
                guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failed(Connectors.schemaError) }
                // 套餐名取自缓存，缓存未命中则后台补——不让 profile 请求拖住已到手的额度读数。
                let plan = await ClaudePlanCache.shared.cached()
                await ClaudePlanCache.shared.refreshIfStale(token: token)
                do { return .success(try parseUsage(root, plan: plan)) } catch { return .failed(error) }
            case 401, 403: return .needsFreshCredentials
            case 429: return .failed(MonitorError.message("平台限流，请稍后刷新（HTTP 429）。上次数据已保留。"))
            default: return .failed(MonitorError.message("服务不可用（HTTP \(http.statusCode)）。上次数据已保留。"))
            }
        } catch { return .failed(error) }
    }

    // 解析 limits 数组（不只读顶层 five_hour/seven_day：数组才带按模型的 weekly_scoped 窗口）。
    // kind 映射窗口（session = 5 小时）；scope.model.display_name 是模型名。桌面路应答同形，共用此解析。
    static func parseUsage(_ root: [String: Any], plan: String?, source: String = "Claude Code 官方接口") throws -> UsageSnapshot {
        var s = UsageSnapshot.empty(source: source)
        var windows = (root["limits"] as? [[String: Any]] ?? []).compactMap(window(fromLimit:))
        if windows.isEmpty {
            for (key, id, title, ws) in [("five_hour", "claude-5h", "Claude · 5 小时", 18_000.0), ("seven_day", "claude-weekly", "Claude · 每周", 604_800.0)] {
                guard let node = root[key] as? [String: Any], let pct = Connectors.number(node["utilization"]), pct.isFinite else { continue }
                windows.append(Quota(id: id, title: title, usedPercent: isSpent(node) ? 100 : min(100, max(0, pct)), resetsAt: isoDate(node["resets_at"]), windowSeconds: ws))
            }
        }
        guard !windows.isEmpty else { throw MonitorError.message("Claude Code 未返回可用额度窗口。") }
        s.quotas = windows
        s.note = (plan.map { "\($0) · " } ?? "") + "官方 OAuth 只读接口；额度比例不等同于固定 Token 余额。"
        try s.validate()
        return s
    }

    static func window(fromLimit limit: [String: Any]) -> Quota? {
        guard let kind = limit["kind"] as? String, let pct = Connectors.number(limit["percent"]), pct.isFinite else { return nil }
        let used = isSpent(limit) ? 100 : min(100, max(0, pct))
        let resets = isoDate(limit["resets_at"])
        let scope = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
        switch kind {
        case "session":
            return Quota(id: "claude-5h", title: "Claude · 5 小时", usedPercent: used, resetsAt: resets, windowSeconds: 18_000)
        case "weekly_all":
            return Quota(id: "claude-weekly", title: "Claude · 每周", usedPercent: used, resetsAt: resets, windowSeconds: 604_800)
        case "weekly_scoped":
            // 模型名可能自带 "Claude " 前缀，标题与 id 里去掉以免叠字。
            let raw = scope ?? "scoped"
            let model = raw.hasPrefix("Claude ") ? String(raw.dropFirst("Claude ".count)) : raw
            let slug = model.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
            return Quota(id: "claude-\(slug)-weekly", title: "Claude \(model) · 每周", usedPercent: used, resetsAt: resets, windowSeconds: 604_800)
        default:
            return nil
        }
    }

    // Spent 语义：locked_reason 或非识别 severity = 耗尽；warning/warn ≠ 耗尽（76% 时也会 warning）。
    static func isSpent(_ limit: [String: Any]) -> Bool {
        if let locked = limit["locked_reason"], !(locked is NSNull) { return true }
        guard let severity = (limit["severity"] as? String)?.lowercased() else { return false }
        return !["normal", "ok", "none", "healthy", "warning", "warn"].contains(severity)
    }

    static func isoDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    // 套餐名：usage 应答不带套餐，需 /api/oauth/profile。缓存 6 小时，失败也缓存——
    // 套餐是锦上添花，绝不能让它每轮都给额度读数添一次重试。
    actor ClaudePlanCache {
        static let shared = ClaudePlanCache()
        private static let freshFor: TimeInterval = 6 * 3600
        private var known: (name: String?, at: Date)?
        private var asking = false
        // 测试门：关闭后 refreshIfStale 直接返回，避免后台 profile 请求干扰 MockHTTP 响应队列。
        private var refreshEnabled = true
        func setRefreshEnabled(_ value: Bool) { refreshEnabled = value }

        func cached() -> String? { known?.name }

        func refreshIfStale(token: String) {
            guard refreshEnabled else { return }
            if let seen = known, Date().timeIntervalSince(seen.at) < Self.freshFor { return }
            guard !asking else { return }
            asking = true
            Task { [weak self] in
                guard let self else { return }
                let name = await Self.fetch(token: token)
                await self.remember(name)
            }
        }

        private func remember(_ name: String?) {
            known = (name, Date()) // 失败（nil）同样记录时间
            asking = false
        }

        private static func fetch(token: String) async -> String? {
            var request = URLRequest(url: URL(string: ClaudeOAuth.profileEndpoint)!)
            request.timeoutInterval = 15
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("claude-cli (external, cli)", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, http) = try? await Connectors.sendOAuth(request), http.statusCode == 200,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            // 顺路记下 CLI 端登录身份：等桌面路需要比对时，这个 token 通常已经过期了。
            ClaudeIdentity.remember(ClaudeIdentity.fingerprint(fromProfile: root))
            return planName(from: root)
        }
    }

    // subscription_type 优先、organization.rate_limit_tier 次之；倍率只在 tier 上（default_claude_max_5x → Max 5x）。
    // 只读 plan 形态字段；同一份应答里的姓名/邮箱/组织信息是用户的，不存不展示。未知值整理后透传，不抹掉。
    nonisolated static func planName(from root: [String: Any]) -> String? {
        let organization = root["organization"] as? [String: Any]
        let tier = (organization?["rate_limit_tier"] as? String)?.lowercased()
        let multiplier = tier.flatMap { t in ["20x", "5x"].first { t.hasSuffix("_" + $0) } }
        if let stated = (organization?["subscription_type"] as? String) ?? (root["subscription_type"] as? String) {
            let name = tidy(stated)
            return multiplier.map { "\(name) \($0)" } ?? name
        }
        guard let tier else { return (organization?["organization_type"] as? String).map(tidy) }
        let base: String
        if tier.contains("max") { base = "Max" }
        else if tier.contains("team") { base = "Team" }
        else if tier.contains("enterprise") { base = "Enterprise" }
        else if tier.contains("pro") { base = "Pro" }
        else if tier.contains("free") { base = "Free" }
        else { base = tidy(tier) }
        return multiplier.map { "\(base) \($0)" } ?? base
    }
    static func tidy(_ raw: String) -> String {
        raw.split(whereSeparator: { $0 == "_" || $0 == "-" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

// MARK: - 状态栏推送钩子（官方文档化 push 通道）
enum ClaudeStatusLine {
    static let modeArgument = "--statusline"
    // 推送读数落在自己的数据目录（不写用户数据目录之外；settings.json 备份是文档明示的唯一例外）。
    static var cacheFile: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("GaoSeries/Token/claude-statusline.json")
    static var settingsFile: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
    static var backupFile: URL { settingsFile.deletingLastPathComponent().appendingPathComponent("settings.json.gaociyuan-backup") }
    // 超过 10 分钟没有新推送即按历史数据展示：会话每次响应都会推，沉默意味着会话停了。
    static let freshFor: TimeInterval = 10 * 60

    // Claude Code 曾把 epoch 重置时间漏进百分比字段；超过 101 的值不是百分比，丢弃而不是画满环。
    static func percent(_ value: Any?) -> Double? {
        guard let n = Connectors.number(value), n >= 0, n <= 101 else { return nil }
        return n
    }

    // 推送窗口：reset 已过的窗口直接丢弃不老化（昨天的 blob 里的 5 小时窗早已重置，
    // 标着「截至」也仍读作「你正处在这个窗口里」，比没有数据更误导）。
    static func capturedWindows(from limits: [String: Any], now: Date = Date()) -> [Quota] {
        [("five_hour", "claude-5h", "Claude · 5 小时", 18_000.0), ("seven_day", "claude-weekly", "Claude · 每周", 604_800.0)].compactMap { key, id, title, ws in
            guard let node = limits[key] as? [String: Any], let pct = percent(node["used_percentage"]) else { return nil }
            let resets = Connectors.number(node["resets_at"]).map { Date(timeIntervalSince1970: $0) }
            if let resets, resets <= now { return nil }
            return Quota(id: id, title: title, usedPercent: min(100, pct), resetsAt: resets, windowSeconds: ws)
        }
    }

    static func capturedUsage(now: Date = Date()) -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: cacheFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any] else { return nil }
        let windows = capturedWindows(from: limits, now: now)
        guard !windows.isEmpty else { return nil }
        let captured = Connectors.number(root["capturedAt"]).map { Date(timeIntervalSince1970: $0) }
        let age = captured.map { now.timeIntervalSince($0) } ?? .infinity
        var s = UsageSnapshot.empty(source: "Claude Code 状态栏推送")
        s.observedAt = captured ?? now
        s.quotas = windows
        let asOf = "数据截至 \(displayDate(s.observedAt))"
        s.note = age > freshFor ? "\(asOf)；推送通道静默超过 10 分钟，按历史数据展示。" : "\(asOf)；Claude Code 会话推送。"
        guard (try? s.validate()) != nil else { return nil }
        return s
    }

    // MARK: 作为状态栏命令运行（Claude Code 每次响应后经 stdin 推来一个 JSON blob）
    static func runAsStatusLine() {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let root = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return }
        if let limits = root["rate_limits"] as? [String: Any] { capture(limits) }
        // 链式保留用户原有状态栏命令的输出；没有则打印默认行。
        if let chained = chainedOutput(for: input) { print(chained, terminator: "") } else { print(defaultLine(root), terminator: "") }
    }
    private static func capture(_ limits: [String: Any]) {
        let payload: [String: Any] = ["capturedAt": Date().timeIntervalSince1970, "rate_limits": limits]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let temporary = cacheFile.appendingPathExtension("tmp-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: temporary)) != nil else { return }
        _ = try? FileManager.default.replaceItemAt(cacheFile, withItemAt: temporary)
    }
    private static func chainedOutput(for input: Data) -> String? {
        guard let command = TokenBundle.defaults.string(forKey: DefaultsKey.previousCommand), !command.isEmpty else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
    private static func defaultLine(_ root: [String: Any]) -> String {
        let limits = root["rate_limits"] as? [String: Any]
        let parts = [("five_hour", "5h"), ("seven_day", "7d")].compactMap { key, label -> String? in
            guard let window = limits?[key] as? [String: Any], let pct = percent(window["used_percentage"]) else { return nil }
            return "\(label) \(Int(pct.rounded()))%"
        }
        let model = (root["model"] as? [String: Any])?["display_name"] as? String
        return ([model] + parts).compactMap { $0 }.joined(separator: "  ·  ")
    }

    // MARK: 安装 / 恢复 / 自修复（改 settings.json 前备份；已有命令链式保留、可恢复）
    static var isInstalled: Bool {
        guard let settings = readSettings(), let line = settings["statusLine"] as? [String: Any],
              let command = line["command"] as? String else { return false }
        return command.contains(modeArgument)
    }
    @discardableResult
    static func install() -> Bool {
        // 无法解析的 settings.json 绝不覆盖（其中可能有注释等 Claude Code 自己容忍的内容）。
        guard var settings = currentSettings() else { return false }
        if let previous = settings["statusLine"] as? [String: Any], let command = previous["command"] as? String,
           !command.contains(modeArgument) {
            TokenBundle.defaults.set(command, forKey: DefaultsKey.previousCommand)
        }
        let executable = ProcessInfo.processInfo.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? TokenBundle.bundle.executablePath ?? ""
        settings["statusLine"] = ["type": "command", "command": "\"\(executable)\" \(modeArgument)"]
        return writeSettings(settings)
    }
    @discardableResult
    static func uninstall() -> Bool {
        guard var settings = readSettings() else { return false }
        if let previous = TokenBundle.defaults.string(forKey: DefaultsKey.previousCommand), !previous.isEmpty {
            settings["statusLine"] = ["type": "command", "command": previous]
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        TokenBundle.defaults.removeObject(forKey: DefaultsKey.previousCommand)
        return writeSettings(settings)
    }
    // 应用路径变化（重装/升级）时重写注册路径。
    static func repairPathIfNeeded() {
        guard isInstalled, let settings = readSettings(),
              let line = settings["statusLine"] as? [String: Any], let command = line["command"] as? String else { return }
        let executable = ProcessInfo.processInfo.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? ""
        guard !executable.isEmpty, !command.contains(executable) else { return }
        _ = install()
    }
    private static func currentSettings() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: settingsFile.path) else { return [:] }
        return readSettings()
    }
    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root
    }
    private static func writeSettings(_ settings: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return false }
        let fm = FileManager.default
        if !fm.fileExists(atPath: backupFile.path), let original = try? Data(contentsOf: settingsFile) {
            try? original.write(to: backupFile)
        }
        // 每次写入前滚动备份最近 3 份（settings.json.bak.1 最新），写坏可手动回滚。
        if fm.fileExists(atPath: settingsFile.path) {
            let backup3 = settingsFile.appendingPathExtension("bak.3")
            let backup2 = settingsFile.appendingPathExtension("bak.2")
            let backup1 = settingsFile.appendingPathExtension("bak.1")
            try? fm.removeItem(at: backup3)
            if fm.fileExists(atPath: backup2.path) { try? fm.moveItem(at: backup2, to: backup3) }
            if fm.fileExists(atPath: backup1.path) { try? fm.moveItem(at: backup1, to: backup2) }
            try? fm.copyItem(at: settingsFile, to: backup1)
        }
        // 原子写：先写临时文件再替换，避免中途断电/崩溃留下半截 JSON。
        return (try? data.write(to: settingsFile, options: .atomic)) != nil
    }
    private enum DefaultsKey {
        static let previousCommand = "gaociyuan.statusLine.previousCommand"
    }
}

// MARK: - 桌面会话路（可选路：默认关，用户在连接方式里显式选择才启用）
enum ClaudeDesktop {
    static var supportDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Claude")
    static let keychainService = "Claude Safe Storage"
    static let host = "claude.ai"
    // 只有这两个键承载会话；lastActiveOrg 不是凭据，只用于匹配组织。其余 cookie 一律不读。
    private static let sessionNames = ["sessionKey", "sessionKeyV3"]
    private static let activeOrgName = "lastActiveOrg"

    // macOS 是否曾把桌面端 Safe Storage 钥匙交给本应用：用户的决定记在这里，
    // 未授权过的自动轮询绝不触碰钥匙串（不反复弹授权框；只在用户选择该路或手动同步时要一次）。
    static var wasPermitted: Bool {
        get { TokenBundle.defaults.bool(forKey: permissionKey) }
        set { TokenBundle.defaults.set(newValue, forKey: permissionKey) }
    }
    private static let permissionKey = "claudeDesktop.keychainGranted"
    static var isAvailable: Bool { cookieStore() != nil }

    struct Outcome {
        let snapshot: UsageSnapshot
        let fingerprint: ClaudeIdentity.Fingerprint
    }

    static func usage() async throws -> Outcome {
        guard let store = cookieStore() else {
            throw MonitorError.message("未在 Claude 桌面端找到登录会话。请在桌面端登录后重试。")
        }
        guard let key = safeStorageKey() else {
            wasPermitted = false
            throw MonitorError.message("未获得读取 Claude 桌面端会话的钥匙串授权。手动同步时会再次询问。")
        }
        wasPermitted = true
        let cookies = chromiumCookies(at: store, key: key)
        guard let cookie = sessionHeader(from: cookies) else {
            throw MonitorError.message("未在 Claude 桌面端找到登录会话。请在桌面端登录后重试。")
        }
        let active = activeOrganization(from: cookies)
        // 缓存的组织可能失效：404 时清缓存重问一次，其余错误首轮即报。
        for attempt in 0...1 {
            let identity = try await resolveIdentity(cookie: cookie, preferring: active, ignoringCache: attempt > 0)
            switch try await readUsage(organization: identity.organization, cookie: cookie) {
            case .success(let root):
                return Outcome(snapshot: try ClaudeOAuth.parseUsage(root, plan: identity.plan, source: "Claude 桌面会话"), fingerprint: identity.fingerprint)
            case .organizationGone where attempt == 0:
                await IdentityCache.shared.forget()
                continue
            case .organizationGone:
                throw MonitorError.message("Claude Code 未返回可用额度窗口。")
            case .failure(let error):
                throw error
            }
        }
        throw MonitorError.message("网络连接失败，请检查网络后重试。上次数据已保留。")
    }

    // MARK: cookie 读取（Electron Chromium cookie store + Safe Storage 钥匙）
    static func cookieStore() -> URL? {
        ["Network/Cookies", "Cookies"].map { supportDirectory.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
    // 这一读会触发「允许访问钥匙串」询问；由调用方控制何时发起。
    static func safeStorageKey() -> Data? {
        let request: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let password = item as? Data else { return nil }
        // Chromium 固定参数：PBKDF2-SHA1、saltysalt、1003 轮、16 字节。
        var key = Data(count: 16)
        let derived = key.withUnsafeMutableBytes { out in
            password.withUnsafeBytes { secret in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), secret.baseAddress, secret.count,
                                     "saltysalt", 9, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, out.baseAddress, 16)
            }
        }
        return derived == kCCSuccess ? key : nil
    }
    // AES-128-CBC + 全空格 IV（v10/v11 前缀后）；无前缀按明文；新版可能在值前补 32 字节 host 哈希。
    static func decrypt(_ encrypted: Data, with key: Data) -> String? {
        guard encrypted.count > 3 else { return nil }
        let prefix = String(decoding: encrypted.prefix(3), as: UTF8.self)
        guard prefix == "v10" || prefix == "v11" else { return String(data: encrypted, encoding: .utf8) }
        let body = encrypted.dropFirst(3)
        var out = Data(count: body.count + kCCBlockSizeAES128)
        var moved = 0
        let status = out.withUnsafeMutableBytes { output in
            body.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, 16, String(repeating: " ", count: 16),
                            input.baseAddress, input.count, output.baseAddress, output.count, &moved)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out = out.prefix(moved)
        if let text = String(data: out, encoding: .utf8) { return text }
        guard out.count > 32, let text = String(data: out.dropFirst(32), encoding: .utf8) else { return nil }
        return text
    }
    // host 匹配：host 本身、点形式与子域，绝不是后缀匹配（notclaude.ai 的值不能发给 claude.ai）。
    static func chromiumCookies(at store: URL, key: Data) -> [(String, String)] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(store.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return []
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        let sql = "SELECT name, encrypted_value FROM cookies WHERE host_key = ? OR host_key = ? OR host_key LIKE ?"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, binding) in [host, ".\(host)", "%.\(host)"].enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), binding, -1, transient)
        }
        var rows: [(String, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 0), let blob = sqlite3_column_blob(statement, 1) else { continue }
            let encrypted = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 1)))
            guard let value = decrypt(encrypted, with: key) else { continue }
            rows.append((String(cString: name), value))
        }
        return rows
    }
    // 同名 cookie（host-only 与 domain 两行）不视为损坏：取第一行，与任何 cookie 头行为一致。
    static func sessionHeader(from cookies: [(String, String)]) -> String? {
        var seen: Set<String> = []
        let pairs = cookies.filter { sessionNames.contains($0.0) && !$0.1.isEmpty }.filter { seen.insert($0.0).inserted }
        guard !pairs.isEmpty else { return nil }
        return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }
    static func activeOrganization(from cookies: [(String, String)]) -> String? {
        guard let raw = cookies.first(where: { $0.0 == activeOrgName })?.1 else { return nil }
        let decoded = (raw.removingPercentEncoding ?? raw).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return decoded.isEmpty ? nil : decoded
    }

    // MARK: 两个 web 端点（非公开 API，web 客户端自身路径，可能变动）
    private struct Identity {
        let organization: String
        let plan: String?
        let fingerprint: ClaudeIdentity.Fingerprint
    }
    private enum ReadOutcome {
        case success([String: Any])
        case organizationGone
        case failure(Error)
    }
    private static func resolveIdentity(cookie: String, preferring active: String?, ignoringCache: Bool) async throws -> Identity {
        if !ignoringCache, let known = await IdentityCache.shared.cached(for: active) { return known }
        let request = URLRequest(url: URL(string: "https://claude.ai/api/bootstrap")!)
        switch await get(request, cookie: cookie) {
        case .success(let root):
            guard let account = root["account"] as? [String: Any], let memberships = account["memberships"] as? [[String: Any]] else { throw Connectors.schemaError }
            let organizations = memberships.compactMap { $0["organization"] as? [String: Any] }
            // 必须是当前活动的组织，不是列表第一个：一个账号可属于多个组织，限额各不相同。
            guard let organization = organizations.first(where: { $0["uuid"] as? String == active }) ?? organizations.first,
                  let id = organization["uuid"] as? String else { throw Connectors.schemaError }
            let identity = Identity(
                organization: id,
                plan: ClaudeOAuth.planName(from: ["organization": organization]),
                fingerprint: ClaudeIdentity.fingerprint(fromBootstrap: root)
            )
            await IdentityCache.shared.remember(identity, seenActive: active)
            return identity
        case .organizationGone: throw Connectors.schemaError
        case .failure(let error): throw error
        }
    }
    private static func readUsage(organization: String, cookie: String) async throws -> ReadOutcome {
        let request = URLRequest(url: URL(string: "https://claude.ai/api/organizations/\(organization)/usage")!)
        return await get(request, cookie: cookie)
    }
    // 会话 cookie 属一次性借用：httpShouldHandleCookies = false，响应的 Set-Cookie 绝不进任何共享 cookie 罐。
    private static func get(_ request: URLRequest, cookie: String) async -> ReadOutcome {
        var request = request
        request.timeoutInterval = 20
        request.httpShouldHandleCookies = false
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("web_claude_ai", forHTTPHeaderField: "anthropic-client-platform")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Claude/1.0 Chrome/130.0.0.0 Electron/33.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        do {
            let (data, http) = try await Connectors.sendOAuth(request)
            switch http.statusCode {
            case 200:
                guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failure(Connectors.schemaError) }
                return .success(root)
            case 401, 403:
                return .failure(MonitorError.message("Claude 桌面端会话已过期，请在桌面端重新登录。上次数据已保留。"))
            case 404:
                return .organizationGone
            case 429:
                return .failure(MonitorError.message("平台限流，请稍后刷新（HTTP 429）。上次数据已保留。"))
            default:
                return .failure(MonitorError.message("服务不可用（HTTP \(http.statusCode)）。上次数据已保留。"))
            }
        } catch { return .failure(error) }
    }

    // 组织与套餐缓存 6 小时，按当前活动组织为键（切组织立刻换缓存条目，而不是等时钟）。
    private actor IdentityCache {
        static let shared = IdentityCache()
        private static let freshFor: TimeInterval = 6 * 3600
        private var stored: (identity: Identity, active: String?, at: Date)?
        func cached(for active: String?) -> Identity? {
            guard let stored, stored.active == active, Date().timeIntervalSince(stored.at) < Self.freshFor else { return nil }
            return stored.identity
        }
        func remember(_ identity: Identity, seenActive active: String?) { stored = (identity, active, Date()) }
        func forget() { stored = nil }
    }
}
