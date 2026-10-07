import Foundation
import CryptoKit

// Fixed read-only routes. No browser cookies, model calls, purchases or limit mutations.
enum OfficialExtras {
    static func fetch(_ a: Account, key: String) async throws -> UsageSnapshot {
        switch a.connection {
        case .minimax:
            let host = a.region == "global" ? "www.minimax.io" : "www.minimaxi.com"
            // 新旧两条路径任何失败都互试（老套餐在新路径上答 401 而不是 404），
            // 但保留**第一个**失败原因：新路径的「密钥被拒」不能被旧路径的 miss 盖掉。
            var firstError: Error?
            for path in ["/v1/token_plan/remains", "/v1/api/openplatform/coding_plan/remains"] {
                do { return try parseMiniMax(await Connectors.get("https://\(host)\(path)",key:key)) }
                catch { if firstError == nil { firstError = error } }
            }
            throw firstError ?? Connectors.schemaError
        case .glm:
            let host = a.region == "global" ? "api.z.ai" : "open.bigmodel.cn"
            return try parseGLM(await Connectors.get("https://\(host)/api/monitor/usage/quota/limit",key:key,rawAuth:true))
        case .kimiCoding:
            return try await fetchKimiCoding(key:key)
        case .xai:
            let team = try identifier(a.scopeID)
            let now = Date(), start = monthStart(now)
            let f = DateFormatter(); f.locale = Locale(identifier:"en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT:0); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            var request = URLRequest(url:URL(string:"https://management-api.x.ai/v1/billing/teams/\(team)/usage")!)
            request.httpMethod = "POST"; request.setValue("Bearer \(key)",forHTTPHeaderField:"Authorization"); request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject:["analyticsRequest":["timeRange":["startTime":f.string(from:start),"endTime":f.string(from:now),"timezone":"Etc/GMT"],"timeUnit":"TIME_UNIT_DAY","values":[["name":"usd","aggregation":"AGGREGATION_SUM"]],"groupBy":["description"],"filters":[]]])
            let usage = try await Connectors.send(request)
            let balance = try await Connectors.get("https://management-api.x.ai/v1/billing/teams/\(team)/prepaid/balance",key:key)
            return try parseXAI(usage,balance:balance,start:start,end:now)
        case .aliyun:
            let request = try aliyunRequest(id:identifier(a.scopeID),secret:key)
            return try parseAliyun(await Connectors.send(request))
        case .volc:
            let request = try volcRequest(id:identifier(a.scopeID),secret:key)
            return try parseVolc(await Connectors.send(request))
        case .volcArk:
            return try await VolcArkBridge.fetch(id:identifier(a.scopeID),secret:key)
        case .mimoCoding:
            return try await XiaomiBridge.fetch(cookieHeader:XiaomiBridge.cookieHeader(from:key))
        default: throw Connectors.schemaError
        }
    }
    static func identifier(_ value: String?) throws -> String {
        guard let v = value, !v.isEmpty, v.utf8.count <= 256, v.allSatisfy({$0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")}) else { throw MonitorError.message("请填写有效的 Team ID 或 AccessKey ID。") }; return v
    }
    static func monthStart(_ date: Date) -> Date { var c = Calendar(identifier:.gregorian); c.timeZone = TimeZone(secondsFromGMT:0)!; return c.date(from:c.dateComponents([.year,.month],from:date))! }
    static func parseMiniMax(_ body: [String:Any]) throws -> UsageSnapshot {
        // base_resp.status_code 是服务自己的裁决，不是 HTTP 状态：坏 key 也是个好 200。
        // 但不是每个非零都是坏 key：1004 及凭证字样是认证，其余是服务在过糟糕的一天。
        if let base = body["base_resp"] as? [String:Any], let status = Connectors.number(base["status_code"]), status != 0 {
            let said = (base["status_msg"] as? String)?.lowercased() ?? ""
            let credential = status == 1004 || ["token","auth","login","cookie","credential"].contains(where: said.contains)
            throw credential
                ? MonitorError.message("MiniMax 密钥无效或已过期（国内站与国际站密钥互不通用，请检查服务地区）。上次数据已保留。")
                : MonitorError.message("MiniMax 服务暂不可用（状态码 \(Int(status))）。上次数据已保留。")
        }
        // 载荷不总在 data 下：有些应答直接放 root，只读 data 会把好账号报成「没有额度」。
        let payload = body["data"] as? [String:Any] ?? body
        guard let models = payload["model_remains"] as? [[String:Any]] else { throw Connectors.schemaError }
        var s = UsageSnapshot.empty(source:"MiniMax 官方 Token Plan API")
        for (i,row) in models.enumerated() {
            let rawName = (row["model_name"] as? String)?.trimmingCharacters(in:.whitespaces) ?? ""
            // "general" 是套餐本身而不是模型，留空标题前缀——「5 小时 · general」什么都没说。
            let name = rawName.isEmpty || rawName.lowercased() == "general" ? nil : rawName
            let key = name ?? "lane\(i)"
            // 短窗：长度从自己两个时间戳量出（实测均为 5 小时），缺时间戳丢弃而不是假定；
            // 每周窗自己声明长度，没有戳也能活。
            if !mmUnavailable(status:Connectors.number(row["current_interval_status"]),total:Connectors.number(row["current_interval_total_count"]),remainingPercent:Connectors.number(row["current_interval_remaining_percent"])),
               let used = mmSpent(percentRemaining:Connectors.number(row["current_interval_remaining_percent"]),total:Connectors.number(row["current_interval_total_count"]),left:Connectors.number(row["current_interval_usage_count"])),
               let start = Connectors.number(row["start_time"]), let end = Connectors.number(row["end_time"]), end > start {
                let seconds = Int((end - start) / 1000)
                if seconds > 0 {
                    let label = seconds == 18000 ? "5 小时" : "当前窗口"
                    s.quotas.append(.init(id:"minimax-\(key)-interval",title:mmTitle(name,label),usedPercent:used,resetsAt:Date(timeIntervalSince1970:end / 1000),windowSeconds:Double(seconds)))
                }
            }
            if !mmUnavailable(status:Connectors.number(row["current_weekly_status"]),total:Connectors.number(row["current_weekly_total_count"]),remainingPercent:Connectors.number(row["current_weekly_remaining_percent"])),
               let used = mmSpent(percentRemaining:Connectors.number(row["current_weekly_remaining_percent"]),total:Connectors.number(row["current_weekly_total_count"]),left:Connectors.number(row["current_weekly_usage_count"])) {
                let reset = Connectors.number(row["weekly_end_time"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970:$0 / 1000) : nil }
                s.quotas.append(.init(id:"minimax-\(key)-weekly",title:mmTitle(name,"每周"),usedPercent:used,resetsAt:reset,windowSeconds:604_800))
            }
        }
        guard !s.quotas.isEmpty else { throw MonitorError.message("平台未返回有效套餐额度，请确认使用 Token Plan 专用密钥。") }
        let plan = ["current_subscribe_title","plan_name","combo_title","current_plan_title"].lazy.compactMap { (payload[$0] as? String)?.trimmingCharacters(in:.whitespaces) }.first { !$0.isEmpty }
        s.note = "\(plan.map { "\($0) · " } ?? "")报的是剩余（已反转）；计数与百分比同为字符串/数字双形态；status 3 未开通车道与无限车道不画；短窗长度由时间戳量出。"; try s.validate(); return s
    }
    static func mmTitle(_ name: String?, _ label: String) -> String { name.map { "\($0) · \(label)" } ?? "MiniMax · \(label)" }
    // 订阅不含的车道：status 3、零配额、100% 剩余——无视频套餐上的视频车道。照字面是给账号
    // 不能用的东西画 0% 环；同形态也覆盖真无限车道，同样没有可画的百分比。
    static func mmUnavailable(status: Double?, total: Double?, remainingPercent: Double?) -> Bool {
        status == 3 && (total ?? 0) == 0 && (remainingPercent ?? 0) >= 100
    }
    // 全部是「剩余」语义：百分比 96 = 已用 4%；计数同样——*_usage_count 名字说反了，它装的是
    // 剩余配额（官方 CLI 约定），当花费读会把卡上每个数字倒过来。百分比优先，计数是老端点唯一的形态。
    static func mmSpent(percentRemaining: Double?, total: Double?, left: Double?) -> Double? {
        if let percentRemaining { return min(max(100 - percentRemaining, 0), 100) }
        guard let total, total > 0, let left else { return nil }
        return min(max((total - left) / total * 100, 0), 100)
    }
    static func parseGLM(_ body: [String:Any]) throws -> UsageSnapshot {
        // 信封自己的裁决：HTTP 200 也可能 success:false（坏 key 就是好 200）。但拒绝不都是 key 的错，
        // 先按信封短语/编号分清「无订阅」「认证失败」「服务故障」，再进成功路径。
        let succeeded = (body["success"] as? Bool) ?? true
        let code = Connectors.number(body["code"]) ?? 200
        if !succeeded || (code != 200 && code != 0) { throw glmProblem(body, code: code) }
        let data = body["data"] as? [String:Any] ?? body
        guard let limits = data["limits"] as? [[String:Any]] else { throw Connectors.schemaError }
        var s = UsageSnapshot.empty(source:"GLM 官方 Coding Plan 接口")
        var rows: [(minutes:Int, quota:Quota)] = []
        for (i,row) in limits.enumerated() {
            // 只有这三种承载额度；服务以后加的新类型丢弃，不猜标题。
            guard let type = row["type"] as? String, ["TOKENS_LIMIT","CREDIT_LIMIT","TIME_LIMIT"].contains(type),
                  let unit = Connectors.number(row["unit"]), let num = Connectors.number(row["number"]),
                  let minutes = glmMinutes(unit:Int(unit), number:Int(num), type:type),
                  let used = glmUsed(row) else { continue }
            let label: String
            if type == "TIME_LIMIT" { label = "MCP 工具 · \(glmWindowName(minutes))" }
            else { label = "编程额度 · \(glmWindowName(minutes))" }
            let reset = Connectors.number(row["nextResetTime"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970:$0 / 1000) : nil }
            rows.append((minutes,.init(id:"glm-\(type)-\(Int(unit))-\(Int(num))-\(i)",title:label,usedPercent:used,resetsAt:reset,windowSeconds:Double(minutes * 60))))
        }
        s.quotas = rows.sorted { $0.minutes < $1.minutes }.map(\.quota)
        guard !s.quotas.isEmpty else { throw Connectors.schemaError }
        let plan = ["planName","plan","plan_type","packageName","level"].lazy.compactMap { (data[$0] as? String)?.trimmingCharacters(in:.whitespaces) }.first { !$0.isEmpty }
        s.note = "\(plan.map { "\($0) · " } ?? "")计数优先（currentValue > 配额−remaining > percentage 兜底）；窗口长度由 unit×number 读出，nextResetTime 为毫秒。"
        try s.validate(); return s
    }
    // 信封拒绝的真实原因。顺序即语义：「coding plan」短语最先——500 是这家厂商的通用编号，单看会
    // 把「账号无订阅」说成服务故障；短语在英文应答里也内嵌，中英文一次覆盖。1000 段是智谱自己的
    // 认证族（实测 1000 身份验证失败 / 1001 缺 Authorization 头），编号表未公开，按文字匹配兜住。
    static func glmProblem(_ body: [String:Any], code: Double) -> Error {
        let said = ((body["msg"] as? String) ?? (body["message"] as? String) ?? "").lowercased()
        if said.contains("coding plan") {
            return MonitorError.message("该账号没有进行中的 Coding Plan 订阅（密钥本身有效）。请开通订阅后重试。上次数据已保留。")
        }
        let authWords = ["token","auth","key","unauthor","forbidden","credential","身份验证","鉴权","认证","令牌","未授权","无权限","密钥"]
        if authWords.contains(where: said.contains) || code == 401 || code == 403 || (1000...1099).contains(code) {
            return MonitorError.message("GLM 密钥无效或未授权（国内站与国际站密钥互不通用，请检查服务地区）。上次数据已保留。")
        }
        if code == 429 { return MonitorError.message("平台限流，请稍后刷新（HTTP 429）。上次数据已保留。") }
        return MonitorError.message("GLM 服务暂不可用（状态码 \(Int(code))）。上次数据已保留。")
    }
    // 窗长 = unit 码 × number（1=天 3=小时 5=分钟 6=周）；不认识的 unit 丢弃而不是猜。
    // MCP 车道把每月额度报成「1 minute」——那是标记不是时长，照字面会排在 5 小时之上并号称每分钟重置。
    static func glmMinutes(unit: Int, number: Int, type: String) -> Int? {
        if type == "TIME_LIMIT", unit == 5, number == 1 { return 30 * 24 * 60 }
        let perUnit = [1: 1440, 3: 60, 5: 1, 6: 10080]
        guard number > 0, let multiplier = perUnit[unit] else { return nil }
        return number * multiplier
    }
    static func glmWindowName(_ minutes: Int) -> String {
        switch minutes {
        case 300: return "5 小时"
        case 10080: return "每周"
        case 43200: return "每月"
        default:
            if minutes >= 1440, minutes % 1440 == 0 { return "\(minutes / 1440) 天" }
            if minutes >= 60, minutes % 60 == 0 { return "\(minutes / 60) 小时" }
            return "\(minutes) 分钟"
        }
    }
    // 计数优先：remaining 是剩余，花掉的是差值；currentValue 是服务在往上数的那个，两者都有时它赢。
    // percentage 是整数，只是兜底（实测 percentage:7 配 usage:1000/remaining:247，实际已用 75%）。
    // 没有任何数字的窗口是读数缺失，不是 0%——丢弃，绝不画满绿环。
    static func glmUsed(_ row: [String:Any]) -> Double? {
        if let usage = Connectors.number(row["usage"]), usage > 0 {
            var used: Double?
            if let remaining = Connectors.number(row["remaining"]) {
                used = max(usage - remaining, Connectors.number(row["currentValue"]) ?? (usage - remaining))
            } else if let current = Connectors.number(row["currentValue"]) {
                used = current
            }
            if let used { return min(max(min(used, usage) / usage * 100, 0), 100) }
        }
        guard let percentage = Connectors.number(row["percentage"]) else { return nil }
        return min(max(percentage, 0), 100)
    }
    static func fetchKimiCoding(key: String) async throws -> UsageSnapshot {
        try parseKimiCoding(await Connectors.get("https://api.kimi.com/coding/v1/usages",key:key))
    }
    // resetTime may be an ISO 8601 string, milliseconds, or seconds; invalid values yield nil, never an error.
    static func kimiResetTime(_ value: Any?) -> Date? {
        if let text = value as? String {
            let f = ISO8601DateFormatter()
            if let d = f.date(from:text) { return d }
            f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
            if let d = f.date(from:text) { return d }
            guard let n = Connectors.number(text) else { return nil }
            return kimiResetTime(n)
        }
        guard let n = Connectors.number(value), n > 0 else { return nil }
        return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
    }
    static func parseKimiCoding(_ body: [String:Any]) throws -> UsageSnapshot {
        var s = UsageSnapshot.empty(source:"Kimi Code 官方额度 API")
        // limits[] is a 5-hour window per entry; quota fields may nest under "detail" or sit flat on the item.
        if let limits = body["limits"] as? [[String:Any]] {
            for (i,item) in limits.enumerated() {
                let detail = item["detail"] as? [String:Any] ?? item
                guard let limit = Connectors.number(detail["limit"]), limit > 0,
                      let remaining = Connectors.number(detail["remaining"]), remaining >= 0 else { continue }
                let used = max(0, limit - remaining)
                let title = s.quotas.isEmpty ? "Kimi Code · 5 小时" : "Kimi Code · 5 小时 \(s.quotas.count + 1)"
                s.quotas.append(.init(id:"kimi-coding-5h-\(i)",title:title,usedPercent:used / limit * 100,resetsAt:kimiResetTime(detail["resetTime"]),windowSeconds:18_000))
            }
        }
        // usage is the weekly window; totalQuota is a known-broken field (always 99) and must be ignored.
        if let usage = body["usage"] as? [String:Any],
           let limit = Connectors.number(usage["limit"]), limit > 0,
           let remaining = Connectors.number(usage["remaining"]), remaining >= 0 {
            let used = max(0, limit - remaining)
            s.quotas.append(.init(id:"kimi-coding-weekly",title:"Kimi Code · 每周",usedPercent:used / limit * 100,resetsAt:kimiResetTime(usage["resetTime"]),windowSeconds:604_800))
        }
        guard !s.quotas.isEmpty else { throw MonitorError.message("Kimi Code 未返回有效额度窗口，请确认 Key 对应已开通的 Kimi Code 订阅。") }
        s.note = "Kimi Code 官方接口；百分比由配额点数（limit − remaining）换算；已知异常的 totalQuota 字段未采用。"
        try s.validate(); return s
    }
    static func parseXAI(_ usage: [String:Any], balance: [String:Any], start: Date, end: Date) throws -> UsageSnapshot {
        guard usage["limitReached"] as? Bool == false, let series = usage["timeSeries"] as? [[String:Any]], let total = balance["total"] as? [String:Any], let cents = Connectors.number(total["val"]) else { throw Connectors.schemaError }
        var cost = 0.0
        for item in series {
            guard let points = item["dataPoints"] as? [[String:Any]] else { throw Connectors.schemaError }
            for point in points { guard let values = point["values"] as? [Any], values.count == 1, let n = Connectors.number(values[0]) else { throw Connectors.schemaError }; cost += n }
        }
        var s = UsageSnapshot.empty(source:"xAI 官方 Management API"); s.periodStart = start; s.periodEnd = end
        s.costs = [.init(currency:"USD",value:cost)]
        // Billing API represents prepaid credit as negative USD cents (official PURCHASE example).
        s.balances = [.init(currency:"USD",value:-cents / 100)]
        s.note = "UTC 本月团队 API 费用及预付余额；不含 Grok 会员额度，接口未提供本次查询的 Token 总数。"; try s.validate(); return s
    }
    static func parseAliyun(_ body: [String:Any]) throws -> UsageSnapshot {
        guard body["Success"] as? Bool == true, Connectors.number(body["Code"]) == 200, let data = body["Data"] as? [String:Any], let c = data["Currency"] as? String, let value = Connectors.number(data["AvailableCashAmount"]) else { throw Connectors.schemaError }
        var s = UsageSnapshot.empty(source:"阿里云官方 BSS API"); s.balances = [.init(currency:c,value:value)]; s.note = "整个阿里云账号的现金余额，包含其他云产品；不是 Qwen 独占额度，不包含授信额度。"; try s.validate(); return s
    }
    static func parseVolc(_ body: [String:Any]) throws -> UsageSnapshot {
        guard let meta = body["ResponseMetadata"] as? [String:Any], meta["Error"] == nil, let result = body["Result"] as? [String:Any], let value = Connectors.number(result["AvailableBalance"]) else { throw Connectors.schemaError }
        var s = UsageSnapshot.empty(source:"火山引擎官方 Billing API"); s.balances = [.init(currency:"CNY",value:value)]; s.note = "火山引擎国内云账号可用余额，可能包含授信并扣除冻结款；不是豆包会员或方舟独占额度。"; try s.validate(); return s
    }
    static func escaped(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters:CharacterSet(charactersIn:"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"))! }
    static func query(_ parameters: [String:String]) -> String { parameters.sorted(by:{$0.key < $1.key}).map { escaped($0.key) + "=" + escaped($0.value) }.joined(separator:"&") }
    static func aliyunSignature(_ parameters: [String:String], secret: String) -> String {
        let content = "GET&%2F&" + escaped(query(parameters))
        return Data(HMAC<Insecure.SHA1>.authenticationCode(for:Data(content.utf8),using:SymmetricKey(data:Data((secret + "&").utf8)))).base64EncodedString()
    }
    static func aliyunRequest(id: String, secret: String, now: Date = Date(), nonce: String = UUID().uuidString) throws -> URLRequest {
        var params = ["AccessKeyId":id,"Action":"QueryAccountBalance","Format":"JSON","Version":"2017-12-14","SignatureMethod":"HMAC-SHA1","SignatureVersion":"1.0","SignatureNonce":nonce,"Timestamp":ISO8601DateFormatter().string(from:now)]
        params["Signature"] = aliyunSignature(params,secret:secret)
        var r = URLRequest(url:URL(string:"https://business.aliyuncs.com/?" + query(params))!); r.httpMethod = "GET"; return r
    }
    static func sha(_ d: Data) -> String { SHA256.hash(data:d).map { String(format:"%02x",$0) }.joined() }
    static func mac(_ key: Data,_ value: String) -> Data { Data(HMAC<SHA256>.authenticationCode(for:Data(value.utf8),using:SymmetricKey(data:key))) }
    static func volcRequest(id: String, secret: String, now: Date = Date()) throws -> URLRequest {
        let f = DateFormatter(); f.locale = Locale(identifier:"en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT:0); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = f.string(from:now), date = String(timestamp.prefix(8)), host = "open.volcengineapi.com"
        let q = "Action=QueryBalanceAcct&Version=2022-01-01", hash = sha(Data())
        let headers = "host:\(host)\nx-content-sha256:\(hash)\nx-date:\(timestamp)\n", signed = "host;x-content-sha256;x-date"
        let canonical = ["GET","/",q,headers,signed,hash].joined(separator:"\n")
        let scope = "\(date)/cn-north-1/billing/request"
        let signString = ["HMAC-SHA256",timestamp,scope,sha(Data(canonical.utf8))].joined(separator:"\n")
        let signingKey = mac(mac(mac(mac(Data(secret.utf8),date),"cn-north-1"),"billing"),"request")
        let signature = mac(signingKey,signString).map { String(format:"%02x",$0) }.joined()
        var r = URLRequest(url:URL(string:"https://\(host)/?\(q)")!); r.httpMethod = "GET"
        r.setValue(host,forHTTPHeaderField:"Host"); r.setValue(timestamp,forHTTPHeaderField:"X-Date"); r.setValue(hash,forHTTPHeaderField:"X-Content-Sha256")
        r.setValue("HMAC-SHA256 Credential=\(id)/\(scope), SignedHeaders=\(signed), Signature=\(signature)",forHTTPHeaderField:"Authorization"); return r
    }
    // Ark Coding Plan 签名：AWS SigV4 变体——scope 终结符是 request 不是 aws4_request，service 是 ark，
    // region 常量 cn-beijing（写错会以签名不匹配失败，是最没帮助的可设置项）；签名头小写排序。
    static func arkRequest(id: String, secret: String, action: String, now: Date = Date()) throws -> URLRequest {
        let f = DateFormatter(); f.locale = Locale(identifier:"en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT:0); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = f.string(from:now), date = String(timestamp.prefix(8)), host = "open.volcengineapi.com"
        let q = query(["Action":action,"Version":"2024-01-01"]), hash = sha(Data())
        let headers = "host:\(host)\nx-content-sha256:\(hash)\nx-date:\(timestamp)\n", signed = "host;x-content-sha256;x-date"
        let canonical = ["GET","/",q,headers,signed,hash].joined(separator:"\n")
        let scope = "\(date)/cn-beijing/ark/request"
        let signString = ["HMAC-SHA256",timestamp,scope,sha(Data(canonical.utf8))].joined(separator:"\n")
        let signingKey = mac(mac(mac(mac(Data(secret.utf8),date),"cn-beijing"),"ark"),"request")
        let signature = mac(signingKey,signString).map { String(format:"%02x",$0) }.joined()
        var r = URLRequest(url:URL(string:"https://\(host)/?\(q)")!); r.httpMethod = "GET"
        r.setValue(host,forHTTPHeaderField:"Host"); r.setValue(timestamp,forHTTPHeaderField:"X-Date"); r.setValue(hash,forHTTPHeaderField:"X-Content-Sha256")
        r.setValue("HMAC-SHA256 Credential=\(id)/\(scope), SignedHeaders=\(signed), Signature=\(signature)",forHTTPHeaderField:"Authorization"); return r
    }
}
