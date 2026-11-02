import Foundation
import SQLite3

/// Synthetic DTOs and temporary ledgers only. No scanner, CLI, application,
/// network, credentials, source logs or installed data are used by this test.
@main struct UsageModelObservationRegression {
    private static let deviceID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private static let knownModel = "gemini-3.8-flash-control"
    private static let clock = Date(timeIntervalSince1970: 1_700_000_000)
    private static let conflictMessage = "同一用量事件的模型信息冲突，已保留历史。"

    private enum Cell: Equatable {
        case integer(Int64), real(UInt64), text(String), blob(Data), null
    }
    private struct Table: Equatable {
        var name: String
        var columns: [String]
        var rows: [[Cell]]
    }
    private struct Snapshot: Equatable {
        var schemaVersion: Int32
        var tables: [Table]
        func rows(_ table: String) -> [[Cell]] { tables.first { $0.name == table }?.rows ?? [] }
        func historyTables() -> [Table] { tables.filter { $0.name != "devices" && $0.name != "metadata" } }
    }

    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "UsageModelObservationRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    private static func quoted(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    private static func snapshot(_ path: URL) throws -> Snapshot {
        var handle: OpaquePointer?
        try check(sqlite3_open_v2(path.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, "Fixture snapshot open failed")
        guard let db = handle else { throw NSError(domain: "Fixture database handle", code: 1) }
        defer { sqlite3_close(db) }
        func rows(_ sql: String) throws -> (columns: [String], values: [[Cell]]) {
            var statement: OpaquePointer?
            try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, "Fixture snapshot query failed")
            guard let stmt = statement else { throw NSError(domain: "Fixture statement", code: 1) }
            defer { sqlite3_finalize(stmt) }
            let count = sqlite3_column_count(stmt)
            let columns = (0..<count).map { String(cString: sqlite3_column_name(stmt, $0)) }
            var values: [[Cell]] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                try check(status == SQLITE_ROW, "Fixture snapshot read failed")
                values.append((0..<count).map { index in
                    switch sqlite3_column_type(stmt, index) {
                    case SQLITE_INTEGER: return .integer(sqlite3_column_int64(stmt, index))
                    case SQLITE_FLOAT: return .real(sqlite3_column_double(stmt, index).bitPattern)
                    case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(stmt, index)))
                    case SQLITE_BLOB:
                        let length = Int(sqlite3_column_bytes(stmt, index))
                        return .blob(sqlite3_column_blob(stmt, index).map { Data(bytes: $0, count: length) } ?? Data())
                    default: return .null
                    }
                })
            }
            return (columns, values)
        }
        let schema = try rows("PRAGMA user_version").values
        guard case .integer(let version)? = schema.first?.first else { throw NSError(domain: "Fixture schema", code: 1) }
        let names = try rows("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").values.compactMap { row -> String? in
            if case .text(let name)? = row.first { return name }; return nil
        }
        var tables: [Table] = []
        for name in names {
            let columns = try rows("SELECT * FROM " + quoted(name) + " LIMIT 0").columns
            let order = (1...columns.count).map(String.init).joined(separator: ",")
            let result = try rows("SELECT * FROM " + quoted(name) + " ORDER BY " + order)
            tables.append(.init(name: name, columns: result.columns, rows: result.values))
        }
        return .init(schemaVersion: Int32(version), tables: tables)
    }

    private static func identity(_ digit: Character = "a") -> String { String(repeating: String(digit), count: 64) }
    private static func event(client: String = "antigravity", model: String = knownModel, id: Character = "a") -> LocalUsageEvent {
        .init(eventID: identity(id), client: client, sessionID: "fixture-session", model: model,
              timestamp: clock, projectKey: "fixture-project", projectLabel: "Fixture",
              durationMS: 4800, amounts: .init(input: 1318, output: 0, costUSD: 0.0009885, messageCount: 1))
    }
    private static func missingModel(_ old: LocalUsageEvent) -> LocalUsageEvent {
        var value = old
        value.model = "unknown"; value.amounts.costUSD = nil
        value.durationMS = 0; value.projectKey = nil; value.projectLabel = nil
        return value
    }
    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: date)
    }
    private static func batch(_ events: [LocalUsageEvent]) -> LocalUsageBatch {
        .init(clients: Array(Set(events.map(\.client))).sorted(), events: events,
              coverageDays: events.map { .init(day: day($0.timestamp), client: $0.client, model: $0.model, sessionID: $0.sessionID, amounts: $0.amounts) },
              coverageSessions: events.map { .init(client: $0.client, sessionID: $0.sessionID, model: $0.model,
                  projectKey: $0.projectKey, projectLabel: $0.projectLabel, firstActive: $0.timestamp, lastActive: $0.timestamp,
                  amounts: $0.amounts, timedTokens: $0.durationMS > 0 ? $0.amounts.totalTokens : 0, timedDurationMS: $0.durationMS) })
    }
    private static func scan(_ events: [LocalUsageEvent], at: Date = clock) -> UsageEngineScan {
        .init(capturedAt: at, days: [], sessions: [], clients: Array(Set(events.map(\.client))).sorted(), warnings: [],
              dayFingerprints: [day(clock): "fixture-original"], localUsage: batch(events))
    }
    private static func withIndependentWrites(_ value: UsageEngineScan) -> UsageEngineScan {
        var value = value
        let ordinary = UsageAmounts(input: 701, output: 3, costUSD: 0.42, messageCount: 1)
        value.days = [.init(day: day(clock), client: "codex", model: "fixture-independent-model", sessionID: "must-rollback", amounts: ordinary)]
        value.sessions = [.init(client: "codex", sessionID: "must-rollback", model: "fixture-independent-model", firstActive: clock, lastActive: clock, amounts: ordinary, timedTokens: 0, timedDurationMS: 0)]
        var independent = event(id: "b")
        independent.sessionID = "independent-event-must-rollback"
        value.localUsage = batch([independent] + (value.localUsage?.events ?? []))
        value.dayFingerprints = [day(clock): "must-rollback-fingerprint"]
        value.capturedAt = clock.addingTimeInterval(60)
        return value
    }
    private static func expectAtomicConflict(_ ledger: UsageLedger, _ incoming: UsageEngineScan, label: String) async throws {
        let path = await ledger.databaseURL
        let before = try snapshot(path)
        var rejected = false
        do { try await ledger.ingest(incoming) }
        catch let error as UsageLedgerError { rejected = error.localizedDescription == conflictMessage }
        try check(rejected, "Expected exact model conflict: " + label)
        let after = try snapshot(path)
        try check(after == before, "Conflict changed logical tables/schema: " + label)
    }
    private static func expectInvalidMarker(_ ledger: UsageLedger, _ incoming: UsageEngineScan, label: String) async throws {
        let path = await ledger.databaseURL, before = try snapshot(await ledger.databaseURL)
        var rejected = false
        do { try await ledger.ingest(incoming) }
        catch is UsageLedgerError { rejected = true }
        let after = try snapshot(path)
        try check(rejected && after == before, "Malformed retained-model marker accepted or changed logical state: " + label)
    }

    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("usage-model-observation-" + UUID().uuidString + ".noindex")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func ledger(_ name: String) -> UsageLedger { .init(directory: root.appendingPathComponent(name), deviceID: deviceID, deviceName: "Synthetic Fixture") }

        // A less complete observation may not erase an exact, already recorded event.
        let accepted = ledger("accepted"), known = event(), unknown = missingModel(event())
        try await accepted.ingest(scan([known]))
        let acceptedPath = await accepted.databaseURL
        let before = try snapshot(acceptedPath)
        try await accepted.ingest(scan([unknown]))
        let after = try snapshot(acceptedPath)
        try check(after.rows("local_events") == before.rows("local_events"), "Missing-model observation changed the complete stored event")
        try check(after.rows("days") == before.rows("days") && after.rows("sessions") == before.rows("sessions"), "Missing-model observation changed derived history")
        let dashboard = try await accepted.dashboard(), summary = try await accepted.sessionSummary()
        try check(dashboard.total.totalTokens == 1318 && dashboard.total.costUSD == known.amounts.costUSD, "Known totals or price changed")
        try check(summary.total == dashboard.total, "Day/session total disagreement")
        try check(after.rows("local_coverage_days").count == 2 && after.rows("local_coverage_sessions").count == 2, "Original unknown coverage was not retained beside old known coverage")
        try await accepted.ingest(scan([unknown]))
        try check(try snapshot(acceptedPath) == after, "Repeated missing-model observation was not idempotent")

        // Each count independently matters. Rejections also exercise ordinary rows,
        // a new event, device timestamp, coverage and fingerprints in one transaction.
        let countMutations: [(String, (inout UsageAmounts) -> Void)] = [
            ("input", { $0.input += 1 }), ("output", { $0.output += 1 }),
            ("cacheRead", { $0.cacheRead += 1 }), ("cacheWrite", { $0.cacheWrite += 1 }),
            ("reasoning", { $0.reasoning += 1 }), ("messages", { $0.messageCount += 1 })
        ]
        for (name, mutate) in countMutations {
            var changed = unknown; mutate(&changed.amounts)
            try await expectAtomicConflict(accepted, withIndependentWrites(scan([changed])), label: name)
        }
        var changedTime = unknown; changedTime.timestamp = clock.addingTimeInterval(0.001)
        try await expectAtomicConflict(accepted, withIndependentWrites(scan([changedTime])), label: "exact timestamp")
        var changedSession = unknown; changedSession.sessionID = "different-session"
        try await expectAtomicConflict(accepted, withIndependentWrites(scan([changedSession])), label: "session")
        var concrete = unknown; concrete.model = "gemini-3.8-flash"
        try await expectAtomicConflict(accepted, withIndependentWrites(scan([concrete])), label: "different concrete model")
        var pricedUnknown = unknown; pricedUnknown.amounts.costUSD = 0
        try await expectAtomicConflict(accepted, withIndependentWrites(scan([pricedUnknown])), label: "explicit zero cost")
        let kimi = ledger("kimi")
        try await kimi.ingest(scan([event(client: "kimi")]))
        try await expectAtomicConflict(kimi, withIndependentWrites(scan([missingModel(event(client: "kimi"))])), label: "Kimi never qualifies")
        let generic = ledger("generic-model")
        try await generic.ingest(scan([event(model: "gemini-default")]))
        try await expectAtomicConflict(generic, withIndependentWrites(scan([missingModel(event(model: "gemini-default"))])), label: "old fallback is not a concrete model")

        // Unknown legacy balances must not be consumed by this observation's raw
        // unknown coverage. Exercise day-only, session-only, and price-only debt.
        for kind in ["day", "session", "cost-only", "different-day", "duration-only"] {
            let protected = ledger("baseline-" + kind)
            try await protected.ingest(scan([known]))
            var oldUnknown = event(model: "unknown", id: "c")
            oldUnknown.amounts = .init(input: 50, output: 0, costUSD: nil, messageCount: 1)
            var seeded = scan([known])
            seeded.localUsage?.baselineDays = []
            seeded.localUsage?.baselineSessions = []
            if kind == "cost-only" { oldUnknown.amounts = .init(costUSD: 0.25) }
            if kind == "duration-only" { oldUnknown.amounts = .init() }
            let source = batch([oldUnknown])
            if kind == "day" || kind == "different-day" || kind == "cost-only" {
                var rows = source.coverageDays
                if kind == "different-day" { rows[0].day = "2023-11-13" }
                seeded.localUsage?.baselineDays = rows
            } else {
                seeded.localUsage?.baselineSessions = source.coverageSessions
            }
            try await protected.ingest(seeded)
            try await expectAtomicConflict(protected, withIndependentWrites(scan([unknown])), label: "nonzero unknown baseline " + kind)
        }

        // Equal amounts remain independent when the event identity is different.
        let distinct = ledger("distinct")
        var other = known; other.eventID = identity("d"); other.model = "gemini-3.8-flash"; other.sessionID = "other-session"
        try await distinct.ingest(scan([known, other]))
        let distinctTotal = try await distinct.dashboard().total.totalTokens
        let distinctSnapshot = try snapshot(await distinct.databaseURL)
        try check(distinctTotal == 2636 && distinctSnapshot.rows("local_events").count == 2, "Independent equal-valued events were swallowed")

        // Export contains the original complete event, not the unknown observer.
        let archive = root.appendingPathComponent("accepted-v4.json")
        try await accepted.export(to: archive)
        let exported = try JSONSerialization.jsonObject(with: Data(contentsOf: archive)) as! [String: Any]
        try check(exported["format"] as? Int == 4, "Expected native v4 usage archive")
        let exportedDevices = exported["devices"] as! [[String: Any]]
        let exportedLocal = exportedDevices[0]["localUsage"] as! [String: Any]
        try check(exportedLocal["retainedUnknownEventIDs"] as? [String] == [identity()], "Accepted observation's protection marker was not exported")
        try await accepted.importFile(archive)
        try check(try snapshot(acceptedPath).historyTables() == after.historyTables(), "Own-device round trip changed event history")
        let restored = ledger("restored")
        try await restored.importFile(archive)
        let restoredPath = await restored.databaseURL
        let restoredOnce = try snapshot(restoredPath)
        try await restored.importFile(archive)
        try check(try snapshot(restoredPath).historyTables() == restoredOnce.historyTables(), "Repeated v4 import was not idempotent")
        let restoredTotals = try await restored.dashboard().total
        try check(restoredTotals == dashboard.total, "v4 round trip changed costs or numeric buckets")
        let restoredArchive = root.appendingPathComponent("restored-v4.json")
        try await restored.export(to: restoredArchive)
        let restoredJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: restoredArchive)) as! [String: Any]
        let restoredDevices = restoredJSON["devices"] as! [[String: Any]]
        let restoredLocal = restoredDevices[0]["localUsage"] as! [String: Any]
        try check(restoredLocal["retainedUnknownEventIDs"] as? [String] == [identity()], "Fresh v4 import lost the retained-model protection marker")

        // A fallback adds raw unknown coverage. A later legacy archive must not
        // let that coverage erase unknown usage which had not yet been imported.
        // The independent first device also proves whole-package atomicity.
        let fixtureEncoder = JSONEncoder(); fixtureEncoder.dateEncodingStrategy = .iso8601
        func encoded<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: fixtureEncoder.encode(value)) }
        func legacyArchive(format: Int, kind: String) throws -> URL {
            let amounts: UsageAmounts
            switch kind {
            case "tokens": amounts = .init(input: 20, messageCount: 1)
            case "cost-only": amounts = .init(costUSD: 0.25)
            default: amounts = .init()
            }
            let dayRow = UsageDayRow(day: day(clock), client: "antigravity", model: "unknown", sessionID: known.sessionID, amounts: amounts)
            let sessionRow = UsageSessionRow(client: "antigravity", sessionID: known.sessionID, model: "unknown", firstActive: clock, lastActive: clock,
                amounts: amounts, timedTokens: kind == "timing-only" ? 1 : 0, timedDurationMS: kind == "timing-only" ? 900 : 0)
            let independentAmounts = UsageAmounts(input: 3, messageCount: 1)
            let independentDay = UsageDayRow(day: day(clock), client: "codex", model: "fixture-model", sessionID: "legacy-device-must-rollback", amounts: independentAmounts)
            let independentSession = UsageSessionRow(client: "codex", sessionID: "legacy-device-must-rollback", model: "fixture-model", firstActive: clock, lastActive: clock,
                amounts: independentAmounts, timedTokens: 0, timedDurationMS: 0)
            let packet: [String: Any] = ["format": format, "exportedAt": "2023-11-14T22:13:20Z", "devices": [
                ["id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "name": "Independent legacy fixture", "days": try encoded([independentDay]), "sessions": try encoded([independentSession])],
                ["id": deviceID, "name": "Synthetic Fixture", "days": try encoded([dayRow]), "sessions": try encoded([sessionRow])]
            ]]
            let file = root.appendingPathComponent("legacy-v\(format)-\(kind).json")
            try JSONSerialization.data(withJSONObject: packet).write(to: file)
            return file
        }
        for format in [1, 2] {
            for kind in ["tokens", "cost-only", "timing-only"] {
                let oldArchive = try legacyArchive(format: format, kind: kind)
                // The same packet is structurally valid without a previous
                // retained-model observation; rejection below is not bad JSON.
                let unmarked = ledger("unmarked-v\(format)-\(kind)")
                try await unmarked.importFile(oldArchive)
                for (name, target) in [("accepted", accepted), ("restored", restored)] {
                    let path = await target.databaseURL
                    let beforeLegacy = try snapshot(path)
                    var rejected = false
                    do { try await target.importFile(oldArchive) }
                    catch is UsageLedgerError { rejected = true }
                    let afterLegacy = try snapshot(path)
                    try check(rejected && afterLegacy == beforeLegacy, "Later legacy unknown balance was consumed after fallback: v\(format) \(kind) \(name)")
                }
            }
        }

        // Optional markers are event references, never authority to turn an
        // unknown or unrelated client's event into a previously known model.
        var missingMarker = scan([known]); missingMarker.localUsage?.retainedUnknownEventIDs = [identity("e")]
        try await expectInvalidMarker(accepted, missingMarker, label: "missing event")
        var kimiMarker = scan([event(client: "kimi")]); kimiMarker.localUsage?.retainedUnknownEventIDs = [identity()]
        try await expectInvalidMarker(accepted, kimiMarker, label: "Kimi event")
        var unknownMarker = scan([unknown]); unknownMarker.localUsage?.retainedUnknownEventIDs = [identity()]
        try await expectInvalidMarker(accepted, unknownMarker, label: "unknown event")
        var nonhexMarker = scan([known]); nonhexMarker.localUsage?.retainedUnknownEventIDs = ["not-a-hex-event"]
        try await expectInvalidMarker(accepted, nonhexMarker, label: "nonhex event")
        var repeatedMarker = scan([known]); repeatedMarker.localUsage?.retainedUnknownEventIDs = [identity(), identity()]
        try await expectInvalidMarker(accepted, repeatedMarker, label: "duplicate event references")

        // Imports have no authoritative live freshness and cannot use the exception.
        var importedUnknown = exported
        var devices = importedUnknown["devices"] as! [[String: Any]]
        var local = devices[0]["localUsage"] as! [String: Any]
        // Exercise the original live-only exception boundary separately from
        // the malformed-marker tests above.
        local.removeValue(forKey: "retainedUnknownEventIDs")
        var events = local["events"] as! [[String: Any]]
        events[0]["model"] = "unknown"
        var amounts = events[0]["amounts"] as! [String: Any]; amounts.removeValue(forKey: "costUSD")
        events[0]["amounts"] = amounts; local["events"] = events; devices[0]["localUsage"] = local; importedUnknown["devices"] = devices
        let conflictArchive = root.appendingPathComponent("imported-unknown.json")
        try JSONSerialization.data(withJSONObject: importedUnknown).write(to: conflictArchive)
        let beforeImport = try snapshot(acceptedPath)
        var importRejected = false
        do { try await accepted.importFile(conflictArchive) }
        catch let error as UsageLedgerError { importRejected = error.localizedDescription == conflictMessage }
        let afterImport = try snapshot(acceptedPath)
        try check(importRejected && afterImport == beforeImport, "Untrusted import used live-only model fallback or partially committed")

        // The decoder stays strict for conflicting surfaces within one fresh scan.
        let raw: [String: Any] = ["eventId": identity(), "client": "antigravity", "sessionId": "fixture-session", "model": knownModel,
            "timestamp": Int64(clock.timeIntervalSince1970 * 1000), "input": 1318, "output": 0, "cacheRead": 0, "cacheWrite": 0,
            "messageCount": 1, "cost": 0.0009885, "durationMs": 4800]
        var rawUnknown = raw; rawUnknown["model"] = "unknown"; rawUnknown["cost"] = 0
        let report = try JSONSerialization.data(withJSONObject: ["entries": [], "localRecords": [raw, rawUnknown]])
        var batchRejected = false
        do { _ = try UsageEngine.decodeLocalReportData(report, clients: ["antigravity"]) }
        catch UsageEngineFailure.malformed { batchRejected = true }
        try check(batchRejected, "Same-batch known/unknown model conflict was relaxed")
        print("Model observation regression passed: exact live Antigravity missing-model fallback preserves complete stored event/cost/duration and raw coverage; repeat idempotence; every count/time/session/client/model/cost boundary atomically rolls back every logical table; unknown baseline debt protected before and after fallback including later legacy v1/v2 imports; retained-model markers survive fresh v4 round trips and reject missing/Kimi/unknown/nonhex/duplicate references; distinct events retained; live-only import boundary and same-batch strict decoding. Synthetic DTO/SQLite only; no CLI, API, real data, application or smoke test.")
    }
}
