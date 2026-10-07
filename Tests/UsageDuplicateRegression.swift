import Foundation
import SQLite3

@main struct UsageDuplicateRegression {
    static func check(_ ok: Bool, _ message: String) throws {
        if !ok {throw NSError(domain:"UsageDuplicateRegression",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
    }
    static func varint(_ value: UInt64) -> Data {
        var v=value,d=Data();while v>127 {d.append(UInt8(v&127)|128);v>>=7};d.append(UInt8(v));return d
    }
    static func number(_ field:UInt64,_ value:UInt64)->Data {varint(field<<3)+varint(value)}
    static func blob(_ field:UInt64,_ value:Data)->Data {varint((field<<3)|2)+varint(UInt64(value.count))+value}
    static func main() async throws {
        let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("gq-duplicate-regression-"+UUID().uuidString)
        defer {try? fm.removeItem(at:root)}
        let home=root.appendingPathComponent("home"),config=root.appendingPathComponent("config")
        try fm.createDirectory(at:config.appendingPathComponent("cache"),withIntermediateDirectories:true)
        for name in ["pricing-litellm.json","pricing-openrouter.json","pricing-models-dev.json"] {
            try JSONSerialization.data(withJSONObject:["timestamp":Int(Date().timeIntervalSince1970),"data":[String:String]()]).write(to:config.appendingPathComponent("cache/"+name))
        }
        let engine=URL(fileURLWithPath:CommandLine.arguments[1])
        func write(_ path:String,_ text:String) throws -> URL {
            let p=home.appendingPathComponent(path);try fm.createDirectory(at:p.deletingLastPathComponent(),withIntermediateDirectories:true);try Data(text.utf8).write(to:p);return p
        }
        func scan(_ clients:[String]) async throws -> UsageEngineScan {
            try await UsageEngine.scan(configuration:.init(enabledClientIDs:clients),engineURL:engine,configurationDirectory:config,homeDirectory:home)
        }
        func tokens(_ ledger:UsageLedger) async throws -> Int64 {try await ledger.dashboard().total.totalTokens}
        let status=#"{"timestamp":1785556800,"message":{"type":"StatusUpdate","payload":{"message_id":"same-message","token_usage":{"input_other":100,"output":10}}}}"#+"\n"
        let a=try write(".kimi/sessions/a/session-1/wire.jsonl",status)
        _=try write(".kimi/sessions/b/session-1/wire.jsonl",status)
        let copied=try await scan(["kimi"])
        try check(copied.sessions.reduce(0){$0+$1.amounts.totalTokens}==110,"native Kimi scan counted a copied log twice")
        try check(copied.localUsage!.events.count==1,"copied status did not keep one event identity")
        let ledger=UsageLedger(directory:root.appendingPathComponent("kimi-ledger"),deviceID:"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",deviceName:"Fixture")
        // Original source is absent: archived 55 tokens must survive the repair.
        let old=UsageAmounts(input:50,output:5,messageCount:1)
        var legacy=copied;legacy.localUsage=nil
        legacy.days[0].amounts.input=200;legacy.days[0].amounts.output=20;legacy.days[0].amounts.messageCount=2
        legacy.sessions[0].amounts=legacy.days[0].amounts
        legacy.days.append(.init(day:"2026-08-01",client:"kimi",model:"kimi-for-coding",sessionID:"gone",amounts:old))
        legacy.sessions.append(.init(client:"kimi",sessionID:"gone",model:"kimi-for-coding",firstActive:Date(timeIntervalSince1970:1785556800),lastActive:Date(timeIntervalSince1970:1785556800),amounts:old,timedTokens:0,timedDurationMS:0))
        try await ledger.ingest(legacy);try check(try await tokens(ledger)==275,"legacy fixture wrong")
        let legacyFile=root.appendingPathComponent("legacy.json");try await ledger.export(to:legacyFile)
        try await ledger.ingest(copied);try await ledger.ingest(copied)
        try check(try await tokens(ledger)==165,"verified duplicate not corrected or missing-source history lost")
        _=try write(".kimi/sessions/c/session-2/wire.jsonl",status)
        let distinct=try await scan(["kimi"]);try await ledger.ingest(distinct)
        try check(try await tokens(ledger)==275,"equal usage from a distinct session was falsely deduplicated")
        try await ledger.importFile(legacyFile)
        try check(try await tokens(ledger)==275,"old aggregate import re-added repaired copies")
        try fm.removeItem(at:home.appendingPathComponent(".kimi"))
        try await ledger.ingest(scan(["kimi"]))
        try check(try await tokens(ledger)==275,"source removal erased event history")
        let newFile=root.appendingPathComponent("v3.json");try await ledger.export(to:newFile)
        let restored=UsageLedger(directory:root.appendingPathComponent("restored"),deviceID:"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",deviceName:"Other")
        try await restored.importFile(newFile);try await restored.importFile(newFile)
        try check(try await tokens(restored)==275,"v3 event/baseline/coverage round trip inflated history")
        let noID=status.replacingOccurrences(of:#""message_id":"same-message","# ,with:"")
        _=try write(".kimi/sessions/a/no-id/wire.jsonl",noID+noID)
        _=try write(".kimi/sessions/b/no-id/wire.jsonl",noID+noID)
        let missing=try await scan(["kimi"])
        try check(missing.sessions.reduce(0){$0+$1.amounts.totalTokens}==220 && missing.localUsage!.events.count==2,"missing IDs collapsed independent positions or copied logs were doubled")
        let code=#"{"type":"usage.record","usageScope":"turn","time":1785556800000,"model":"kimi-for-coding","usage":{"inputOther":100,"output":10}}"#+"\n"
        _=try write(".kimi-code/sessions/a/code-1/agents/main/wire.jsonl",code+code)
        _=try write(".kimi-code/sessions/b/code-1/agents/main/wire.jsonl",code+code)
        let codeScan=try await scan(["kimi"])
        try check(codeScan.sessions.reduce(0){$0+$1.amounts.totalTokens}==440,"Kimi Code copied records were duplicated or independent equal calls lost")
        // Antigravity extension -> desktop cache: provider response ID survives
        // the change in its source-specific session identifier.
        let dbURL=home.appendingPathComponent(".gemini/antigravity/conversations/extension-session.db")
        try fm.createDirectory(at:dbURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        let usage=number(2,100)+number(9,10)+blob(11,Data("shared-response".utf8))
        let chat=blob(4,usage)+blob(19,Data("gemini-3-flash".utf8))+blob(9,blob(4,number(1,1785556800)))
        let payload=blob(1,chat)
        var db:OpaquePointer?;try check(sqlite3_open(dbURL.path,&db)==SQLITE_OK,"fixture DB open failed")
        try check(sqlite3_exec(db,"CREATE TABLE gen_metadata(idx INTEGER,data BLOB)",nil,nil,nil)==SQLITE_OK,"fixture table failed")
        var stmt:OpaquePointer?;sqlite3_prepare_v2(db,"INSERT INTO gen_metadata VALUES(1,?)",-1,&stmt,nil)
        _=payload.withUnsafeBytes {sqlite3_bind_blob(stmt,1,$0.baseAddress,Int32(payload.count),unsafeBitCast(-1,to:sqlite3_destructor_type.self))}
        try check(sqlite3_step(stmt)==SQLITE_DONE,"fixture protobuf insert failed");sqlite3_finalize(stmt);sqlite3_close(db)
        let ag=UsageLedger(directory:root.appendingPathComponent("ag-ledger"),deviceID:"cccccccc-cccc-cccc-cccc-cccccccccccc",deviceName:"AG")
        let extensionScan=try await scan(["antigravity"])
        try check(extensionScan.localUsage?.events.count==1,"extension record absent")
        var oldExtension=extensionScan;oldExtension.localUsage=nil;try await ag.ingest(oldExtension)
        try await ag.ingest(extensionScan)
        let cache=#"{"type":"usage","sessionId":"desktop-session","modelId":"gemini-3-flash","timestamp":1785556800000,"input":100,"output":10,"cacheRead":0,"cacheWrite":0,"reasoning":0,"responseId":"shared-response"}"#+"\n"
        _=try write(".config/tokscale/antigravity-cache/sessions/cache.jsonl",cache)
        let desktopScan=try await scan(["antigravity"])
        try await ag.ingest(desktopScan);try await ag.ingest(desktopScan)
        try check(try await tokens(ag)==110,"Antigravity source transition double-counted response")
        let page=try await ag.sessionPage();try check(page.totalCount==1,"source transition duplicated displayed session")
        try fm.removeItem(at:dbURL);try await ag.ingest(scan(["antigravity"]))
        try check(try await tokens(ag)==110,"removing old surface changed response total")
        let next=cache.replacingOccurrences(of:"shared-response",with:"another-response")
        _=try write(".config/tokscale/antigravity-cache/sessions/cache.jsonl",next)
        try await ag.ingest(scan(["antigravity"]))
        try check(try await tokens(ag)==220,"new response with equal values was swallowed")
        let agJSON=root.appendingPathComponent("ag.json");try await ag.export(to:agJSON);try await ag.importFile(agJSON)
        try check(try await tokens(ag)==220,"Antigravity own-device export duplicated events")
        // Invalid identities fail atomically.
        var invalid=desktopScan;invalid.localUsage!.events[0].eventID="bad"
        var rejected=false;do {try await ag.ingest(invalid)} catch {rejected=true}
        let afterFailure=try await tokens(ag)
        try check(rejected && afterFailure==220,"malformed event was committed")
        _=a
        print("Duplicate regression passed: actual patched CLI; copied Kimi/Kimi Code with and without IDs; distinct equal-valued calls; old duplicate correction; missing-source history; Antigravity source transitions; repeat scans; v3 round trip; old import; malformed rollback.")
    }
}
