import Foundation
import CoreFoundation

// Native adapters derived from Token Monitor's MIT-licensed provider contracts.
// Reference: Javis603/token-monitor, Copyright (c) 2026 Javis.
// Credentials are supplied by KeyVault callers, never read from unrelated apps here.
enum ProviderCloudHTTP {
    static let agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
    static func secret(_ value: String) throws -> String {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result.utf8.count <= 65_536, !result.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw MonitorError.message("凭据为空或含有非法控制字符，请重新粘贴。")
        }
        return result
    }
    static func cookie(_ value: String) throws -> String {
        var text = try secret(value)
        if text.lowercased().hasPrefix("cookie:") { text = String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        let pairs = text.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !pairs.isEmpty, pairs.allSatisfy({ pair in
            guard let split = pair.firstIndex(of: "=") else { return false }
            let name = String(pair[..<split]).trimmingCharacters(in: .whitespaces)
            return name.range(of: #"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$"#, options: .regularExpression) != nil
        }) else { throw MonitorError.message("请粘贴完整 Cookie 请求头，不能使用网页地址或 API Key 代替。") }
        return pairs.joined(separator: "; ")
    }
    static func n(_ raw: Any?) -> Double? {
        if let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { return value.doubleValue.isFinite ? value.doubleValue : nil }
        if let text = raw as? String, let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite { return value }
        return nil
    }
    static func b(_ raw: Any?) -> Bool? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }
    static func date(_ raw: Any?) -> Date? {
        if let n = n(raw), n > 0 { return Date(timeIntervalSince1970: n >= 1e12 ? n / 1000 : n) }
        guard let text = raw as? String else { return nil }
        for fractional in [true, false] {
            let f = ISO8601DateFormatter(); f.formatOptions = fractional ? [.withInternetDateTime,.withFractionalSeconds] : [.withInternetDateTime]
            if let d = f.date(from: text) { return d }
        }
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 8 * 3600); f.dateFormat = format; f.isLenient = false
            if let d = f.date(from: text) { return d }
        }
        return nil
    }
    static func request(_ url: URL, provider: String, method: String = "GET", headers: [String:String] = [:], body: Data? = nil, timeout: Double = 20) async throws -> Data {
        try Task.checkCancellation()
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw MonitorError.message("\(provider) 查询地址无效。") }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body; request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept"); request.setValue(agent, forHTTPHeaderField: "User-Agent")
        for (key,value) in headers { request.setValue(try secret(value), forHTTPHeaderField: key) }
        let (data,response): (Data,URLResponse)
        do { (data,response) = try await BoundedHTTP.data(for: request, session: Connectors.session) }
        catch is CancellationError { throw CancellationError() }
        catch { if (error as? URLError)?.code == .cancelled { throw CancellationError() }; throw MonitorError.message("\(provider) 网络请求未完成，请稍后重试。上次数据已保留。") }
        guard let http = response as? HTTPURLResponse else { throw Connectors.schemaError }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 403, http.value(forHTTPHeaderField: "cf-mitigated") == "challenge" { throw MonitorError.message("\(provider) 被网站验证拦截，请在官网确认访问状态。上次数据已保留。") }
            if http.statusCode == 401 || http.statusCode == 403 || (300..<400).contains(http.statusCode) { throw MonitorError.message("\(provider) 凭证已被拒绝或会话已过期，请重新登录官网并更新凭据。上次数据已保留。") }
            if http.statusCode == 429 { throw MonitorError.message("\(provider) 查询限流，请稍后重试。上次数据已保留。") }
            throw MonitorError.message("\(provider) 查询失败（HTTP \(http.statusCode)）。上次数据已保留。")
        }
        guard data.count <= 8 * 1024 * 1024 else { throw MonitorError.message("\(provider) 响应超出支持大小。上次数据已保留。") }
        return data
    }
    static func json(_ url: URL, provider: String, method: String = "GET", headers: [String:String] = [:], body: Data? = nil, timeout: Double = 20) async throws -> [String:Any] {
        let data = try await request(url, provider: provider, method: method, headers: headers, body: body, timeout: timeout)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String:Any] else { throw MonitorError.message("\(provider) 返回格式已变化，请确认登录状态。上次数据已保留。") }
        return json
    }
    static func finish(_ snapshot: UsageSnapshot) throws -> UsageSnapshot { try Task.checkCancellation(); try snapshot.validate(); return snapshot }
    static func month(_ snapshot: inout UsageSnapshot, now: Date = Date()) { snapshot.periodStart = Calendar(identifier: .gregorian).dateInterval(of: .month, for: now)?.start; snapshot.periodEnd = now }
    static func form(_ values: [String:String]) -> Data {
        var components = URLComponents(); components.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name:$0.key,value:$0.value) }
        return Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    }
    static func jsonData(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    static func noteNumber(_ n: Double) -> String { n.formatted(.number.precision(.fractionLength(0...4))) }
}

