import Foundation

enum TokenBundle { static let bundle = Bundle.main }
enum AlertRules {
    static func attention(_ account: Account, threshold: Double, at: Date) -> [String] { [] }
}

@main struct AntigravityDesktopQuotaRegression {
    static func main() throws {
        typealias Desktop = AntigravityDesktopQuota
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let email = "owner@example.com"
        let lines = [
            "Gemini Models", "Models within this group: Gemini Flash and Gemini Pro",
            "Weekly Limit Remaining: 75.5%", "Resets in 12 hours", "Five Hour Limit Remaining", "60%",
            "Claude and GPT models", "Weekly Limit Used: 20%", "Five Hour Limit Remaining", "N/A",
            "Gemini 4 Argon", "Weekly Limit Remaining: 0%",
        ]
        func snapshot(_ lines: [String], title: String = "View Usage", route: Desktop.Route = .standalone) throws -> UsageSnapshot {
            try Desktop.parsePane(title: title, lines: lines, route: route, expectedEmail: email, observedAt: date)
        }
        func rejects(_ failure: Desktop.Failure, _ action: () throws -> UsageSnapshot) {
            do {
                _ = try action()
                preconditionFailure("Expected a denied desktop quota reading")
            } catch let caught as Desktop.Failure {
                precondition(caught == failure, "Unexpected desktop quota failure: \(caught)")
            } catch {
                preconditionFailure("Unexpected desktop quota error: \(error)")
            }
        }

        let standalone = try snapshot(["Signed in as OWNER@Example.com"] + lines)
        let embedded = try snapshot(["当前 Google 账号：", email] + lines,
                                    title: "Antigravity 模型额度", route: .embedded)
        precondition(standalone.source == Desktop.Route.standalone.snapshotSource)
        precondition(embedded.source == Desktop.Route.embedded.snapshotSource)
        precondition(standalone.quotas == embedded.quotas)
        precondition(standalone.observedAt == date && standalone.isFreshObservation(at: date))
        precondition(standalone.quotas.map(\.usedPercent) == [24.5, 40, 20, 100])
        precondition(standalone.quotas.map(\.windowSeconds) == [604_800, 18_000, 604_800, 604_800])
        precondition(standalone.quotas.allSatisfy { $0.resetsAt == nil })
        precondition(Desktop.Route(.file) == nil && Desktop.Route(.geminiApp) == .embedded)
        precondition(Desktop.Route.standalone.bundleIdentifier == "com.google.antigravity")
        precondition(Desktop.Route.embedded.bundleIdentifier == "com.google.GeminiMacOS")

        rejects(.paneNotAvailable) { try snapshot(["Signed in as \(email)"] + lines, title: "Gemini Usage Limits", route: .embedded) }
        rejects(.paneNotAvailable) { try snapshot(["Signed in as \(email)"] + lines, route: .embedded) }
        rejects(.paneNotAvailable) { try snapshot(["Signed in as \(email)"] + lines, title: "Google Settings") }
        rejects(.accountNotVerified) { try snapshot(lines) }
        rejects(.accountNotVerified) { try snapshot(["Google Account", email] + lines) }
        rejects(.accountNotVerified) { try snapshot(["Signed in as guest"] + lines) }
        rejects(.accountNotVerified) { try snapshot(["Signed in as owner@example.com.evil.test"] + lines) }
        rejects(.accountNotVerified) { try snapshot(["Signed in as \(email)", "Current Google Account: another@example.com"] + lines) }
        rejects(.paneNotAvailable) { try snapshot(["Signed in as \(email)", "Gemini Models", "Weekly Limit Remaining: 101%"] ) }
        rejects(.paneNotAvailable) { try snapshot(["Signed in as \(email)", "Gemini Models", "Weekly Limit Remaining: 45%", "Weekly Limit Remaining: 55%"] ) }
        rejects(.paneNotAvailable) { try snapshot(["Signed in as \(email)", "Gemini Models", "Another Model Group", "Weekly Limit Remaining: 75%"] ) }
        rejects(.paneNotAvailable) { try snapshot(["Signed in as \(email)", "Gemini Models", "Weekly Limit Remaining", "Guest"] ) }
        rejects(.invalidAccount) {
            try Desktop.parsePane(title: "View Usage", lines: lines, route: .standalone,
                                  expectedEmail: "owner example.com", observedAt: date)
        }
        print("PASS: desktop Antigravity source scope, account evidence, quota labels, unknown groups and limits.")
    }
}
