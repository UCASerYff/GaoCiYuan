import Foundation
import SQLite3

struct UsageLedgerDay: Identifiable, Sendable {
    var deviceID: String
    var deviceName: String
    var row: UsageDayRow
    var id: String { [deviceID, row.day, row.client, row.model].joined(separator: "|") }
    var day: String { row.day }
    var client: String { row.client }
    var model: String { row.model }
    var amounts: UsageAmounts { row.amounts }
}
struct UsageLedgerSession: Identifiable, Sendable {
    var deviceID: String
    var deviceName: String
    var row: UsageSessionRow
    var id: String { [deviceID, row.client, row.sessionID, row.model].joined(separator: "|") }
}
struct UsageLedgerBreakdown: Identifiable, Sendable {
    var key: String
    var label: String
    var amounts: UsageAmounts
    var id: String { key }
}
struct UsageLedgerDevice: Identifiable, Sendable {
    var id: String
    var name: String
    var lastImportedAt: Date
}
struct UsageLedgerDashboard: Sendable {
    var days: [UsageLedgerDay]
    var total: UsageAmounts
    var byClient: [UsageLedgerBreakdown]
    var byModel: [UsageLedgerBreakdown]
    var devices: [UsageLedgerDevice]
}
struct UsageLedgerSessionPage: Sendable { var rows: [UsageLedgerSession]; var totalCount: Int }
struct UsageLedgerSessionSummary: Sendable {
    var total: UsageAmounts
    var byProject: [UsageLedgerBreakdown]
    var byDevice: [UsageLedgerBreakdown]
}
extension UsageLedgerDashboard {
    static var empty: Self { .init(days: [], total: .init(input:0,output:0,cacheRead:0,cacheWrite:0,reasoning:0,costUSD:0,messageCount:0), byClient: [], byModel: [], devices: []) }
}
extension UsageLedgerSessionPage { static var empty: Self { .init(rows: [], totalCount: 0) } }
extension UsageLedgerSessionSummary {
    static var empty: Self { .init(total: .init(input:0,output:0,cacheRead:0,cacheWrite:0,reasoning:0,costUSD:0,messageCount:0), byProject: [], byDevice: []) }
}
struct UsageLedgerMetadata: Sendable { var deviceID: String; var deviceName: String; var lastScanAt: Date? }
struct UsageLedgerImportResult: Sendable { var deviceCount: Int; var dayCount: Int; var sessionCount: Int }

enum UsageLedgerError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

/// Numeric usage only: this archive never contains prompts, credentials, or transcript bodies.
private struct UsageLedgerArchive: Codable {
    var format: Int = 1
    var exportedAt: Date
    var devices: [Device]
    struct Device: Codable {
        var id: String
        var name: String
        var days: [UsageDayRow]
        var sessions: [UsageSessionRow]
        var cursorEvents: [CursorUsageEvent]? = nil
        var localUsage: LocalUsageBatch? = nil
    }
}