enum OpenRouterBridge {
    static func fetch(key: String) async throws -> UsageSnapshot {
        let headers = ["Authorization":"Bearer " + (try ProviderCloudHTTP.secret(key))]
        var keyData:[String:Any]?, credits:[String:Any]?, keyError:Error?
        do {keyData=try await ProviderCloudHTTP.json(URL(string:"https://openrouter.ai/api/v1/key")!, provider:"OpenRouter", headers:headers)}
        catch is CancellationError {throw CancellationError()} catch {keyError=error}
        do {credits=try await ProviderCloudHTTP.json(URL(string:"https://openrouter.ai/api/v1/credits")!, provider:"OpenRouter", headers:headers)}
        catch is CancellationError {throw CancellationError()} catch {if keyError==nil{keyError=error}}
        guard keyData != nil || credits != nil else {throw keyError ?? Connectors.schemaError}
        return try parse(key: keyData, credits: credits)
    }
    static func parse(key: [String:Any]?, credits: [String:Any]?) throws -> UsageSnapshot {
        var s = UsageSnapshot.empty(source:"OpenRouter 官方 API")
        let k = key?["data"] as? [String:Any] ?? [:], c = credits?["data"] as? [String:Any] ?? [:]
        if let total = ProviderCloudHTTP.n(c["total_credits"]), total >= 0, let used = ProviderCloudHTTP.n(c["total_usage"]), used >= 0 {
            s.balances = [.init(currency:"USD",value:max(0,total-used))]
        }
        if let limit = ProviderCloudHTTP.n(k["limit"]), limit > 0 {
            let reset = (k["limit_reset"] as? String ?? "").lowercased()
            let suffix = ["daily":"_daily","weekly":"_weekly","monthly":"_monthly"][reset] ?? ""
            let supplied = ProviderCloudHTTP.n(k["limit_remaining"])
            let reported = ProviderCloudHTTP.n(k["usage" + suffix])
            let byok = k["include_byok_in_limit"] as? Bool == true ? ProviderCloudHTTP.n(k["byok_usage" + suffix]) : 0
            if let used = supplied.map({ max(0,limit-$0) }) ?? (reported != nil && byok != nil ? max(0,reported!) + max(0,byok!) : nil) {
                let label = ["daily":"每日","weekly":"每周","monthly":"每月"][reset] ?? "累计"
                s.quotas = [.init(id:"openrouter-key-"+reset,title:"API Key · \(label)限额",usedPercent:min(100,used/limit*100),resetsAt:nil)]
            }
        }
        if let month = ProviderCloudHTTP.n(k["usage_monthly"]), month >= 0 { s.costs = [.init(currency:"USD",value:month)]; ProviderCloudHTTP.month(&s) }
        var details = ["余额为账户余额；Key 限额按平台当前周期与 BYOK 设置计算。"]
        if let all = ProviderCloudHTTP.n(k["usage"]), all >= 0 { details.append("本 Key 累计消费 USD \(ProviderCloudHTTP.noteNumber(all))") }
        s.note = details.joined(separator:" ")
        guard !s.balances.isEmpty || !s.quotas.isEmpty || !s.costs.isEmpty else { throw Connectors.schemaError }
        return try ProviderCloudHTTP.finish(s)
    }
}

