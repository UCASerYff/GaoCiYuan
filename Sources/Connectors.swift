import Foundation
import CoreFoundation
import Security
import Darwin
import AppKit
import CryptoKit

enum KeyVault {
    private static let service = "com.gaoseries.GaoQiNianSan.credentials"
    static func read(_ id: UUID) throws -> String {
        let q: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:id.uuidString,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { throw MonitorError.message("请在账户设置中保存 API 密钥。") }
        guard status == errSecSuccess, let data = item as? Data, let value = String(data:data,encoding:.utf8) else { throw MonitorError.message("钥匙串读取失败（\(status)）。") }
        return value
    }
    static func save(_ value: String, id: UUID) throws {
        let q: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:id.uuidString]
        let data = Data(value.utf8)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let inserted = SecItemAdd(add as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw MonitorError.message("密钥保存失败（\(inserted)）。") }; return
        }
        guard status == errSecSuccess else { throw MonitorError.message("密钥保存失败（\(status)）。") }
    }
    static func delete(_ id: UUID) {
        SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:id.uuidString] as CFDictionary)
    }
}
// Reject redirects: credentials must only go to the fixed official endpoint.
final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
enum Connectors {
    static var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral; c.timeoutIntervalForRequest = 25; c.timeoutIntervalForResource = 45; c.httpShouldSetCookies = false; c.httpCookieStorage = nil; c.urlCache = nil; c.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration:c,delegate:NoRedirect(),delegateQueue:nil)
    }()
    static func fetch(_ account: Account, userInitiated: Bool = false, keyOverride: String? = nil) async throws -> ConnectorResult {
        try Task.checkCancellation()
        return try await HTTPPolicyContext.$userInitiated.withValue(userInitiated) {
            try await HTTPPolicyContext.$trigger.withValue(userInitiated ? "quota.manual" : "quota.automatic") {
                try await HTTPPolicyContext.$operationIdentity.withValue(UUID().uuidString) {
                    let route = account.id.uuidString + account.connection.rawValue + account.filePath + (account.scopeID ?? "") + (account.region ?? "") + String(describing:account.customConfig)
                    let fingerprint = SHA256.hash(data:Data(route.utf8)).map { String(format:"%02x",$0) }.joined()
                    return try await HTTPPolicyContext.$credentialIdentity.withValue(fingerprint) {
                        let result = try await fetchImpl(account, userInitiated: userInitiated, keyOverride: keyOverride)
                        try Task.checkCancellation()
                        return result
                    }
                }
            }
        }
    }
    private static func fetchImpl(_ account: Account, userInitiated: Bool, keyOverride: String?) async throws -> ConnectorResult {
        if let tool = account.connection.toolBridgeID {
            let credential = account.connection == .kiroQuota ? "" : try suppliedKey(account, override: keyOverride)
            let snapshot = try await ProviderToolBridge.fetch(provider: tool, credential: credential, scope: account.scopeID, region: account.region)
            try snapshot.validate()
            return .snapshot(snapshot)
        }
        if account.connection.integration != nil {
            let key = try suppliedKey(account, override: keyOverride)
            let snapshot: UsageSnapshot
            switch account.connection {
            case .openRouterQuota: snapshot = try await OpenRouterBridge.fetch(key: key)
            case .typeSafeQuota: snapshot = try await TypeSafeBridge.fetch(cookie: key)
            case .traeQuota: snapshot = try await TraeCNBridge.fetch(token: key, deviceID: account.scopeID ?? "")
            case .alibabaPlan: snapshot = try await AlibabaTokenPlanBridge.fetch(cookie: key, variant: account.region ?? "cn")
            case .stepFunQuota: snapshot = try await StepFunBridge.fetch(token: key)
            case .newAPIQuota: snapshot = try await ThirdPartyQuotaBridge.fetch(adapter: "newapi", baseURL: account.filePath, credential: key, userID: account.scopeID, tokenMode: account.region != "account")
            case .sub2APIQuota: snapshot = try await ThirdPartyQuotaBridge.fetch(adapter: "sub2api", baseURL: account.filePath, credential: key)
            default: throw schemaError
            }
            try snapshot.validate()
            return .snapshot(snapshot)
        }
        switch account.connection {
        case .agentLocal:
            return try await AgentBridge.fetch(account, userInitiated: userInitiated)
        case .codex:
            return .snapshot(try await CodexBridge.fetch())
        case .kimiDesktop:
            return try await KimiDesktopBridge.fetch(account, userInitiated: userInitiated)
        case .claudeDesktop:
            return try await ClaudeBridge.fetch(account, userInitiated: userInitiated)
        case .geminiApp:
            return .status(AntigravityUsageReport.manualHint)
        case .cursor:
            return .snapshot(try await CursorBridge.fetch())
        case .dshHarness:
            return try await DshBridge.fetch(account, userInitiated: userInitiated)
        case .workbuddyLocal:
            return try await WorkBuddyBridge.fetch(account, userInitiated: userInitiated)
        case .customAPI:
            return try await CustomBridge.fetch(account, userInitiated: userInitiated, keyOverride: keyOverride)
        case .grokAccount:
            return .snapshot(try await GrokAccountBridge.fetch())
        case .devinApp:
            // 同步开 sqlite 读套餐缓存：卸载后台队列，不堵调用方 actor。
            let cached = try await Task.detached(priority: .userInitiated) { try DevinBridge.fetchLocal() }.value
            return .snapshot(cached)
        case .file:
            guard !account.filePath.isEmpty else { throw MonitorError.message("请选择快照 JSON 文件。") }
            let url = URL(fileURLWithPath:account.filePath)
            guard let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize, size <= 2_000_000 else { throw MonitorError.message("快照文件不能超过 2 MB。") }
            let snapshot = try JSONCoding.decoder.decode(UsageSnapshot.self, from:Data(contentsOf:url))
            try snapshot.validate()
            return .snapshot(snapshot)
        default:
            // Command Code：粘贴 key 优先，钥匙串无存时回落本机 CLI 保存的登录（不读环境变量）。
            if account.connection == .commandCode {
                let entered = keyOverride.flatMap { $0.isEmpty ? nil : $0 } ?? (try? KeyVault.read(account.id))
                return .snapshot(try await CommandCodeBridge.fetch(enteredKey: entered))
            }
            let key: String
            if let override = keyOverride, !override.isEmpty { key = override } else { key = try KeyVault.read(account.id) }
            if account.connection == .devinApi { return .snapshot(try await DevinBridge.fetchAPI(pasted: key)) }
            if account.connection == .ollamaCloud { return .snapshot(try await OllamaBridge.fetch(cookieHeader: key)) }
            if [.minimax,.glm,.kimiCoding,.xai,.aliyun,.volc,.volcArk,.mimoCoding].contains(account.connection) { return .snapshot(try await OfficialExtras.fetch(account,key:key)) }
            if account.connection == .deepseek {
                let data = try await get("https://api.deepseek.com/user/balance", key:key)
                return .snapshot(try parseDeepSeek(data))
            }
            if account.connection == .moonshot {
                let data = try await get("https://api.moonshot.cn/v1/users/me/balance", key:key)
                guard data["status"] as? Bool == true, number(data["code"]) == 0, let body = data["data"] as? [String:Any], let amount = number(body["available_balance"]) else { throw schemaError }
                var s = UsageSnapshot.empty(source:"Kimi 官方 API"); s.balances = [.init(currency:"CNY",value:amount)]; s.note = "余额不代表累计消费；此接口不提供 Token 用量。"; return .snapshot(s)
            }
            if account.connection == .copilot {
                return .snapshot(try await CopilotBridge.fetch(token: key))
            }
            var cal = Calendar(identifier:.gregorian); cal.timeZone = TimeZone(secondsFromGMT:0)!
            let now = Date(), start = cal.date(from:cal.dateComponents([.year,.month],from:Date()))!
            var s = UsageSnapshot.empty(source:"官方 API"); s.periodStart = start; s.periodEnd = now
            if account.connection == .openai {
                let q = "start_time=\(Int(start.timeIntervalSince1970))&end_time=\(Int(now.timeIntervalSince1970))&bucket_width=1d&limit=31"
                let usage = try await pages("https://api.openai.com/v1/organization/usage/completions?\(q)", key:key)
                let costs = try await pages("https://api.openai.com/v1/organization/costs?\(q)", key:key)
                s = try parseReports(usage:usage,costs:costs,anthropic:false,start:start,end:now)
            } else {
                let f = ISO8601DateFormatter()
                let q = "starting_at=\(f.string(from:start))&ending_at=\(f.string(from:now))&limit=31"
                let usage = try await pages("https://api.anthropic.com/v1/organizations/usage_report/messages?\(q)&bucket_width=1d", key:key,anthropic:true)
                let costs = try await pages("https://api.anthropic.com/v1/organizations/cost_report?\(q)",key:key,anthropic:true)
                s = try parseReports(usage:usage,costs:costs,anthropic:true,start:start,end:now)
            }
            try s.validate(); return .snapshot(s)
        }
    }
    private static func suppliedKey(_ account: Account, override: String?) throws -> String {
        if let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return override }
        return try KeyVault.read(account.id)
    }
    static let schemaError = MonitorError.message("平台响应格式不符，保留上次数据；请检查接口或升级连接器。")
    static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        if let n = value as? NSNumber { return n.doubleValue.isFinite ? n.doubleValue : nil }
        if let str = value as? String, let n = Double(str), n.isFinite { return n }; return nil
    }
    static func integer(_ value: Any?) throws -> Int64 {
        guard let n = number(value), n >= 0, n < Double(Int64.max / 4), n.rounded() == n else { throw schemaError }; return Int64(n)
    }
    static func get(_ path: String, key: String, anthropic: Bool = false, rawAuth: Bool = false, timeout: TimeInterval = 25, category: HTTPBudgetKind = .quota) async throws -> [String:Any] {
        guard let url = URL(string:path), url.scheme == "https", ["api.openai.com","api.anthropic.com","api.deepseek.com","api.moonshot.cn","api.kimi.com","www.minimaxi.com","www.minimax.io","open.bigmodel.cn","api.z.ai","management-api.x.ai"].contains(url.host ?? "") else { throw schemaError }
        var r = URLRequest(url:url); r.httpMethod = "GET"; r.timeoutInterval = timeout
        r.setValue("application/json", forHTTPHeaderField:"Accept")
        if anthropic { r.setValue(key,forHTTPHeaderField:"x-api-key"); r.setValue("2023-06-01",forHTTPHeaderField:"anthropic-version") }
        else { r.setValue(rawAuth ? key : "Bearer \(key)",forHTTPHeaderField:"Authorization") }
        return try await send(r, category: category)
    }
    static func send(_ r: URLRequest, category: HTTPBudgetKind = .quota) async throws -> [String:Any] {
        let (data, response): (Data, URLResponse)
        // 取消（整轮超时）原样上抛，让调用方区分「被取消」与「真失败」。
        do { (data, response) = try await BoundedHTTP.data(for: r, session: session, timeout: min(45, r.timeoutInterval), category: category) } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            throw MonitorError.message("网络连接失败，请检查网络后重试。")
        }
        guard let http = response as? HTTPURLResponse else { throw schemaError }
        guard (200..<300).contains(http.statusCode) else {
            let hint: String
            switch http.statusCode {
            case 401: hint = "密钥无效或登录已过期"
            case 403: hint = "权限不足；管理接口需要组织 Admin Key"
            case 429: hint = "平台限流，请稍后刷新"
            default: hint = "服务不可用"
            }
            throw MonitorError.message("\(hint)（HTTP \(http.statusCode)）。上次数据已保留。")
        }
        guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw schemaError }; return object
    }
    // V1.9 本机 OAuth 凭证路线的请求原语：https + 官方 host 白名单 + NoRedirect（复用 Connectors.session）+ 错误消毒。
    // 单次请求，统一网络层负责跨入口退避；HTTP 状态交给调用方，自动请求不会反复续期同一失效凭据。
    // token 只出现在请求头，绝不落日志、不写盘。
    static let oauthHosts = ["chatgpt.com","api.anthropic.com","claude.ai","cursor.com","github.com","api.github.com","cli-chat-proxy.grok.com","platform.xiaomimimo.com","app.devin.ai","ollama.com","api.commandcode.ai","platform.deepseek.com"]
    static func sendOAuth(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = r.url, url.scheme == "https", let host = url.host, oauthHosts.contains(host) else { throw schemaError }
        try Task.checkCancellation()
        // One transport attempt. Shared host policy owns backoff; connector and
        // fallback layers must not multiply retries of the same request.
        let (data, response) = try await BoundedHTTP.data(for: r, session: session, timeout: min(45, r.timeoutInterval))
        guard let http = response as? HTTPURLResponse else { throw schemaError }
        return (data, http)
    }

    static func pages(_ path: String, key: String, anthropic: Bool = false) async throws -> [[String:Any]] {
        var items: [[String:Any]] = [], next: String? = nil, seen = Set<String>()
        let started = Date()
        for _ in 0..<64 {
            try Task.checkCancellation()
            guard Date().timeIntervalSince(started) < 90 else { throw HTTPBudgetError.deadline }
            var url = URLComponents(string:path)!
            if let next { var q = url.queryItems ?? []; q.append(.init(name:"page",value:next)); url.queryItems = q; url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of:"+",with:"%2B") }
            let response = try await get(url.url!.absoluteString,key:key,anthropic:anthropic,timeout:min(25,max(0.01,90-Date().timeIntervalSince(started))),category:.history)
            guard let buckets = response["data"] as? [[String:Any]] else { throw schemaError }
            for bucket in buckets { guard let results = bucket["results"] as? [[String:Any]] else { throw schemaError }; guard items.count <= 200_000 - results.count else { throw HTTPBudgetError.responseTooLarge }; items += results }
            guard let more = response["has_more"] as? Bool else { throw schemaError }
            if !more { return items }
            guard let cursor = response["next_page"] as? String, !cursor.isEmpty, seen.insert(cursor).inserted else { throw schemaError }; next = cursor
        }
        throw MonitorError.message("报告页数超出安全上限，未保存不完整统计。")
    }
    static func parseDeepSeek(_ data: [String:Any]) throws -> UsageSnapshot {
        guard let balances = data["balance_infos"] as? [[String:Any]], !balances.isEmpty else { throw schemaError }
        var s = UsageSnapshot.empty(source:"DeepSeek 官方 API")
        s.balances = try balances.map { r in guard let c = r["currency"] as? String, let amount = number(r["total_balance"]) else { throw schemaError }; return Money(currency:c,value:amount) }
        s.note = "余额包含有效赠金与充值余额；此接口不提供 Token 和累计费用。"; try s.validate(); return s
    }
    static func parseReports(usage: [[String:Any]], costs: [[String:Any]], anthropic: Bool, start: Date, end: Date) throws -> UsageSnapshot {
        var input: Int64 = 0, output: Int64 = 0, totals: [String:Double] = [:]
        for row in usage {
            var n: Int64 = 0
            if anthropic {
                n += try integer(row["uncached_input_tokens"])
                n += try integer(row["cache_read_input_tokens"])
                if let creation = row["cache_creation"] as? [String:Any] {
                    n += try integer(creation["ephemeral_1h_input_tokens"])
                    n += try integer(creation["ephemeral_5m_input_tokens"])
                } else if let flat = row["cache_creation_input_tokens"] { n += try integer(flat) }
                else { throw schemaError }
            } else { n = try integer(row["input_tokens"]) } // cached tokens are already included
            let out = try integer(row["output_tokens"])
            guard input <= Int64.max / 2 - n, output <= Int64.max / 2 - out else { throw schemaError }
            input += n; output += out
        }
        for row in costs {
            if anthropic {
                guard let n = number(row["amount"]), let c = row["currency"] as? String else { throw schemaError }; totals[c.uppercased(),default:0] += n / 100 // Anthropic reports cents
            } else {
                guard let amount = row["amount"] as? [String:Any], let n = number(amount["value"]), let c = amount["currency"] as? String else { throw schemaError }; totals[c.uppercased(),default:0] += n
            }
        }
        if costs.isEmpty { totals["USD"] = 0 }
        var s = UsageSnapshot.empty(source:anthropic ? "Claude 官方管理 API" : "OpenAI 官方管理 API")
        s.periodStart = start; s.periodEnd = end; s.inputTokens = input; s.outputTokens = output
        s.costs = totals.sorted(by: { $0.key < $1.key }).map { Money(currency:$0.key,value:$0.value) }
        s.note = anthropic ? "UTC 本月组织级报告；含缓存读写，Priority Tier 费用不在官方成本接口内。" : "UTC 本月组织级报告；Token 为 completions 类别，费用来自独立 Costs 报告。缓存输入不重复累加。"
        return s
    }
}

