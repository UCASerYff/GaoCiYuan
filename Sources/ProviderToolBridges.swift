import Foundation
import Darwin

/// First-party quota surfaces compared with Javis603/token-monitor (2026-10-05).
/// These are account read endpoints, not inference requests. Credentials are passed by
/// the existing KeyVault route, are never persisted here, and never follow redirects.
enum ProviderToolBridge {
    private struct HTTPFailure: Error { var status: Int }
    private static let browserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/130.0.0.0 Safari/537.36"
    private static let allowedHosts: Set<String> = ["api.cline.bot", "api.factory.ai", "app.factory.ai", "cloud.zed.dev", "qoder.com", "qoder.com.cn", "opencode.ai"]
    static func fetch(provider: String, credential: String, scope: String?, region: String?) async throws -> UsageSnapshot {
        do {
            let result: UsageSnapshot
            switch provider {
            case "opencode": result = region == "go" ? try await fetchOpenCodeGo(credential) : try await fetchOpenCodeZen(credential, workspace: scope)
            case "cline": result = try await fetchCline(credential)
            case "factory": result = try await fetchFactory(credential)
            case "zed": result = try await fetchZed(credential)
            case "qoder": result = try await fetchQoder(credential, region: region)
            case "kiro": result = try await fetchKiro(path: scope)
            default: throw MonitorError.message("该额度连接方式尚未实现。")
            }
            try Task.checkCancellation(); try result.validate(); return result
        } catch let error as HTTPFailure {
            switch error.status {
            case 401, 403: throw MonitorError.message("凭据失效或权限不足，请在账户设置更新登录凭据。上次数据已保留。")
            case 429: throw MonitorError.message("平台限流，请稍后刷新。上次数据已保留。")
            default: throw MonitorError.message("平台额度接口暂时不可用（HTTP \(error.status)）。上次数据已保留。")
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw MonitorError.message("额度连接失败，请检查网络后重试。上次数据已保留。")
        }
    }
    private static func secret(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 65_536, !value.unicodeScalars.contains(where: {$0.value < 32 || $0.value == 127}) else {throw MonitorError.message("凭据为空、过长或含有换行控制字符。")}
        return value
    }
    private static func bearer(_ value: String) throws -> String {
        let value=try secret(value)
        return value.lowercased().hasPrefix("bearer ") ? String(value.dropFirst(7)).trimmingCharacters(in:.whitespaces) : value
    }
    static func cookie(_ value: String, kind: String) throws -> String {
        var value=try secret(value)
        if value.lowercased().hasPrefix("cookie:") {value=String(value.dropFirst(7)).trimmingCharacters(in:.whitespaces)}
        if kind == "opencode", !value.contains("=") {value="auth="+value}
        let pairs=value.split(separator:";").compactMap {(part: Substring) -> (String,String)? in
            guard let index=part.firstIndex(of:"=") else {return nil}
            let name=String(part[..<index]).trimmingCharacters(in:.whitespaces), val=String(part[part.index(after:index)...]).trimmingCharacters(in:.whitespaces)
            guard !name.isEmpty,!val.isEmpty,name.range(of:"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$",options:.regularExpression) != nil else {return nil}
            return (name,val)
        }
        if kind == "zed" {
            guard pairs.contains(where:{$0.0.lowercased()=="zed.session"}) else {throw MonitorError.message("Zed Cookie 必须包含 zed.session。")}
            let names:Set<String>=["zed.session","c15t","__cf_bm","cf_clearance"]
            return pairs.filter{names.contains($0.0.lowercased())}.map{"\($0.0)=\($0.1)"}.joined(separator:"; ")
        }
        if kind == "opencode", !pairs.contains(where:{$0.0=="auth"}) {throw MonitorError.message("OpenCode Zen Cookie 必须包含 auth。Go API Key 请切换到 Go 接口。")}
        guard !pairs.isEmpty else {throw MonitorError.message("Cookie 格式无效，请粘贴请求中的 Cookie 头。")}
        return pairs.map{"\($0.0)=\($0.1)"}.joined(separator:"; ")
    }
    private static func request(_ url: URL, headers: [String:String], method: String = "GET", body: Data? = nil) async throws -> Data {
        guard url.scheme=="https", let host=url.host,allowedHosts.contains(host),url.user==nil,url.password==nil else {throw Connectors.schemaError}
        try Task.checkCancellation()
        var request=URLRequest(url:url);request.httpMethod=method;request.httpBody=body;request.timeoutInterval=20
        request.setValue("application/json",forHTTPHeaderField:"Accept");request.setValue(browserAgent,forHTTPHeaderField:"User-Agent")
        for (name,value) in headers {request.setValue(value,forHTTPHeaderField:name)}
        let (data,response)=try await Connectors.session.data(for:request)
        try Task.checkCancellation()
        guard let http=response as? HTTPURLResponse else {throw Connectors.schemaError}
        guard (200..<300).contains(http.statusCode) else {throw HTTPFailure(status:http.statusCode)}
        guard data.count<=5_000_000 else {throw MonitorError.message("额度响应过大，未保存本次读数。")}
        return data
    }
    private static func json(_ url: String, headers: [String:String]) async throws -> [String:Any] {
        guard let url=URL(string:url) else {throw Connectors.schemaError}
        let data=try await request(url,headers:headers)
        guard let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else {throw Connectors.schemaError};return object
    }
    private static func n(_ value: Any?) -> Double? {Connectors.number(value)}
    private static func nonnegative(_ value: Any?) -> Double? {guard let value=n(value),value>=0 else{return nil};return value}
    private static func date(_ value: Any?) -> Date? {
        if let number=n(value),number>1_000_000_000 {return Date(timeIntervalSince1970:number>1_000_000_000_000 ? number/1000:number)}
        guard let text=value as? String else{return nil}
        let f=ISO8601DateFormatter();f.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        if let result=f.date(from:text){return result};f.formatOptions=[.withInternetDateTime];return f.date(from:text)
    }
    private static func pct(_ value:Double)->Double {min(100,max(0,value))}
    private static func dictionary(_ value:Any?)->[String:Any]? {value as? [String:Any]}
    private static func pick(_ root:[String:Any],_ camel:String,_ snake:String)->Any? {root[camel] ?? root[snake]}
    private static func component(_ value:String)->String {value.addingPercentEncoding(withAllowedCharacters:CharacterSet.alphanumerics.union(CharacterSet(charactersIn:"-_.~"))) ?? ""}

    // MARK: ClinePass and pay-as-you-go credit. The free-model daily cap has no read API.
    static func parseCline(_ root:[String:Any], now:Date=Date()) throws -> UsageSnapshot {
        guard root["success"] as? Bool == true,let data=dictionary(root["data"]),let limits=data["limits"] as? [[String:Any]] else{throw Connectors.schemaError}
        var result=UsageSnapshot.empty(source:"Cline 账户接口"), windows:[String:Quota]=[:]
        let definitions:[String:(String,Double?)]=["five_hour":("5 小时",18_000),"weekly":("每周",604_800),"monthly":("每月",nil)]
        for entry in limits {
            if let raw=entry["type"], !(raw is String) {throw Connectors.schemaError}
            guard let kind=entry["type"] as? String,let def=definitions[kind] else{continue}
            let raw=pick(entry,"percentUsed","percent_used")
            if raw == nil || raw is NSNull || (raw as? String)?.trimmingCharacters(in:.whitespaces).isEmpty == true {continue}
            guard let used=n(raw) else{throw Connectors.schemaError}
            let reset=pick(entry,"resetsAt","resets_at")
            if reset != nil, !(reset is NSNull),date(reset)==nil {throw Connectors.schemaError}
            windows[kind]=Quota(id:"cline-"+kind,title:"ClinePass · "+def.0,usedPercent:pct(used),resetsAt:date(reset),windowSeconds:def.1)
        }
        result.quotas=["five_hour","weekly","monthly"].compactMap{windows[$0]};result.observedAt=now
        result.note="ClinePass 套餐额度；免费模型的每日上限不由此接口提供。"
        return result
    }
    private static func fetchCline(_ raw:String) async throws -> UsageSnapshot {
        let token=try bearer(raw),headers=["Authorization":"Bearer "+token]
        var result=UsageSnapshot.empty(source:"Cline 账户接口"), partial:[String]=[]
        do {result=try parseCline(await json("https://api.cline.bot/api/v1/users/me/plan/usage-limits",headers:headers))}
        catch let error as HTTPFailure {if error.status==401 || error.status==403 || error.status==429 {throw error};if error.status != 404 {partial.append("套餐额度暂不可读")}}
        catch {partial.append("套餐额度响应无法识别")}
        var credits:Double?
        if let me=try? await json("https://api.cline.bot/api/v1/users/me",headers:headers),let data=dictionary(me["data"]),let id=data["id"] as? String,!id.isEmpty {
            let base="https://api.cline.bot/api/v1/users/"+component(id)
            if let body=try? await json(base+"/balance",headers:headers),body["success"] as? Bool==true,let amount=nonnegative(dictionary(body["data"])?["balance"]) {credits=amount/1_000_000}
            let now=Date(),cal=Calendar.current,start=cal.date(from:cal.dateComponents([.year,.month],from:now)) ?? now
            let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.dateFormat="yyyy-MM-dd"
            if let body=try? await json(base+"/usages/daily?startDate="+f.string(from:start)+"&endDate="+f.string(from:now),headers:headers),body["success"] as? Bool==true,let rows=dictionary(body["data"])?["items"] as? [[String:Any]] {
                let cost=try clineCost(rows)
                result.periodStart=start;result.periodEnd=now;result.costs=[Money(currency:"USD",value:cost)]
            }
        }
        if let credits {result.creditBalances=[.init(id:"cline-credits",title:"账户余额",unit:"Credits",value:credits)]}
        guard !result.quotas.isEmpty || !result.costs.isEmpty || credits != nil else {throw MonitorError.message("Cline 未返回可用套餐额度或积分余额，请确认使用 Cline API Key 或带 workos: 前缀的登录令牌。")}
        result.note=([result.note ?? ""]+partial).filter{!$0.isEmpty}.joined(separator:"；")
        return result
    }
    static func clineCost(_ rows:[[String:Any]]) throws -> Double {
        var total=0.0
        for row in rows {
            let free=[row["aiModelName"],row["aiModelTypeName"]].compactMap{$0 as? String}.contains{let text=$0.lowercased();return text=="cline-free" || text.hasPrefix("cline-free/")}
            if free {continue};guard let value=nonnegative(row["costUsd"]) else{throw Connectors.schemaError};total+=value/100_000_000
        }
        guard total.isFinite else{throw Connectors.schemaError};return total
    }

    // MARK: Factory Droid. Standard and Core are independent pools, not duplicates.
    static func parseFactory(_ root:[String:Any], now:Date=Date()) throws -> UsageSnapshot {
        var result=UsageSnapshot.empty(source:"Factory Droid 账单接口");result.observedAt=now
        if root["usesTokenRateLimitsBilling"] as? Bool==true,let limits=dictionary(root["limits"]),dictionary(limits["standard"]) != nil {
            for name in ["standard","core"] {
                guard let pool=dictionary(limits[name]) else{continue}
                if name=="core", !["fiveHour","weekly","monthly"].contains(where:{let r=dictionary(pool[$0]);return (n(r?["usedPercent"]) ?? 0)>0 || r?["windowEnd"] != nil || r?["secondsRemaining"] != nil}) {continue}
                for (field,label,seconds) in [("fiveHour","5 小时",Optional(18_000.0)),("weekly","每周",Optional(604_800.0)),("monthly","每月",nil)] {
                    guard let window=dictionary(pool[field]) else{continue}
                    guard let used=n(window["usedPercent"]) else{if window["usedPercent"] != nil {throw Connectors.schemaError};continue}
                    let remaining=nonnegative(window["secondsRemaining"]),end=date(window["windowEnd"])
                    if remaining==nil,let end,end<=now {continue}
                    let reset=remaining.flatMap{$0>0 ? now.addingTimeInterval($0):nil} ?? end
                    result.quotas.append(.init(id:"factory-\(name)-\(field)",title:"Droid \(name=="core" ? "Core":"Standard") · \(label)",usedPercent:pct(used),resetsAt:reset,windowSeconds:seconds))
                }
            }
            if let balance=nonnegative(root["extraUsageBalanceCents"]) {result.balances=[.init(currency:"USD",value:balance/100)]}
        } else if let usage=dictionary(root["usage"]) {
            for name in ["standard","premium"] {
                guard let bucket=dictionary(usage[name]) else{continue}
                let used=nonnegative(bucket["userTokens"]),limit=nonnegative(bucket["totalAllowance"]),ratio=n(bucket["usedRatio"])
                let reliable=limit.map{$0>0 && $0<=1_000_000_000_000} ?? false
                var percentage:Double?
                if let ratio,(-0.001...1.001).contains(ratio),!(ratio==0 && (used ?? 0)>0 && reliable) {percentage=ratio*100}
                else if reliable,let used,let limit {percentage=used/limit*100}
                else if !reliable,let ratio,(-0.1...100.1).contains(ratio) {percentage=ratio}
                if let percentage {result.quotas.append(.init(id:"factory-legacy-"+name,title:"Droid · "+name.capitalized,usedPercent:pct(percentage),resetsAt:date(usage["endDate"])))}
            }
        }
        guard !result.quotas.isEmpty || !result.balances.isEmpty else{throw Connectors.schemaError}
        result.note="Factory 返回的独立额度池；额外余额按美分换算，不从本地 Token 消耗反推套餐额度。";return result
    }
    private static func fetchFactory(_ raw:String) async throws -> UsageSnapshot {
        let headers=["Authorization":"Bearer "+(try bearer(raw)),"Origin":"https://app.factory.ai","Referer":"https://app.factory.ai/","x-factory-client":"web-app"]
        do {return try parseFactory(await json("https://api.factory.ai/api/billing/limits",headers:headers))}
        catch let error as HTTPFailure {if error.status==401 || error.status==403 || error.status==429 {throw error}}
        catch is CancellationError {throw CancellationError()}
        catch {}
        var latest:Error=Connectors.schemaError
        for base in ["https://api.factory.ai","https://app.factory.ai"] {
            do {
                let auth=try await json(base+"/api/app/auth/me",headers:headers),profile=dictionary(auth["userProfile"])
                let id=(profile?["id"] as? String) ?? (dictionary(profile?["workosUser"])?["id"] as? String)
                let query=id.map{"&userId="+component($0)} ?? ""
                return try parseFactory(await json(base+"/api/organization/subscription/usage?useCache=true"+query,headers:headers))
            } catch is CancellationError {throw CancellationError()}
            catch let error as HTTPFailure {if error.status==401 || error.status==403 || error.status==429 {throw error};latest=error}
            catch {latest=error}
        };throw latest
    }

    // MARK: Zed. Infinite edit predictions are a note, never a fabricated percentage.
    static func parseZed(_ root:[String:Any], subscription:[String:Any]?=nil) throws -> UsageSnapshot {
        guard let usage=dictionary(root["current_usage"]) else{throw Connectors.schemaError}
        let sub=dictionary(subscription?["subscription"]),period=dictionary(sub?["period"]),reset=date(period?["end_at"])
        var result=UsageSnapshot.empty(source:"Zed 官方账单页面接口"),notes:[String]=[]
        if let spend=dictionary(usage["token_spend"]),let cents=nonnegative(usage["token_spend_in_cents"] ?? spend["spend_in_cents"]),let limit=nonnegative(spend["limit_in_cents"]),limit>0 {
            result.quotas.append(.init(id:"zed-token-spend",title:"Zed · 模型用量",usedPercent:pct(cents/limit*100),resetsAt:reset))
            notes.append(String(format:"模型用量 $%.2f / $%.2f",cents/100,limit/100))
        }
        if let prediction=dictionary(usage["edit_predictions"]),prediction["limit"] is NSNull {notes.append("编辑预测：不限量")}
        else if let prediction=dictionary(usage["edit_predictions"]),let used=nonnegative(prediction["used"]),let limit=nonnegative(prediction["limit"]),limit>0 {result.quotas.append(.init(id:"zed-edit-predictions",title:"Zed · 编辑预测",usedPercent:pct(used/limit*100),resetsAt:reset))}
        guard !result.quotas.isEmpty || !notes.isEmpty else{throw Connectors.schemaError}
        result.note=notes.joined(separator:"；");return result
    }
    private static func fetchZed(_ raw:String) async throws -> UsageSnapshot {
        let headers=["Cookie":try cookie(raw,kind:"zed"),"Origin":"https://dashboard.zed.dev","Referer":"https://dashboard.zed.dev/"]
        let usage=try await json("https://cloud.zed.dev/frontend/billing/usage",headers:headers)
        let subscription=try? await json("https://cloud.zed.dev/frontend/billing/subscriptions/current",headers:headers)
        return try parseZed(usage,subscription:subscription)
    }

    // MARK: Qoder global / China; shared credits belong to the same additive pool.
    static func parseQoder(_ root:[String:Any]) throws -> UsageSnapshot {
        let body=dictionary(root["data"]) ?? root
        func summary(_ value:Any?) throws -> (Double,Double,Double)? {
            guard let container=dictionary(value) else{return nil}
            guard let summary=dictionary(pick(container,"quotaSummary","quota_summary")),let used=nonnegative(pick(summary,"usedValue","used_value")),let total=nonnegative(pick(summary,"limitValue","limit_value")) else{throw Connectors.schemaError}
            return (used,total,nonnegative(pick(summary,"remainingValue","remaining_value")) ?? max(0,total-used))
        }
        guard let main=try summary(pick(body,"totalQuota","total_quota")) else{throw Connectors.schemaError}
        let shared=try summary(pick(body,"sharedQuota","shared_quota")) ?? (0,0,0),used=main.0+shared.0,total=main.1+shared.1,left=main.2+shared.2
        guard used.isFinite,total.isFinite,left.isFinite else{throw Connectors.schemaError}
        var result=UsageSnapshot.empty(source:"Qoder 账户用量接口")
        if total>0 {result.quotas=[.init(id:"qoder-credits",title:"Qoder · 积分",usedPercent:pct(used/total*100),resetsAt:date(pick(body,"nextResetAt","next_reset_at")))]}
        result.creditBalances=[.init(id:"qoder-credits",title:"剩余积分",unit:"Credits",value:left)]
        result.note=String(format:"积分已用 %.2f，剩余 %.2f，总额 %.2f；包含团队共享积分。",used,left,total)
        return result
    }
    private static func fetchQoder(_ raw:String,region:String?) async throws -> UsageSnapshot {
        let origin=region=="cn" ? "https://qoder.com.cn":"https://qoder.com"
        let headers=["Cookie":try cookie(raw,kind:"qoder"),"Origin":origin,"Referer":origin+"/account/usage","X-Requested-With":"XMLHttpRequest","Bx-V":"2.5.35"]
        return try parseQoder(await json(origin+"/api/v2/me/usages/big_model_credits",headers:headers))
    }

    // MARK: OpenCode Go is a separate API product from Zen's console cookie.
    static func parseOpenCodeGo(_ root:[String:Any]) throws -> UsageSnapshot {
        guard let usage=dictionary(root["usage"]) else{throw Connectors.schemaError}
        var result=UsageSnapshot.empty(source:"OpenCode Go 官方用量 API")
        for (key,label) in [("rolling","滚动窗口"),("weekly","每周"),("monthly","每月")] {
            guard let row=dictionary(usage[key]) else{continue}
            let exhausted=(row["status"] as? String)=="rate-limited"
            guard let used=n(row["percent"]) ?? (exhausted ? 100:nil) else{throw Connectors.schemaError}
            result.quotas.append(.init(id:"opencode-go-"+key,title:"OpenCode Go · "+label,usedPercent:pct(used),resetsAt:date(row["resetsAt"]),exhausted:exhausted))
        }
        guard !result.quotas.isEmpty else{throw Connectors.schemaError}
        result.note="Go 接口返回的百分比；窗口时长和美元授权额未由响应提供，保持未知。Zen 余额需使用 Zen Cookie 接口。";return result
    }
    private static func fetchOpenCodeGo(_ raw:String) async throws -> UsageSnapshot {try parseOpenCodeGo(await json("https://opencode.ai/zen/go/v1/usage",headers:["Authorization":"Bearer "+(try bearer(raw))]))}
    private static let workspaceFunction="def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"
    private static let subscriptionFunction="7abeebee372f304e050aaaf92be863f4a86490e382f8c79db68fd94040d691b4"
    static func parseOpenCodeZen(_ text:String,now:Date=Date()) throws -> UsageSnapshot {
        var result=UsageSnapshot.empty(source:"OpenCode Zen 控制台只读接口");result.observedAt=now
        let keys=[("rollingUsage","滚动窗口"),("weeklyUsage","每周"),("monthlyUsage","每月")]
        for (key,label) in keys {
            if let body=firstCapture("(?:\\\"?"+key+"\\\"?)\\s*[:=]\\s*\\{([^}]{0,1000})\\}",text),let raw=firstCapture("\\\"?(?:usagePercent|usedPercent|percentUsed|percent)\\\"?\\s*[:=]\\s*([0-9]+(?:\\.[0-9]+)?)",body),let used=Double(raw) {
                let reset=firstCapture("\\\"?(?:resetInSec|resetInSeconds)\\\"?\\s*[:=]\\s*([0-9]+)",body).flatMap(Double.init).flatMap{$0>0 ? now.addingTimeInterval($0):nil}
                result.quotas.append(.init(id:"opencode-zen-"+key,title:"OpenCode Zen · "+label,usedPercent:pct(used),resetsAt:reset))
            }
        }
        if let raw=firstCapture("\\\"?(?:balanceUSD|balanceUsd|currentBalanceUSD|currentBalance|zenBalance)\\\"?\\s*[:=]\\s*([0-9]+(?:\\.[0-9]+)?)",text),let value=Double(raw),value.isFinite {result.balances=[.init(currency:"USD",value:value)]}
        guard !result.quotas.isEmpty || !result.balances.isEmpty else{throw MonitorError.message("OpenCode Zen 未返回可识别的订阅或余额。控制台接口可能已更新，请检查工作区与登录状态。")}
        result.note="Zen 控制台的真实读数；使用网站内部只读函数，网站升级时可能需要更新连接器。";return result
    }
    private static func serverFunction(_ id:String,args:[String],cookie:String,method:String="GET") async throws -> String {
        var components=URLComponents(string:"https://opencode.ai/_server")!
        let arguments=try JSONSerialization.data(withJSONObject:args)
        if method=="GET" {components.queryItems=[URLQueryItem(name:"id",value:id)];if !args.isEmpty {components.queryItems?.append(.init(name:"args",value:String(decoding:arguments,as:UTF8.self)))}}
        var headers=["Cookie":cookie,"X-Server-Id":id,"X-Server-Instance":"server-fn:"+UUID().uuidString,"Origin":"https://opencode.ai","Referer":"https://opencode.ai","Accept":"text/javascript, application/json;q=0.9, */*;q=0.8"]
        if method=="POST" {headers["Content-Type"]="application/json"}
        let data=try await request(components.url!,headers:headers,method:method,body:method=="POST" ? arguments:nil),text=String(decoding:data,as:UTF8.self)
        if ["<html","auth/authorize","not associated with an account","actor of type \"public\""].contains(where:{text.lowercased().contains($0)}) {throw HTTPFailure(status:401)}
        return text
    }
    private static func fetchOpenCodeZen(_ raw:String,workspace:String?) async throws -> UsageSnapshot {
        let cookies=try cookie(raw,kind:"opencode")
        var id=workspace?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        if !id.isEmpty, id.range(of:"^wrk_[A-Za-z0-9]+$",options:.regularExpression)==nil {throw MonitorError.message("OpenCode 工作区应填写 wrk_ 开头的工作区 ID。")}
        if id.isEmpty {
            var text=try await serverFunction(workspaceFunction,args:[],cookie:cookies)
            var ids=Set(captures("\\b(wrk_[A-Za-z0-9]+)\\b",text))
            if ids.isEmpty {text=try await serverFunction(workspaceFunction,args:[],cookie:cookies,method:"POST");ids=Set(captures("\\b(wrk_[A-Za-z0-9]+)\\b",text))}
            guard ids.count==1,let selected=ids.first else{throw MonitorError.message(ids.isEmpty ? "OpenCode 未找到工作区，请在账户设置填写工作区 ID。":"OpenCode 有多个工作区，请在账户设置指定工作区 ID，避免显示错误账户。")};id=selected
        }
        let text=try await serverFunction(subscriptionFunction,args:[id],cookie:cookies)
        if text.trimmingCharacters(in:.whitespacesAndNewlines)=="null" {throw MonitorError.message("该 OpenCode 工作区没有 Zen 订阅；Go 套餐请切换 Go API。")}
        do{return try parseOpenCodeZen(text)}catch{return try parseOpenCodeZen(await serverFunction(subscriptionFunction,args:[id],cookie:cookies,method:"POST"))}
    }

    // MARK: Kiro's CLI query. Only the literal /usage command is executed; no prompt,
    // interactive authentication, refresh-token rewrite, or arbitrary shell is involved.
    private static func captures(_ pattern:String,_ text:String)->[String] {
        guard let re=try? NSRegularExpression(pattern:pattern,options:[.caseInsensitive]) else{return []}
        return re.matches(in:text,range:NSRange(text.startIndex...,in:text)).compactMap{guard $0.numberOfRanges>1,let range=Range($0.range(at:1),in:text) else{return nil};return String(text[range])}
    }
    private static func firstCapture(_ pattern:String,_ text:String)->String? {captures(pattern,text).first}
    static func parseKiro(_ raw:String,now:Date=Date()) throws -> UsageSnapshot {
        let text=raw.replacingOccurrences(of:"\u{1B}\\[[0-9;?]*[ -/]*[@-~]",with:"",options:.regularExpression).replacingOccurrences(of:"\u{1B}\\].*?(?:\u{07}|\u{1B}\\\\)",with:"",options:.regularExpression)
        let lower=text.lowercased()
        if ["not logged in","login required","failed to initialize auth portal","kiro-cli login","oauth error"].contains(where:{lower.contains($0)}) {throw MonitorError.message("Kiro CLI 尚未登录，请在 Kiro 中完成登录后重试。")}
        let pair=captures("\\(([0-9]+(?:\\.[0-9]+)?)\\s+of\\s+[0-9]+(?:\\.[0-9]+)?\\s+covered",text).first.flatMap(Double.init)
        let limit=firstCapture("\\([0-9]+(?:\\.[0-9]+)?\\s+of\\s+([0-9]+(?:\\.[0-9]+)?)\\s+covered",text).flatMap(Double.init)
        let bar=firstCapture("█+\\s*([0-9]+(?:\\.[0-9]+)?)%",text).flatMap(Double.init)
        guard let percent=bar ?? pair.flatMap({used in limit.flatMap{$0>0 ? used/$0*100:nil}}) else{throw MonitorError.message(lower.contains("managed by") ? "Kiro 由组织管理，CLI 没有提供可读取的个人额度。":"Kiro CLI 未返回可识别的额度，请更新 Kiro CLI 后重试。")}
        var result=UsageSnapshot.empty(source:"Kiro CLI /usage 只读查询");result.observedAt=now
        let resetText=firstCapture("resets on ([0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{2}/[0-9]{2})",text)
        let reset=resetText.flatMap{kiroReset($0,now:now)}
        result.quotas=[.init(id:"kiro-credits",title:"Kiro · 月度积分",usedPercent:pct(percent),resetsAt:reset)]
        var notes:[String]=[]
        if let used=pair,let total=limit {notes.append(String(format:"积分 %.2f / %.2f",used,total))}
        if lower.contains("bonus credits"),let used=firstCapture("(?:Bonus credits:\\s*|)([0-9]+(?:\\.[0-9]+)?)\\s*/\\s*[0-9]+(?:\\.[0-9]+)?\\s+credits used",text).flatMap(Double.init),let total=firstCapture("[0-9]+(?:\\.[0-9]+)?\\s*/\\s*([0-9]+(?:\\.[0-9]+)?)\\s+credits used",text).flatMap(Double.init),total>0 {
            result.quotas.append(.init(id:"kiro-bonus",title:"Kiro · 赠送积分",usedPercent:pct(used/total*100),resetsAt:nil))
            if let days=firstCapture("expires in ([0-9]+) days?",text) {notes.append("赠送积分将在 \(days) 天后到期")}
        }
        if let status=firstCapture("Overages:\\s*([^\\n]+)",text),status.lowercased().hasPrefix("enabled"),let cost=firstCapture("Est\\.?\\s*cost:\\s*\\$?([0-9]+(?:\\.[0-9]+)?)\\s*USD",text) {notes.append("额外用量估算 $\(cost)，以 Kiro 账单为准")}
        result.note=notes.joined(separator:"；");return result
    }
    private static func kiroReset(_ text:String,now:Date)->Date? {
        let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.isLenient=false;f.dateFormat="yyyy-MM-dd"
        if text.contains("-") {return f.date(from:text)}
        let pieces=text.split(separator:"/").compactMap{Int($0)};guard pieces.count==2 else{return nil}
        let cal=Calendar.current,year=cal.component(.year,from:now)
        for candidateYear in [year,year+1] {
            let string=String(format:"%04d-%02d-%02d",candidateYear,pieces[0],pieces[1])
            if let value=f.date(from:string),f.string(from:value)==string,value>now{return value}
        };return nil
    }
    private static func fetchKiro(path:String?) async throws -> UsageSnapshot {
        let configured=path?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        let candidates=configured.isEmpty ? [NSHomeDirectory()+"/.local/bin/kiro-cli","/opt/homebrew/bin/kiro-cli","/usr/local/bin/kiro-cli"]:[configured]
        guard let executable=candidates.first(where:{$0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath:$0)}) else{throw MonitorError.message("未找到 Kiro CLI，请安装并登录 kiro-cli，或填写其绝对路径。")}
        let cancellation=ToolQueryCancellation()
        return try await withTaskCancellationHandler(operation: {
            let text=try await Task.detached(priority:.utility){try runKiro(executable,legacy:false,cancellation:cancellation)}.value
            try Task.checkCancellation()
            if firstCapture(#"Plan:[^\n]*\|\s*([0-9]+)\s+usage breakdowns?"#,text) != nil, !text.contains("covered"),!text.contains("█") {
                let fallback=try await Task.detached(priority:.utility){try runKiro(executable,legacy:true,cancellation:cancellation)}.value
                try Task.checkCancellation();return try parseKiro(fallback)
            };return try parseKiro(text)
        },onCancel:{cancellation.cancel()})
    }
    private static func runKiro(_ executable:String,legacy:Bool,cancellation:ToolQueryCancellation) throws -> String {
        if cancellation.cancelled {throw CancellationError()}
        let process=Process();process.executableURL=URL(fileURLWithPath:executable)
        process.arguments=legacy ? ["chat","--no-interactive","--agent-engine=v1","--legacy-ui","/usage"]:["chat","--no-interactive","/usage"]
        process.standardInput=FileHandle.nullDevice
        var env=ProcessInfo.processInfo.environment;env["TERM"]="xterm-256color";env["NO_COLOR"]="1";process.environment=env
        let out=Pipe(),err=Pipe();process.standardOutput=out;process.standardError=err
        let handles=[out.fileHandleForReading,err.fileHandleForReading]
        for handle in handles {let flags=fcntl(handle.fileDescriptor,F_GETFL);_ = fcntl(handle.fileDescriptor,F_SETFL,flags|O_NONBLOCK)}
        do {try process.run()} catch {throw MonitorError.message("Kiro CLI 无法启动，请检查可执行文件。")}
        var outputs=[Data(),Data()],oversized=false,timedOut=false,stoppedAt:Date?
        let deadline=Date().addingTimeInterval(30)
        func drain() {
            for (index,handle) in handles.enumerated() {
                var buffer=[UInt8](repeating:0,count:16_384)
                while true {
                    let count=Darwin.read(handle.fileDescriptor,&buffer,buffer.count)
                    if count<=0 {break}
                    if outputs[index].count+count>1_000_000 {oversized=true;break}
                    outputs[index].append(contentsOf:buffer.prefix(count))
                }
            }
        }
        while process.isRunning {
            drain()
            if Date()>=deadline {timedOut=true}
            if (oversized || timedOut || cancellation.cancelled),stoppedAt==nil {process.terminate();stoppedAt=Date()}
            if let stoppedAt,Date().timeIntervalSince(stoppedAt)>=1,process.isRunning {kill(process.processIdentifier,SIGKILL)}
            Thread.sleep(forTimeInterval:0.02)
        }
        drain()
        for handle in handles {try? handle.close()}
        if cancellation.cancelled {throw CancellationError()}
        guard !timedOut else{throw MonitorError.message("Kiro /usage 查询超时，已停止进程。上次数据已保留。")}
        guard !oversized else{throw MonitorError.message("Kiro CLI 输出过大，已停止本次查询。")}
        let text=String(decoding:outputs[0],as:UTF8.self)
        return text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? String(decoding:outputs[1],as:UTF8.self):text
    }
}

private final class ToolQueryCancellation: @unchecked Sendable {
    private let lock=NSLock();private var value=false
    func cancel(){lock.lock();value=true;lock.unlock()}
    var cancelled:Bool {lock.lock();defer{lock.unlock()};return value}
}
