import Foundation
// This file is only linked into standalone offline scanner regressions.
enum CursorBridge {
    struct Session { var cookie: String }
    static func session() -> Session? { nil }
}
