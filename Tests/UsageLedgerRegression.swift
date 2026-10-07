import Foundation
import SQLite3

@main struct UsageLedgerRegression {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "UsageLedgerRegression", code: 1, userInfo: [NSLocalizedDescriptionKey:message]) }
    }
    static func sample(_ id: String, input: Int64 = 100, day: String = "2026-10-01", cost: Double? = 0.1) -> UsageEngineScan {
        let a=UsageAmounts(input:input,output:10,cacheRead:20,cacheWrite:2,reasoning:3,costUSD:cost,messageCount:1)
        return .init(capturedAt:Date(),days:[.init(day:day,client:"codex",model:"model'A",sessionID:id,amounts:a)],sessions:[.init(client:"codex",sessionID:id,model:"model'A",projectKey:"proj'",projectLabel:"=unsafe spreadsheet label",firstActive:Date(timeIntervalSince1970:1_700_000_000),lastActive:Date(timeIntervalSince1970:1_700_000_100),amounts:a,timedTokens:13,timedDurationMS:1000)],clients:["codex"],warnings:[],dayFingerprints:[day:"sig-\(id)-\(input)"])
    }
    static func main() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("usage-ledger-regression-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let first=UsageLedger(directory:root.appendingPathComponent("first"),deviceID:"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",deviceName:"First Mac")
        let scan=sample("s1")
        try await first.ingest(scan); try await first.ingest(scan)
        var dash=try await first.dashboard()
        try check(dash.total.input==100 && dash.days.count==1,"repeat ingest doubled usage")
        try check(dash.total.totalTokens==135,"token buckets not disjoint")
        var page=try await first.sessionPage()
        try check(page.totalCount==1 && page.rows[0].row.projectLabel=="=unsafe spreadsheet label","session metadata changed")
        let fingerprints=try await first.knownDayFingerprints()
        try check(fingerprints["2026-10-01"]=="sig-s1-100","fingerprint absent")
        let metadata=try await first.metadata(); try check(metadata.lastScanAt != nil,"last scan missing")
        // Source s1 disappears, s2 appears on the same date. The old session must remain,
        // and s2 must add to it even though its amount is smaller than s1's old total.
        try await first.ingest(sample("s2",input:25))
        dash=try await first.dashboard(); try check(dash.total.input==125,"deleted source swallowed newer session")
        try await first.ingest(sample("s1",input:50))
        dash=try await first.dashboard(); try check(dash.total.input==125,"partial rescan reduced state")
        try await first.ingest(sample("s1",input:150))
        dash=try await first.dashboard(); try check(dash.total.input==175,"incremental growth lost")
        let empty=try await first.dashboard(fromDay:"2026-10-02",throughDay:"2026-10-03"); try check(empty.total.input==0,"date filter failed")
        let summary=try await first.sessionSummary(); try check(summary.total.input==175 && summary.byProject.count==1,"daily/session totals mixed")
        page=try await first.sessionPage(offset:1,limit:1); try check(page.rows.count==1 && page.totalCount==2,"pagination incorrect")

        let archive=root.appendingPathComponent("first.json")
        try await first.export(to:archive)
        let second=UsageLedger(directory:root.appendingPathComponent("second"),deviceID:"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",deviceName:"Second Mac")
        try await second.ingest(sample("s1",input:40))
        try await second.importFile(archive); try await second.importFile(archive)
        var merged=try await second.dashboard()
        try check(merged.total.input==215 && merged.devices.count==2,"multi-device merge not idempotent")
        try await first.importFile(archive)
        dash=try await first.dashboard(); try check(dash.total.input==175,"own-device export/import inflated totals")
        var legacyPacket = try JSONSerialization.jsonObject(with: Data(contentsOf: archive)) as! [String: Any]
        legacyPacket["format"] = 1
        legacyPacket["devices"] = (legacyPacket["devices"] as! [[String: Any]]).map { device -> [String: Any] in var device=device; device.removeValue(forKey:"cursorEvents"); return device }
        let legacyArchive=root.appendingPathComponent("v1.json"); try JSONSerialization.data(withJSONObject:legacyPacket).write(to:legacyArchive)
        try await first.importFile(legacyArchive)
        dash=try await first.dashboard(); try check(dash.total.input==175,"v1 JSON backward compatibility failed")
        // Imported negative numeric values fail before any row is committed.
        var malformed=try JSONSerialization.jsonObject(with:Data(contentsOf:archive)) as! [String:Any]
        var packets=malformed["devices"] as! [[String:Any]]
        var days=packets[0]["days"] as! [[String:Any]]
        var amounts=days[0]["amounts"] as! [String:Any]; amounts["input"] = -1; days[0]["amounts"]=amounts; packets[0]["days"]=days; malformed["devices"]=packets
        let bad=root.appendingPathComponent("bad.json"); try JSONSerialization.data(withJSONObject:malformed).write(to:bad)
        var rejected=false; do { try await second.importFile(bad) } catch { rejected=true }
        try check(rejected,"invalid import accepted")
        merged=try await second.dashboard(); try check(merged.total.input==215,"invalid import changed history")

        // Simulate an installed v1 database: no Cursor table existed in 3.64.
        let migrationDB = await first.databaseURL
        var legacy: OpaquePointer?; sqlite3_open(migrationDB.path, &legacy)
        try check(sqlite3_exec(legacy,"DROP TABLE cursor_events; PRAGMA user_version=1",nil,nil,nil)==SQLITE_OK,"legacy schema fixture failed")
        sqlite3_close(legacy)
        dash=try await first.dashboard(); try check(dash.total.input==175,"schema v1 migration altered local records")
        let unknown=sample("unknown",input:5,cost:nil); try await first.ingest(unknown)
        dash=try await first.dashboard(); try check(dash.total.costUSD==nil,"unpriced usage became a complete price")
        try await first.ingest(sample("unknown",input:5,cost:0.03))
        dash=try await first.dashboard(); try check(dash.total.costUSD != nil,"new price could not replace unknown estimate")
        var invalidFingerprint=sample("must-rollback",input:999)
        invalidFingerprint.dayFingerprints=["bad-day":"bad"]
        rejected=false; do { try await first.ingest(invalidFingerprint) } catch { rejected=true }
        try check(rejected,"invalid index accepted")
        dash=try await first.dashboard(); try check(dash.total.input==180,"index failure did not roll back usage rows")
        let csv=root.appendingPathComponent("rows.csv"); try await first.exportCSV(to:csv)
        let csvText=try String(contentsOf:csv,encoding:.utf8)
        try check(csvText.contains("model'A") && csvText.contains("First Mac"),"CSV not written")
        let db=await first.databaseURL, snap=root.appendingPathComponent("snapshot.sqlite")
        try UsageLedger.snapshotDatabase(from:db,to:snap); try UsageLedger.verifyDatabase(snap)
        let perms=try FileManager.default.attributesOfItem(atPath:db.path)[.posixPermissions] as? NSNumber
        try check(perms?.intValue==0o600,"database permissions not private")
        // Standalone snapshot must contain an open database's committed WAL rows.
        let wal=root.appendingPathComponent("wal.sqlite"), walCopy=root.appendingPathComponent("wal-copy.sqlite")
        var handle:OpaquePointer?; try check(sqlite3_open(wal.path,&handle)==SQLITE_OK,"fixture open failed")
        defer { sqlite3_close(handle) }
        try check(sqlite3_exec(handle,"PRAGMA journal_mode=WAL; CREATE TABLE t(x); INSERT INTO t VALUES(42)",nil,nil,nil)==SQLITE_OK,"fixture write failed")
        try UsageLedger.snapshotDatabase(from:wal,to:walCopy)
        var read:OpaquePointer?; sqlite3_open_v2(walCopy.path,&read,SQLITE_OPEN_READONLY,nil); defer {sqlite3_close(read)}
        var statement:OpaquePointer?; sqlite3_prepare_v2(read,"SELECT x FROM t",-1,&statement,nil); defer {sqlite3_finalize(statement)}
        try check(sqlite3_step(statement)==SQLITE_ROW && sqlite3_column_int64(statement,0)==42,"snapshot lost committed WAL data")
        print("Usage ledger regression passed: idempotence, source deletion, monotonic merge, device import, validation rollback, pricing, CSV, private file mode, WAL snapshot.")
    }
}