enum CodexBridge {
    // D2 专属助手完整性校验：安装脚本从 ChatGPT.app 拷贝内嵌 codex 到专属目录后写入 sha256 sidecar；
    // 使用前核对 sidecar，不符时尝试从 ChatGPT.app 源修复，无法修复则拒绝执行并报错。
    // 只约束专属助手：系统路径的 codex 来自 npm 等无签名分发，不做哈希校验以免误伤。
    static var helperRejectionReason: String?
    static func sha256(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath:path) else { return nil }
        return SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    }
    static func verifyDedicatedHelper(_ helper: String, chatGPTSource: String) -> Bool {
        let sidecar = helper + ".sha256"
        func matches() -> Bool {
            guard let raw = try? String(contentsOfFile:sidecar,encoding:.utf8),
                  let actual = sha256(helper) else { return false }
            let expected = raw.trimmingCharacters(in:.whitespacesAndNewlines)
            return !expected.isEmpty && expected == actual
        }
        if matches() { helperRejectionReason = nil; return true }
        if FileManager.default.isExecutableFile(atPath:chatGPTSource) {
            try? FileManager.default.removeItem(atPath:helper)
            if (try? FileManager.default.copyItem(atPath:chatGPTSource,toPath:helper)) != nil {
                try? FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper)
                if let digest = sha256(helper) { try? digest.write(toFile:sidecar,atomically:true,encoding:.utf8) }
                if matches() {
                    helperRejectionReason = nil
                    Log.connectors.error("dedicated codex helper repaired from ChatGPT.app source")
                    return true
                }
            }
        }
        helperRejectionReason = "专属 Codex 助手校验失败（文件可能已被改动），已拒绝执行。请重新运行安装脚本，或在设置中手动选择 Codex 可执行文件。"
        Log.connectors.error("dedicated codex helper rejected: sha256 mismatch")
        return false
    }
    static var executable: String? {
        let appSupport = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first
        let dedicatedHelper = appSupport?.appendingPathComponent("GaoSeries/Token/bin/codex").path ?? ""
        let chatGPTSource = "/Applications/ChatGPT.app/Contents/Resources/codex"
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let candidates = [
            TokenBundle.defaults.string(forKey:"codexPath") ?? "",
            dedicatedHelper,
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.codex/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            chatGPTSource
        ]
        for path in candidates where !path.isEmpty && FileManager.default.isExecutableFile(atPath:path) {
            if path == dedicatedHelper && !verifyDedicatedHelper(dedicatedHelper, chatGPTSource:chatGPTSource) { continue }
            if path.contains("/Applications/ChatGPT.app") && !dedicatedHelper.isEmpty && !FileManager.default.fileExists(atPath:dedicatedHelper) {
                let helperDir = (dedicatedHelper as NSString).deletingLastPathComponent
                try? FileManager.default.createDirectory(atPath:helperDir,withIntermediateDirectories:true)
                if (try? FileManager.default.copyItem(atPath:path,toPath:dedicatedHelper)) != nil {
                    try? FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:dedicatedHelper)
                    if FileManager.default.isExecutableFile(atPath:dedicatedHelper) {
                        if let digest = sha256(dedicatedHelper) { try? digest.write(toFile:dedicatedHelper + ".sha256",atomically:true,encoding:.utf8) }
                        return dedicatedHelper
                    }
                }
            }
            return path
        }
        return nil
    }
    // V1.9 主路：读用户自己 ~/.codex/auth.json 的 OAuth 凭证 → 官方 usage 端点（进程不在跑也能读）。
    // 凭证只从该文件读、只发往白名单 host chatgpt.com、NoRedirect、不落日志。测试可注入路径。
    static var authFilePath: String = NSHomeDirectory() + "/.codex/auth.json"
    struct AuthCredentials: Equatable {
        var accessToken: String
        var accountID: String
    }
    static func loadAuthCredentials(path: String? = nil) -> AuthCredentials? {
        guard let data = FileManager.default.contents(atPath:path ?? authFilePath),
              let root = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let tokens = root["tokens"] as? [String:Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else { return nil }
        return AuthCredentials(accessToken:token, accountID:(tokens["account_id"] as? String) ?? "")
    }
    enum HTTPOutcome {
        case success(UsageSnapshot)
        case needsFreshCredentials // 401/403 或 auth.json 缺失：app-server 自己续期凭证，走回落
        case failed(Error) // 已消毒的错误（网络/限流/服务不可用/格式不符）
    }
    static func fetchOverHTTP() async -> HTTPOutcome {
        guard let credentials = loadAuthCredentials() else { return .needsFreshCredentials }
        var request = URLRequest(url:URL(string:"https://chatgpt.com/backend-api/wham/usage")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField:"Authorization")
        // 仅在有 account_id 时发送：空头与不命名账户不是一回事。
        if !credentials.accountID.isEmpty { request.setValue(credentials.accountID, forHTTPHeaderField:"ChatGPT-Account-Id") }
        request.setValue("application/json", forHTTPHeaderField:"Accept")
        do {
            let (data, http) = try await Connectors.sendOAuth(request)
            switch http.statusCode {
            case 200:
                guard let root = try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return .failed(Connectors.schemaError) }
                do { return .success(try parseHTTPUsage(root)) } catch { return .failed(error) }
            case 401, 403: return .needsFreshCredentials
            case 429: return .failed(MonitorError.message("平台限流，请稍后刷新（HTTP 429）。上次数据已保留。"))
            default: return .failed(MonitorError.message("服务不可用（HTTP \(http.statusCode)）。上次数据已保留。"))
            }
        } catch { return .failed(error) }
    }
    // 端点是 Codex 客户端内部接口（非公开文档 API），字段名与 app-server 协议不同，单独解析。
    static func parseHTTPUsage(_ root: [String:Any]) throws -> UsageSnapshot {
        var s = UsageSnapshot.empty(source:"Codex 官方接口")
        var plans = Set<String>()
        if let p = root["plan_type"] as? String, !p.isEmpty { plans.insert(planName(p)) }
        let spendReached = (root["spend_control"] as? [String:Any])?["reached"] as? Bool ?? false
        var groups: [(prefix:String, name:String?, limit:[String:Any], spent:Bool)] = []
        if let limit = root["rate_limit"] as? [String:Any] {
            let reached = root["rate_limit_reached_type"] != nil && !(root["rate_limit_reached_type"] is NSNull)
            groups.append(("codex", nil, limit, isGroupSpent(limit) || reached || spendReached))
        }
        for extra in root["additional_rate_limits"] as? [[String:Any]] ?? [] {
            guard let limit = extra["rate_limit"] as? [String:Any] else { continue }
            let label = extra["limit_name"] as? String
            let key = extra["metered_feature"] as? String ?? label ?? "extra"
            groups.append((key, label, limit, isGroupSpent(limit)))
        }
        // 与 app-server 路一致：外来（claude/gemini）额度池在入快照前过滤，绝不进入快照。
        groups = groups.filter { g in
            let text = (g.prefix + " " + (g.name ?? "")).lowercased()
            return !text.contains("claude") && !text.contains("gemini")
        }
        var idCounts: [String:Int] = [:]
        for g in groups {
            let name = g.name ?? g.prefix
            var windows: [Quota] = []
            for (slot, short) in [("primary_window","primary"),("secondary_window","secondary")] {
                guard let node = g.limit[slot] as? [String:Any] else { continue }
                guard let used = Connectors.number(node["used_percent"]), (0...100).contains(used) else { throw Connectors.schemaError }
                let seconds = Connectors.number(node["limit_window_seconds"])
                if let seconds, seconds <= 0 || seconds > 31_536_000 { throw Connectors.schemaError }
                let label: String
                switch seconds {
                case 18_000: label = "5 小时"
                case 604_800: label = "每周"
                case .some(let sec): label = sec >= 60 ? "\(Int(sec / 60)) 分钟" : "\(Int(sec)) 秒"
                default: label = slot == "primary_window" ? "主要窗口" : "次要窗口"
                }
                var id = "\(g.prefix)-\(short)"
                if let seen = idCounts[id] { idCounts[id] = seen + 1; id = "\(id)-\(seen + 1)" } else { idCounts[id] = 1 }
                windows.append(.init(id:id, title:"\(name) · \(label)", usedPercent:used, resetsAt:Connectors.number(node["reset_at"]).map { Date(timeIntervalSince1970:$0) }))
            }
            // spent 语义：「已达上限」是组级标记（一组可能同时含 5 小时与每周窗），只钉在最满的窗口，不摊到整组。
            if g.spent, let fullest = windows.max(by: { $0.usedPercent < $1.usedPercent }) {
                windows = windows.map { w -> Quota in guard w.id == fullest.id else { return w }; var c = w; c.usedPercent = 100; return c }
            }
            s.quotas += windows
        }
        guard !s.quotas.isEmpty else { throw MonitorError.message("该账号未返回可用额度窗口。API Key 登录不能读取会员额度。") }
        s.note = "\(plans.isEmpty ? "" : plans.sorted().joined(separator:" / ") + " · ")额度比例不等同于固定 Token 余额；保留官方独立额度池。"
        try s.validate(); return s
    }
    static func isGroupSpent(_ limit: [String:Any]) -> Bool {
        if limit["limit_reached"] as? Bool == true { return true }
        if limit["allowed"] as? Bool == false { return true }
        return false
    }
    // 端点返回内部档名（如 prolite 是 5× Pro 档）：映射已知档名，未知原样透传而不是抹掉。
    static func planName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "free": return "Free"
        case "go": return "Go"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "prolite": return "Pro 5x"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu": return "Edu"
        default: return raw
        }
    }
    static func fetch() async throws -> UsageSnapshot {
        switch await fetchOverHTTP() {
        case .success(let s): return s
        case .needsFreshCredentials:
            try Task.checkCancellation()
            guard HTTPPolicyContext.userInitiated else { throw MonitorError.message("Codex 凭据缺失或已失效，已停止自动续期请求。请在 Codex 登录后手动同步；上次数据已保留。") }
            Log.connectors.error("codex auth.json route unavailable; falling back to app-server")
            return try await fetchViaAppServer()
        case .failed(let error): throw error
        }
    }
    // V1.8 既有资产：官方文档化 codex app-server JSON-RPC（stdio 一次性会话），作为 401/403/缺凭证时的回落。
    static func fetchViaAppServer() async throws -> UsageSnapshot {
        let cancellation = ConnectorCancellation()
        return try await withTaskCancellationHandler(operation: {
            let value = try await Task.detached(priority: .utility) { try read(cancellation: cancellation) }.value
            try Task.checkCancellation()
            return value
        }, onCancel: { cancellation.cancel() })
    }
    static func read(cancellation: ConnectorCancellation = ConnectorCancellation()) throws -> UsageSnapshot {
        try cancellation.check()
        guard let path = executable else {
            if let reason = helperRejectionReason { throw MonitorError.message(reason) }
            throw MonitorError.message("未找到 Codex。请安装并登录 Codex，或在设置中选择可执行文件。")
        }
        let input = Pipe(), output = Pipe()
        let pid = try spawnQuotaProcess(path: path, arguments: ["app-server","--listen","stdio://"], input: input, output: output)
        cancellation.attachGroup(pid)
        let timer = DispatchSource.makeTimerSource(queue:.global(qos:.utility))
        timer.schedule(deadline:.now() + 35)
        timer.setEventHandler { cancellation.cancel() }; timer.resume()
        defer {
            timer.cancel(); cancellation.finishGroup(pid)
            try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
        }
        try cancellation.check()
        func send(_ value: [String:Any]) throws { var data = try JSONSerialization.data(withJSONObject:value); data.append(10); try input.fileHandleForWriting.write(contentsOf:data) }
        try send(["id":1,"method":"initialize","params":["clientInfo":["name":"gaociyuan","title":"搞词元","version":"0.6.0"]]])
        var buffer = Data()
        while true {
            try cancellation.check()
            let chunk = output.fileHandleForReading.availableData
            try cancellation.check()
            if chunk.isEmpty { throw MonitorError.message("Codex 读取超时或服务退出。请确认已登录且网络可用。") }
            buffer.append(chunk)
            if buffer.count > 4_000_000 { throw Connectors.schemaError }
            while let index = buffer.firstIndex(of:10) {
                let line = buffer.prefix(upTo:index); buffer.removeSubrange(...index)
                guard let obj = try? JSONSerialization.jsonObject(with:line) as? [String:Any], let id = obj["id"] as? Int else { continue }
                if obj["error"] != nil { throw MonitorError.message("Codex 额度读取失败。请在 Codex 中登录会员账号后重试。") }
                if id == 1 { try send(["method":"initialized"]); try send(["id":2,"method":"account/rateLimits/read"] ) }
                if id == 2 {
                    guard let result = obj["result"] as? [String:Any] else { throw Connectors.schemaError }
                    return try parse(result)
                }
            }
        }
    }
    static func parse(_ result: [String:Any]) throws -> UsageSnapshot {
        var pools: [(String,[String:Any])] = []
        if let map = result["rateLimitsByLimitId"] as? [String:[String:Any]], !map.isEmpty { pools = map.sorted(by:{$0.key < $1.key}).map { ($0.key,$0.value) } }
        else if let legacy = result["rateLimits"] as? [String:Any] { pools = [(legacy["limitId"] as? String ?? "codex",legacy)] }
        // Filter foreign (claude/gemini) pools BEFORE appending, so they never enter the snapshot.
        pools = pools.filter { id, _ in !id.lowercased().contains("claude") && !id.lowercased().contains("gemini") }
        var s = UsageSnapshot.empty(source:"Codex 本机服务")
        var plans = Set<String>()
        for (id, pool) in pools {
            if let plan = pool["planType"] as? String { plans.insert(plan) }
            let name = pool["limitName"] as? String ?? id
            for field in ["primary","secondary"] {
                guard let w = pool[field] as? [String:Any] else { continue }
                guard let used = Connectors.number(w["usedPercent"]), (0...100).contains(used) else { throw Connectors.schemaError }
                let duration = Connectors.number(w["windowDurationMins"])
                if let duration, duration <= 0 || duration > 5_256_000 { throw Connectors.schemaError }
                let label: String
                switch duration {
                case 300: label = "5 小时"
                case 10080: label = "每周"
                case .some(let m): label = "\(Int(m)) 分钟"
                default: label = field == "primary" ? "主要窗口" : "次要窗口"
                }
                s.quotas.append(.init(id:"\(id)-\(field)",title:"\(name) · \(label)",usedPercent:used,resetsAt:Connectors.number(w["resetsAt"]).map { Date(timeIntervalSince1970:$0) },windowSeconds:duration.map { $0 * 60 }))
            }
        }
        guard !s.quotas.isEmpty else { throw MonitorError.message("该账号未返回可用额度窗口。API Key 登录不能读取会员额度。") }
        s.note = "\(plans.sorted().joined(separator:" / ")) · 额度比例不等同于固定 Token 余额；保留官方独立额度池。"; try s.validate(); return s
    }
}