enum TraeCNBridge {
    static func fetch(token: String, deviceID: String = "") async throws -> UsageSnapshot {
        var key = try ProviderCloudHTTP.secret(token)
        key = key.replacingOccurrences(of:#"(?i)^authorization\s*:\s*"#,with:"",options:.regularExpression).replacingOccurrences(of:#"(?i)^cloud-ide-jwt\s+"#,with:"",options:.regularExpression)
        var headers = ["Authorization":"Cloud-IDE-JWT " + (try ProviderCloudHTTP.secret(key)),"X-User-Region":"CN","Content-Type":"application/json"]
        if !deviceID.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { headers["X-Device-Id"] = try ProviderCloudHTTP.secret(deviceID) }
        return try parse(await ProviderCloudHTTP.json(URL(string:"https://api.trae.cn/trae/api/v2/pay/ide_user_ent_usage")!,provider:"Trae CN",method:"POST",headers:headers,body:Data("{}".utf8)))
    }
    static func parse(_ body: [String:Any]) throws -> UsageSnapshot {
        guard let packs = (body["user_entitlement_pack_list"] ?? body["userEntitlementPackList"]) as? [[String:Any]] else { throw Connectors.schemaError }
        var total=0.0, used=0.0
        for pack in packs {
            let info=(pack["entitlement_base_info"] ?? pack["entitlementBaseInfo"]) as? [String:Any]
            let quota=info?["quota"] as? [String:Any], usage=pack["usage"] as? [String:Any]
            let cap=ProviderCloudHTTP.n(quota?["credits_limit"] ?? quota?["creditsLimit"])
            let consumed=ProviderCloudHTTP.n(usage?["credits_amount"] ?? usage?["creditsAmount"])
            guard let cap else { if quota != nil && consumed == nil { continue }; throw Connectors.schemaError }
            // The source contract explicitly uses an empty usage object for an untouched pack.
            // A missing usage object is not evidence that consumption is zero.
            guard usage != nil else {throw Connectors.schemaError}
            let value=consumed ?? 0
            if cap == 0 && value == 0 { continue }
            guard cap > 0, value >= 0 else { throw Connectors.schemaError }
            total += cap; used += value
        }
        guard total > 0, total.isFinite, used.isFinite else { throw MonitorError.message("Trae CN 没有返回可用的积分权益。上次数据已保留。") }
        var s=UsageSnapshot.empty(source:"Trae CN 权益接口")
        s.quotas=[.init(id:"trae-credits",title:"Trae CN · 积分",usedPercent:min(100,used/total*100),resetsAt:nil)]
        s.creditBalances=[.init(id:"trae-credits",title:"剩余积分",unit:"积分",value:max(0,total-used))]
        s.note="剩余 \(ProviderCloudHTTP.noteNumber(max(0,total-used))) / \(ProviderCloudHTTP.noteNumber(total)) 积分。积分不是法币余额；平台未提供重置时间。"
        return try ProviderCloudHTTP.finish(s)
    }
}

enum StepFunBridge {
    static func normalizedToken(_ value: String) throws -> String {
        let raw=try ProviderCloudHTTP.secret(value)
        if let range=raw.range(of:#"(?:^|;)\s*Oasis-Token=([^;]+)"#,options:.regularExpression), let eq=raw[range].firstIndex(of:"=") { return try ProviderCloudHTTP.secret(String(raw[raw.index(after:eq)..<range.upperBound])) }
        let token=raw.replacingOccurrences(of:#"(?i)^Oasis-Token\s*:\s*"#,with:"",options:.regularExpression)
        guard !token.contains(";") else { throw MonitorError.message("请粘贴 StepFun 的 Oasis-Token 值或包含该项的 Cookie。") }
        return try ProviderCloudHTTP.secret(token)
    }
    static func deviceID(_ token: String) -> String {
        for jwt in token.components(separatedBy:"...").reversed() {
            let parts=jwt.split(separator:"."); guard parts.count > 1 else {continue}
            var payload=String(parts[1]).replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")
            payload += String(repeating:"=",count:(4-payload.count%4)%4)
            if let data=Data(base64Encoded:payload), let json=try? JSONSerialization.jsonObject(with:data) as? [String:Any], let id=json["device_id"] as? String, id.range(of:#"^[A-Za-z0-9_-]{1,128}$"#,options:.regularExpression) != nil { return id }
        }
        return "c8a1002d2c457e758785a9979832217c7c0b884c"
    }
    static func fetch(token: String) async throws -> UsageSnapshot {
        let token=try normalizedToken(token), webID=deviceID(token)
        let headers=["Content-Type":"application/json","oasis-appid":"10300","oasis-platform":"web","oasis-webid":webID,"Cookie":"Oasis-Token=\(token); Oasis-Webid=\(webID)"]
        let base="https://platform.stepfun.com/api/step.openapi.devcenter.Dashboard/"
        var s=try parse(await ProviderCloudHTTP.json(URL(string:base+"QueryStepPlanRateLimit")!,provider:"StepFun",method:"POST",headers:headers,body:Data("{}".utf8)))
        if let plan=try? await ProviderCloudHTTP.json(URL(string:base+"GetStepPlanStatus")!,provider:"StepFun",method:"POST",headers:headers,body:Data("{}".utf8),timeout:3), let subscription=plan["subscription"] as? [String:Any], let name=subscription["name"] as? String {s.note=String(name.prefix(200))+" · 按平台报告的额度窗口显示。"}
        return try ProviderCloudHTTP.finish(s)
    }
    static func parse(_ body:[String:Any]) throws -> UsageSnapshot {
        guard ProviderCloudHTTP.n(body["status"]) == 1 else { throw MonitorError.message("StepFun 未返回有效额度，请重新登录并更新 Oasis-Token。上次数据已保留。") }
        let sessionReset=ProviderCloudHTTP.date(body["five_hour_usage_reset_time"]), weekReset=ProviderCloudHTTP.date(body["weekly_usage_reset_time"])
        let credit=body["plan_credit_rate_limit"] as? [String:Any] ?? [:]
        func fraction(_ raw:Any?) -> Double? {guard let n=ProviderCloudHTTP.n(raw),(0...1).contains(n) else{return nil};return n}
        var s=UsageSnapshot.empty(source:"StepFun 官方控制台接口")
        if sessionReset == nil && weekReset == nil && (!credit.isEmpty || ProviderCloudHTTP.n(body["plan_family"]) == 2) {
            var left:Double?
            if let buckets=credit["credit_buckets"] as? [[String:Any]],!buckets.isEmpty {
                var total=0.0, remaining=0.0
                for bucket in buckets {
                    guard let cap=ProviderCloudHTTP.n(bucket["credit_total"]),cap>0,let value=ProviderCloudHTTP.n(bucket["credit_residual"]),(0...cap).contains(value) else{throw Connectors.schemaError}
                    total += cap; remaining += value
                }
                guard total.isFinite,remaining.isFinite else{throw Connectors.schemaError};left=remaining/total
            }
            left=left ?? fraction(credit["subscription_credit_left_rate"]) ?? fraction(credit["topup_credit_left_rate"])
            guard let left else{throw Connectors.schemaError}
            s.quotas=[.init(id:"stepfun-credits",title:"StepFun · 积分",usedPercent:(1-left)*100,resetsAt:ProviderCloudHTTP.date(credit["subscription_credit_reset_time"]))]
        } else {
            guard let left=fraction(body["five_hour_usage_left_rate"]),let week=fraction(body["weekly_usage_left_rate"]),let sessionReset,let weekReset else{throw Connectors.schemaError}
            s.quotas=[.init(id:"stepfun-5h",title:"StepFun · 5 小时",usedPercent:(1-left)*100,resetsAt:sessionReset,windowSeconds:18000),.init(id:"stepfun-week",title:"StepFun · 每周",usedPercent:(1-week)*100,resetsAt:weekReset,windowSeconds:604800)]
        }
        return try ProviderCloudHTTP.finish(s)
    }
}

enum ThirdPartyQuotaBridge {
    static func baseURL(_ value:String) throws -> URL {
        guard let url=URL(string:value.trimmingCharacters(in:.whitespacesAndNewlines)),url.scheme=="https",url.host?.isEmpty==false,url.user==nil,url.password==nil,url.query==nil,url.fragment==nil else{throw MonitorError.message("第三方站点必须使用 HTTPS，不能在地址中包含账号、密码、查询参数或片段。")}
        return url
    }
    static func endpoint(_ base:URL,_ path:String)->URL { URL(string:base.absoluteString.trimmingCharacters(in:CharacterSet(charactersIn:"/"))+path)! }
    static func fetch(adapter:String,baseURL:String,credential:String,userID:String?=nil,tokenMode:Bool=false) async throws -> UsageSnapshot {
        let base=try self.baseURL(baseURL),secret=try ProviderCloudHTTP.secret(credential)
        var headers=["Authorization":"Bearer "+secret]
        if adapter=="newapi" {
            if !tokenMode,let id=userID,!id.isEmpty {headers["New-Api-User"]=try ProviderCloudHTTP.secret(id)}
            let payload=try await ProviderCloudHTTP.json(endpoint(base,tokenMode ? "/api/usage/token/" : "/api/user/self"),provider:"NewAPI",headers:headers)
            let status=try? await ProviderCloudHTTP.json(endpoint(base,"/api/status"),provider:"NewAPI")
            return try parseNewAPI(payload,status:status,tokenMode:tokenMode)
        }
        guard adapter=="sub2api" else{throw MonitorError.message("不支持的第三方额度适配器。")}
        let me=try await ProviderCloudHTTP.json(endpoint(base,"/api/v1/auth/me"),provider:"Sub2API",headers:headers)
        var monthQuery=URLComponents();monthQuery.queryItems=[URLQueryItem(name:"period",value:"month"),URLQueryItem(name:"timezone",value:TimeZone.current.identifier)]
        let month=try? await ProviderCloudHTTP.json(endpoint(base,"/api/v1/usage/stats?"+(monthQuery.percentEncodedQuery ?? "period=month")),provider:"Sub2API",headers:headers)
        return try parseSub2API(me,month:month)
    }
    static func parseNewAPI(_ body:[String:Any],status:[String:Any]?,tokenMode:Bool) throws -> UsageSnapshot {
        guard ProviderCloudHTTP.b(body["success"]) != false,ProviderCloudHTTP.b(body["code"]) != false,let data=body["data"] as? [String:Any] else{throw Connectors.schemaError}
        let statusData=status?["data"] as? [String:Any]
        let reportedUnit=ProviderCloudHTTP.b(status?["success"]) == false ? nil : ProviderCloudHTTP.n(statusData?["quota_per_unit"])
        let hasUnit=(reportedUnit ?? 0)>0
        let unit=hasUnit ? reportedUnit! : 1
        let raw=ProviderCloudHTTP.n(data[tokenMode ? "total_available":"quota"])
        let unlimited=data["unlimited_quota"] as? Bool==true || (!tokenMode && raw == -1)
        var s=UsageSnapshot.empty(source:"NewAPI · "+(tokenMode ? "API Key 额度":"账户额度"))
        let used=ProviderCloudHTTP.n(data[tokenMode ? "total_used":"used_quota"]).map {max(0,$0)/unit}
        if unlimited {s.note="平台报告不限额度，未将其转换为无限法币余额。"}
        else {
            guard let raw,raw>=0 else{throw Connectors.schemaError}
            let remaining=raw/unit
            if hasUnit{s.balances=[.init(currency:"USD",value:remaining)]}
            else{s.creditBalances=[.init(id:"newapi-raw-quota",title:"剩余额度",unit:"原始额度单位",value:remaining)]}
            if let used,remaining+used>0 {s.quotas=[.init(id:"newapi-quota",title:tokenMode ? "API Key · 额度":"账户 · 额度",usedPercent:min(100,used/(remaining+used)*100),resetsAt:nil)]}
            s.note=hasUnit ? "按站点报告的额度换算单位显示美元值。":"站点未报告有效换算比例，保留原始额度单位，不推测美元余额。"
        }
        if let used {s.note=(s.note ?? "")+" 累计使用 \(ProviderCloudHTTP.noteNumber(used)) \(hasUnit ? "USD":"原始额度单位")。"}
        if let expiry=ProviderCloudHTTP.date(data["expires_at"]) {s.deadlines=[.init(label:"API Key 到期",date:expiry)]}
        return try ProviderCloudHTTP.finish(s)
    }
    static func parseSub2API(_ body:[String:Any],month:[String:Any]?) throws -> UsageSnapshot {
        guard ProviderCloudHTTP.n(body["code"])==0,let data=body["data"] as? [String:Any],data["id"] != nil,let balance=ProviderCloudHTTP.n(data["balance"]) else{throw Connectors.schemaError}
        var s=UsageSnapshot.empty(source:"Sub2API 账户接口");s.balances=[.init(currency:"USD",value:balance)]
        if let month,ProviderCloudHTTP.n(month["code"])==0,let stats=month["data"] as? [String:Any] {
            if let cost=ProviderCloudHTTP.n(stats["total_actual_cost"]),cost>=0{s.costs=[.init(currency:"USD",value:cost)];ProviderCloudHTTP.month(&s)}
            let input=ProviderCloudHTTP.n(stats["total_input_tokens"]),output=ProviderCloudHTTP.n(stats["total_output_tokens"])
            if let input,let output,input>=0,output>=0,input<=Double(Int64.max/2),output<=Double(Int64.max/2){s.inputTokens=Int64(input);s.outputTokens=Int64(output);ProviderCloudHTTP.month(&s)}
        }
        s.note="月费用采用站点 total_actual_cost；基础价格估算不替代实际计费。访问令牌过期后请重新粘贴，不自动登录。"
        return try ProviderCloudHTTP.finish(s)
    }
}

enum AlibabaTokenPlanBridge {
    struct Variant {
        var gateway:String;var quota:String;var region:String;var product:String;var personal:Bool;var action:String;var site:String
        var dashboard:String {gateway+"/"+region+(region=="ap-southeast-1" ? "/":"")+"?tab=plan#/efm/subscription/token-plan"+(personal ? "/personal":"")}
    }
    static func variant(_ id:String) throws -> Variant {
        switch id {
        case "cn":return .init(gateway:"https://bailian.console.aliyun.com",quota:"https://bailian.console.aliyun.com",region:"cn-beijing",product:"sfm_tokenplanteams_dp_cn",personal:false,action:"BroadScopeAspnGateway",site:"BAILIAN_ALIYUN")
        case "intl":return .init(gateway:"https://modelstudio.console.alibabacloud.com",quota:"https://modelstudio.console.alibabacloud.com",region:"ap-southeast-1",product:"sfm_tokenplanteams_dp_intl",personal:false,action:"IntlBroadScopeAspnGateway",site:"MODELSTUDIO_ALBABACLOUD")
        case "cn-personal":return .init(gateway:"https://bailian.console.aliyun.com",quota:"https://bailian-cs.console.aliyun.com",region:"cn-beijing",product:"sfm_tokenplansolo_public_cn",personal:true,action:"BroadScopeAspnGateway",site:"BAILIAN_ALIYUN")
        case "intl-personal":return .init(gateway:"https://modelstudio.console.alibabacloud.com",quota:"https://bailian-singapore-cs.alibabacloud.com",region:"ap-southeast-1",product:"sfm_tokenplansolo_public_intl",personal:true,action:"IntlBroadScopeAspnGateway",site:"MODELSTUDIO_ALBABACLOUD")
        default:throw MonitorError.message("请选择有效的阿里云 Token Plan 区域与套餐类型。")
        }
    }
    static func cookieValue(_ cookie:String,name:String)->String? {
        for pair in cookie.split(separator:";") {
            let pieces=pair.split(separator:"=",maxSplits:1,omittingEmptySubsequences:false)
            if pieces.count==2,pieces[0].trimmingCharacters(in:.whitespaces)==name{return pieces[1].trimmingCharacters(in:.whitespaces)}
        }
        return nil
    }
    static func headers(cookie:String,variant:Variant)->[String:String] {
        var values=["Content-Type":"application/x-www-form-urlencoded","Cookie":cookie,"Origin":variant.gateway,"Referer":variant.gateway+"/","X-Requested-With":"XMLHttpRequest"]
        if let csrf=cookieValue(cookie,name:"login_aliyunid_csrf") ?? cookieValue(cookie,name:"csrf"),!csrf.isEmpty{values["x-xsrf-token"]=csrf;values["x-csrf-token"]=csrf}
        return values
    }
    static func fetch(cookie:String,variant id:String="cn") async throws -> UsageSnapshot {
        let cookie=try ProviderCloudHTTP.cookie(cookie),v=try variant(id),header=headers(cookie:cookie,variant:v)
        var sec=cookieValue(cookie,name:"sec_token") ?? ""
        if sec.isEmpty,let data=try? await ProviderCloudHTTP.request(URL(string:v.dashboard)!,provider:"阿里云 Token Plan",headers:["Cookie":cookie,"Accept":"text/html","Referer":v.gateway+"/"],timeout:5),let text=String(data:data,encoding:.utf8){sec=secToken(text) ?? ""}
        if sec.isEmpty,let info=try? await ProviderCloudHTTP.json(URL(string:v.gateway+"/tool/user/info.json")!,provider:"阿里云 Token Plan",headers:["Cookie":cookie,"Referer":v.gateway+"/"],timeout:5){sec=find(info,keys:["secToken","sec_token"]) as? String ?? ""}
        if !v.personal {
            var values=["product":"BssOpenAPI-V3","action":"GetSubscriptionSummary","params":String(data:try ProviderCloudHTTP.jsonData(["ProductCode":v.product]),encoding:.utf8)!,"region":v.region]
            if !sec.isEmpty{values["sec_token"]=sec}
            let data=try await ProviderCloudHTTP.request(URL(string:v.quota+"/data/api.json?action=GetSubscriptionSummary&product=BssOpenAPI-V3&_tag=")!,provider:"阿里云 Token Plan",method:"POST",headers:header,body:ProviderCloudHTTP.form(values))
            return try parseTeam(parseEnvelope(data))
        }
        var snapshot:UsageSnapshot?
        for attempt in 0..<3 {
            if attempt>0{try await Task.sleep(nanoseconds:400_000_000)}
            let body=try await personalAPI("usage",cookie:cookie,variant:v,sec:sec,data:[:])
            if ["per5HourPercentage","per1WeekPercentage","per1MonthPercentage"].contains(where:{ProviderCloudHTTP.n(find(body,keys:[$0])) != nil}){snapshot=try parsePersonal(body);break}
        }
        guard var s=snapshot else{throw MonitorError.message("阿里云个人 Token Plan 暂未返回任何额度窗口。上次数据已保留。")}
        if let sub=try? await personalAPI("subscription",cookie:cookie,variant:v,sec:sec,data:["commodityCode":v.product]),let plan=find(sub,keys:["specCode","spec_code","planName","plan_name"]) as? String,!plan.isEmpty{s.note=String(plan.prefix(160))+" · 按平台实际提供的 5 小时、每周或每月窗口显示。"}
        return try ProviderCloudHTTP.finish(s)
    }
    static func personalAPI(_ suffix:String,cookie:String,variant v:Variant,sec:String,data:[String:Any]) async throws->[String:Any] {
        let api="zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/"+suffix
        var cornerstone:[String:Any]=["feTraceId":UUID().uuidString.lowercased(),"feURL":v.dashboard,"protocol":"V2","console":"ONE_CONSOLE","productCode":"p_efm","switchUserType":3,"domain":URL(string:v.gateway)!.host!,"consoleSite":v.site,"userNickName":"","userPrincipalName":"","xsp_lang":"en-US"]
        if let anonymous=cookieValue(cookie,name:"cna"){cornerstone["X-Anonymous-Id"]=anonymous}
        var inner=data;inner["cornerstoneParam"]=cornerstone
        var values=["product":"sfm_bailian","action":v.action,"region":v.region,"language":"en-US","params":String(data:try ProviderCloudHTTP.jsonData(["Api":api,"V":"1.0","Data":inner]),encoding:.utf8)!]
        if !sec.isEmpty{values["sec_token"]=sec}
        var url=URLComponents(string:v.quota+"/data/api.json")!;url.queryItems=[.init(name:"action",value:v.action),.init(name:"product",value:"sfm_bailian"),.init(name:"api",value:api),.init(name:"_v",value:"undefined")]
        return try parseEnvelope(await ProviderCloudHTTP.request(url.url!,provider:"阿里云 Token Plan",method:"POST",headers:headers(cookie:cookie,variant:v),body:ProviderCloudHTTP.form(values)))
    }
    static func secToken(_ html:String)->String? {
        for pattern in [#""secToken"\s*:\s*"([^"]+)""#,#""sec_token"\s*:\s*"([^"]+)""#,#"SEC_TOKEN['"]?\s*[:=]\s*['"]([^'"]+)['"]"#] {
            if let regex=try? NSRegularExpression(pattern:pattern),let match=regex.firstMatch(in:html,range:NSRange(html.startIndex...,in:html)),let range=Range(match.range(at:1),in:html){return String(html[range])}
        }
        return nil
    }
    static func expand(_ value:Any,depth:Int=0)->Any {
        guard depth<20 else{return value}
        if let text=value as? String,let data=text.data(using:.utf8),let parsed=try? JSONSerialization.jsonObject(with:data){return expand(parsed,depth:depth+1)}
        if let dict=value as? [String:Any]{return dict.mapValues{expand($0,depth:depth+1)}}
        if let array=value as? [Any]{return array.map{expand($0,depth:depth+1)}}
        return value
    }
    static func find(_ value:Any,keys:[String])->Any? {
        for key in keys {if let value=findKey(value,key:key.lowercased(),depth:0){return value}}
        return nil
    }
    private static func findKey(_ value:Any,key:String,depth:Int)->Any? {
        guard depth<24 else{return nil}
        if let dict=value as? [String:Any] {
            if let found=dict.first(where:{$0.key.lowercased()==key})?.value,!(found is NSNull){return found}
            for child in dict.keys.sorted(){if let found=findKey(dict[child]!,key:key,depth:depth+1){return found}}
        } else if let array=value as? [Any]{for child in array{if let found=findKey(child,key:key,depth:depth+1){return found}}}
        return nil
    }
    private static func object(_ value:Any,keys:Set<String>,depth:Int=0)->[String:Any]? {
        guard depth<24 else{return nil}
        if let dict=value as? [String:Any]{if dict.keys.contains(where:{keys.contains($0.lowercased())}){return dict};for key in dict.keys.sorted(){if let found=object(dict[key]!,keys:keys,depth:depth+1){return found}}}
        if let array=value as? [Any]{for child in array{if let found=object(child,keys:keys,depth:depth+1){return found}}}
        return nil
    }
    static func parseEnvelope(_ data:Data) throws->[String:Any] {
        guard let raw=try? JSONSerialization.jsonObject(with:data),let body=expand(raw) as? [String:Any] else{throw MonitorError.message("阿里云控制台未返回 JSON，请重新登录并更新 Cookie。上次数据已保留。")}
        func rejected(_ value:Any,depth:Int=0)->Bool {
            guard depth<24 else{return false}
            if let object=value as? [String:Any] {
                if object.contains(where:{pair in ["success","successresponse"].contains(pair.key.lowercased()) && (ProviderCloudHTTP.b(pair.value)==false || (pair.value as? String)?.lowercased()=="false")}){return true}
                return object.values.contains{rejected($0,depth:depth+1)}
            }
            return (value as? [Any])?.contains{rejected($0,depth:depth+1)} ?? false
        }
        let bad=rejected(body)
        let code=ProviderCloudHTTP.n(find(body,keys:["statusCode","status_code","code"]))
        let errorCode=(find(body,keys:["errorCode","code"]) as? String ?? "").lowercased()
        let denied=["login","unauthor","forbidden","invalidsession","accessdenied"].contains{errorCode.contains($0)}
        if bad || denied || (code != nil && code != 0 && code != 200){throw MonitorError.message("阿里云控制台凭证已被拒绝或查询失败，请确认 Cookie、所选区域和套餐类型。上次数据已保留。")}
        return body
    }
    static let totals=["totalQuota","totalCredits","totalCredit","creditLimit","creditsTotal","monthlyTotalQuota","totalValue","cycleTotalValue","quota","amount"]
    static let remaining=["remainingQuota","remainQuota","remainingCredits","remainingCredit","availableCredits","availableAmount","remainAmount","totalSurplusValue","surplusValue","cycleSurplusValue","balance","remaining"]
    static let usedKeys=["usedQuota","usedCredits","usedCredit","consumedCredits","usedAmount","consumeAmount","usedValue","consumedValue","usage","used"]
    static let resets=["nextRefreshTime","resetTime","periodEndTime","billingCycleEnd","billCycleEndTime","expireTime","expirationTime","validEndTime","instanceEndTime","cycleEndTime","nearestExpireDate","endTime"]
    static func parseTeam(_ payload:[String:Any]) throws->UsageSnapshot {
        let keySet=Set((totals+remaining+usedKeys).map{$0.lowercased()})
        let candidate=find(payload,keys:["data","successResponse"]) ?? payload
        let frame=object(candidate,keys:keySet) ?? object(payload,keys:keySet) ?? payload
        let total=ProviderCloudHTTP.n(find(frame,keys:totals)),balance=ProviderCloudHTTP.n(find(frame,keys:remaining))
        let used=ProviderCloudHTTP.n(find(frame,keys:usedKeys)) ?? (total != nil && balance != nil ? max(0,total!-balance!):nil)
        var s=UsageSnapshot.empty(source:"阿里云 Token Plan · 团队套餐")
        if let total,total>0,let used,used>=0 {s.quotas=[.init(id:"alibaba-team",title:"Token Plan · 每月",usedPercent:min(100,used/total*100),resetsAt:ProviderCloudHTTP.date(find(payload,keys:resets)),windowSeconds:nil)]}
        var details:[String]=[]
        if let balance,balance>=0{details.append("剩余额度 \(ProviderCloudHTTP.noteNumber(balance))")}
        if let balance,balance>=0{s.creditBalances=[.init(id:"alibaba-team-remaining",title:"套餐剩余额度",unit:"额度",value:balance)]}
        if let total,total>=0{details.append("总额度 \(ProviderCloudHTTP.noteNumber(total))")}
        if let used,used>=0{details.append("已用 \(ProviderCloudHTTP.noteNumber(used))")}
        if details.isEmpty,ProviderCloudHTTP.n(find(payload,keys:["totalCount","subscriptionTotalNumber"])) == 0 {details=["当前没有有效的团队订阅。"]}
        guard !details.isEmpty || !s.quotas.isEmpty else{throw Connectors.schemaError}
        s.note=details.joined(separator:" · ")+"；套餐额度不是阿里云现金余额。"
        return try ProviderCloudHTTP.finish(s)
    }
    static func parsePersonal(_ payload:[String:Any]) throws->UsageSnapshot {
        var s=UsageSnapshot.empty(source:"阿里云 Token Plan · 个人套餐")
        for (prefix,label,seconds) in [("per5Hour","5 小时",18000.0),("per1Week","每周",604800.0),("per1Month","每月",2592000.0)] {
            if let ratio=ProviderCloudHTTP.n(find(payload,keys:[prefix+"Percentage"])) {s.quotas.append(.init(id:"alibaba-"+prefix,title:"Token Plan · "+label,usedPercent:max(0,min(1,ratio))*100,resetsAt:ProviderCloudHTTP.date(find(payload,keys:[prefix+"ResetTime"])),windowSeconds:prefix=="per1Month" ? nil:seconds))}
        }
        guard !s.quotas.isEmpty else{throw Connectors.schemaError}
        s.note="只展示平台当前实际提供的额度窗口；未返回的窗口不会补成零用量。"
        return try ProviderCloudHTTP.finish(s)
    }
}

enum TypeSafeBridge {
    private static let origin="https://console.typesafe.ai"
    private static let lock=NSLock()
    private struct Discovery {var action:String;var inputRate:Double?;var outputRate:Double?;var expires:Date}
    private static var cached:Discovery?
    private static func cachedDiscovery()->Discovery?{lock.lock();defer{lock.unlock()};return cached.flatMap{$0.expires>Date() ? $0:nil}}
    private static func saveDiscovery(_ value:Discovery){lock.lock();defer{lock.unlock()};cached=value}
    private static func matches(_ pattern:String,in text:String)->[String] {
        guard let regex=try? NSRegularExpression(pattern:pattern,options:[]) else{return []}
        return regex.matches(in:text,range:NSRange(text.startIndex...,in:text)).compactMap{match in guard match.numberOfRanges>1,let range=Range(match.range(at:1),in:text) else{return nil};return String(text[range])}
    }
    static func actionID(in script:String)->String? {matches(#""([0-9a-fA-F]{40,})"[^)]{0,150}"getBillingOverviewResult""#,in:script).first}
    static func tokenRate(in script:String,name:String)->Double? {
        let escaped=NSRegularExpression.escapedPattern(for:name)
        guard let regex=try? NSRegularExpression(pattern:"\""+escaped+"\"\\s*,\\s*[\\w$.eE+-]+\\s*,\\s*([\\w$.eE+-]+)"),let match=regex.firstMatch(in:script,range:NSRange(script.startIndex...,in:script)),let range=Range(match.range(at:1),in:script),let head=Range(NSRange(location:0,length:match.range.location),in:script) else{return nil}
        let raw=String(script[range])
        func plausible(_ value:Double?)->Double?{guard let value,value.isFinite,value>=0,value<0.001 else{return nil};return value}
        if let direct=Double(raw){return plausible(direct)}
        let variable=NSRegularExpression.escapedPattern(for:raw)
        let values=matches("(?:^|[^\\w$])"+variable+"\\s*=\\s*([\\d.eE+-]+(?:\\s*/\\s*[\\d.eE+-]+)?)",in:String(script[head]))
        guard let expression=values.last else{return nil}
        let parts=expression.split(separator:"/").map{$0.trimmingCharacters(in:.whitespaces)}
        guard let numerator=parts.first.flatMap(Double.init) else{return nil}
        if parts.count==1{return plausible(numerator)}
        guard parts.count==2,let denominator=Double(parts[1]),denominator != 0 else{return nil}
        return plausible(numerator/denominator)
    }
    private static func webHeaders(_ cookie:String)->[String:String] {
        ["Cookie":cookie,"Sec-CH-UA":"\"Chromium\";v=\"143\", \"Not_A Brand\";v=\"24\", \"Google Chrome\";v=\"143\"","Sec-CH-UA-Mobile":"?0","Sec-CH-UA-Platform":"\"macOS\""]
    }
    private static func discover(cookie:String) async throws->Discovery {
        var headers=webHeaders(cookie);headers["Accept"]="text/html"
        let data=try await ProviderCloudHTTP.request(URL(string:origin+"/settings/billing")!,provider:"TypeSafe",headers:headers)
        guard let html=String(data:data,encoding:.utf8) else{throw Connectors.schemaError}
        let sourceURLs=matches(#"(?i)<script\b[^>]*\bsrc=["']([^"']+)["'][^>]*>"#,in:html)
        let base=URL(string:origin)!
        let candidates:[URL]=sourceURLs.compactMap{URL(string:$0,relativeTo:base)?.absoluteURL}
        let sameOrigin=candidates.filter{url in url.scheme=="https" && url.host==base.host && (url.port==nil || url.port==443) && url.path.hasSuffix(".js")}
        let urls=Array(Set(sameOrigin)).sorted{$0.path<$1.path}.prefix(60)
        var action:String?,input:Double?,output:Double?
        let deadline=Date().addingTimeInterval(30)
        for url in urls {
            try Task.checkCancellation()
            if Date()>=deadline{break}
            guard let data=try? await ProviderCloudHTTP.request(url,provider:"TypeSafe",headers:webHeaders(cookie),timeout:5),let script=String(data:data,encoding:.utf8) else{continue}
            action=action ?? actionID(in:script)
            input=input ?? tokenRate(in:script,name:"INPUT_TOKEN_COST_USD")
            output=output ?? tokenRate(in:script,name:"OUTPUT_TOKEN_COST_USD")
            if action != nil,input != nil,output != nil{break}
        }
        guard let action else{throw MonitorError.message("TypeSafe 控制台登录状态或计费页面已变化，未识别到余额查询接口。请重新登录并更新 Cookie。上次数据已保留。")}
        let result=Discovery(action:action,inputRate:input,outputRate:output,expires:Date().addingTimeInterval(12*3600));saveDiscovery(result);return result
    }
    static func fetch(cookie:String) async throws->UsageSnapshot {
        let cookie=try ProviderCloudHTTP.cookie(cookie)
        var discovery:Discovery
        if let value=cachedDiscovery(){discovery=value}else{discovery=try await discover(cookie:cookie)}
        func billing(_ action:String) async throws->Data {
            var headers=webHeaders(cookie);headers["Origin"]=origin;headers["Next-Action"]=action;headers["Accept"]="text/x-component";headers["Content-Type"]="application/json"
            return try await ProviderCloudHTTP.request(URL(string:origin+"/settings/billing")!,provider:"TypeSafe",method:"POST",headers:headers,body:Data("[]".utf8))
        }
        let billingData:Data
        do{billingData=try await billing(discovery.action)}catch is CancellationError{throw CancellationError()}catch{
            discovery=try await discover(cookie:cookie);billingData=try await billing(discovery.action)
        }
        let billingObject=try parseBilling(billingData)
        do {
            let usage=try await ProviderCloudHTTP.json(URL(string:origin+"/api/usage?granularity=hour")!,provider:"TypeSafe",headers:webHeaders(cookie))
            return try parse(billing:billingObject,usage:usage,inputRate:discovery.inputRate,outputRate:discovery.outputRate)
        } catch is CancellationError {throw CancellationError()} catch {
            var balance=try parseBalance(billingObject)
            balance.note=(balance.note ?? "")+" 余额已更新；用量接口暂不可读，本次不显示用量与估算费用。"
            return try ProviderCloudHTTP.finish(balance)
        }
    }
    static func parseBilling(_ data:Data) throws->[String:Any] {
        guard let body=String(data:data,encoding:.utf8) else{throw Connectors.schemaError}
        for line in body.split(whereSeparator:{$0.isNewline}) {
            guard let colon=line.firstIndex(of:":"),let jsonData=String(line[line.index(after:colon)...]).data(using:.utf8),let result=try? JSONSerialization.jsonObject(with:jsonData) as? [String:Any],result["ok"] != nil else{continue}
            guard result["ok"] as? Bool==true,let data=result["data"] as? [String:Any],let billing=data["billing"] as? [String:Any],ProviderCloudHTTP.n(billing["balance"]) != nil else{throw Connectors.schemaError}
            return billing
        }
        throw MonitorError.message("TypeSafe 余额响应已变化，未覆盖上次数据。")
    }
    static func parse(billing:[String:Any],usage:[String:Any],inputRate:Double?,outputRate:Double?,now:Date=Date()) throws->UsageSnapshot {
        guard let balance=ProviderCloudHTTP.n(billing["balance"]),let buckets=usage["buckets"] as? [[String:Any]],buckets.count<=100_000 else{throw Connectors.schemaError}
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone.current
        let month=calendar.dateInterval(of:.month,for:now)!.start,today=calendar.startOfDay(for:now)
        let week=calendar.date(byAdding:.day,value:-6,to:today)!
        var monthInput:Int64=0,monthOutput:Int64=0,todayTokens:Int64=0,weekTokens:Int64=0
        for bucket in buckets {
            guard let date=ProviderCloudHTTP.date(bucket["day"]),let input=ProviderCloudHTTP.n(bucket["inputTokens"]),let output=ProviderCloudHTTP.n(bucket["outputTokens"]),let requests=ProviderCloudHTTP.n(bucket["requests"]),[input,output,requests].allSatisfy({$0>=0 && $0<=1e12 && $0.rounded(.towardZero)==$0}) else{throw Connectors.schemaError}
            let total=Int64(input)+Int64(output)
            if date>=today && date<=now{todayTokens += total};if date>=week && date<=now{weekTokens += total}
            if date>=month && date<=now{monthInput += Int64(input);monthOutput += Int64(output)}
        }
        var s=try parseBalance(billing,now:now)
        s.balances=[.init(currency:"USD",value:balance)];s.inputTokens=monthInput;s.outputTokens=monthOutput;s.periodStart=month;s.periodEnd=now
        if let inputRate,let outputRate,inputRate.isFinite,outputRate.isFinite,inputRate>=0,outputRate>=0{s.costs=[.init(currency:"USD",value:Double(monthInput)*inputRate+Double(monthOutput)*outputRate)]}
        var details=["今日 \(todayTokens.formatted()) Token，近 7 天 \(weekTokens.formatted()) Token。"]
        if let plan=billing["plan"] as? String{details.insert(String(plan.prefix(120)),at:0)}
        details.append(s.costs.isEmpty ? "未识别完整公开单价，未估算费用。":"费用按控制台公开单价估算，不代表实际扣费。")
        s.note=details.joined(separator:" ");return try ProviderCloudHTTP.finish(s)
    }
    static func parseBalance(_ billing:[String:Any],now:Date=Date()) throws->UsageSnapshot {
        guard let balance=ProviderCloudHTTP.n(billing["balance"]) else{throw Connectors.schemaError}
        var s=UsageSnapshot.empty(source:"TypeSafe 官方控制台接口")
        s.balances=[.init(currency:"USD",value:balance)]
        s.note=(billing["plan"] as? String).map{String($0.prefix(120))}
        if let grants=billing["credits"] as? [[String:Any]] {
            s.deadlines=grants.compactMap{grant in guard let amount=ProviderCloudHTTP.n(grant["remaining"]),amount>0,let expiry=ProviderCloudHTTP.date(grant["expiresAt"]),expiry>now else{return nil};return Deadline(label:"USD \(ProviderCloudHTTP.noteNumber(amount)) 额度到期",date:expiry)}.sorted{$0.date<$1.date}.prefix(20).map{$0}
        }
        return try ProviderCloudHTTP.finish(s)
    }
}
