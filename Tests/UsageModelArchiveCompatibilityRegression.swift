import Foundation
import SQLite3

/// This exact helper links against both historical and current ledger sources.
/// Optional observation markers are inspected through JSON only, so an old
/// compiler/reader cannot accidentally learn the new DTO's field or policy.
@main struct UsageModelArchiveCompatibilityRegression {
    private static let deviceID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private static let clock = Date(timeIntervalSince1970: 1_700_000_000)
    private static let eventID = String(repeating: "a", count: 64)
    private static let session = "synthetic-session"
    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "UsageModelArchiveCompatibilityRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    private static func day() -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: clock)
    }
    private static func event(model: String, cost: Double?) -> LocalUsageEvent {
        .init(eventID: eventID, client: "antigravity", sessionID: session, model: model,
              timestamp: clock, durationMS: 4800, amounts: .init(input: 100, costUSD: cost, messageCount: 1))
    }
    private static func scan(_ value: LocalUsageEvent) -> UsageEngineScan {
        let local = LocalUsageBatch(clients: ["antigravity"], events: [value],
            coverageDays: [.init(day: day(), client: value.client, model: value.model, sessionID: value.sessionID, amounts: value.amounts)],
            coverageSessions: [.init(client: value.client, sessionID: value.sessionID, model: value.model,
                firstActive: clock, lastActive: clock, amounts: value.amounts, timedTokens: value.amounts.totalTokens, timedDurationMS: value.durationMS)])
        return .init(capturedAt: clock, days: [], sessions: [], clients: ["antigravity"], warnings: [], localUsage: local)
    }
    private static func readJSON(_ path: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
    }
    private static func writeJSON(_ value: [String: Any], _ path: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: path)
    }
    private static func markers(_ packet: [String: Any]) -> [String] {
        (packet["devices"] as? [[String: Any]] ?? []).flatMap {
            ($0["localUsage"] as? [String: Any])?["retainedUnknownEventIDs"] as? [String] ?? []
        }
    }
    private static func snapshot(_ file: URL) throws -> [String: [[String]]] {
        var handle: OpaquePointer?
        try check(sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, "Synthetic snapshot open failed")
        guard let db = handle else { throw NSError(domain: "Synthetic database", code: 1) }
        defer { sqlite3_close(db) }
        func query(_ sql: String) throws -> [[String]] {
            var statement: OpaquePointer?
            try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, "Synthetic snapshot query failed")
            guard let stmt = statement else { throw NSError(domain: "Synthetic statement", code: 1) }
            defer { sqlite3_finalize(stmt) }
            var result: [[String]] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { return result }
                try check(status == SQLITE_ROW, "Synthetic snapshot row failed")
                result.append((0..<sqlite3_column_count(stmt)).map { index in
                    switch sqlite3_column_type(stmt, index) {
                    case SQLITE_INTEGER: return "i:" + String(sqlite3_column_int64(stmt, index))
                    case SQLITE_FLOAT: return "f:" + String(sqlite3_column_double(stmt, index).bitPattern)
                    case SQLITE_TEXT: return "t:" + String(cString: sqlite3_column_text(stmt, index))
                    case SQLITE_BLOB:
                        return "b:" + (sqlite3_column_blob(stmt, index).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(stmt, index))).base64EncodedString() } ?? "")
                    default: return "null"
                    }
                })
            }
        }
        let names = try query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").map { String($0[0].dropFirst(2)) }
        var result: [String: [[String]]] = ["PRAGMA.user_version": try query("PRAGMA user_version")]
        for name in names {
            let escaped = name.replacingOccurrences(of: "\"", with: "\"\"")
            let columns = try query("PRAGMA table_info(\"" + escaped + "\")").count
            let order = (1...columns).map(String.init).joined(separator: ",")
            result[name] = try query("SELECT * FROM \"" + escaped + "\" ORDER BY " + order)
        }
        return result
    }
    private static func ledger(_ path: URL) -> UsageLedger { .init(directory: path, deviceID: deviceID, deviceName: "Synthetic Fixture") }

    private static func prepare(_ directory: URL) async throws {
        let source = ledger(directory.appendingPathComponent("prepare-ledger.noindex"))
        try await source.ingest(scan(event(model: "gemini-3.8-flash-control", cost: 0.01)))
        try await source.ingest(scan(event(model: "unknown", cost: nil)))
        let original = directory.appendingPathComponent("protected-current.json")
        try await source.export(to: original)
        let packet = try readJSON(original)
        try check(markers(packet) == [eventID], "Current reader did not export the synthetic protection marker")
        let originalFormat = packet["format"] as! Int
        for format in [3, 4] {
            var versioned = packet; versioned["format"] = format
            try writeJSON(versioned, directory.appendingPathComponent("protected-v\(format).json"))
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let amounts = UsageAmounts(input: 20, messageCount: 1)
        let days = [UsageDayRow(day: day(), client: "antigravity", model: "unknown", sessionID: session, amounts: amounts)]
        let sessions = [UsageSessionRow(client: "antigravity", sessionID: session, model: "unknown", firstActive: clock, lastActive: clock, amounts: amounts, timedTokens: 0, timedDurationMS: 0)]
        for format in [1, 2] {
            let legacy: [String: Any] = ["format": format, "exportedAt": "2023-11-14T22:13:20Z", "devices": [
                ["id": deviceID, "name": "Synthetic Fixture", "days": try JSONSerialization.jsonObject(with: encoder.encode(days)), "sessions": try JSONSerialization.jsonObject(with: encoder.encode(sessions))]
            ]]
            try writeJSON(legacy, directory.appendingPathComponent("legacy-v\(format)-unknown20.json"))
        }
        try writeJSON(["mode": "prepare", "original_export_format": originalFormat, "protected_marker_count": markers(packet).count,
                       "known_event_tokens": 100, "later_legacy_unknown_tokens": 20, "no_cli_api_app_real_data": true], directory.appendingPathComponent("prepare-result.json"))
        print("PREPARE original_format=\(originalFormat) marker_count=1 known_tokens=100 legacy_unknown_tokens=20; protected-v3/v4 differ only in format. Synthetic only.")
    }

    private static func oldAccept(_ directory: URL) async throws {
        var results: [[String: Any]] = []
        for format in [1, 2] {
            let target = ledger(directory.appendingPathComponent("old-accept-v\(format)-" + UUID().uuidString + ".noindex"))
            try await target.importFile(directory.appendingPathComponent("protected-v3.json"))
            let before = try await target.dashboard().total.totalTokens
            let reexport = directory.appendingPathComponent("old-reexport-v\(format).json")
            try await target.export(to: reexport)
            let forgotten = markers(try readJSON(reexport))
            try check(before == 100 && forgotten.isEmpty, "Historical reader did not exhibit optional-marker loss")
            let state = try snapshot(await target.databaseURL)
            let markerMetadata = state["metadata", default: []].filter { $0.contains(where: { $0.hasPrefix("t:retainedUnknown.") }) }
            try check(markerMetadata.isEmpty, "Historical reader unexpectedly persisted a retained-model marker")
            try await target.importFile(directory.appendingPathComponent("legacy-v\(format)-unknown20.json"))
            let after = try await target.dashboard().total.totalTokens
            try check(after == 100, "Expected historical coverage to swallow the later synthetic 20-token balance")
            results.append(["legacy_format": format, "before_tokens": before, "imported_unknown_tokens": 20, "after_tokens": after,
                            "marker_count_after_old_reexport": forgotten.count, "persisted_marker_rows": markerMetadata.count,
                            "demonstrated_lost_unknown_tokens": 20])
            print("OLD_ACCEPT legacy_format=\(format) known100+unknown20=>\(after) marker_count=0 lost_unknown_tokens=20")
        }
        try writeJSON(["mode": "old-accept", "historical_reader_vulnerability_confirmed": true, "results": results, "no_cli_api_app_real_data": true], directory.appendingPathComponent("old-accept-result.json"))
    }

    private static func oldReject(_ directory: URL) async throws {
        let target = ledger(directory.appendingPathComponent("old-reject-" + UUID().uuidString + ".noindex"))
        let amounts = UsageAmounts(input: 7, messageCount: 1)
        try await target.ingest(.init(capturedAt: clock,
            days: [.init(day: day(), client: "codex", model: "fixture", sessionID: "existing", amounts: amounts)],
            sessions: [.init(client: "codex", sessionID: "existing", model: "fixture", firstActive: clock, lastActive: clock, amounts: amounts, timedTokens: 0, timedDurationMS: 0)],
            clients: ["codex"], warnings: [], dayFingerprints: [day(): "fixture-original"]))
        let path = await target.databaseURL, before = try snapshot(await target.databaseURL)
        var rejected = false
        do { try await target.importFile(directory.appendingPathComponent("protected-v4.json")) }
        catch is UsageLedgerError { rejected = true }
        let after = try snapshot(path)
        try check(rejected && before == after, "Historical reader did not atomically reject protected format4")
        try writeJSON(["mode": "old-reject", "protected_format": 4, "rejected": true, "all_logical_tables_and_schema_unchanged": true,
                       "preexisting_tokens": 7, "no_cli_api_app_real_data": true], directory.appendingPathComponent("old-reject-result.json"))
        print("OLD_REJECT protected_format=4 rejected=1 all_logical_tables_and_schema_unchanged=1 preexisting_tokens=7")
    }

    private static func currentVerify(_ directory: URL) async throws {
        let run = directory.appendingPathComponent("current-verify-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let source = ledger(run.appendingPathComponent("source-ledger.noindex"))
        try await source.ingest(scan(event(model: "gemini-3.8-flash-control", cost: 0.01)))
        try await source.ingest(scan(event(model: "unknown", cost: nil)))
        let archive = run.appendingPathComponent("native-protected-v4.json")
        try await source.export(to: archive)
        let protected = try readJSON(archive)
        try check(protected["format"] as? Int == 4 && markers(protected) == [eventID], "Current native export lacks format4 or its protection marker")
        let restored = ledger(run.appendingPathComponent("restored-ledger.noindex"))
        try await restored.importFile(archive)
        let restoredTotal = try await restored.dashboard().total.totalTokens
        try check(restoredTotal == 100, "Fresh format4 import changed synthetic usage")
        let reexport = run.appendingPathComponent("restored-protected-v4.json")
        try await restored.export(to: reexport)
        let restoredPacket = try readJSON(reexport)
        try check(restoredPacket["format"] as? Int == 4 && markers(restoredPacket) == [eventID], "Fresh format4 import/reexport lost its protection marker")
        for format in [1, 2] {
            let path = await restored.databaseURL
            let before = try snapshot(path)
            var rejected = false
            do { try await restored.importFile(directory.appendingPathComponent("legacy-v\(format)-unknown20.json")) }
            catch is UsageLedgerError { rejected = true }
            let after = try snapshot(path)
            try check(rejected && before == after, "Format4-imported marker failed to protect a later legacy unknown balance")
        }
        print("CURRENT protected native_format=4 fresh_import_tokens=100 marker_count=1 later_legacy_v1_v2_rejected=1 all_logical_state_unchanged=1")

        var validOldResults: [[String: Any]] = []
        for format in [1, 2, 3] {
            var legacy = try readJSON(directory.appendingPathComponent("legacy-v2-unknown20.json"))
            legacy["format"] = format
            let file = run.appendingPathComponent("valid-unmarked-v\(format).json")
            try writeJSON(legacy, file)
            let target = ledger(run.appendingPathComponent("valid-unmarked-v\(format)-ledger.noindex"))
            try await target.importFile(file)
            let total = try await target.dashboard().total.totalTokens
            try check(total == 20, "Valid unmarked legacy archive lost compatibility")
            let native = run.appendingPathComponent("native-unmarked-after-v\(format).json")
            try await target.export(to: native)
            let packet = try readJSON(native)
            try check(packet["format"] as? Int == 4 && markers(packet).isEmpty, "Unmarked normal ledger did not natively export format4")
            validOldResults.append(["imported_format": format, "tokens": total, "native_export_format": 4, "markers": 0])
            print("CURRENT valid_unmarked_legacy_format=\(format) tokens=20 native_export_format=4 marker_count=0")
        }

        var rejectedOldResults: [[String: Any]] = []
        for format in [1, 2, 3] {
            for empty in [false, true] {
                var packet = protected
                packet["format"] = format
                var devices = packet["devices"] as! [[String: Any]]
                var local = devices[0]["localUsage"] as! [String: Any]
                local["retainedUnknownEventIDs"] = empty ? [] : [eventID]
                devices[0]["localUsage"] = local; packet["devices"] = devices
                let label = "v\(format)-" + (empty ? "empty" : "nonempty")
                let file = run.appendingPathComponent("invalid-marked-" + label + ".json")
                try writeJSON(packet, file)
                let targetDirectory = run.appendingPathComponent("must-not-create-" + label + ".noindex")
                let target = ledger(targetDirectory)
                let database = await target.databaseURL
                try check(!FileManager.default.fileExists(atPath: targetDirectory.path), "Synthetic target existed before invalid old archive test")
                var rejected = false
                do { try await target.importFile(file) }
                catch is UsageLedgerError { rejected = true }
                let created = FileManager.default.fileExists(atPath: database.path) || FileManager.default.fileExists(atPath: targetDirectory.path)
                try check(rejected && !created, "Low-format marker archive reached database creation")
                rejectedOldResults.append(["format": format, "marker_count": empty ? 0 : 1, "rejected": true, "database_or_directory_created": false])
                print("CURRENT invalid_marked_legacy_format=\(format) marker_count=\(empty ? 0 : 1) rejected_before_db_creation=1")
            }
        }
        try writeJSON(["mode": "current-verify", "native_export_format": 4, "restored_tokens": restoredTotal,
                       "restored_marker_count": 1, "later_legacy_unknown_balance_rejected_atomically": true,
                       "valid_old_archives": validOldResults, "marked_old_archives_rejected_before_db_creation": rejectedOldResults,
                       "historical_reader_format4_rejection_reused_without_rerun": true, "no_cli_api_app_real_data": true],
                      directory.appendingPathComponent("current-verify-result.json"))
    }

    static func main() async throws {
        try check(CommandLine.arguments.count == 3, "Usage: helper prepare|old-accept|old-reject|current-verify fixture-directory")
        let mode = CommandLine.arguments[1], directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        switch mode {
        case "prepare": try await prepare(directory)
        case "old-accept": try await oldAccept(directory)
        case "old-reject": try await oldReject(directory)
        case "current-verify": try await currentVerify(directory)
        default: throw NSError(domain: "Unknown compatibility mode", code: 1)
        }
    }
}
