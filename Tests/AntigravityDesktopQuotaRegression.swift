import Foundation
import Security

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
        precondition(standalone.source == Desktop.Route.standalone.snapshotSource)
        precondition(standalone.observedAt == date && standalone.isFreshObservation(at: date))
        precondition(standalone.quotas.map(\.usedPercent) == [24.5, 40, 20, 100])
        precondition(standalone.quotas.map(\.windowSeconds) == [604_800, 18_000, 604_800, 604_800])
        precondition(standalone.quotas.allSatisfy { $0.resetsAt == nil })
        precondition(Desktop.Route(.file) == nil && Desktop.Route(.geminiApp) == .embedded && Desktop.Route(.agentLocal) == .standalone)
        precondition(Desktop.Route.standalone.bundleIdentifier == "com.google.antigravity")
        precondition(Desktop.Route.embedded.bundleIdentifier == "com.google.GeminiMacOS")
        for route in [Desktop.Route.embedded, .standalone] {
            var requirement: SecRequirement?
            let rule = route.signingRequirement
            precondition(SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess && requirement != nil)
            precondition(rule.contains("identifier \"\(route.bundleIdentifier)\""))
            precondition(rule.contains("certificate leaf[subject.OU] = \"EQHXZ8M8AV\""))
        }
        precondition(Desktop.Route.embedded.signingRequirement != Desktop.Route.standalone.signingRequirement)
        rejects(.paneNotAvailable) {
            try snapshot(["当前 Google 账号：", email] + lines, title: "Antigravity 模型额度", route: .embedded)
        }

        let compact = "Gemini Models Weekly limit 67% left Resets in 5d 11h 5h limit 100% left"
        let compactReading = try snapshot(["Signed in as \(email)", "Usage", compact],
                                          title: "Antigravity Usage", route: .embedded)
        precondition(compactReading.source == Desktop.Route.embedded.snapshotSource)
        precondition(compactReading.quotas.map(\.id) == ["gemini-models-weekly", "gemini-models-5h"])
        precondition(compactReading.quotas.map(\.remaining) == [67, 100])
        precondition(compactReading.quotas.map(\.windowSeconds) == [604_800, 18_000])
        precondition(compactReading.quotas[0].resetsAt == date.addingTimeInterval(5 * 86_400 + 11 * 3_600))
        precondition(compactReading.quotas[1].resetsAt == nil)
        let splitReading = try snapshot(["Signed in as \(email)", "Gemini Models", "Weekly limit", "67% left",
                                         "Resets in", "5d 11h", "5h limit", "100% left",
                                         "Claude and GPT Models", "5h limit: 35.5% left Resets in 2h 17m",
                                         "Gemini 4 Argon Weekly limit 100% left"], title: "Antigravity Usage", route: .embedded)
        precondition(Array(splitReading.quotas.prefix(2)) == compactReading.quotas)
        precondition(splitReading.quotas[2].id == "claude-and-gpt-models-5h")
        precondition(splitReading.quotas[2].remaining == 35.5)
        precondition(splitReading.quotas[2].resetsAt == date.addingTimeInterval(2 * 3_600 + 17 * 60))
        precondition(splitReading.quotas[3].id == "gemini-4-argon-weekly")
        for invalid in [
            "Gemini Models Weekly limit 101% left 5h limit 100% left",
            "Gemini Models Weekly limit 67% left Resets in 5d 11h 11h 5h limit 100% left",
            "Gemini Models Weekly limit 67% left Resets in tomorrow 5h limit 100% left",
            "Gemini Models Weekly limit 67% left Resets in 5d 24h 5h limit 100% left",
            "Gemini Models Weekly limit 67% left 5h limit 80% left Resets in 6h",
            "Gemini Models Weekly limit 67% left Weekly limit 66% left 5h limit 100% left",
            "Unrecognized Models Weekly limit 67% left 5h limit 100% left",
        ] {
            rejects(.paneNotAvailable) {
                try snapshot(["Signed in as \(email)", invalid], title: "Antigravity Usage", route: .embedded)
            }
        }
        rejects(.accountNotVerified) { try snapshot([compact], title: "Antigravity Usage", route: .embedded) }
        rejects(.paneNotAvailable) { try snapshot(["Signed in as \(email)", compact]) }

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
        print("PASS: desktop Antigravity source scope, account evidence, compact quota windows and reset countdowns.")
    }
}
