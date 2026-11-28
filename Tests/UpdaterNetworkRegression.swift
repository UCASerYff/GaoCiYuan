import Foundation
import CryptoKit

// Standalone regression: only fixture HTTP and temporary files. No app/UI,
// configured update source, keychain, or personal preferences are accessed.
enum TokenBundle { static let defaults = UserDefaults(suiteName: "com.gaoseries.GaoCiYuan.test.UpdaterNetwork")! }
enum AppInfo { static let version = "4.15"; static let build = "17" }
func L(_ value: String) -> String { value }

@main struct UpdaterNetworkRegression {
    enum FixtureError: Error { case failed }
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "UpdaterNetworkRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    actor MockHTTP {
        var metadata: Data; var package: Data
        var metadataCalls = 0, packageCalls = 0
        var delay: UInt64 = 20_000_000
        var status = 200
        init(metadata: Data, package: Data) { self.metadata = metadata; self.package = package }
        func setDelay(_ value: UInt64) { delay = value }
        func fetch(_ request: URLRequest, _ limit: Int, _ timeout: TimeInterval,
                   _ resource: UpdateService.Resource, _ progress: UpdateService.Progress?) async throws -> (Data, HTTPURLResponse) {
            try check(request.url?.host == "updates.fixture.invalid", "unexpected real URL")
            try check(limit > 0 && timeout > 0, "missing request budget")
            let body: Data
            switch resource {
            case .metadata:
                metadataCalls += 1; body = metadata
                try check(limit <= 256 * 1024, "metadata allowance too large")
            case .package:
                packageCalls += 1; body = package
                try check(limit <= 128 * 1024 * 1024, "package allowance too large")
            }
            try await Task.sleep(nanoseconds: delay)
            try Task.checkCancellation()
            progress?(Int64(body.count), Int64(body.count))
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        func calls() -> (Int, Int) { (metadataCalls, packageCalls) }
    }
    static func failure(_ message: String, operation: () async throws -> Void) async throws {
        do { try await operation() } catch { return }
        throw NSError(domain: "UpdaterNetworkRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    @MainActor static func checkBuildOrdering(source: URL, remote: URL, cache: URL) async throws {
        func enclosure(_ attrs: String = "") -> String {
            "<enclosure url=\"\(remote.absoluteString)\" \(attrs)/>"
        }
        func feed(_ items: [String]) -> Data {
            let entries = items.map { "<item>\($0)</item>" }.joined()
            return Data("<rss xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel>\(entries)</channel></rss>".utf8)
        }
        func latest(_ items: [String]) -> AppcastItem? {
            latestAppcastUpdate(parseAppcast(feed(items)), marketingVersion: AppInfo.version, buildVersion: AppInfo.build)
        }
        func entry(_ display: String, _ build: String) -> String {
            "<sparkle:shortVersionString>\(display)</sparkle:shortVersionString><sparkle:version>\(build)</sparkle:version>" + enclosure()
        }

        let legacy = "<title>Maintenance notes</title>" + enclosure("sparkle:version=\"18\" sparkle:shortVersionString=\"4.15\"")
        let modern = "<title>Version 4.15 (maintenance)</title>" +
            enclosure("sparkle:version=\"16\" sparkle:shortVersionString=\"4.14\"") +
            "<sparkle:version> 19 </sparkle:version><sparkle:shortVersionString>4.15</sparkle:shortVersionString>"
        let same = entry("4.15.0", "17.0")
        let older = entry("4.15", "16")
        let rollback = entry("4.14", "25")
        let inconsistent = entry("4.16", "16")
        let malformed = entry("4.15", "18beta")

        try check(latest([legacy])?.versionLabel == "4.15 (18)", "Legacy enclosure attributes were masked by the title")
        try check(latest([modern, entry("4.16", "18"), legacy, same, older, rollback])?.versionLabel == "4.15 (19)",
                  "Child elements failed to override enclosure data or the highest compatible build was not selected")
        try check(latest([same, older, rollback, inconsistent, malformed]) == nil,
                  "A same, older, malformed or inconsistent build was offered")
        try check(latest(["<title>Maintenance</title>" + enclosure("sparkle:version=\"18\"")])?.buildVersion == "18",
                  "An internal-build-only feed was ignored")
        try check(latest(["<title>V4.17</title>" + enclosure()])?.versionLabel == "V4.17" &&
                  latest([enclosure("sparkle:version=\"4.18\"")])?.versionLabel == "4.18" &&
                  latest(["<title>4.18</title>" + enclosure("sparkle:version=\"4.18\"")])?.versionLabel == "4.18",
                  "A legacy display-only or title-only feed lost compatibility")

        let windows = "<enclosure url=\"https://updates.fixture.invalid/windows.zip\" sparkle:os=\"windows\" " +
            "sparkle:version=\"99\" sparkle:shortVersionString=\"9.99\" sparkle:edSignature=\"windows-fixture\" length=\"1024\"/>"
        let unlabeledWindows = "<enclosure url=\"https://updates.fixture.invalid/GaoCiYuan-Windows-x64-Setup.exe\" " +
            "sparkle:version=\"99\" sparkle:edSignature=\"windows-fixture\" length=\"1024\"/>"
        let mac = enclosure("sparkle:os=\"macos\" sparkle:version=\"20\" sparkle:shortVersionString=\"4.15\" " +
            "sparkle:edSignature=\"mac-fixture\" length=\"2048\"")
        let itemHeading = "<title>Version 4.15 (cross-platform)</title>"
        for combined in [mac + windows + unlabeledWindows, windows + unlabeledWindows + mac] {
            let candidate = latest([itemHeading + combined, "<title>Version 9.99</title>" + windows])
            try check(candidate?.versionLabel == "4.15 (20)" && candidate?.url == remote &&
                      candidate?.signatureBase64 == "mac-fixture" && candidate?.expectedLength == 2048,
                      "A mixed appcast failed to keep the Mac enclosure tuple together")
        }
        try check(latest(["<title>Version 9.99</title>" + windows, "<title>Version 9.99</title>" + unlabeledWindows,
                          "<sparkle:os>windows</sparkle:os><title>Version 9.99</title>" + enclosure()]) == nil,
                  "A Windows-only item was offered to macOS")

        let mock = MockHTTP(metadata: feed([same, modern, legacy, rollback]), package: Data())
        let checker = UpdateChecker(service: UpdateService(cacheDirectory: cache, fetcher: { try await mock.fetch($0, $1, $2, $3, $4) }))
        await checker.checkNow(userInitiated: false)
        try check(checker.availableVersion == "4.15 (19)" && !checker.downloading && checker.lastError == nil,
                  "Scheduled updater did not offer a higher build of the installed marketing version")
        let calls = await mock.calls()
        try check(calls == (1, 0), "Same-version availability initiated a package download")
        try check(!FileManager.default.fileExists(atPath: cache.path), "Metadata wrote to the download cache")
        checker.stop()
        try check(source.absoluteString == UpdateChecker.appcastURLString, "Fixture update source changed")
    }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gaociyuan-updater-regression-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(string: "https://updates.fixture.invalid/appcast.xml")!
        let remote = URL(string: "https://updates.fixture.invalid/latest.zip")!
        let package = Data(repeating: 0x51, count: 2048)
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32))
        let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()
        let signature = try privateKey.signature(for: package).base64EncodedString()
        let xml = Data("<rss xmlns:sparkle=\"urn:fixture\"><channel><item><enclosure url=\"\(remote.absoluteString)\" sparkle:shortVersionString=\"4.99\" sparkle:edSignature=\"\(signature)\" length=\"\(package.count)\"/></item></channel></rss>".utf8)
        let mock = MockHTTP(metadata: xml, package: package)
        let service = UpdateService(cacheDirectory: root.appendingPathComponent("good"), fetcher: { try await mock.fetch($0, $1, $2, $3, $4) })
        let items = try await service.checkMetadata(source)
        _ = try await service.checkMetadata(source)
        let testDomain = "com.gaoseries.GaoCiYuan.test.UpdaterNetwork"
        defer { TokenBundle.defaults.removePersistentDomain(forName: testDomain) }
        TokenBundle.defaults.set(source.absoluteString, forKey: "updateAppcastURL")
        let checker = UpdateChecker(service: service)
        await checker.checkNow(userInitiated: false)
        try check(checker.availableVersion == "4.99" && !checker.downloading, "scheduled metadata check did not record availability independently")
        checker.stop()
        let metadataCalls = await mock.calls()
        try check(metadataCalls == (1, 0), "checking a new release downloaded its package or bypassed metadata cache")
        try check(items.count == 1 && items[0].expectedLength == 2048, "appcast length/version parse failed")
        let item = items[0]
        let cache = root.appendingPathComponent("good")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let oldPackages = ["a", "b", "c"].map { cache.appendingPathComponent(String(repeating: $0, count: 64) + ".zip") }
        for url in oldPackages { try Data("old package".utf8).write(to: url) }
        async let first = service.downloadExplicitly(item, publicKey: publicKey)
        async let second = service.downloadExplicitly(item, publicKey: publicKey)
        let (firstURL, secondURL) = try await (first, second)
        try check(firstURL == secondURL, "same version download was not shared")
        try check(oldPackages.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "old update packages were retained as backups")
        let afterFlight = await mock.calls()
        try check(afterFlight == (1, 1), "concurrent explicit downloads duplicated network traffic")
        let restarted = UpdateService(cacheDirectory: root.appendingPathComponent("good"), fetcher: { try await mock.fetch($0, $1, $2, $3, $4) })
        _ = try await restarted.downloadExplicitly(item, publicKey: publicKey)
        let afterCache = await mock.calls()
        try check(afterCache == (1, 1), "verified package was downloaded again after service restart")
        try Data("tampered cache".utf8).write(to: firstURL)
        _ = try await restarted.downloadExplicitly(item, publicKey: publicKey)
        let restoredPackage = try Data(contentsOf: firstURL)
        try check(restoredPackage == package, "tampered cached ZIP was accepted")
        let afterTamper = await mock.calls()
        try check(afterTamper == (1, 2), "tampered cache was not fetched and verified again")
        try await failure("missing public key caused a package fetch") { _ = try await service.downloadExplicitly(item, publicKey: "") }
        var absentSignature = item; absentSignature.signatureBase64 = nil
        try await failure("missing signature caused a package fetch") { _ = try await service.downloadExplicitly(absentSignature, publicKey: publicKey) }
        var huge = item; huge.expectedLength = 129 * 1024 * 1024
        try await failure("oversized declared package was fetched") { _ = try await service.downloadExplicitly(huge, publicKey: publicKey) }
        let preflight = await mock.calls()
        try check(preflight == (1, 2), "invalid key/signature/size should fail before network")
        var wrong = item; wrong.signatureBase64 = Data(repeating: 0xFF, count: 64).base64EncodedString()
        try await failure("invalid package signature accepted") { _ = try await service.downloadExplicitly(wrong, publicKey: publicKey) }
        let afterWrong = await mock.calls()
        try await failure("same failed version bypassed cooldown") { _ = try await service.downloadExplicitly(wrong, publicKey: publicKey) }
        let afterCooldown = await mock.calls()
        try check(afterWrong == afterCooldown, "failed same-version package was redownloaded during cooldown")
        let goodStillExists = try Data(contentsOf: firstURL)
        try check(goodStillExists == package, "signature failure damaged previous verified package")

        let slow = MockHTTP(metadata: xml, package: package); await slow.setDelay(2_000_000_000)
        let cancelled = UpdateService(cacheDirectory: root.appendingPathComponent("cancelled"), fetcher: { try await slow.fetch($0, $1, $2, $3, $4) })
        let task = Task { try await cancelled.downloadExplicitly(item, publicKey: publicKey) }
        defer { task.cancel() }
        let startDeadline = ProcessInfo.processInfo.systemUptime + 3
        while await slow.calls().1 == 0 {
            try check(ProcessInfo.processInfo.systemUptime < startDeadline, "download fixture never started")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        task.cancel()
        do { _ = try await task.value; throw FixtureError.failed } catch is CancellationError { }
        let cancelledCalls = await slow.calls()
        try check(cancelledCalls.1 == 1 && !FileManager.default.fileExists(atPath: root.appendingPathComponent("cancelled").path), "cancelled package continued or created a cache")
        await slow.setDelay(0)
        _ = try await cancelled.downloadExplicitly(item, publicKey: publicKey)
        let afterCancellationRetry = await slow.calls()
        try check(afterCancellationRetry.1 == 2, "cancellation incorrectly started failure backoff")

        var tiny = UpdateService.Limits(); tiny.packageBytes = 16; tiny.metadataBytes = 16
        let limited = UpdateService(cacheDirectory: root.appendingPathComponent("limited"), limits: tiny, fetcher: { try await mock.fetch($0, $1, $2, $3, $4) })
        try await failure("oversized metadata accepted") { _ = try await limited.checkMetadata(source) }
        var undeclared = item; undeclared.expectedLength = nil
        try await failure("oversized unknown-length package accepted") { _ = try await limited.downloadExplicitly(undeclared, publicKey: publicKey) }
        try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("limited").path), "over-budget download cached partial data")
        try check(parseAppcast(Data("<!DOCTYPE rss [<!ENTITY x SYSTEM 'file:///private/fixture'>]><rss>&x;</rss>".utf8)).isEmpty, "appcast external entity was allowed")
        try check(allowedAppcastURL("http://updates.fixture.invalid/a") == nil && allowedAppcastURL("https://user:secret@updates.fixture.invalid/a") == nil, "unsafe update URL allowed")
        try await checkBuildOrdering(source: source, remote: remote, cache: root.appendingPathComponent("same-marketing"))
        print("PASS updater MockHTTP: metadata-only checks, TTL, same-version single-flight/persistent verified cache, tamper rejection, key/signature/declared-size preflight, failure cooldown, cancellation without retry, unknown-length budgets, no app/UI or real requests")
        print("PASS updater appcast: Sparkle child and enclosure build ordering, legacy display feeds, downgrade rejection, macOS enclosure identity, same marketing metadata without a download")
    }
}
