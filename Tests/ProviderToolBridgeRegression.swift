import Foundation
import CoreFoundation

// Standalone transport/parser regression fixtures. No user credentials are read.
struct Money {var currency:String;var value:Double}
struct CreditBalance {var id:String;var title:String;var unit:String;var value:Double}
struct Quota {var id:String;var title:String;var usedPercent:Double;var resetsAt:Date?;var exhausted=false;var windowSeconds:Double?=nil}
struct UsageSnapshot {
    var observedAt=Date();var source:String;var quotas:[Quota]=[];var costs:[Money]=[];var balances:[Money]=[];var note:String?;var periodStart:Date?;var periodEnd:Date?;var creditBalances:[CreditBalance]?
    static func empty(source:String)->Self{.init(source:source)}
    func validate()throws {guard quotas.allSatisfy({$0.usedPercent.isFinite && (0...100).contains($0.usedPercent)}),(costs+balances).allSatisfy({$0.value.isFinite}),costs.isEmpty || (periodStart != nil && periodEnd != nil) else{throw MonitorError.message("bad snapshot")}}
}
enum MonitorError:LocalizedError {case message(String);var errorDescription:String? {if case .message(let text)=self{return text};return nil}}
enum Connectors {
    static let schemaError=MonitorError.message("schema")
    static var session:URLSession={let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[MockQuotaProtocol.self];return URLSession(configuration:config)}()
    static func number(_ value:Any?)->Double? {
        if let n=value as? NSNumber {if CFGetTypeID(n)==CFBooleanGetTypeID(){return nil};return n.doubleValue.isFinite ? n.doubleValue:nil}
        if let text=value as? String,let n=Double(text),n.isFinite{return n};return nil
    }
}
final class MockQuotaProtocol:URLProtocol {
    static var handler:((URLRequest)throws->(Int,Data))?
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){do{let(status,data)=try Self.handler!(request);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)}catch{client?.urlProtocol(self,didFailWithError:error)}}
    override func stopLoading(){}
}
@main struct ProviderToolBridgeRegression {
    static func check(_ condition:@autoclosure()throws->Bool,_ message:String)throws{if try !condition(){throw MonitorError.message(message)}}
    static func data(_ object:Any)throws->Data{try JSONSerialization.data(withJSONObject:object,options:[.fragmentsAllowed])}
    static func main()async throws {
        let now=Date(timeIntervalSince1970:1_790_000_000)
        let cline:[String:Any]=["success":true,"data":["limits":[["type":"five_hour","percentUsed":0.5],["type":"weekly","percentUsed":20],["type":"monthly","percent_used":30],["type":"weekly","percentUsed":25]]]]
        let c=try ProviderToolBridge.parseCline(cline,now:now)
        try check(c.quotas.count==3 && c.quotas[0].usedPercent==0.5 && c.quotas[1].usedPercent==25,"Cline percentage or duplicate window wrong")
        let paid=try ProviderToolBridge.clineCost([["aiModelName":"cline-free/test","costUsd":900000000],["aiModelName":"paid","costUsd":125000000]])
        try check(paid==1.25,"Cline free tier or 1e8 billing conversion wrong")
        var rejected=false;do{_=try ProviderToolBridge.parseCline(["success":true,"data":["limits":[["type":"weekly","percentUsed":"broken"]]]])}catch{rejected=true};try check(rejected,"Cline invalid percentage became zero")
        let factory:[String:Any]=["usesTokenRateLimitsBilling":true,"limits":["standard":["fiveHour":["usedPercent":40,"secondsRemaining":600],"weekly":["usedPercent":60]],"core":["fiveHour":["usedPercent":15,"secondsRemaining":30],"weekly":["usedPercent":0]]],"extraUsageBalanceCents":425]
        let f=try ProviderToolBridge.parseFactory(factory,now:now);try check(f.quotas.count==4 && f.balances.first?.value==4.25,"Factory independent pools/cents wrong")
        let legacy=try ProviderToolBridge.parseFactory(["usage":["standard":["userTokens":25,"totalAllowance":100,"usedRatio":0]]]);try check(legacy.quotas.first?.usedPercent==25,"Factory stale zero ratio masks real consumption")
        let z=try ProviderToolBridge.parseZed(["current_usage":["token_spend_in_cents":250,"token_spend":["limit_in_cents":1000],"edit_predictions":["limit":NSNull()]]]);try check(z.quotas.count==1 && z.quotas[0].usedPercent==25 && z.note!.contains("不限量"),"Zed cents/unlimited wrong")
        let filtered=try ProviderToolBridge.cookie("zed.session=test; secret.other=discard; cf_clearance=ok",kind:"zed");try check(!filtered.contains("secret.other"),"Zed forwarded unrelated cookies")
        rejected=false;do{_=try ProviderToolBridge.cookie("session=wrongsite",kind:"zed")}catch{rejected=true};try check(rejected,"Zed accepted another site's cookie")
        let q=try ProviderToolBridge.parseQoder(["data":["totalQuota":["quotaSummary":["usedValue":25,"limitValue":100]],"sharedQuota":["quotaSummary":["usedValue":25,"limitValue":100]]]])
        try check(q.quotas.first?.usedPercent==25 && q.creditBalances?.first?.value==150,"Qoder additive pools or remaining credits wrong")
        let go=try ProviderToolBridge.parseOpenCodeGo(["usage":["rolling":["percent":0.5],"weekly":["status":"rate-limited"]]])
        try check(go.quotas.first?.usedPercent==0.5 && go.quotas[1].exhausted && go.quotas.first?.windowSeconds==nil,"Go percent/status/unknown duration wrong")
        let zen=try ProviderToolBridge.parseOpenCodeZen("fn({rollingUsage:{usagePercent:0.5,resetInSec:60},weeklyUsage:{usagePercent:10},balanceUSD:3.25})",now:now)
        try check(zen.quotas[0].usedPercent==0.5 && zen.quotas[1].resetsAt==nil && zen.balances.first?.value==3.25,"Zen fraction wrongly expanded or missing reset fabricated")
        // Literal fixtures supplied by reference tests/shared/opencodeWeb.test.js.
        let upstreamJS="foo({rollingUsage:{usagePercent:55,resetInSec:120},weeklyUsage:{usagePercent:5,resetInSec:600},balanceUSD:3.25})"
        let upstreamJSON="{\"rollingUsage\":{\"usagePercent\":33,\"resetInSec\":60}}"
        try check(try ProviderToolBridge.parseOpenCodeZen(upstreamJS,now:now).quotas.first?.usedPercent==55,"reference JavaScript fixture unsupported")
        try check(try ProviderToolBridge.parseOpenCodeZen(upstreamJSON,now:now).quotas.first?.usedPercent==33,"reference JSON fixture unsupported")
        let kiro=try ProviderToolBridge.parseKiro("Estimated Usage | resets on 2027-02-01 | KIRO PRO\n██ 25% (25 of 100 covered)\nBonus credits:\n5/20 credits used\nexpires in 7 days\nOverages: Enabled\nEst. cost: $1.25 USD",now:now)
        try check(kiro.quotas.count==2 && kiro.quotas[0].usedPercent==25 && kiro.note!.contains("1.25"),"Kiro quota/bonus/overage parse failed")
        rejected=false;do{_=try ProviderToolBridge.parseKiro("Plan: Q Developer Pro\nManaged by admin")}catch{rejected=true};try check(rejected,"Kiro fabricated managed-plan quota")

        // Read-only endpoint request fixtures verify credential shape and account routing.
        MockQuotaProtocol.handler={request in
            try check(request.url?.host=="api.cline.bot","Cline wrong host")
            try check(request.value(forHTTPHeaderField:"Authorization")=="Bearer workos:fixture","Cline dropped workos prefix")
            switch request.url!.path {
            case "/api/v1/users/me/plan/usage-limits":return (200,try data(cline))
            case "/api/v1/users/me":return (200,try data(["data":["id":"own-user"]]))
            case "/api/v1/users/own-user/balance":return (200,try data(["success":true,"data":["balance":500000]]))
            default:return (200,try data(["success":true,"data":["items":[["aiModelName":"cline-free/test","costUsd":99000000],["aiModelName":"paid","costUsd":125000000]]]]))
            }
        }
        let liveCline=try await ProviderToolBridge.fetch(provider:"cline",credential:"workos:fixture",scope:nil,region:nil)
        try check(liveCline.creditBalances?.first?.value==0.5 && liveCline.balances.isEmpty && liveCline.costs.first?.value==1.25,"Cline credits represented as USD or spend wrong")
        MockQuotaProtocol.handler={request in try check(request.url?.host=="qoder.com.cn","Qoder region wrong");try check(request.httpMethod=="GET","quota request mutates");return(200,try data(["totalQuota":["quotaSummary":["usedValue":1,"limitValue":10]]]))}
        _=try await ProviderToolBridge.fetch(provider:"qoder",credential:"session=fixture",scope:nil,region:"cn")
        MockQuotaProtocol.handler={request in try check(request.url?.absoluteString=="https://opencode.ai/zen/go/v1/usage","Go endpoint wrong");try check(request.value(forHTTPHeaderField:"Authorization")=="Bearer fixture","Go key header wrong");return(200,try data(["usage":["rolling":["percent":42]]]))}
        _=try await ProviderToolBridge.fetch(provider:"opencode",credential:"fixture",scope:nil,region:"go")
        var zenCalls=0
        MockQuotaProtocol.handler={request in
            zenCalls += 1
            try check(request.url?.host=="opencode.ai" && request.url?.path=="/_server","Zen route wrong")
            try check(request.value(forHTTPHeaderField:"Cookie")=="auth=fixture","Zen auth cookie wrong")
            if zenCalls==1 {return (200,Data("{\"id\":\"wrk_ABC\"}".utf8))}
            try check(request.url!.query!.contains("wrk_ABC"),"Zen workspace not used")
            return (200,Data(upstreamJSON.utf8))
        }
        let liveZen=try await ProviderToolBridge.fetch(provider:"opencode",credential:"auth=fixture",scope:nil,region:"zen")
        try check(zenCalls==2 && liveZen.quotas.first?.usedPercent==33,"reference Zen transport fixture failed")
        MockQuotaProtocol.handler={_ in (401,Data("sensitive raw rejection body".utf8))}
        do{_=try await ProviderToolBridge.fetch(provider:"factory",credential:"secret-fixture",scope:nil,region:nil);throw MonitorError.message("401 accepted")}catch{try check(!error.localizedDescription.contains("secret-fixture") && !error.localizedDescription.contains("sensitive raw"),"credential/body leaked")}

        // Executable fixture confirms fixed slash query and the constrained v1 fallback.
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent("provider-tool-tests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:dir)}
        let executable=dir.appendingPathComponent("kiro-cli")
        let script="""
        #!/bin/sh
        if [ "$1" != "chat" ] || [ "$2" != "--no-interactive" ]; then exit 33; fi
        if [ "$3" = "/usage" ]; then
          printf 'Plan: KIRO FREE | 1 usage breakdown\\n'
        elif [ "$3" = "--agent-engine=v1" ] && [ "$4" = "--legacy-ui" ] && [ "$5" = "/usage" ]; then
          printf 'Estimated Usage | resets on 2027-02-01 | KIRO FREE\\n██ 50%% (25 of 50 covered)\\n'
        else
          exit 34
        fi
        """
        try script.write(to:executable,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable.path)
        let cli=try await ProviderToolBridge.fetch(provider:"kiro",credential:"",scope:executable.path,region:nil)
        try check(cli.quotas.first?.usedPercent==50,"Kiro command/fallback not read-only fixed usage")
        // Cancelling a pending query must stop promptly and never enter the fallback.
        let sleeper=dir.appendingPathComponent("kiro-sleeper")
        try "#!/bin/sh\nexec sleep 20\n".write(to:sleeper,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:sleeper.path)
        let started=Date()
        let task=Task {try await ProviderToolBridge.fetch(provider:"kiro",credential:"",scope:sleeper.path,region:nil)}
        try await Task.sleep(nanoseconds:100_000_000);task.cancel()
        var cancelled=false;do{_=try await task.value}catch is CancellationError{cancelled=true}
        try check(cancelled && Date().timeIntervalSince(started)<3,"cancelled Kiro query kept running")
        print("Provider tool bridge regressions passed: all six parsers, real request fixtures, currency/credit scales, multi-pool quotas, cookie filtering, redacted errors, fixed Kiro usage CLI fallback and cancellation.")
    }
}
