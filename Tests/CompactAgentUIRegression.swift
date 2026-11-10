import Foundation

@main struct CompactAgentUIRegression {
    static func text(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }
    static func main() throws {
        let content = try text("Sources/ContentView.swift")
        for required in [
            "case overview = \"总览\"", "agent = \"Agent 软件\"",
            "analytics = \"用量分析\"", "providers = \"平台接入\"",
            "private var navigation", ".frame(minWidth: 880, minHeight: 560)"
        ] {
            precondition(content.contains(required), "Missing compact UI contract: \(required)")
        }
        for removed in [
            "case overview = \"用量总览\"", "llm = \"LLM\"",
            "history = \"用量记录\"", "AccountHistoryChart", "sidebarHidden"
        ] {
            precondition(!content.contains(removed), "Removed UI remains: \(removed)")
        }
        let theme = try text("Sources/Theme.swift")
        precondition(theme.contains("dynamicProvider"), "Theme must support dynamic appearances")
        let host = try text("Host/AppMain.swift")
        precondition(host.contains("minWidth:880,minHeight:560"), "Main window is not compact")
        print("Compact Agent UI regression passed")
    }
}
