import Foundation

// Real Models.swift and ProviderIntegrations.swift are compiled with these adapters.
// Only unrelated logging dependencies and network transport are isolated.
enum Log {struct Sink{func error(_ value:String){}};static let store=Sink()}
enum AlertRules {static func attention(_ account:Account,threshold:Double,at:Date)->[String]{[]}}
enum TokenBundle {static let bundle=Bundle.main}
enum Connectors {static var session=URLSession(configuration:.ephemeral);static var schemaError:Error{MonitorError.message("响应结构不完整。")}}
final class CloudQuotaFixtureProtocol:URLProtocol {
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){
        client?.urlProtocol(self,didFailWithError:URLError(.resourceUnavailable))
    }
    override func stopLoading(){}
}

@main struct CloudQuotaBridgeRegression {
    static func require(_ value: @autoclosure()->Bool,_ message:String){if !value(){fatalError(message)}}
    static func rejected(_ label:String,_ body:()throws->Void){do{try body();fatalError(label+" was accepted")}catch{}}
    static func main() async throws {
        let packs:[[String:Any]]=[
            ["entitlement_base_info":["quota":["credits_limit":100]],"usage":["credits_amount":30]],
            ["entitlement_base_info":["quota":["credits_limit":50]],"usage":[:]],
            ["entitlement_base_info":["quota":["feature":true]],"usage":[:]]]
        let trae=try TraeCNBridge.parse(["user_entitlement_pack_list":packs])
        require(trae.quotas[0].usedPercent==20 && trae.creditBalances?.first?.value==120 && trae.balances.isEmpty,"Trae credits not currency")
        rejected("Trae missing usage"){_ = try TraeCNBridge.parse(["user_entitlement_pack_list":[["entitlement_base_info":["quota":["credits_limit":100]]]]])}
        rejected("Trae partial malformed pack"){_ = try TraeCNBridge.parse(["user_entitlement_pack_list":packs+[["usage":["credits_amount":3]]]])}
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
        rejected("cookie header injection"){_ = try ProviderCloudHTTP.cookie("session=test\r\nX-Injected: yes")}
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[CloudQuotaFixtureProtocol.self];Connectors.session=URLSession(configuration:config)
        let cancelled=Task{try Task.checkCancellation();_ = try await TraeCNBridge.fetch(token:"fixture-only")};cancelled.cancel()
        do{try await cancelled.value;fatalError("cancelled query accepted")}catch is CancellationError{}catch{fatalError("cancellation was turned into an authentication failure")}
        print("PASS CloudQuotaBridgeRegression: real snapshot validation; Trae CN and Alibaba Token Plan envelopes, units, monthly windows, credential sanitization, cancellation")
    }
}
