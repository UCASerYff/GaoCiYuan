import Foundation

// Keep the report fixture independent of the application's alert and bundle services.
enum TokenBundle { static let bundle = Bundle.main }
enum AlertRules {
    static func attention(_ account: Account, threshold: Double, at: Date) -> [String] { [] }
}

@main struct AntigravityUsageReportRegression {
    static func main() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func fetch(_ text: String) throws -> UsageSnapshot {
            try AntigravityUsageReport.parseStandalone(Data(text.utf8), importedAt: date)
        }
        let report = try fetch("""
            Antigravity Usage
            Gemini Models
            Five Hour Limit Remaining: 75.5%
            Weekly Limit Remaining:
            60%

            Claude and GPT models:
            Five Hour Limit Remaining: 75.5%
            Weekly Limit Remaining: 0%
            """)
        precondition(report.source == UsageSnapshot.standaloneAntigravityManualSource && report.observedAt == date)
        precondition(report.isHistoricalAntigravityReading && !report.isFreshObservation(at: date))
        precondition(report.quotas.map(\.usedPercent) == [24.5, 40, 24.5, 100])
        precondition(report.quotas.map(\.windowSeconds) == [18_000, 604_800, 18_000, 604_800])
        precondition(report.quotas.allSatisfy { $0.resetsAt == nil && !$0.exhausted })
        precondition(Set(report.quotas.map(\.id)).count == 4, "Equal observations from distinct pools must not merge")
        let single = try fetch("\u{FEFF}│ \u{001B}[31mGemini Models\u{001B}[0m │\r\n│ Weekly Limit Remaining │ ███ 100% │")
        precondition(single.source == report.source)
        precondition(single.quotas.count == 1 && single.quotas[0].usedPercent == 0)
        let unknown = try fetch("Gemini Models\nWeekly Limit Remaining: 75%\nOther Models\nFive Hour Limit Remaining: 12%")
        precondition(unknown.quotas.count == 1)
        let partial = try fetch("Gemini Models\nFive Hour Limit Remaining: N/A\nWeekly Limit Remaining: 50%\nClaude and GPT models\nFive Hour Limit Remaining:\n—\nWeekly Limit Remaining: 77%")
        precondition(partial.quotas.map(\.usedPercent) == [50, 23], "Unknown windows must not suppress known windows or become full quotas")
        let fixture = try String(contentsOfFile: "Tests/Fixtures/AntigravityCLIUsage.json", encoding: .utf8)
        let structured = try fetch("\u{FEFF}" + fixture)
        precondition(structured.source == UsageSnapshot.standaloneAntigravityJSONSource && structured.isHistoricalAntigravityReading)
        precondition(structured.quotas.map(\.id) == ["gemini-weekly", "gemini-5h", "3p-weekly", "gemini-argon-wtu-weekly"])
        precondition(structured.quotas.map(\.usedPercent) == [25, 37.5, 100, 50])
        precondition(structured.quotas.map(\.windowSeconds) == [604_800, 18_000, 604_800, 604_800])
        precondition(structured.quotas.allSatisfy { $0.resetsAt != nil && !$0.exhausted })
        let manual = try AntigravityUsageReport.recordEmbedded([
            .init(title: "Visible quota", remaining: "62.5"),
            .init(title: "Another quota", remaining: "0", window: .weekly),
            .init(),
        ], importedAt: date)
        precondition(manual.source == UsageSnapshot.embeddedAntigravityEntrySource && manual.observedAt == date && manual.isHistoricalAntigravityReading)
        precondition(manual.quotas.map(\.windowSeconds) == [nil, 604_800] && manual.quotas.map(\.usedPercent) == [37.5, 100])
        do {
            _ = try AntigravityUsageReport.recordEmbedded([.init(title: "Visible quota", remaining: "150")])
            preconditionFailure("Invalid manual percentage was accepted")
        } catch is MonitorError {}
        for text in [
            "Gemini Pro\nWeekly Limit Remaining: 99%",
            "Gemini Models\nWeekly usage: 0%",
            "Gemini Models\nWeekly Limit Remaining:",
            "Gemini Models\nWeekly Limit Remaining\nFive Hour Limit Remaining: 12%",
            "Gemini Models\nWeekly Limit Remaining: N/A",
            "Gemini Models\nWeekly Limit Remaining: N/A\nWeekly Limit Remaining: 85%",
            "Gemini Models\nWeekly Limit Remaining85%",
            "Gemini Models\nWeekly Limit Remaining: 106%",
            "Gemini Models\nWeekly Limit Remaining: 60%\nWeekly Limit Remaining: 55%",
            "Gemini Models\nWeekly Limit Remaining: 60% remaining or 40% used",
            #"{"product":"antigravity","quota":{"gemini-weekly":{"remaining_fraction":0.8}}}"#,
            fixture.replacingOccurrences(of: #""name": "usage""#, with: #""name": "model""#),
            fixture.replacingOccurrences(of: #""num_turns": 0"#, with: #""num_turns": 1"#),
            fixture.replacingOccurrences(of: #""total_tokens": 0"#, with: #""total_tokens": 10"#),
            fixture.replacingOccurrences(of: #""remaining_fraction": 0.75"#, with: #""remaining_fraction": true"#),
            fixture.replacingOccurrences(of: "2026-10-21T15:42:30Z", with: "next week"),
            fixture.replacingOccurrences(of: "gemini-argon-wtu-weekly", with: "gemini-weekly"),
            String(repeating: "x", count: AntigravityUsageReport.maxBytes + 1)
        ] {
            do {
                _ = try fetch(text)
                preconditionFailure("Invalid quota output was accepted")
            } catch is MonitorError {}
        }
        let embedded = AgentPlatformTable.geminiEmbeddedAntigravity
        let standalone = AgentPlatformTable.standaloneAntigravity
        precondition(AgentPlatformTable.matchesRunning(embedded, bundle: "com.google.geminimacos", name: "renamed"))
        precondition(!AgentPlatformTable.matchesRunning(standalone, bundle: "com.google.geminimacos", name: "gemini"))
        precondition(AgentPlatformTable.matchesRunning(standalone, bundle: "com.google.antigravity", name: "renamed"))
        precondition(!AgentPlatformTable.matchesRunning(embedded, bundle: "com.google.antigravity", name: "antigravity"))
        precondition(!AgentPlatformTable.matchesRunning(standalone, bundle: "", name: "agy"))
        precondition(embedded.cli.isEmpty && standalone.cli.contains { $0.hasSuffix("/agy") })
        precondition(!AgentPlatformTable.isStandaloneAntigravityCLIPath(URL(fileURLWithPath: "/fixture/Gemini.app/Contents/Helpers/agy")))
        precondition(AgentPlatformTable.isStandaloneAntigravityCLIPath(URL(fileURLWithPath: "/fixture/Antigravity.app/Contents/Helpers/agy")))
        print("PASS: separate Antigravity detection and report origins, explicit quota windows, unknowns, historical-only timing, and size limit.")
    }
}
