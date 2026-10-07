import Foundation
import SQLite3

// Minimal account fixtures isolate DataTransfer's file/SQLite transaction behavior.
// Real account validation remains covered by the app's connector/backup regression suite.
enum TokenBundle { static let defaults=UserDefaults(suiteName:"UsageTransferRegression")! }
enum AppInfo { static let version="3.64" }
enum MonitorError: LocalizedError {case message(String);var errorDescription:String? {if case .message(let value)=self{return value};return nil}}
enum JSONCoding {static var encoder:JSONEncoder {let e=JSONEncoder();e.dateEncodingStrategy = .iso8601;return e};static var decoder:JSONDecoder{let d=JSONDecoder();d.dateDecodingStrategy = .iso8601;return d}}
enum Connection:String,Codable {case file,other}
struct Account:Codable {var id=UUID();var connection=Connection.other;var filePath=""}
struct Library:Codable {var accounts:[Account]=[];var autoRefresh=true}
enum MonitorStore {static func validate(_ library:Library)throws{}}

@main struct UsageTransferRegression {
    static func check(_ value:@autoclosure()->Bool,_ message:String)throws{if !value(){throw MonitorError.message(message)}}
    static func scan(_ id:String,_ input:Int64)->UsageEngineScan {
        let a=UsageAmounts(input:input,output:5,costUSD:0.01,messageCount:1)
        return .init(capturedAt:Date(),days:[.init(day:"2026-10-01",client:"codex",model:"test",sessionID:id,amounts:a)],sessions:[.init(client:"codex",sessionID:id,model:"test",firstActive:nil,lastActive:nil,amounts:a,timedTokens:0,timedDurationMS:0)],clients:["codex"],warnings:[])
    }
    static func main()async throws {
        let fm=FileManager.default, root=fm.temporaryDirectory.appendingPathComponent("usage-transfer-regression-"+UUID().uuidString)
        let live=root.appendingPathComponent("Token"), backup=root.appendingPathComponent("backup.gaociyuan")
        try fm.createDirectory(at:live,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
        let library=Library();try JSONCoding.encoder.encode(library).write(to:live.appendingPathComponent("library.json"))
        let attachment=Data("PDF fixture bytes: unchanged by backup".utf8)
        try attachment.write(to:live.appendingPathComponent("paper.pdf"))
        let ledger=UsageLedger(directory:live,deviceID:"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",deviceName:"Test")
        try await ledger.ingest(scan("before",100))
        let cursorEvent = try CursorUsageBridge.decode(["eventId":"backup-event", "conversationId":"backup-conversation", "timestamp":"2026-08-01T04:00:00Z", "model":"auto", "tokenUsage":["inputTokens":42,"totalCents":1]], accountKey: CursorUsageBridge.digest("backup-fixture"))
        try await ledger.ingest(.init(capturedAt:.now,days:[],sessions:[],clients:["cursor"],warnings:[],cursorEvents:[cursorEvent]))
        var oldLocal=scan("local-before",40)
        oldLocal.days[0].client="kimi";oldLocal.sessions[0].client="kimi";oldLocal.clients=["kimi"]
        try await ledger.ingest(oldLocal)
        let localAmounts=UsageAmounts(input:7,output:5,costUSD:0.01,messageCount:1)
        let event=LocalUsageEvent(eventID:CursorUsageBridge.digest("local-backup-event"),client:"kimi",sessionID:"local-before",model:"test",timestamp:Date(timeIntervalSince1970:1790812800),durationMS:0,amounts:localAmounts)
        let batch=LocalUsageBatch(clients:["kimi"],events:[event],coverageDays:[.init(day:"2026-10-01",client:"kimi",model:"test",sessionID:"local-before",amounts:localAmounts)],coverageSessions:[.init(client:"kimi",sessionID:"local-before",model:"test",firstActive:nil,lastActive:nil,amounts:localAmounts,timedTokens:0,timedDurationMS:0)])
        let localScan=UsageEngineScan(capturedAt:.now,days:[],sessions:[],clients:["kimi"],warnings:[],localUsage:batch)
        try await ledger.ingest(localScan)
        // Keep an extra database in WAL mode open throughout export.
        let wal=live.appendingPathComponent("wal.sqlite");var handle:OpaquePointer?
        sqlite3_open(wal.path,&handle);defer{sqlite3_close(handle)}
        try check(sqlite3_exec(handle,"PRAGMA journal_mode=WAL;CREATE TABLE t(x);INSERT INTO t VALUES(42)",nil,nil,nil)==SQLITE_OK,"WAL setup failed")
        let prefs=Preferences(appearance:"system",language:"zh-Hans",codexPath:"")
        try DataTransfer.export(to:backup,root:live,library:library,preferences:prefs)
        let files=try DataTransfer.files(backup.appendingPathComponent("Data"))
        try check(!files.keys.contains(where:{$0.hasSuffix("-wal")||$0.hasSuffix("-shm")}),"unsafe WAL sidecars copied")
        var read:OpaquePointer?;sqlite3_open_v2(backup.appendingPathComponent("Data/wal.sqlite").path,&read,SQLITE_OPEN_READONLY,nil);defer{sqlite3_close(read)}
        var stmt:OpaquePointer?;sqlite3_prepare_v2(read,"SELECT x FROM t",-1,&stmt,nil);defer{sqlite3_finalize(stmt)}
        try check(sqlite3_step(stmt)==SQLITE_ROW && sqlite3_column_int64(stmt,0)==42,"backup lost committed WAL data")
        sqlite3_close(handle);handle=nil
        try await ledger.ingest(scan("after",50))
        let epoch=UsageLedger.restoreGeneration()
        let prepared=try DataTransfer.prepare(backup)
        _=try DataTransfer.restore(prepared,to:live)
        var staleRejected=false
        do {try await ledger.ingest(scan("stale-scan",999),expectedGeneration:epoch)} catch {staleRejected=true}
        try check(staleRejected,"pre-restore scan mutated restored data")
        let restored=try await ledger.dashboard();try check(restored.total.input==182,"same ledger object still reads replaced database")
        try await ledger.ingest(.init(capturedAt:.now,days:[],sessions:[],clients:["cursor"],warnings:[],cursorEvents:[cursorEvent]))
        let afterCursorRescan = try await ledger.dashboard()
        try check(afterCursorRescan.total.input == 182, "restored Cursor event identity lost or duplicated")
        try await ledger.ingest(localScan)
        let afterLocalRescan=try await ledger.dashboard()
        try check(afterLocalRescan.total.input==182,"restored local event/baseline/coverage identities were lost")
        let restoredAttachment=try Data(contentsOf:live.appendingPathComponent("paper.pdf"));try check(restoredAttachment==attachment,"attachment changed")
        let retained=try fm.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("GaoCiYuan-UserBackup-")}
        try check(retained.count==1,"pre-restore original data not retained")
        let beforeRestore=UsageLedger(directory:retained[0],deviceID:"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",deviceName:"Test")
        let old=try await beforeRestore.dashboard();try check(old.total.input==232,"original database lost")
        try Data("tampered".utf8).write(to:backup.appendingPathComponent("Data/paper.pdf"))
        var rejected=false;do{_=try DataTransfer.prepare(backup)}catch{rejected=true};try check(rejected,"tampered attachment accepted")
        let unchanged=try await ledger.dashboard();try check(unchanged.total.input==182,"failed prepare mutated history")
        print("Token transfer regression passed: open WAL snapshot, all attachments + Cursor/local events, baseline and coverage, same-object restore reload, stale scan rejection, retained original data, tamper rejection.")
    }
}
