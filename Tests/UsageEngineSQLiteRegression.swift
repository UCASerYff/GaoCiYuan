import Foundation
import SQLite3

/// Actual pinned CLI, synthetic SQLite records, isolated home/cache only.
/// This checks the concurrency constraint and complete numeric accounting; it
/// does not claim to reproduce the rare ARM64 initialization crash.
@main struct UsageEngineSQLiteRegression {
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "UsageEngineSQLiteRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func varint(_ value: UInt64) -> Data {
        var value = value, data = Data()
        while value > 127 { data.append(UInt8(value & 127) | 128); value >>= 7 }
        data.append(UInt8(value)); return data
    }
    static func number(_ field: UInt64, _ value: UInt64) -> Data { varint(field << 3) + varint(value) }
    static func blob(_ field: UInt64, _ value: Data) -> Data { varint((field << 3) | 2) + varint(UInt64(value.count)) + value }

    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("gaociyuan-sqlite-regression-" + UUID().uuidString + ".noindex")
        let home = root.appendingPathComponent("home")
        let configuration = root.appendingPathComponent("config")
        let databases = home.appendingPathComponent(".gemini/antigravity/conversations")
        try fm.createDirectory(at: databases, withIntermediateDirectories: true)
        try fm.createDirectory(at: configuration.appendingPathComponent("cache"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for filename in ["pricing-litellm.json", "pricing-openrouter.json", "pricing-models-dev.json"] {
            try JSONSerialization.data(withJSONObject: ["timestamp": Int(Date().timeIntervalSince1970), "data": [String: String]()])
                .write(to: configuration.appendingPathComponent("cache/" + filename))
        }
        let count = 64
        for index in 0..<count {
            let usage = number(2, 100) + number(9, 10) + blob(11, Data("fixture-response-\(index)".utf8))
            let chat = blob(4, usage) + blob(19, Data("gemini-3-flash".utf8)) + blob(9, blob(4, number(1, 1_789_516_800)))
            let payload = blob(1, chat)
            let file = databases.appendingPathComponent("fixture-\(index).db")
            var db: OpaquePointer?
            try check(sqlite3_open(file.path, &db) == SQLITE_OK, "synthetic SQLite creation failed")
            defer { sqlite3_close(db) }
            try check(sqlite3_exec(db, "CREATE TABLE gen_metadata(idx INTEGER,data BLOB)", nil, nil, nil) == SQLITE_OK, "synthetic table creation failed")
            var statement: OpaquePointer?
            try check(sqlite3_prepare_v2(db, "INSERT INTO gen_metadata VALUES(1,?)", -1, &statement, nil) == SQLITE_OK, "synthetic insert prepare failed")
            _ = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(payload.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            try check(sqlite3_step(statement) == SQLITE_DONE, "synthetic insert failed")
            sqlite3_finalize(statement)
        }
        // Every graph/day/all-history invocation must pass through this guard
        // before exec'ing the unchanged, real resource binary.
        let engine = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let quoted = "'" + engine.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let wrapper = root.appendingPathComponent("checked-engine")
        let script = """
        #!/bin/zsh
        [[ "${TOKSCALE_PRICING_CACHE_ONLY:-}" == 1 && "${RAYON_NUM_THREADS:-}" == 1 ]] || exit 92
        exec \(quoted) "$@"
        """
        try Data(script.utf8).write(to: wrapper)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let work = Task {
            try await UsageEngine.scan(configuration: .init(enabledClientIDs: ["antigravity"]),
                engineURL: wrapper, configurationDirectory: configuration, homeDirectory: home)
        }
        let timeout = Task {
            try await Task.sleep(nanoseconds: 10_000_000_000)
            work.cancel()
        }
        defer { timeout.cancel() }
        let scan = try await work.value
        try check(scan.days.count == count && scan.sessions.count == count, "single-worker scan omitted SQLite day/session records")
        try check(scan.days.reduce(0) { $0 + $1.amounts.totalTokens } == Int64(count * 110), "daily SQLite numeric total changed")
        try check(scan.sessions.reduce(0) { $0 + $1.amounts.totalTokens } == Int64(count * 110), "session SQLite numeric total changed")
        try check(scan.sessions.allSatisfy { $0.amounts.input == 100 && $0.amounts.output == 10 && $0.amounts.costUSD == nil }, "numeric buckets or unknown pricing changed")
        guard let local = scan.localUsage else { throw NSError(domain: "SQLite-local-records", code: 1) }
        try check(local.events.count == count && Set(local.events.map(\.eventID)).count == count, "single-worker scan lost distinct SQLite response identities")
        try check(local.events.reduce(0) { $0 + $1.amounts.totalTokens } == Int64(count * 110), "local event total differs from aggregate coverage")
        try check(scan.dayFingerprints.count == 1, "synthetic single-day fingerprint coverage changed")
        print("SQLite engine regression passed: real pinned CLI; every subprocess asserted cached-only pricing and one Rayon worker; 64 synthetic SQLite records fully retained as 64 day/session/events and 7040 tokens; unknown cost preserved; isolated home/cache; 10-second scan budget. Rare crash not reproduced; no private source scan or app smoke test.")
    }
}
