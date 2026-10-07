import Foundation

// Real Models.swift and ProviderIntegrations.swift are compiled with these adapters.
// Only unrelated logging dependencies and network transport are isolated.
enum Log {struct Sink{func error(_ value:String){}};static let store=Sink()}
enum AlertRules {static func attention(_ account:Account,threshold:Double,at:Date)->[String]{[]}}
enum TokenBundle {static let bundle=Bundle.main}
enum Connectors {static var session=URLSession(configuration:.ephemeral);static var schemaError:Error{MonitorError.message("响应结构不完整。")}}
final class CloudQuotaFixtureProtocol:URLProtocol {
    static var answer:((URLRequest)->(Int,Data))?
    static var requests:[URLRequest]=[]
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){
        Self.requests.append(request)
        let (status,data)=Self.answer?(request) ?? (500,Data())
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading(){}
}

@main struct CloudQuotaBridgeRegression {
    static func require(_ value: @autoclosure()->Bool,_ message:String){if !value(){fatalError(message)}}
    static func rejected(_ label:String,_ body:()throws->Void){do{try body();fatalError(label+" was accepted")}catch{}}
    static func main() async throws {
        let key:[String:Any]=["data":["limit":100,"limit_reset":"monthly","usage":999,"usage_monthly":20,"byok_usage_monthly":5,"include_byok_in_limit":true,"limit_remaining":70]]
        let router=try OpenRouterBridge.parse(key:key,credits:["data":["total_credits":200,"total_usage":50]])
        require(router.quotas[0].usedPercent==30,"authoritative remaining must beat cumulative spend")
        require(router.balances.first?.value==150 && router.costs.first?.value==20,"credits or monthly spend")
        let unknown=try OpenRouterBridge.parse(key:["data":["limit":100,"limit_reset":"weekly","usage_weekly":30,"include_byok_in_limit":true]],credits:["data":["total_credits":10,"total_usage":0]])
        require(unknown.quotas.isEmpty,"missing BYOK usage must not mean zero")
        let packs:[[String:Any]]=[
            ["entitlement_base_info":["quota":["credits_limit":100]],"usage":["credits_amount":30]],
            ["entitlement_base_info":["quota":["credits_limit":50]],"usage":[:]],
            ["entitlement_base_info":["quota":["feature":true]],"usage":[:]]]
        let trae=try TraeCNBridge.parse(["user_entitlement_pack_list":packs])
        require(trae.quotas[0].usedPercent==20 && trae.creditBalances?.first?.value==120 && trae.balances.isEmpty,"Trae credits not currency")
        rejected("Trae missing usage"){_ = try TraeCNBridge.parse(["user_entitlement_pack_list":[["entitlement_base_info":["quota":["credits_limit":100]]]]])}
        rejected("Trae partial malformed pack"){_ = try TraeCNBridge.parse(["user_entitlement_pack_list":packs+[["usage":["credits_amount":3]]]])}
        let step=try StepFunBridge.parse(["status":1,"five_hour_usage_left_rate":0.25,"weekly_usage_left_rate":0.7,"five_hour_usage_reset_time":1900000000,"weekly_usage_reset_time":1900100000])
        require(step.quotas.count==2 && step.quotas[0].usedPercent==75,"StepFun fraction direction")
        let credits=try StepFunBridge.parse(["status":1,"plan_family":2,"plan_credit_rate_limit":["credit_buckets":[["credit_total":100,"credit_residual":20],["credit_total":100,"credit_residual":80]]]])
        require(credits.quotas.first?.usedPercent==50 && credits.balances.isEmpty,"StepFun weighted credit buckets")
        rejected("StepFun partial credit bucket"){_ = try StepFunBridge.parse(["status":1,"plan_family":2,"plan_credit_rate_limit":["credit_buckets":[["credit_total":100]]]])}
        let token=try StepFunBridge.normalizedToken("other=x; Oasis-Token=fixture-token; Oasis-Webid=test")
        require(token=="fixture-token","StepFun cookie token normalization")
        let newBody:[String:Any]=["success":true,"code":0,"data":["quota":1000,"used_quota":500,"request_count":5]]
        let newRaw=try ThirdPartyQuotaBridge.parseNewAPI(newBody,status:nil,tokenMode:false)
        require(newRaw.balances.isEmpty && newRaw.creditBalances?.first?.value==1000,"unknown NewAPI unit must remain raw")
        let newUSD=try ThirdPartyQuotaBridge.parseNewAPI(newBody,status:["data":["quota_per_unit":100]],tokenMode:false)
        require(newUSD.balances.first?.value==10,"NewAPI reported unit")
        let unlimited=try ThirdPartyQuotaBridge.parseNewAPI(["data":["quota":-1,"used_quota":5]],status:nil,tokenMode:false)
        require(unlimited.balances.isEmpty && unlimited.quotas.isEmpty,"unlimited is not infinite money")
        rejected("NewAPI rejected envelope"){_ = try ThirdPartyQuotaBridge.parseNewAPI(["success":false,"data":["quota":1]],status:nil,tokenMode:false)}
        for url in ["http://service.example","https://secret@service.example","https://service.example?token=x","https://service.example/#x"] {rejected("unsafe base URL"){_ = try ThirdPartyQuotaBridge.baseURL(url)}}
        let sub=try ThirdPartyQuotaBridge.parseSub2API(["code":0,"data":["id":1,"balance":12.3]],month:["code":0,"data":["total_actual_cost":1.5,"total_cost":9.9,"total_input_tokens":100,"total_output_tokens":25]])
        require(sub.costs.first?.value==1.5 && sub.totalTokens==125,"Sub2API actual price vs list price")
        require(sub.periodStart != nil && sub.periodEnd != nil,"monthly scope")
        let personal=try AlibabaTokenPlanBridge.parsePersonal(["data":["per1MonthPercentage":0.4,"per1MonthResetTime":"2026-12-01 00:00:00"]])
        require(personal.quotas.count==1 && personal.quotas[0].usedPercent==40,"Alibaba monthly-only policy")
        require(personal.quotas[0].windowSeconds==nil,"calendar month cannot assume 30 days")
        let embedded=Data(#"{"success":true,"data":"{\"totalValue\":100,\"totalSurplusValue\":35,\"TotalCount\":1}"}"#.utf8)
        let team=try AlibabaTokenPlanBridge.parseTeam(AlibabaTokenPlanBridge.parseEnvelope(embedded))
        require(team.quotas.first?.usedPercent==65 && team.creditBalances?.first?.value==35 && team.balances.isEmpty,"Alibaba embedded quota not money")
        let noSubscription=try AlibabaTokenPlanBridge.parseTeam(["data":["TotalCount":0]])
        require(noSubscription.quotas.isEmpty,"no Alibaba subscription must not show free quota")
        rejected("Alibaba error envelope"){_ = try AlibabaTokenPlanBridge.parseEnvelope(Data(#"{"success":false,"code":403,"data":{"per1MonthPercentage":0}}"#.utf8))}
        rejected("nested Alibaba failure"){_ = try AlibabaTokenPlanBridge.parseEnvelope(Data(#"{"success":true,"data":{"success":false,"per1MonthPercentage":0}}"#.utf8))}
        for id in ["cn","intl","cn-personal","intl-personal"]{_ = try AlibabaTokenPlanBridge.variant(id)}
        require(AlibabaTokenPlanBridge.secToken(#"window.ALIYUN_CONSOLE_CONFIG={SEC_TOKEN:'fixture'}"#)=="fixture","Alibaba shell security token")
        let action=String(repeating:"a",count:40)
        require(TypeSafeBridge.actionID(in:"\"\(action)\",xx,\"getBillingOverviewResult\"")==action,"TypeSafe dynamic action")
        let script=#"let gt=.042/1e6; t.s(["INPUT_TOKEN_COST_USD",0,gt,"OUTPUT_TOKEN_COST_USD",0,0])"#
        require(abs((TypeSafeBridge.tokenRate(in:script,name:"INPUT_TOKEN_COST_USD") ?? 0)-0.042/1e6)<1e-16,"TypeSafe minified token rate")
        let billing=try TypeSafeBridge.parseBilling(Data(#"1:{"ok":true,"data":{"billing":{"balance":9.5,"plan":"pro_plan"}}}"#.utf8))
        let now=Date(timeIntervalSince1970:1900000000),f=ISO8601DateFormatter()
        let usage:[String:Any]=["buckets":[["day":f.string(from:now.addingTimeInterval(-1)),"inputTokens":100,"outputTokens":20,"requests":1]]]
        let typed=try TypeSafeBridge.parse(billing:billing,usage:usage,inputRate:0.01,outputRate:0,now:now)
        require(typed.balances.first?.value==9.5 && typed.totalTokens==120 && typed.costs.first?.value==1,"TypeSafe usage period and rate")
        let unpriced=try TypeSafeBridge.parse(billing:billing,usage:usage,inputRate:nil,outputRate:nil,now:now)
        require(unpriced.costs.isEmpty,"missing TypeSafe prices not zero")
        rejected("cookie header injection"){_ = try ProviderCloudHTTP.cookie("session=test\r\nX-Injected: yes")}
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[CloudQuotaFixtureProtocol.self];Connectors.session=URLSession(configuration:config)
        CloudQuotaFixtureProtocol.answer={request in
            if request.url!.path=="/settings/billing" && request.httpMethod=="GET"{return (200,Data("<html><script src=\"/_next/a.js\"></script><script src=\"https://unrelated.example/evil.js\"></script></html>".utf8))}
            if request.url!.path=="/_next/a.js"{return (200,Data(("\"\(action)\",xx,\"getBillingOverviewResult\";"+script).utf8))}
            if request.url!.path=="/settings/billing" && request.httpMethod=="POST"{return (200,Data(#"1:{"ok":true,"data":{"billing":{"balance":9.5}}}"#.utf8))}
            return (503,Data())
        }
        let partial=try await TypeSafeBridge.fetch(cookie:"session=fixture-only")
        require(partial.balances.first?.value==9.5 && partial.inputTokens==nil,"TypeSafe usage failure must retain proven balance")
        require(CloudQuotaFixtureProtocol.requests.allSatisfy{$0.url?.host=="console.typesafe.ai"},"TypeSafe sent a credential to unrelated script origin")
        require(CloudQuotaFixtureProtocol.requests.contains{$0.httpMethod=="POST" && $0.value(forHTTPHeaderField:"Next-Action")==action},"TypeSafe action ID header not bound")
        CloudQuotaFixtureProtocol.answer={_ in(401,Data())}
        do{_ = try await OpenRouterBridge.fetch(key:"fixture-key");fatalError("OpenRouter rejected key accepted")}
        catch{require(error.localizedDescription.contains("凭证已被拒绝"),"OpenRouter credential error swallowed")}
        CloudQuotaFixtureProtocol.requests=[]
        CloudQuotaFixtureProtocol.answer={request in
            if request.url!.path.hasSuffix("/api/user/self"){return(200,Data(#"{"success":true,"data":{"quota":1000,"used_quota":200}}"#.utf8))}
            return(200,Data(#"{"success":true,"data":{"quota_per_unit":100}}"#.utf8))
        }
        let requestResult=try await ThirdPartyQuotaBridge.fetch(adapter:"newapi",baseURL:"https://fixture.example/relay",credential:"test-credential",userID:"42",tokenMode:false)
        require(requestResult.balances.first?.value==10,"NewAPI request path/response integration")
        require(CloudQuotaFixtureProtocol.requests.first?.url?.path=="/relay/api/user/self","base path was dropped")
        require(CloudQuotaFixtureProtocol.requests.first?.value(forHTTPHeaderField:"New-Api-User")=="42","NewAPI account user ID absent")
        CloudQuotaFixtureProtocol.requests=[]
        CloudQuotaFixtureProtocol.answer={request in
            if request.url!.path.hasSuffix("/api/v1/auth/me"){return(200,Data(#"{"code":0,"data":{"id":1,"balance":8}}"#.utf8))}
            return(200,Data(#"{"code":0,"data":{"total_actual_cost":1}}"#.utf8))
        }
        _ = try await ThirdPartyQuotaBridge.fetch(adapter:"sub2api",baseURL:"https://fixture.example",credential:"test-credential")
        let monthRequest=CloudQuotaFixtureProtocol.requests.first{$0.url?.path.hasSuffix("/usage/stats")==true}!
        let timezone=URLComponents(url:monthRequest.url!,resolvingAgainstBaseURL:false)?.queryItems?.first{$0.name=="timezone"}?.value
        require(timezone==TimeZone.current.identifier,"Sub2API monthly query timezone differs from snapshot month")
        let cancelled=Task{try Task.checkCancellation();_ = try await TraeCNBridge.fetch(token:"fixture-only")};cancelled.cancel()
        do{try await cancelled.value;fatalError("cancelled query accepted")}catch is CancellationError{}catch{fatalError("cancellation was turned into an authentication failure")}
        print("PASS CloudQuotaBridgeRegression: real snapshot validation; 7 providers, envelopes, units, monthly windows, partial errors, dynamic discovery, credential sanitization")
    }
}
