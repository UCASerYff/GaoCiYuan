import Foundation

@main struct AntigravityStatusLineRegression {
    static func main() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("gaociyuan-cli-status-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: directory) }
        let now = Date().addingTimeInterval(-20)
        let email = "monitor@example.com"
        let digest = AntigravityStatusLine.digest(for: email)!
        let sample = Data(#"{"product":"antigravity","email":"MONITOR@example.com","agent_state":"idle","quota":{"gemini-weekly":{"remaining_fraction":0.75,"reset_in_seconds":45},"gemini-argon-wtu-weekly":{"remaining_fraction":0.5,"reset_in_seconds":900},"3p-5h":{"remaining_fraction":0.32,"disabled":true},"unknown-pool":{"remaining_amount":42}},"cwd":"project-secret","conversation_title":"private title","transcript_path":"private path"}"#.utf8)
        try AntigravityStatusLine.capture(sample, expectedDigest: digest, directory: directory, now: now)

        let observation = AntigravityStatusLine.snapshot(email: email, directory: directory, now: now)
        precondition(observation?.source == AntigravityStatusLine.source)
        precondition(observation?.observedAt == now)
        precondition(observation?.quotas.map(\.id) == ["antigravity-gemini-argon-wtu-weekly", "antigravity-gemini-weekly"])
        precondition(observation?.quotas.last?.remaining == 75)
        precondition(observation?.quotas.last?.resetsAt == now.addingTimeInterval(45))
        precondition(AntigravityStatusLine.snapshot(email: "other@example.com", directory: directory, now: now) == nil)
        let record = directory.appendingPathComponent(digest + ".json")
        let persisted = try String(contentsOf: record, encoding: .utf8)
        for privateValue in ["monitor@example.com", "project-secret", "private title", "private path", "transcript_path"] {
            precondition(!persisted.contains(privateValue))
        }

        let foreign = Data(String(decoding: sample, as: UTF8.self).replacingOccurrences(of: "\"antigravity\"", with: "\"gemini\"").utf8)
        let signingIn = Data(String(decoding: sample, as: UTF8.self).replacingOccurrences(of: "\"idle\"", with: "\"authenticating\"").utf8)
        let anotherAccount = Data(String(decoding: sample, as: UTF8.self).replacingOccurrences(of: "MONITOR@example.com", with: "other@example.com").utf8)
        for invalid in [foreign, signingIn, anotherAccount] {
            try AntigravityStatusLine.capture(invalid, expectedDigest: digest, directory: directory, now: now.addingTimeInterval(10))
        }
        let preserved = try String(contentsOf: record, encoding: .utf8)
        precondition(preserved == persisted)
        precondition(AntigravityStatusLine.snapshot(email: "other@example.com", directory: directory, now: now) == nil)
        precondition(AntigravityStatusLine.snapshot(email: email, directory: directory, now: now.addingTimeInterval(46))?.quotas.count == 1)
        precondition(AntigravityStatusLine.snapshot(email: email, directory: directory, now: now.addingTimeInterval(901)) == nil)

        let config = AntigravityStatusLine.configuration(executable: "/Applications/It's safe.app/Contents/MacOS/App", email: email)!
        precondition(config.contains("stack_with_default") && config.contains("--capture-antigravity-status --antigravity-account \(digest)"))
        precondition(!config.contains(email) && AntigravityStatusLine.configuration(executable: "relative/path", email: email) == nil)
        print("Antigravity CLI status-line account matching, privacy and aging passed.")
    }
}