/// Full usage history is independent of the 300 quota snapshots. Each row belongs to one
/// session, so removing old source logs cannot make new sessions disappear under an old
/// aggregate high-water mark. Within a session, token buckets are monotonic observations;
/// source truncation or a partial rescan never reduces an already observed total.
actor UsageLedger {
    static let didRestoreNotification = Notification.Name("GaoSeries.token.usage.didRestore")
    private static let gate = NSRecursiveLock()
    private static var restoreEpoch: UInt64 = 0
    private let directory: URL
    let deviceID: String
    let deviceName: String
    var databaseURL: URL { directory.appendingPathComponent("usage-ledger.sqlite") }
    private static let columns = "input,output,cache_read,cache_write,reasoning,messages,cost"
    private static let summed = "COALESCE(SUM(input),0),COALESCE(SUM(output),0),COALESCE(SUM(cache_read),0),COALESCE(SUM(cache_write),0),COALESCE(SUM(reasoning),0),COALESCE(SUM(messages),0),CASE WHEN COUNT(*)=COUNT(cost) THEN COALESCE(SUM(cost),0) ELSE NULL END"

    init(directory: URL, deviceID: String? = nil, deviceName: String? = nil) {
        self.directory = directory
        self.deviceID = deviceID ?? Self.localDeviceID()
        self.deviceName = deviceName ?? Host.current().localizedName ?? "这台 Mac"
    }
    nonisolated static func localDeviceID() -> String {
        if ProcessInfo.processInfo.environment["GAOQINIANSAN_INTEGRATION_TEST"] == "1" {return "00000000-0000-4000-8000-000000000001"}
        return withExclusiveAccess {
            let defaults = UserDefaults.standard, key = "gqns.token.usage.localDeviceUUID"
            if let value = defaults.string(forKey: key), UUID(uuidString: value) != nil { return value }
            let value = UUID().uuidString.lowercased(); defaults.set(value, forKey: key); return value
        }
    }
    /// DataTransfer shares this gate for a complete restore; no SQLite handle survives a call.
    nonisolated static func withExclusiveAccess<T>(_ body: () throws -> T) rethrows -> T {
        gate.lock(); defer { gate.unlock() }; return try body()
    }

    nonisolated static func restoreGeneration() -> UInt64 {withExclusiveAccess {restoreEpoch}}
    nonisolated static func invalidateScans() {withExclusiveAccess {restoreEpoch &+= 1}}

    func ingest(_ scan: UsageEngineScan, expectedGeneration: UInt64? = nil) throws {
        try Self.validateDevice(id: deviceID, name: deviceName)
        guard scan.capturedAt.timeIntervalSince1970.isFinite, scan.capturedAt.timeIntervalSince1970 >= 0, scan.capturedAt <= Date().addingTimeInterval(300) else { throw UsageLedgerError.invalid("采集时间无效。") }
        try Self.validate(days: scan.days, sessions: scan.sessions)
        try Self.validateCursorEvents(scan.cursorEvents ?? [])
        if let batch = scan.localUsage {try Self.validateLocalUsage(batch)}
        try withDB { db in
            guard expectedGeneration.map({$0 == Self.restoreEpoch}) ?? true else {throw UsageLedgerError.invalid("数据已从备份恢复，请重新扫描本机用量。")}
            try Self.transaction(db) {
                try Self.writeDevice(db, id: deviceID, name: deviceName, at: scan.capturedAt)
                let eventClients = Set(scan.localUsage?.clients ?? [])
                try Self.writeRows(db, deviceID: deviceID, days: scan.days.filter {!eventClients.contains($0.client)}, sessions: scan.sessions.filter {!eventClients.contains($0.client)})
                if let batch = scan.localUsage {try Self.writeLocalUsage(db, deviceID:deviceID, batch:batch)}
                try Self.writeCursorEvents(db, events: scan.cursorEvents ?? [], at: scan.capturedAt)
                try Self.validateDatabaseTotals(db)
                try Self.query(db, "INSERT INTO metadata VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text("lastScanAt." + deviceID), .text(String(scan.capturedAt.timeIntervalSince1970))])
                for (day, signature) in scan.dayFingerprints {
                    try Self.validateDay(day)
                    guard signature.utf8.count <= 256 else { throw UsageLedgerError.invalid("扫描索引无效。") }
                    try Self.query(db, "INSERT INTO metadata VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text("fingerprint." + deviceID + "." + day), .text(signature)])
                }
            }
        }
    }

    func knownDayFingerprints() throws -> [String: String] {
        try withDB { db in
            var result: [String:String] = [:]
            let prefix = "fingerprint." + deviceID + "."
            try Self.query(db, "SELECT key,value FROM metadata WHERE key LIKE ?", [.text(prefix + "%")]) { result[String(Self.string($0,0).dropFirst(prefix.count))] = Self.string($0,1) }
            return result
        }
    }
    func metadata() throws -> UsageLedgerMetadata {
        try withDB { db in
            var scanned: Date?
            try Self.query(db, "SELECT value FROM metadata WHERE key=?", [.text("lastScanAt." + deviceID)]) { if let value = Double(Self.string($0,0)), value.isFinite { scanned = Date(timeIntervalSince1970:value) } }
            return .init(deviceID:deviceID,deviceName:deviceName,lastScanAt:scanned)
        }
    }

    func dashboard(fromDay: String? = nil, throughDay: String? = nil, client: String? = nil, deviceID: String? = nil) throws -> UsageLedgerDashboard {
        if let fromDay { try Self.validateDay(fromDay) }; if let throughDay { try Self.validateDay(throughDay) }
        if let fromDay, let throughDay, fromDay > throughDay { throw UsageLedgerError.invalid("统计开始日期不能晚于结束日期。") }
        return try withDB { db in
            let (clause, values) = Self.filter(fromDay: fromDay, throughDay: throughDay, client: client, device: deviceID)
            var days: [UsageLedgerDay] = []
            try Self.query(db, "SELECT d.device_id,v.name,d.day,d.client,d.model,\(Self.summed) FROM days d JOIN devices v ON v.id=d.device_id \(clause) GROUP BY d.device_id,d.day,d.client,d.model ORDER BY d.day,d.client,d.model", values) { stmt in
                days.append(.init(deviceID: Self.string(stmt, 0), deviceName: Self.string(stmt, 1), row: .init(day: Self.string(stmt, 2), client: Self.string(stmt, 3), model: Self.string(stmt, 4), sessionID: "", amounts: Self.amounts(stmt, 5))))
            }
            let total = try Self.aggregate(db, table: "days", clause: clause, values: values)
            let byClient = try Self.groups(db, table: "days", key: "client", clause: clause, values: values)
            let byModel = try Self.groups(db, table: "days", key: "model", clause: clause, values: values)
            return .init(days: days, total: total, byClient: byClient, byModel: byModel, devices: try Self.devices(db))
        }
    }

    func sessionPage(offset: Int = 0, limit: Int = 50, client: String? = nil, deviceID: String? = nil, project: String? = nil, model: String? = nil) throws -> UsageLedgerSessionPage {
        guard offset >= 0, (1...200).contains(limit) else { throw UsageLedgerError.invalid("会话分页参数无效。") }
        return try withDB { db in
            let (clause, values) = Self.filter(client: client, device: deviceID, project: project, model: model)
            var count = 0, rows: [UsageLedgerSession] = []
            try Self.query(db, "SELECT COUNT(*) FROM sessions d \(clause)", values) { count = Int(sqlite3_column_int64($0, 0)) }
            try Self.query(db, "SELECT d.device_id,v.name,d.client,d.session_id,d.model,d.project_key,d.project_label,d.first_active,d.last_active,d.timed_tokens,d.duration_ms,\(Self.columns) FROM sessions d JOIN devices v ON v.id=d.device_id \(clause) ORDER BY d.last_active DESC,d.device_id,d.client,d.session_id,d.model LIMIT ? OFFSET ?", values + [.integer(Int64(limit)), .integer(Int64(offset))]) { stmt in
                rows.append(.init(deviceID: Self.string(stmt, 0), deviceName: Self.string(stmt, 1), row: Self.session(stmt, start: 2)))
            }
            return .init(rows: rows, totalCount: count)
        }
    }

    func sessionSummary(client: String? = nil, deviceID: String? = nil) throws -> UsageLedgerSessionSummary {
        try withDB { db in
            let (clause, values) = Self.filter(client: client, device: deviceID)
            let devices = try Self.devices(db)
            let names = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.name) })
            var byDevice = try Self.groups(db, table: "sessions", key: "device_id", clause: clause, values: values)
            for i in byDevice.indices { byDevice[i].label = names[byDevice[i].key] ?? byDevice[i].key }
            var byProject = try Self.groups(db, table: "sessions", key: "COALESCE(project_key,'')", label: "COALESCE(MAX(project_label),'未标记项目')", clause: clause, values: values)
            for i in byProject.indices where byProject[i].label.isEmpty { byProject[i].label = "未标记项目" }
            return .init(total: try Self.aggregate(db, table: "sessions", clause: clause, values: values), byProject: byProject, byDevice: byDevice)
        }
    }

    /// Encode one persisted row at a time, so exporting a large history does not load the
    /// complete archive or all session records into memory. The transfer envelope is capped;
    /// the application's complete backup remains available for larger historical databases.
    func export(to url: URL) throws {
        try validateExportDestination(url)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".usage-export-" + UUID().uuidString)
        let fm = FileManager.default
        guard fm.createFile(atPath:temp.path,contents:nil,attributes:[.posixPermissions:0o600]) else { throw UsageLedgerError.invalid("无法创建用量导出文件。") }
        defer { try? fm.removeItem(at:temp) }
        let handle = try FileHandle(forWritingTo:temp); defer { try? handle.close() }
        let encoder=JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        var count=0, records=0
        func write(_ data:Data) throws {
            guard count <= 64 * 1_024 * 1_024 - data.count else { throw UsageLedgerError.invalid("用量 JSON 超过 64 MB，请用完整应用备份迁移全部历史。") }
            try handle.write(contentsOf:data); count += data.count
        }
        func literal(_ value:String) throws { try write(Data(value.utf8)) }
        func record<T:Encodable>(_ value:T) throws {
            records += 1
            guard records <= 200_000 else {throw UsageLedgerError.invalid("用量 JSON 超过 20 万条，请用完整应用备份迁移全部历史。")}
            try write(encoder.encode(value))
        }
        try literal("{\"format\":3,\"exportedAt\":")
        try write(encoder.encode(Date()))
        try literal(",\"devices\":[")
        try withDB { db in
            let devices=try Self.devices(db)
            guard devices.count <= 64 else {throw UsageLedgerError.invalid("设备数量超出单个用量包上限，请使用完整应用备份。")}
            for (index,device) in devices.enumerated() {
                if index > 0 {try literal(",")}
                try literal("{\"id\":"); try write(encoder.encode(device.id)); try literal(",\"name\":"); try write(encoder.encode(device.name)); try literal(",\"days\":[")
                var first=true
                try Self.query(db,"SELECT day,client,model,session_id,\(Self.columns) FROM days WHERE device_id=? ORDER BY day,client,session_id,model",[.text(device.id)]) {stmt in
                    if !first {try literal(",")}; first=false
                    try record(UsageDayRow(day:Self.string(stmt,0),client:Self.string(stmt,1),model:Self.string(stmt,2),sessionID:Self.string(stmt,3),amounts:Self.amounts(stmt,4)))
                }
                try literal("],\"sessions\":["); first=true
                try Self.query(db,"SELECT client,session_id,model,project_key,project_label,first_active,last_active,timed_tokens,duration_ms,\(Self.columns) FROM sessions WHERE device_id=? ORDER BY client,session_id,model",[.text(device.id)]) {stmt in
                    if !first {try literal(",")}; first=false; try record(Self.session(stmt,start:0))
                }
                try literal("],\"cursorEvents\":["); first=true
                try Self.query(db, "SELECT account_key,event_id,conversation_id,model,timestamp,\(Self.columns) FROM cursor_events WHERE source_id=? ORDER BY event_id", [.text(device.id)]) { stmt in
                    if !first { try literal(",") }; first=false
                    try record(Self.cursorEvent(stmt))
                }
                try literal("]")
                if let local = try Self.readLocalUsage(db, deviceID:device.id) {
                    records += local.events.count + local.coverageDays.count + local.coverageSessions.count + (local.baselineDays?.count ?? 0) + (local.baselineSessions?.count ?? 0)
                    guard records <= 200_000 else {throw UsageLedgerError.invalid("用量 JSON 超过 20 万条，请使用完整应用备份。")}
                    try literal(",\"localUsage\":"); try write(encoder.encode(local))
                }
                try literal("}")
            }
        }
        try literal("]}"); try handle.synchronize(); try handle.close()
        if fm.fileExists(atPath:url.path) {_ = try fm.replaceItemAt(url,withItemAt:temp)} else {try fm.moveItem(at:temp,to:url)}
    }

    /// Row-wise CSV export avoids constructing the complete archive in memory.
    func exportCSV(to url: URL, fromDay: String? = nil, throughDay: String? = nil, client: String? = nil, deviceID: String? = nil) throws {
        try validateExportDestination(url)
        if let fromDay { try Self.validateDay(fromDay) }; if let throughDay { try Self.validateDay(throughDay) }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".usage-export-" + UUID().uuidString)
        let fm = FileManager.default
        guard fm.createFile(atPath:temp.path,contents:nil,attributes:[.posixPermissions:0o600]) else { throw UsageLedgerError.invalid("无法创建用量导出文件。") }
        defer { try? fm.removeItem(at:temp) }
        let handle = try FileHandle(forWritingTo:temp); defer { try? handle.close() }
        func write(_ fields: [String]) throws {
            let escaped = fields.map { raw -> String in
                let text = ["=","+","-","@"].contains(raw.first.map(String.init) ?? "") ? "'" + raw : raw
                return "\"" + text.replacingOccurrences(of:"\"",with:"\"\"") + "\""
            }.joined(separator:",") + "\r\n"
            try handle.write(contentsOf:Data(escaped.utf8))
        }
        try handle.write(contentsOf:Data([0xef,0xbb,0xbf]))
        try write(["日期","设备标识","设备","客户端","模型","会话","输入 Token","输出 Token","缓存读取","缓存写入","推理 Token","消息数","估算美元费用"])
        try withDB { db in
            let (clause, values) = Self.filter(fromDay:fromDay,throughDay:throughDay,client:client,device:deviceID)
            try Self.query(db,"SELECT day,d.device_id,v.name,client,model,session_id,\(Self.columns) FROM days d JOIN devices v ON v.id=d.device_id \(clause) ORDER BY day,d.device_id,client,session_id,model",values) { stmt in
                var fields = (Int32(0)...Int32(5)).map { Self.string(stmt,$0) }
                fields += (Int32(6)...Int32(11)).map { String(sqlite3_column_int64(stmt,$0)) }
                fields.append(sqlite3_column_type(stmt,12) == SQLITE_NULL ? "" : String(sqlite3_column_double(stmt,12)))
                try write(fields)
            }
        }
        try handle.synchronize(); try handle.close()
        if fm.fileExists(atPath:url.path) { _ = try fm.replaceItemAt(url,withItemAt:temp) } else { try fm.moveItem(at:temp,to:url) }
    }

    @discardableResult func importFile(_ url: URL) throws -> UsageLedgerImportResult {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= 64 * 1_024 * 1_024 else { throw UsageLedgerError.invalid("请选择不超过 64 MB 的用量 JSON 普通文件。") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let handle=try FileHandle(forReadingFrom:url); defer {try? handle.close()}
        let data=try handle.read(upToCount:64 * 1_024 * 1_024 + 1) ?? Data()
        guard data.count <= 64 * 1_024 * 1_024 else {throw UsageLedgerError.invalid("用量 JSON 超过 64 MB。")}
        let archive = try decoder.decode(UsageLedgerArchive.self, from:data)
        guard [1,2,3].contains(archive.format), archive.devices.count <= 64, Set(archive.devices.map(\.id)).count == archive.devices.count,
              archive.devices.reduce(0, { $0 + $1.days.count + $1.sessions.count + ($1.cursorEvents?.count ?? 0) + ($1.localUsage?.events.count ?? 0) + ($1.localUsage?.coverageDays.count ?? 0) + ($1.localUsage?.coverageSessions.count ?? 0) + ($1.localUsage?.baselineDays?.count ?? 0) + ($1.localUsage?.baselineSessions?.count ?? 0) }) <= 200_000 else { throw UsageLedgerError.invalid("用量包格式、设备或记录数量无效。") }
        for device in archive.devices {
            try Self.validateDevice(id: device.id, name: device.name)
            try Self.validate(days: device.days, sessions: device.sessions)
            try Self.validateCursorEvents(device.cursorEvents ?? [])
            if let batch = device.localUsage {try Self.validateLocalUsage(batch)}
            guard (device.cursorEvents ?? []).allSatisfy({ $0.sourceID == device.id }),
                  !device.days.contains(where: { $0.client == "cursor" }) || !(device.cursorEvents ?? []).isEmpty,
                  !device.sessions.contains(where: { $0.client == "cursor" }) || !(device.cursorEvents ?? []).isEmpty else {
                throw UsageLedgerError.invalid("Cursor 云账户缺少可验证的事件身份，未合并此用量包。")
            }
        }
        // Own-device round trips are safe: the same high-water keys are idempotent and can
        // only restore observations; imported samples never trigger game rewards.
        try withDB { db in
            try Self.transaction(db) {
                for device in archive.devices {
                    try Self.writeDevice(db, id: device.id, name: device.id == deviceID ? deviceName : device.name, at: Date())
                    // Cloud aggregates are rebuilt from the union of immutable
                    // events, not merged as device totals. Repeated exports from
                    // two Macs therefore cannot duplicate the same Cursor usage.
                    var local = device.localUsage
                    if local == nil, var existing = try Self.readLocalUsage(db, deviceID:device.id) {
                        // A legacy export restores original observations into the
                        // baseline; it cannot re-add already identified events.
                        existing.baselineDays=device.days.filter {existing.clients.contains($0.client)}
                        existing.baselineSessions=device.sessions.filter {existing.clients.contains($0.client)}
                        local=existing
                    }
                    let managed = Set(local?.clients ?? [])
                    try Self.writeRows(db, deviceID: device.id, days: device.days.filter { $0.client != "cursor" && !managed.contains($0.client) }, sessions: device.sessions.filter { $0.client != "cursor" && !managed.contains($0.client) })
                    if let local {try Self.writeLocalUsage(db, deviceID:device.id, batch:local, importing:true)}
                    try Self.writeCursorEvents(db, events: device.cursorEvents ?? [], at: Date(), importing: true)
                }
                try Self.validateDatabaseTotals(db)
            }
        }
        return .init(deviceCount: archive.devices.count, dayCount: archive.devices.reduce(0) { $0 + $1.days.count }, sessionCount: archive.devices.reduce(0) { $0 + $1.sessions.count })
    }

    private func validateExportDestination(_ url: URL) throws {
        let source=directory.standardizedFileURL.resolvingSymlinksInPath().path
        let target=url.standardizedFileURL.resolvingSymlinksInPath().path
        guard target != source, !target.hasPrefix(source + "/") else {throw UsageLedgerError.invalid("请将用量导出保存在应用数据目录之外。")}
    }

    // MARK: SQL. Each operation opens/closes within the transfer gate; there is no stale DB
    // handle after an app/module backup restore replaces the directory.
    private func withDB<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try Self.withExclusiveAccess {
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = databaseURL
            if fm.fileExists(atPath: url.path), (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true { throw UsageLedgerError.invalid("用量数据库不能是符号链接。") }
            var handle: OpaquePointer?
            guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db = handle else { if let handle { sqlite3_close(handle) }; throw UsageLedgerError.invalid("无法打开用量数据库。") }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 5_000)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try Self.exec(db, "PRAGMA foreign_keys=ON; PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;")
            var version = 0
            try Self.query(db, "PRAGMA user_version") { version = Int(sqlite3_column_int64($0, 0)) }
            guard (0...3).contains(version) else { throw UsageLedgerError.invalid("用量数据库来自较新版本，已保留原文件。") }
            if version == 0 {
                try Self.transaction(db) {
                    try Self.exec(db, """
                    CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
                    CREATE TABLE devices(id TEXT PRIMARY KEY,name TEXT NOT NULL,updated REAL NOT NULL);
                    CREATE TABLE days(device_id TEXT NOT NULL REFERENCES devices(id),day TEXT NOT NULL,client TEXT NOT NULL,model TEXT NOT NULL,session_id TEXT NOT NULL,input INTEGER NOT NULL,output INTEGER NOT NULL,cache_read INTEGER NOT NULL,cache_write INTEGER NOT NULL,reasoning INTEGER NOT NULL,messages INTEGER NOT NULL,cost REAL,PRIMARY KEY(device_id,day,client,model,session_id));
                    CREATE TABLE sessions(device_id TEXT NOT NULL REFERENCES devices(id),client TEXT NOT NULL,session_id TEXT NOT NULL,model TEXT NOT NULL,project_key TEXT,project_label TEXT,first_active REAL,last_active REAL,timed_tokens INTEGER NOT NULL,duration_ms INTEGER NOT NULL,input INTEGER NOT NULL,output INTEGER NOT NULL,cache_read INTEGER NOT NULL,cache_write INTEGER NOT NULL,reasoning INTEGER NOT NULL,messages INTEGER NOT NULL,cost REAL,PRIMARY KEY(device_id,client,session_id,model));
                    CREATE INDEX days_by_date ON days(day,client,model);
                    CREATE INDEX sessions_by_date ON sessions(last_active DESC);
                    CREATE INDEX sessions_by_project ON sessions(project_key);
                    PRAGMA user_version=1;
                    """)
                }
            }
            try Self.exec(db, "CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
            if version < 2 {
                try Self.transaction(db) {
                    try Self.exec(db, """
                    CREATE TABLE IF NOT EXISTS cursor_events(source_id TEXT NOT NULL REFERENCES devices(id),account_key TEXT NOT NULL,event_id TEXT NOT NULL,conversation_id TEXT NOT NULL,model TEXT NOT NULL,timestamp REAL NOT NULL,input INTEGER NOT NULL,output INTEGER NOT NULL,cache_read INTEGER NOT NULL,cache_write INTEGER NOT NULL,reasoning INTEGER NOT NULL,messages INTEGER NOT NULL,cost REAL,PRIMARY KEY(account_key,event_id));
                    CREATE INDEX IF NOT EXISTS cursor_events_by_account ON cursor_events(source_id,conversation_id,model);
                    PRAGMA user_version=2;
                    """)
                }
            }
            if version < 3 {
                try Self.transaction(db) {
                    try Self.exec(db, """
                    CREATE TABLE IF NOT EXISTS local_events(device_id TEXT NOT NULL REFERENCES devices(id),client TEXT NOT NULL,event_id TEXT NOT NULL,session_id TEXT NOT NULL,model TEXT NOT NULL,timestamp REAL NOT NULL,project_key TEXT,project_label TEXT,duration_ms INTEGER NOT NULL,input INTEGER NOT NULL,output INTEGER NOT NULL,cache_read INTEGER NOT NULL,cache_write INTEGER NOT NULL,reasoning INTEGER NOT NULL,messages INTEGER NOT NULL,cost REAL,PRIMARY KEY(device_id,client,event_id));
                    CREATE INDEX IF NOT EXISTS local_events_by_session ON local_events(device_id,client,session_id,model);
                    CREATE TABLE IF NOT EXISTS local_baseline_days AS SELECT * FROM days WHERE 0;
                    CREATE UNIQUE INDEX IF NOT EXISTS local_baseline_day_keys ON local_baseline_days(device_id,day,client,model,session_id);
                    CREATE TABLE IF NOT EXISTS local_baseline_sessions AS SELECT * FROM sessions WHERE 0;
                    CREATE UNIQUE INDEX IF NOT EXISTS local_baseline_session_keys ON local_baseline_sessions(device_id,client,session_id,model);
                    CREATE TABLE IF NOT EXISTS local_coverage_days AS SELECT * FROM days WHERE 0;
                    CREATE UNIQUE INDEX IF NOT EXISTS local_coverage_day_keys ON local_coverage_days(device_id,day,client,model,session_id);
                    CREATE TABLE IF NOT EXISTS local_coverage_sessions AS SELECT * FROM sessions WHERE 0;
                    CREATE UNIQUE INDEX IF NOT EXISTS local_coverage_session_keys ON local_coverage_sessions(device_id,client,session_id,model);
                    PRAGMA user_version=3;
                    """)
                }
            }
            return try body(db)
        }
    }
    private enum Value { case text(String), integer(Int64), double(Double), null }
    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure(db) }
    }
    private static func query(_ db: OpaquePointer, _ sql: String, _ values: [Value] = [], row: (OpaquePointer) throws -> Void = { _ in }) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure(db) }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_parameter_count(stmt) == values.count else { throw UsageLedgerError.invalid("用量查询参数无效。") }
        for (index, value) in values.enumerated() {
            let i = Int32(index + 1), result: Int32
            switch value {
            case .text(let text): result = sqlite3_bind_text(stmt, i, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .integer(let n): result = sqlite3_bind_int64(stmt, i, n)
            case .double(let n): result = sqlite3_bind_double(stmt, i, n)
            case .null: result = sqlite3_bind_null(stmt, i)
            }
            guard result == SQLITE_OK else { throw failure(db) }
        }
        while true { let result = sqlite3_step(stmt); if result == SQLITE_DONE { return }; guard result == SQLITE_ROW else { throw failure(db) }; try row(stmt) }
    }
    private static func failure(_ db: OpaquePointer) -> Error { UsageLedgerError.invalid("用量数据库操作失败：" + String(cString: sqlite3_errmsg(db))) }
    private static func transaction<T>(_ db: OpaquePointer, _ body: () throws -> T) throws -> T {
        try exec(db, "BEGIN IMMEDIATE")
        do { let result = try body(); try exec(db, "COMMIT"); return result } catch { try? exec(db, "ROLLBACK"); throw error }
    }
    private static func string(_ stmt: OpaquePointer, _ column: Int32) -> String { sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? "" }
    private static func optionalString(_ stmt: OpaquePointer, _ column: Int32) -> String? { sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : string(stmt, column) }
    private static func date(_ stmt: OpaquePointer, _ column: Int32) -> Date? { sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, column)) }
    private static func amounts(_ stmt: OpaquePointer, _ start: Int32) -> UsageAmounts {
        .init(input: sqlite3_column_int64(stmt, start), output: sqlite3_column_int64(stmt, start+1), cacheRead: sqlite3_column_int64(stmt, start+2), cacheWrite: sqlite3_column_int64(stmt, start+3), reasoning: sqlite3_column_int64(stmt, start+4), costUSD: sqlite3_column_type(stmt, start+6) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, start+6), messageCount: sqlite3_column_int64(stmt, start+5))
    }
    private static func amountValues(_ a: UsageAmounts) -> [Value] { [.integer(a.input),.integer(a.output),.integer(a.cacheRead),.integer(a.cacheWrite),.integer(a.reasoning),.integer(a.messageCount),a.costUSD.map(Value.double) ?? .null] }
    private static func session(_ stmt: OpaquePointer, start: Int32) -> UsageSessionRow {
        .init(client: string(stmt,start), sessionID: string(stmt,start+1), model: string(stmt,start+2), projectKey: optionalString(stmt,start+3), projectLabel: optionalString(stmt,start+4), firstActive: date(stmt,start+5), lastActive: date(stmt,start+6), amounts: amounts(stmt,start+9), timedTokens: sqlite3_column_int64(stmt,start+7), timedDurationMS: sqlite3_column_int64(stmt,start+8))
    }
    private static func validateDatabaseTotals(_ db: OpaquePointer) throws {
        // SQLite raises an error instead of silently wrapping SUM(Int64); both the total
        // token sum and per-bucket/message sums must fit before the transaction commits.
        for table in ["days","sessions"] {
            try query(db,"SELECT COALESCE(SUM(input+output+cache_read+cache_write+reasoning),0),\(summed) FROM \(table)") { stmt in
                guard sqlite3_column_int64(stmt,0) >= 0, amounts(stmt,1).costUSD.map({$0.isFinite && $0 >= 0}) ?? true else {throw UsageLedgerError.invalid("累计用量超出可表示范围。")}
            }
        }
    }
    private static func writeDevice(_ db: OpaquePointer, id: String, name: String, at: Date) throws {
        try query(db, "INSERT INTO devices VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,updated=MAX(devices.updated,excluded.updated)", [.text(id),.text(name),.double(at.timeIntervalSince1970)])
    }
    private static func writeRows(_ db: OpaquePointer, deviceID: String, days: [UsageDayRow], sessions: [UsageSessionRow], prefix: String = "") throws {
        let daysTable = prefix + "days", sessionsTable = prefix + "sessions"
        // A nullable cost remains unknown if either observation is unpriced. Never label
        // a mixed known/unknown total as a complete bill. Known estimates use high-water.
        func update(_ table: String) -> String {
            ["input","output","cache_read","cache_write","reasoning","messages"].map { "\($0)=MAX(\(table).\($0),excluded.\($0))" }.joined(separator: ",") + ",cost=CASE WHEN " + ["input","output","cache_read","cache_write","reasoning"].map { "excluded.\($0)>=\(table).\($0)" }.joined(separator:" AND ") + " THEN excluded.cost WHEN excluded.cost IS NULL OR \(table).cost IS NULL THEN NULL ELSE MAX(\(table).cost,excluded.cost) END"
        }
        for row in days {
            try query(db, "INSERT INTO \(daysTable) VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(device_id,day,client,model,session_id) DO UPDATE SET \(update(daysTable))", [.text(deviceID),.text(row.day),.text(row.client),.text(row.model),.text(row.sessionID)] + amountValues(row.amounts))
        }
        for row in sessions {
            let metadata: [Value] = [.text(deviceID),.text(row.client),.text(row.sessionID),.text(row.model),row.projectKey.map(Value.text) ?? .null,row.projectLabel.map(Value.text) ?? .null,row.firstActive.map { .double($0.timeIntervalSince1970) } ?? .null,row.lastActive.map { .double($0.timeIntervalSince1970) } ?? .null,.integer(row.timedTokens),.integer(row.timedDurationMS)]
            try query(db, "INSERT INTO \(sessionsTable) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(device_id,client,session_id,model) DO UPDATE SET \(update(sessionsTable)),project_key=COALESCE(excluded.project_key,\(sessionsTable).project_key),project_label=COALESCE(excluded.project_label,\(sessionsTable).project_label),first_active=CASE WHEN \(sessionsTable).first_active IS NULL THEN excluded.first_active WHEN excluded.first_active IS NULL THEN \(sessionsTable).first_active ELSE MIN(\(sessionsTable).first_active,excluded.first_active) END,last_active=CASE WHEN \(sessionsTable).last_active IS NULL THEN excluded.last_active WHEN excluded.last_active IS NULL THEN \(sessionsTable).last_active ELSE MAX(\(sessionsTable).last_active,excluded.last_active) END,timed_tokens=MAX(\(sessionsTable).timed_tokens,excluded.timed_tokens),duration_ms=MAX(\(sessionsTable).duration_ms,excluded.duration_ms)", metadata + amountValues(row.amounts))
        }
    }
    private static func cursorEvent(_ stmt: OpaquePointer) -> CursorUsageEvent {
        .init(accountKey: string(stmt,0), eventID: string(stmt,1), conversationID: string(stmt,2),
              model: string(stmt,3), timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt,4)), amounts: amounts(stmt,5))
    }
    private static func validateCursorEvents(_ events: [CursorUsageEvent]) throws {
        guard events.count <= 250_000 else { throw UsageLedgerError.invalid("Cursor 单次事件超过 25 万条。") }
        var identities = Set<String>()
        for batchStart in stride(from: 0, to: events.count, by: 5_000) {
            let batch = events[batchStart..<min(events.count, batchStart + 5_000)]
            for event in batch {
                let validHashes = [event.accountKey,event.eventID,event.conversationID].allSatisfy { $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }
                guard validHashes, identities.insert(event.accountKey + event.eventID).inserted,
                      event.amounts.reasoning == 0, event.amounts.messageCount == 1 else {
                    throw UsageLedgerError.invalid("Cursor 事件身份或计数无效。")
                }
            }
            try validate(days: [], sessions: batch.map {
                .init(client: "cursor", sessionID: $0.accountKey + $0.eventID, model: $0.model,
                      projectKey: nil, projectLabel: nil, firstActive: $0.timestamp, lastActive: $0.timestamp,
                      amounts: $0.amounts, timedTokens: 0, timedDurationMS: 0)
            })
        }
    }
    private static func validateLocalUsage(_ batch: LocalUsageBatch) throws {
        guard Set(batch.clients).count == batch.clients.count, batch.clients.allSatisfy({["kimi","antigravity"].contains($0)}), batch.events.count <= 1_000_000 else {throw UsageLedgerError.invalid("本机事件身份无效。")}
        try validate(days:batch.coverageDays,sessions:batch.coverageSessions)
        try validate(days:batch.baselineDays ?? [],sessions:batch.baselineSessions ?? [])
        var identities=Set<String>()
        for event in batch.events {
            guard batch.clients.contains(event.client), event.eventID.count == 64, event.eventID.allSatisfy({$0.isHexDigit}), identities.insert(event.client + ":" + event.eventID).inserted,
                  !event.sessionID.isEmpty, event.sessionID.count <= 4096, !event.model.isEmpty, event.model.count <= 300,
                  event.timestamp.timeIntervalSince1970 > 0, event.timestamp <= Date().addingTimeInterval(86400), event.durationMS >= 0 else {throw UsageLedgerError.invalid("本机事件身份或时间无效。")}
            try validate(days:[],sessions:[.init(client:event.client,sessionID:event.sessionID,model:event.model,projectKey:event.projectKey,projectLabel:event.projectLabel,firstActive:event.timestamp,lastActive:event.timestamp,amounts:event.amounts,timedTokens:0,timedDurationMS:event.durationMS)])
        }
        guard (batch.coverageDays + (batch.baselineDays ?? [])).allSatisfy({batch.clients.contains($0.client)}),
              (batch.coverageSessions + (batch.baselineSessions ?? [])).allSatisfy({batch.clients.contains($0.client)}) else {throw UsageLedgerError.invalid("事件覆盖范围无效。")}
    }
    private static func readLocalUsage(_ db: OpaquePointer, deviceID: String) throws -> LocalUsageBatch? {
        var clients:[String]=[]
        for client in ["kimi","antigravity"] {
            var initialized=false
            try query(db,"SELECT value FROM metadata WHERE key=?",[.text("localEvents." + deviceID + "." + client)]) {_ in initialized=true}
            if initialized {clients.append(client)}
        }
        guard !clients.isEmpty else {return nil}
        func days(_ table:String) throws -> [UsageDayRow] {
            var result:[UsageDayRow]=[]
            try query(db,"SELECT day,client,model,session_id,\(columns) FROM \(table) WHERE device_id=? ORDER BY day,client,session_id,model",[.text(deviceID)]) {stmt in
                result.append(.init(day:string(stmt,0),client:string(stmt,1),model:string(stmt,2),sessionID:string(stmt,3),amounts:amounts(stmt,4)))
            };return result
        }
        func sessions(_ table:String) throws -> [UsageSessionRow] {
            var result:[UsageSessionRow]=[]
            try query(db,"SELECT client,session_id,model,project_key,project_label,first_active,last_active,timed_tokens,duration_ms,\(columns) FROM \(table) WHERE device_id=? ORDER BY client,session_id,model",[.text(deviceID)]) {result.append(session($0,start:0))};return result
        }
        var events:[LocalUsageEvent]=[]
        try query(db,"SELECT event_id,client,session_id,model,timestamp,project_key,project_label,duration_ms,\(columns) FROM local_events WHERE device_id=? ORDER BY client,event_id",[.text(deviceID)]) {stmt in
            events.append(.init(eventID:string(stmt,0),client:string(stmt,1),sessionID:string(stmt,2),model:string(stmt,3),timestamp:Date(timeIntervalSince1970:sqlite3_column_double(stmt,4)),projectKey:optionalString(stmt,5),projectLabel:optionalString(stmt,6),durationMS:sqlite3_column_int64(stmt,7),amounts:amounts(stmt,8)))
        }
        return try .init(clients:clients,events:events,coverageDays:days("local_coverage_days"),coverageSessions:sessions("local_coverage_sessions"),baselineDays:days("local_baseline_days"),baselineSessions:sessions("local_baseline_sessions"))
    }
    private static func writeLocalUsage(_ db: OpaquePointer, deviceID: String, batch: LocalUsageBatch, importing: Bool = false) throws {
        for client in batch.clients {
            let key="localEvents." + deviceID + "." + client
            var initialized=false
            try query(db,"SELECT value FROM metadata WHERE key=?",[.text(key)]) {_ in initialized=true}
            if !initialized && batch.baselineDays == nil {
                try query(db,"INSERT INTO local_baseline_days SELECT * FROM days WHERE device_id=? AND client=?",[.text(deviceID),.text(client)])
                try query(db,"INSERT INTO local_baseline_sessions SELECT * FROM sessions WHERE device_id=? AND client=?",[.text(deviceID),.text(client)])
            }
            try query(db,"INSERT INTO metadata VALUES(?, '1') ON CONFLICT(key) DO NOTHING",[.text(key)])
        }
        try writeRows(db,deviceID:deviceID,days:batch.baselineDays ?? [],sessions:batch.baselineSessions ?? [],prefix:"local_baseline_")
        try writeRows(db,deviceID:deviceID,days:batch.coverageDays,sessions:batch.coverageSessions,prefix:"local_coverage_")
        for event in batch.events {
            var oldModel:String?
            try query(db,"SELECT model FROM local_events WHERE device_id=? AND client=? AND event_id=?",[.text(deviceID),.text(event.client),.text(event.eventID)]) {oldModel=string($0,0)}
            guard oldModel == nil || oldModel == event.model else {throw UsageLedgerError.invalid("同一用量事件的模型信息冲突，已保留历史。")}
            let fields=["input","output","cache_read","cache_write","reasoning","messages","duration_ms"].map {"\($0)=MAX(local_events.\($0),excluded.\($0))"}.joined(separator:",")
            let cost=importing ? "cost=COALESCE(local_events.cost,excluded.cost)" : "cost=CASE WHEN excluded.input>=local_events.input AND excluded.output>=local_events.output AND excluded.cache_read>=local_events.cache_read AND excluded.cache_write>=local_events.cache_write THEN excluded.cost WHEN local_events.cost IS NULL OR excluded.cost IS NULL THEN NULL ELSE MAX(local_events.cost,excluded.cost) END"
            let values:[Value]=[.text(deviceID),.text(event.client),.text(event.eventID),.text(event.sessionID),.text(event.model),.double(event.timestamp.timeIntervalSince1970),event.projectKey.map(Value.text) ?? .null,event.projectLabel.map(Value.text) ?? .null,.integer(event.durationMS)] + amountValues(event.amounts)
            // Preserve the first observed session and clock when the provider moves
            // the same response to a new surface. Only numeric completeness grows.
            try query(db,"INSERT INTO local_events VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(device_id,client,event_id) DO UPDATE SET \(fields),\(cost)",values)
        }
        guard let saved=try readLocalUsage(db,deviceID:deviceID) else {return}
        func sessionKey(_ client:String,_ session:String,_ model:String)->String {[client,session,model].joined(separator:"\0")}
        let dayCoverage=Dictionary(uniqueKeysWithValues:saved.coverageDays.map {($0.day + "\0" + sessionKey($0.client,$0.sessionID,$0.model),$0.amounts)})
        let sessionCoverage=Dictionary(uniqueKeysWithValues:saved.coverageSessions.map {(sessionKey($0.client,$0.sessionID,$0.model),$0.amounts)})
        func residual(_ original:UsageAmounts,_ covered:UsageAmounts?) -> UsageAmounts {
            let covered=covered ?? UsageAmounts()
            var result=UsageAmounts(input:max(0,original.input-covered.input),output:max(0,original.output-covered.output),cacheRead:max(0,original.cacheRead-covered.cacheRead),cacheWrite:max(0,original.cacheWrite-covered.cacheWrite),reasoning:max(0,original.reasoning-covered.reasoning),messageCount:max(0,original.messageCount-covered.messageCount))
            result.costUSD=result.totalTokens == 0 && result.messageCount == 0 ? 0 : original.costUSD.flatMap {old in covered.totalTokens == 0 ? old : covered.costUSD.map {max(0,old-$0)}}
            return result
        }
        var days:[UsageDayRow]=[],sessions:[UsageSessionRow]=[]
        for var row in saved.baselineDays ?? [] where batch.clients.contains(row.client) {
            row.amounts=residual(row.amounts,dayCoverage[row.day + "\0" + sessionKey(row.client,row.sessionID,row.model)])
            if row.amounts.totalTokens > 0 || row.amounts.messageCount > 0 || (row.amounts.costUSD ?? 0) > 0 {days.append(row)}
        }
        for var row in saved.baselineSessions ?? [] where batch.clients.contains(row.client) {
            row.amounts=residual(row.amounts,sessionCoverage[sessionKey(row.client,row.sessionID,row.model)])
            if row.amounts.totalTokens > 0 || row.amounts.messageCount > 0 || (row.amounts.costUSD ?? 0) > 0 {sessions.append(row)}
        }
        for client in batch.clients {
            try query(db,"DELETE FROM days WHERE device_id=? AND client=?",[.text(deviceID),.text(client)])
            try query(db,"DELETE FROM sessions WHERE device_id=? AND client=?",[.text(deviceID),.text(client)])
        }
        try writeRows(db,deviceID:deviceID,days:days,sessions:sessions)
        let adds=["input","output","cache_read","cache_write","reasoning","messages"].map {"\($0)=\($0)+excluded.\($0)"}.joined(separator:",")
        for client in batch.clients {
            try query(db,"INSERT INTO days SELECT device_id,strftime('%Y-%m-%d',timestamp,'unixepoch','localtime'),client,model,session_id,\(summed) FROM local_events WHERE device_id=? AND client=? GROUP BY device_id,strftime('%Y-%m-%d',timestamp,'unixepoch','localtime'),client,model,session_id ON CONFLICT(device_id,day,client,model,session_id) DO UPDATE SET \(adds),cost=CASE WHEN days.cost IS NULL OR excluded.cost IS NULL THEN NULL ELSE days.cost+excluded.cost END",[.text(deviceID),.text(client)])
            try query(db,"INSERT INTO sessions SELECT device_id,client,session_id,model,CASE WHEN COUNT(DISTINCT project_key)=1 THEN MAX(project_key) ELSE NULL END,CASE WHEN COUNT(DISTINCT project_key)=1 THEN MAX(project_label) ELSE NULL END,MIN(timestamp),MAX(timestamp),SUM(CASE WHEN duration_ms>0 THEN input+output+cache_read+cache_write+reasoning ELSE 0 END),SUM(duration_ms),\(summed) FROM local_events WHERE device_id=? AND client=? GROUP BY device_id,client,session_id,model ON CONFLICT(device_id,client,session_id,model) DO UPDATE SET \(adds),cost=CASE WHEN sessions.cost IS NULL OR excluded.cost IS NULL THEN NULL ELSE sessions.cost+excluded.cost END",[.text(deviceID),.text(client)])
        }
    }

    private static func writeCursorEvents(_ db: OpaquePointer, events: [CursorUsageEvent], at: Date, importing: Bool = false) throws {
        guard !events.isEmpty else { return }
        let accounts = Dictionary(grouping: events, by: \.accountKey)
        for (account, rows) in accounts {
            let sourceID = rows[0].sourceID
            try writeDevice(db, id: sourceID, name: "Cursor 云账户 · " + account.prefix(6), at: at)
            for event in rows {
                let values: [Value] = [.text(sourceID),.text(account),.text(event.eventID),.text(event.conversationID),.text(event.model),.double(event.timestamp.timeIntervalSince1970)] + amountValues(event.amounts)
                // Cost may settle after the event; an unpriced response does not
                // erase a previously reported official amount. Tokens remain
                // observations, preserving history across server retention.
                let fields = ["input","output","cache_read","cache_write","reasoning","messages"].map { "\($0)=MAX(cursor_events.\($0),excluded.\($0))" }.joined(separator: ",")
                // An exported observation has no authoritative freshness. A
                // stale device archive may only fill an unknown price; only a
                // live official export may revise an already known price.
                let cost = importing ? "COALESCE(cursor_events.cost,excluded.cost)" : "COALESCE(excluded.cost,cursor_events.cost)"
                try query(db, "INSERT INTO cursor_events VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(account_key,event_id) DO UPDATE SET \(fields),cost=\(cost)", values)
            }
            // Rebuild only derived Cursor rows from every saved event, including
            // events which have disappeared from the provider's export window.
            try query(db, "DELETE FROM days WHERE device_id=? AND client='cursor'", [.text(sourceID)])
            try query(db, "DELETE FROM sessions WHERE device_id=? AND client='cursor'", [.text(sourceID)])
            try query(db, "INSERT INTO days SELECT source_id,strftime('%Y-%m-%d',timestamp,'unixepoch','localtime'),'cursor',model,event_id,\(columns) FROM cursor_events WHERE source_id=?", [.text(sourceID)])
            try query(db, "INSERT INTO sessions SELECT source_id,'cursor',conversation_id,model,NULL,NULL,MIN(timestamp),MAX(timestamp),0,0,\(summed) FROM cursor_events WHERE source_id=? GROUP BY source_id,conversation_id,model", [.text(sourceID)])
        }
    }
    private static func devices(_ db: OpaquePointer) throws -> [UsageLedgerDevice] {
        var rows: [UsageLedgerDevice] = []
        try query(db, "SELECT id,name,updated FROM devices ORDER BY name,id") { rows.append(.init(id:string($0,0), name:string($0,1), lastImportedAt:Date(timeIntervalSince1970:sqlite3_column_double($0,2)))) }; return rows
    }
    private static func filter(fromDay: String? = nil, throughDay: String? = nil, client: String? = nil, device: String? = nil, project: String? = nil, model: String? = nil) -> (String, [Value]) {
        var clauses: [String] = [], values: [Value] = []
        for (column,value,op) in [("d.day",fromDay,">="),("d.day",throughDay,"<="),("d.client",client,"="),("d.device_id",device,"="),("COALESCE(d.project_key,'')",project,"="),("d.model",model,"=")] {
            if let value { clauses.append("\(column)\(op)?"); values.append(.text(value)) }
        }
        return (clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND "), values)
    }
    private static func aggregate(_ db: OpaquePointer, table: String, clause: String, values: [Value]) throws -> UsageAmounts {
        var result = UsageAmounts(input:0,output:0,cacheRead:0,cacheWrite:0,reasoning:0,costUSD:0,messageCount:0)
        try query(db, "SELECT \(summed) FROM \(table) d \(clause)", values) { result = amounts($0,0) }; return result
    }
    private static func groups(_ db: OpaquePointer, table: String, key: String, label: String? = nil, clause: String, values: [Value]) throws -> [UsageLedgerBreakdown] {
        var rows: [UsageLedgerBreakdown] = []
        try query(db, "SELECT \(key),\(label ?? key),\(summed) FROM \(table) d \(clause) GROUP BY \(key) ORDER BY SUM(input+output+cache_read+cache_write+reasoning) DESC,1", values) { rows.append(.init(key:string($0,0), label:string($0,1), amounts:amounts($0,2))) }; return rows
    }
    private static func validateDevice(id: String, name: String) throws {
        guard UUID(uuidString:id) != nil, !name.isEmpty, name.utf8.count <= 200 else { throw UsageLedgerError.invalid("用量包设备标识或名称无效。") }
    }
    private static func validateDay(_ day: String) throws {
        let f = DateFormatter(); f.locale = Locale(identifier:"en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT:0); f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        guard day.utf8.count == 10, let date = f.date(from:day), f.string(from:date) == day else { throw UsageLedgerError.invalid("用量记录日期无效。") }
    }
    private static func validate(days: [UsageDayRow], sessions: [UsageSessionRow]) throws {
        guard days.count + sessions.count <= 200_000 else { throw UsageLedgerError.invalid("单次用量记录超过 20 万条。") }
        func text(_ value: String, optional: Bool = false) throws {
            guard (optional || !value.isEmpty), value.utf8.count <= 1024, !value.unicodeScalars.contains(where: { $0.value == 0 }) else { throw UsageLedgerError.invalid("用量记录标识无效。") }
        }
        func amounts(_ a: UsageAmounts) throws {
            guard [a.input,a.output,a.cacheRead,a.cacheWrite,a.reasoning,a.messageCount].allSatisfy({ (0...1_000_000_000_000).contains($0) }), a.costUSD.map({ $0.isFinite && (0...1_000_000_000).contains($0) }) ?? true else { throw UsageLedgerError.invalid("用量记录包含无效或过大数值。") }
        }
        var dayKeys=Set<[String]>(), sessionKeys=Set<[String]>(), checkedDays=Set<String>()
        for row in days {
            if checkedDays.insert(row.day).inserted {try validateDay(row.day)}; try text(row.client); try text(row.model); try text(row.sessionID); try amounts(row.amounts)
            guard dayKeys.insert([row.day,row.client,row.model,row.sessionID]).inserted else { throw UsageLedgerError.invalid("用量包包含重复的每日会话记录。") }
        }
        for row in sessions {
            try text(row.client); try text(row.model); try text(row.sessionID); if let value=row.projectKey { try text(value,optional:true) }; if let value=row.projectLabel { try text(value,optional:true) }; try amounts(row.amounts)
            guard (0...1_000_000_000_000).contains(row.timedTokens), (0...1_000_000_000_000).contains(row.timedDurationMS), [row.firstActive,row.lastActive].compactMap({$0}).allSatisfy({ $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 >= 0 && $0 <= Date().addingTimeInterval(86400) }), !(row.firstActive != nil && row.lastActive != nil && row.firstActive! > row.lastActive!), sessionKeys.insert([row.client,row.sessionID,row.model]).inserted else { throw UsageLedgerError.invalid("会话记录时间或唯一标识无效。") }
        }
    }

    /// A consistent standalone copy, including committed WAL rows. Used by Token backup.
    nonisolated static func snapshotDatabase(from source: URL, to destination: URL) throws {
        try withExclusiveAccess {
            var handle: OpaquePointer?
            guard sqlite3_open_v2(source.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db=handle else { if let handle { sqlite3_close(handle) }; throw UsageLedgerError.invalid("无法读取用量数据库备份。") }
            defer { sqlite3_close(db) }; sqlite3_busy_timeout(db,5000)
            guard !FileManager.default.fileExists(atPath:destination.path) else { throw UsageLedgerError.invalid("数据库备份目标已存在。") }
            try query(db,"VACUUM INTO ?",[.text(destination.path)])
            try verifyDatabase(destination)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)
        }
    }
    nonisolated static func verifyDatabase(_ url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path,&handle,SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK, let db=handle else { if let handle {sqlite3_close(handle)};throw UsageLedgerError.invalid("数据库备份无法打开。") }
        defer { sqlite3_close(db) }
        var result:[String]=[]; try query(db,"PRAGMA quick_check") {result.append(string($0,0))}
        guard result == ["ok"] else {throw UsageLedgerError.invalid("数据库完整性检查失败，原资料已保留。")}
    }
}
