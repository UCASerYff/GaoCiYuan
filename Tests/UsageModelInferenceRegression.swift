import Foundation
import CryptoKit
import SQLite3

/// Actual pinned CLI, entirely synthetic SQLite input. Appending a second
/// concrete model invalidates the parser's whole-file sole-model inference;
/// it must not create a new identity for the earlier model-less observation.
@main struct UsageModelInferenceRegression {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "UsageModelInferenceRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func varint(_ value: UInt64) -> Data {
        var value = value, bytes = Data()
        while value > 127 { bytes.append(UInt8(value & 127) | 128); value >>= 7 }
        bytes.append(UInt8(value)); return bytes
    }
    static func number(_ field: UInt64, _ value: UInt64) -> Data { varint(field << 3) + varint(value) }
    static func blob(_ field: UInt64, _ value: Data) -> Data { varint((field << 3) | 2) + varint(UInt64(value.count)) + value }

    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("gaociyuan-model-inference-" + UUID().uuidString + ".noindex")
        let home = root.appendingPathComponent("home")
        let configuration = root.appendingPathComponent("configuration")
        let database = home.appendingPathComponent(".gemini/antigravity/conversations/fixture-session.db")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: configuration.appendingPathComponent("cache"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for filename in ["pricing-litellm.json", "pricing-openrouter.json", "pricing-models-dev.json"] {
            try JSONSerialization.data(withJSONObject: ["timestamp": Int(Date().timeIntervalSince1970), "data": [String: String]()])
                .write(to: configuration.appendingPathComponent("cache/" + filename))
        }
        let modelA = "gemini-3.8-flash-control"
        let modelB = "claude-opus-4-6-thinking"
        let start: UInt64 = 1_789_516_800
        func insert(index: Int64, model: String?, input: UInt64, output: UInt64) throws {
            var handle: OpaquePointer?
            try check(sqlite3_open(database.path, &handle) == SQLITE_OK, "synthetic SQLite open failed")
            defer { sqlite3_close(handle) }
            try check(sqlite3_exec(handle, "CREATE TABLE IF NOT EXISTS gen_metadata(idx INTEGER,data BLOB)", nil, nil, nil) == SQLITE_OK, "synthetic metadata table failed")
            // Deliberately omit usage.#11 responseId from every row. The
            // model-less row also has no chatModel.#19 or #21. Its identity is
            // the pinned patch's source/session/lane-position fallback.
            let usage = number(2, input) + number(9, output)
            var chat = blob(4, usage) + blob(9, blob(4, number(1, start + UInt64(index) * 60)))
            if let model { chat += blob(19, Data(model.utf8)) }
            let payload = blob(1, chat)
            var statement: OpaquePointer?
            try check(sqlite3_prepare_v2(handle, "INSERT INTO gen_metadata VALUES(?,?)", -1, &statement, nil) == SQLITE_OK, "synthetic metadata insert prepare failed")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, index)
            _ = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(payload.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            try check(sqlite3_step(statement) == SQLITE_DONE, "synthetic metadata insert failed")
        }
        try insert(index: 0, model: modelA, input: 100, output: 10)
        try insert(index: 1, model: nil, input: 1318, output: 0)

        let binary = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let quoted = "'" + binary.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let wrapper = root.appendingPathComponent("checked-engine")
        try Data("""
        #!/bin/zsh
        [[ "${TOKSCALE_PRICING_CACHE_ONLY:-}" == 1 && "${RAYON_NUM_THREADS:-}" == 1 ]] || exit 92
        exec \(quoted) "$@"
        """.utf8).write(to: wrapper)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let settings = UsageEngineConfiguration(enabledClientIDs: ["antigravity"], modelPrices: [
            .init(model: modelA, inputPerMillion: 0.75, outputPerMillion: 3)
        ])
        func scan() async throws -> UsageEngineScan {
            let work = Task {
                try await UsageEngine.scan(configuration: settings, engineURL: wrapper,
                    configurationDirectory: configuration, homeDirectory: home)
            }
            let deadline = Task { try await Task.sleep(nanoseconds: 10_000_000_000); work.cancel() }
            defer { deadline.cancel() }
            return try await work.value
        }
        let before = try await scan()
        guard let initial = before.localUsage,
              let inferred = initial.events.first(where: { $0.amounts.input == 1318 }) else {
            throw NSError(domain: "missing-inferred-fixture-event", code: 1)
        }
        try check(initial.events.count == 2 && inferred.model == modelA, "single concrete model did not infer the earlier model-less generation")
        try check(inferred.sessionID == "antigravity-extension:fixture-session", "source-specific session namespace changed")
        let basis = ["antigravity-extension", database.path, "fixture-session", "1"].joined(separator: "\0")
        let expectedID = SHA256.hash(data: Data(basis.utf8)).map { String(format: "%02x", $0) }.joined()
        try check(inferred.eventID == expectedID, "model-less generation did not use the expected source/session/position identity")
        try check(abs((inferred.amounts.costUSD ?? -1) - 0.0009885) < 0.000000000001, "initial inferred model lost its explicit synthetic price")

        try insert(index: 2, model: modelB, input: 17, output: 3)
        let after = try await scan()
        guard let changed = after.localUsage,
              let unknown = changed.events.first(where: { $0.eventID == inferred.eventID }) else {
            throw NSError(domain: "missing-stable-fixture-event", code: 1)
        }
        try check(changed.events.count == 3 && Set(changed.events.map(\.eventID)).count == 3, "appending one generation lost or duplicated source identities")
        try check(unknown.model == "unknown", "two concrete models did not retire sole-model inference")
        try check(unknown.client == inferred.client && unknown.sessionID == inferred.sessionID && unknown.timestamp == inferred.timestamp,
                  "model inference changed immutable event/session/time identity")
        var expectedAmounts = inferred.amounts; expectedAmounts.costUSD = nil
        try check(unknown.amounts == expectedAmounts && unknown.durationMS == inferred.durationMS,
                  "model inference degradation changed numeric usage or invented a known cost")
        try check(changed.events.contains(where: { $0.amounts.input == 100 && $0.model == modelA }),
                  "explicit control model was incorrectly canonicalized or stripped")
        // The CLI may canonicalize the known Claude spelling. It must still
        // retain this generation as a concrete model distinct from model A.
        try check(changed.events.contains(where: { $0.amounts.input == 17 && $0.model != "unknown" && $0.model != modelA }),
                  "new explicit model generation was omitted or lost its attribution")
        try check(changed.events.reduce(0) { $0 + $1.amounts.totalTokens } == initial.events.reduce(0) { $0 + $1.amounts.totalTokens } + 20,
                  "source totals changed beyond the appended generation")
        try check(changed.coverageDays.contains(where: { $0.model == "unknown" && $0.amounts.input == 1318 }),
                  "raw source coverage did not retain the unknown-model observation")
        print("Model inference regression passed: actual pinned CLI; isolated home/config; per-process cached-only/one-worker assertions; same source/session/position event inferred as control model before append and unknown afterwards; unchanged identity/time/numeric counts; old estimated cost becomes unknown; explicit control label preserved; one new generation adds exactly 20 tokens. No private source, app launch or smoke test.")
    }
}
