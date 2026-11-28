import Foundation

// Keep the report fixture independent of the application's alert and bundle services.
enum TokenBundle { static let bundle = Bundle.main }
enum AlertRules {
    static func attention(_ account: Account, threshold: Double, at: Date) -> [String] { [] }
}

@main struct AntigravityUsageReportRegression {
    static func main() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func fetch(_ text: String, source: String = AntigravityUsageReport.embeddedSource) throws -> UsageSnapshot {
            try AntigravityUsageReport.parse(Data(text.utf8), source: source, observedAt: date)
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
        precondition(report.source == AntigravityUsageReport.embeddedSource && report.observedAt == date)
        precondition(report.quotas.map(\.usedPercent) == [24.5, 40, 24.5, 100])
        precondition(report.quotas.map(\.windowSeconds) == [18_000, 604_800, 18_000, 604_800])
        precondition(report.quotas.allSatisfy { $0.resetsAt == nil && !$0.exhausted })
        precondition(Set(report.quotas.map(\.id)).count == 4, "Equal observations from distinct pools must not merge")
        let single = try fetch("│ \u{001B}[31mGemini Models\u{001B}[0m │\r\n│ Weekly Limit Remaining: 100% │",
                               source: AntigravityUsageReport.importedSource)
        precondition(single.source != report.source && single.quotas.count == 1 && single.quotas[0].usedPercent == 0)
        let unknown = try fetch("Gemini Models\nWeekly Limit Remaining: 75%\nOther Models\nFive Hour Limit Remaining: 12%")
        precondition(unknown.quotas.count == 1)
        for text in [
            "Gemini Pro\nWeekly Limit Remaining: 99%",
            "Gemini Models\nWeekly usage: 0%",
            "Gemini Models\nWeekly Limit Remaining:",
            "Gemini Models\nWeekly Limit Remaining\nFive Hour Limit Remaining: 12%",
            "Gemini Models\nWeekly Limit Remaining: N/A",
            "Gemini Models\nWeekly Limit Remaining: 106%",
            "Gemini Models\nWeekly Limit Remaining: 60%\nWeekly Limit Remaining: 55%",
            "Gemini Models\nWeekly Limit Remaining: 60% remaining or 40% used",
            String(repeating: "x", count: AntigravityUsageReport.maxBytes + 1)
        ] {
            do {
                _ = try fetch(text)
                preconditionFailure("Invalid quota output was accepted")
            } catch is MonitorError {}
        }
        let capability = AntigravityUsageReport.supportsHeadlessUsage
        precondition(capability(Data("--prompt <text>\n  /usage    Show limits\n".utf8)))
        precondition(!capability(Data("--prompt <text>\nNo built-ins listed\n".utf8)))
        precondition(!capability(Data("--prompt <text>\nSee /usage for examples\n".utf8)))
        precondition(!capability(Data("/usage    Show limits\n".utf8)))
        print("PASS: Antigravity report source, explicit shared pools and windows, percentage direction, no invented readings, CLI capability gate.")
    }
}
