import Foundation
import SQLite3
enum DailyBackup {
    enum SQLiteError: LocalizedError {
        case openFailed(String)
        case vacuumFailed(String)
        var errorDescription: String? {
            switch self {
            case .openFailed(let p): return "无法只读打开 \(p)"
            case .vacuumFailed(let d): return "VACUUM INTO 失败：\(d)"
            }
        }
    }

    static func vacuumInto(source: URL, destination: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(source.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            throw SQLiteError.openFailed(source.lastPathComponent)
        }
        defer { sqlite3_close(db) }
        let escaped = destination.path.replacingOccurrences(of: "'", with: "''")
        var errorMessage: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(db, "VACUUM INTO '\(escaped)'", nil, nil, &errorMessage)
        if code != SQLITE_OK {
            let detail = errorMessage.map { String(cString: $0) } ?? "code \(code)"
            sqlite3_free(errorMessage)
            throw SQLiteError.vacuumFailed(detail)
        }
    }

    /// 对快照副本跑 PRAGMA integrity_check，返回首行结果（正常为 "ok"）。
    static func integrityCheck(_ url: URL) -> String {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return "无法打开" }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK else { return "无法执行校验" }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return "无结果" }
        return String(cString: text)
    }

}