enum ClaudeBridge {
    static var historyURL: URL? {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let candidates = [
            appSupport?.appendingPathComponent("Claude/plan-usage-history.json"),
            URL(fileURLWithPath: "\(home)/Library/Application Support/Claude/plan-usage-history.json"),
            URL(fileURLWithPath: "\(home)/.config/Claude/plan-usage-history.json")
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // V1.9 1C 四层链：OAuth 官方端点（主路）→ 可选桌面会话路（默认关，显式选择）→ 状态栏推送钩子 →
    // 旧本地记录（已实现资产保留）→ 缓存（MonitorStore 保留上次数据）+ 可行动的错误。
    static func fetch(_ account: Account, userInitiated: Bool = false) async throws -> ConnectorResult {
        // 1. OAuth 官方端点：读一次凭证（过期 token 仍是「登录过」的证据，且避免每轮两次 security 子进程）。
        // spawn /usr/bin/security 是同步子进程调用：卸载后台队列。
        let credentials = await Task.detached(priority: .userInitiated) { ClaudeOAuth.storedCredentials() }.value
        let hadCredentials = credentials != nil
        if let token = credentials.flatMap({ ClaudeOAuth.unexpiredAccessToken($0) }) {
            switch await ClaudeOAuth.usage(token: token) {
            case .success(let s):
                return .snapshot(s)
            case .needsFreshCredentials:
                break // 落入桌面路 → 状态栏 → 旧记录
            case .failed(let error):
                // 网络类失败不应盖住完好的推送读数：推送路优先，错误留作兜底。
                if let captured = ClaudeStatusLine.capturedUsage() { return .snapshot(captured) }
                if let legacy = legacyHistorySnapshot() { return .snapshot(legacy) }
                throw error
            }
        }
        // 2. 桌面会话路：默认关闭，仅当用户在连接方式里显式选择才启用；
        //    未授权过钥匙串时只在手动同步尝试一次（不反复弹授权框）。
        var desktopFailure: Error?
        var desktopSkippedForPermission = false
        if account.connection == .claudeDesktop {
            if ClaudeDesktop.wasPermitted || userInitiated {
                do {
                    let outcome = try await ClaudeDesktop.usage()
                    // 身份比对：一侧为空不算不匹配；明确不符才拒绝替答。
                    if ClaudeIdentity.maySubstitute(outcome.fingerprint) {
                        return .snapshot(outcome.snapshot)
                    }
                    desktopFailure = MonitorError.message("Claude 桌面端与 CLI 登录的账号不一致，已忽略桌面会话读数。上次数据已保留。")
                } catch { desktopFailure = error }
            } else {
                desktopSkippedForPermission = true
            }
        }
        // 3. 状态栏推送（含 stale 标注与 reset 已过窗口丢弃规则）。
        if let captured = ClaudeStatusLine.capturedUsage() { return .snapshot(captured) }
        // 4. 旧资产：桌面端本地用量记录（observedAt 取记录自身时间戳，陈旧由既有 stale 机制标注）。
        if let legacy = legacyHistorySnapshot() { return .snapshot(legacy) }
        // 收口：沉默 ≠ 失败（push 豁免——已连接状态栏时等待推送是状态不是错误）。
        if let failure = desktopFailure { throw failure }
        if desktopSkippedForPermission {
            throw MonitorError.message("Claude 桌面会话路需要一次钥匙串授权：请点击「立即同步」完成授权。上次数据已保留。")
        }
        if ClaudeStatusLine.isInstalled {
            return .status("Claude Code 状态栏已连接，等待下次会话推送额度数据；上次数据已保留。")
        }
        if hadCredentials {
            throw MonitorError.message("Claude Code 登录已过期，请在 Claude Code 中重新登录，或在设置中连接状态栏推送。上次数据已保留。")
        }
        let status = AgentBridge.detectLocalAgent(account)
        if status.available { return .status(status.message) }
        throw MonitorError.message("未找到 Claude Code 登录凭证。请登录 Claude Code，或在设置中连接状态栏推送。")
    }

    static func legacyHistorySnapshot() -> UsageSnapshot? {
        guard let url = historyURL,
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = json["samples"] as? [[String: Any]], !samples.isEmpty else { return nil }
        return try? parse(samples: samples)
    }

    static func parse(samples: [[String: Any]]) throws -> UsageSnapshot {
        var s = UsageSnapshot.empty(source: "Claude Code 本机服务")
        
        var targetUtilization: [String: Double] = [:]
        var targetDate: Date?

        for sample in samples.reversed() {
            if let u = sample["u"] as? [String: Any], !u.isEmpty {
                var map: [String: Double] = [:]
                for (k, v) in u {
                    if let d = Connectors.number(v) {
                        map[k] = d
                    }
                }
                if !map.isEmpty {
                    targetUtilization = map
                    if let ts = Connectors.number(sample["t"]) {
                        targetDate = Date(timeIntervalSince1970: ts / 1000.0)
                    }
                    break
                }
            } else if let fh = Connectors.number(sample["fh"]) {
                var map: [String: Double] = ["fh": fh]
                if let sd = Connectors.number(sample["sd"]) { map["sd"] = sd }
                targetUtilization = map
                if let ts = Connectors.number(sample["t"]) {
                    targetDate = Date(timeIntervalSince1970: ts / 1000.0)
                }
                break
            }
        }

        guard let targetDate, !targetUtilization.isEmpty else {
            throw MonitorError.message("Claude 本地用量记录暂无有效配额数据。请在 Claude 中使用后点击同步。")
        }

        s.observedAt = targetDate

        var fiveHourReset: Date? = nil
        var lastZeroTs: Double? = nil
        for sample in samples {
            let u = sample["u"] as? [String: Any] ?? [:]
            let fh = Connectors.number(u["fh"] ?? sample["fh"])
            let ts = Connectors.number(sample["t"])
            if let fh, let ts {
                if fh == 0 {
                    lastZeroTs = ts
                } else if fh > 0, let start = lastZeroTs {
                    let windowEnd = Date(timeIntervalSince1970: (start / 1000.0) + 5 * 3600)
                    if windowEnd > Date() {
                        fiveHourReset = windowEnd
                    }
                }
            }
        }

        if let fh = targetUtilization["fh"] {
            s.quotas.append(Quota(id: "claude-5h", title: "Claude · 5 小时", usedPercent: fh, resetsAt: fiveHourReset, windowSeconds: 18000))
        }
        if let sd = targetUtilization["sd"] {
            s.quotas.append(Quota(id: "claude-weekly", title: "Claude · 每周", usedPercent: sd, resetsAt: nil))
        }
        if let so = targetUtilization["so"] {
            s.quotas.append(Quota(id: "claude-opus-weekly", title: "Claude Opus · 每周", usedPercent: so, resetsAt: nil))
        }
        if let sn = targetUtilization["sn"] {
            s.quotas.append(Quota(id: "claude-sonnet-weekly", title: "Claude Sonnet · 每周", usedPercent: sn, resetsAt: nil))
        }
        if let cw = targetUtilization["cw"] {
            s.quotas.append(Quota(id: "claude-cowork-weekly", title: "Claude Cowork · 每周", usedPercent: cw, resetsAt: nil))
        }
        if let xu = targetUtilization["xu"] {
            s.quotas.append(Quota(id: "claude-extra-usage", title: "Claude · 额外用量", usedPercent: xu, resetsAt: nil))
        }

        guard !s.quotas.isEmpty else {
            throw MonitorError.message("未从 Claude 本地记录中解析到额度池。")
        }

        s.note = "Claude Code 本机服务 · 自动读取本地客户端用量数据"
        try s.validate()
        return s
    }
}

enum AgentBridge {
    static func fetch(_ account: Account, userInitiated: Bool = false) async throws -> ConnectorResult {
        try Task.checkCancellation()
        let p = account.provider
        switch p {
        case .openai:
            return .snapshot(try await CodexBridge.fetch())
        case .claude:
            return try await ClaudeBridge.fetch(account, userInitiated: userInitiated)
        case .grok:
            return try await GrokBotBridge.fetch(account, userInitiated: userInitiated)
        case .gemini:
            return .status(AntigravityUsageReport.manualHint)
        case .doubao:
            return try await DoubaoBridge.fetch(account, userInitiated: userInitiated)
        case .minimax:
            if let key = readKey(account.id), !key.isEmpty {
                return .snapshot(try await OfficialExtras.fetch(account, key: key))
            }
            return .status(detectLocalAgent(account).message)
        case .glm:
            if let key = readKey(account.id), !key.isEmpty {
                return .snapshot(try await OfficialExtras.fetch(account, key: key))
            }
            return .status(detectLocalAgent(account).message)
        case .kimi:
            if let key = readKey(account.id), !key.isEmpty {
                return .snapshot(try await OfficialExtras.fetchKimiCoding(key: key))
            }
            return .status(detectLocalAgent(account).message)
        default:
            return .status(detectLocalAgent(account).message)
        }
    }

    // 钥匙串读取失败按无 Key 处理并落脱敏日志（只记连接器名与错误类别，不记数值/凭据/路径）。
    private static func readKey(_ id: UUID) -> String? {
        do { return try KeyVault.read(id) }
        catch { Log.connectors.error("agent-bridge keychain read failed"); return nil }
    }

    // 本机软件状态文案：只作状态展示，不产生额度快照。
    static func detectLocalAgent(_ account: Account) -> AgentStatus {
        let p = account.provider
        let agentName = p.agentSoftware
        let running = NSWorkspace.shared.runningApplications
        let isRunning = MemberDiscovery.isAgentRunning(p, in: running)
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let candidateBins = AgentPlatformTable.cliCandidates(p, home: home, appSupport: "", includeDedicatedHelper: false)
        let cliFound = candidateBins.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
        if isRunning || cliFound != nil {
            return AgentStatus(available: true, message: "\(agentName) 软件运行中。请在软件中打开额度详情（如点头像-额度状态）后点击同步，不预填额度。")
        }
        return AgentStatus(available: false, message: "\(agentName) 暂未启动。启动本机软件并查看额度后自动读取，不预填额度。")
    }
}


// MARK: - DeepSeek 余额分母（实测口径）

// DeepSeek 的 /user/balance 只说还剩多少钱——没有额度、没有窗口、没有重置、没有消费历史。
// 环需要分母，而分母只有三个诚实来源：观测到的充值峰值（默认）、不分母（只显示钱）、
// 用户自认的满罐数字。峰值的全部诚实性在于「实测而非推断」：余额上升只可能是充值，
// 此时重置标记从满重新计。第一次观测没有历史，峰值即当前余额、环读 0%——这是对
// 「我们看见过什么」的真实陈述，note 写明观测起始日期。峰值按币种分开：人民币峰值
// 不是美元余额的分母。
enum DeepSeekBasis {
    enum Mode: String {
        case sinceTopUp, balanceOnly, budget
        static func of(_ raw: String?) -> Mode { Mode(rawValue: raw ?? "") ?? .sinceTopUp }
    }

    static func apply(account: inout Account, snapshot: inout UsageSnapshot, now: Date = Date()) {
        switch Mode.of(account.balanceBasis) {
        case .balanceOnly:
            snapshot.note = (snapshot.note ?? "") + " 仅显示余额，无分母。"
        case .budget:
            if let budget = account.budget, budget > 0,
               let balance = snapshot.balances.first(where: { $0.currency == account.currency }) {
                let used = max(0, min(100, (budget - balance.value) / budget * 100))
                snapshot.quotas = [.init(id: "deepseek-budget", title: "DeepSeek 余额 · 预算口径", usedPercent: used, resetsAt: nil)]
                snapshot.note = (snapshot.note ?? "") + " 分母为自填预算 \(account.currency) \(budget)，自填数字不是平台口径。"
            }
        case .sinceTopUp:
            var marks = account.baselines ?? [:]
            var quotas: [Quota] = []
            var oldest: Date?
            for balance in snapshot.balances {
                let mark: BaselineMark
                if let existing = marks[balance.currency], balance.value <= existing.peak {
                    mark = existing
                } else {
                    // 首次观测或余额上升（只可能是充值）：重置标记从满计。
                    mark = BaselineMark(peak: max(0, balance.value), setAt: now)
                }
                marks[balance.currency] = mark
                oldest = min(oldest ?? mark.setAt, mark.setAt)
                // 峰值为 0 是从未有过余额的账号，与「花光了」不是一回事，不给分母。
                guard mark.peak > 0 else { continue }
                let used = max(0, min(100, (mark.peak - balance.value) / mark.peak * 100))
                quotas.append(.init(id: "deepseek-topup-\(balance.currency)", title: "DeepSeek 余额（\(balance.currency)）· 充值以来", usedPercent: used, resetsAt: nil))
            }
            account.baselines = marks
            snapshot.quotas = quotas
            if let oldest {
                snapshot.note = (snapshot.note ?? "") + " 分母为自 \(displayDate(oldest, time: false)) 起本机观测到的余额峰值（实测口径，余额上升即视为充值重新计满）。"
            }
        }
    }
}
