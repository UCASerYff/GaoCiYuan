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
    static func form(_ values: [String:String]) -> Data {
        var components = URLComponents(); components.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name:$0.key,value:$0.value) }
        return Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    }
    static func jsonData(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    static func noteNumber(_ n: Double) -> String { n.formatted(.number.precision(.fractionLength(0...4))) }
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
