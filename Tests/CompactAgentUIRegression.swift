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

        let catalog = try text("Sources/ProviderCatalogView.swift")
        for removed in ["addAccount(provider, .llm)", "添加 API 账户", "自定义 API"] {
            precondition(!catalog.contains(removed), "API catalog entry remains: \(removed)")
        }
        let module = try text("Module.swift")
        let settings = try text("Host/Settings.swift") + text("Sources/Editors.swift")
        let store = try text("Sources/MonitorStore.swift")
        let backupSurfaces = [module, settings, store, host].joined(separator: "\n")
        for removed in ["exportBackup(", "restoreBackup(", "GaoSeries.token.import", "GaoSeries.token.export"] {
            precondition(!backupSurfaces.contains(removed), "Backup surface remains: \(removed)")
        }
        let claude = try text("Sources/ClaudeCode.swift")
        for removed in ["backupFile", ".bak.1", ".bak.2", ".bak.3"] {
            precondition(!claude.contains(removed), "Claude backup remains: \(removed)")
        }
        print("Compact Agent UI and no-backup regressions passed")
    }
}
