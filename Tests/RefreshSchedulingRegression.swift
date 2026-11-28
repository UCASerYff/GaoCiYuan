import Foundation
import SwiftUI
import UniformTypeIdentifiers

// Compile with Models, AgentTables, ProviderIntegrations, Pacing, RefreshCoordinator,
// MonitorStore and UsageAnalyticsStore. Every external dependency below is inert;
// connector/scanner operations are controllable fixtures with no HTTP or credentials.
enum TokenBundle {
    static let bundle = Bundle.main
    static let defaults = UserDefaults(suiteName: "RefreshSchedulingRegression." + UUID().uuidString)!
}
enum HTTPPolicyContext {
    @TaskLocal static var userInitiated = false
    @TaskLocal static var trigger = "test"
}
enum Log {
    struct Sink { func error(_ text: String) {} }
    static let store = Sink()
}
func L(_ text: String) -> String { text }
enum KeyVault {
    static var deleted: [UUID] = []
    static func save(_ value: String, id: UUID) throws {}
    static func delete(_ id: UUID) { deleted.append(id) }
}
enum MemberDiscovery { static func rememberRemoval(_ account: Account) {} }
enum Connectors { static func fetch(_ account: Account, userInitiated: Bool) async throws -> ConnectorResult { fatalError("Unexpected real fetch") } }
enum GrokBotBridge { static func isUsageRoute(_ account: Account) -> Bool { false } }
enum DeepSeekBasis { static func apply(account: inout Account, snapshot: inout UsageSnapshot) {} }
enum AlertOutcome { case reading(UsageSnapshot), neutral }
enum AlertRules {
    static func attention(_ account: Account, threshold: Double, at: Date) -> [String] { [] }
    static func standing(connection: Connection, error: String) -> AlertOutcome { .neutral }
}
struct AlertMemory {
    struct Entry { var failures = 0 }
    var accounts: [String: Entry] = [:]
    static let failuresBeforeSaying = 3
}
final class AlertCenter {
    var memory = AlertMemory()
    init(directory: URL) {}
    func observe(account: Account, outcome: AlertOutcome) {}
    func forget(account: UUID) {}
}
struct UsageEngineConfiguration: Codable, Equatable { var fixture = 0 }
struct UsageEngineScan { var capturedAt = Date(); var warnings: [String] = []; var value = 1 }
enum UsageEngine {
    static func scan(configuration: UsageEngineConfiguration, configurationDirectory: URL, knownDayFingerprints: [String: String], onProgress: @escaping @Sendable (String, Int, Int) -> Void) async throws -> UsageEngineScan { fatalError("Unexpected real scan") }
}
struct UsageLedgerDashboard { static var empty: Self { .init() } }
struct UsageLedgerSessionSummary { static var empty: Self { .init() } }
struct UsageLedgerSessionPage { var totalCount = 0; static var empty: Self { .init() } }
actor UsageLedger {
    static let didRestoreNotification = Notification.Name("FixtureRestore")
    private(set) var ingested = 0
    init(directory: URL) {}
    nonisolated static func restoreGeneration() -> UInt64 { 0 }
    func knownDayFingerprints() throws -> [String: String] { [:] }
    func ingest(_ scan: UsageEngineScan, expectedGeneration: UInt64) throws { ingested += scan.value }
    func dashboard(fromDay: String?, throughDay: String?) throws -> UsageLedgerDashboard { .empty }
    func sessionSummary() throws -> UsageLedgerSessionSummary { .empty }
    func sessionPage(offset: Int, limit: Int) throws -> UsageLedgerSessionPage { .empty }
    func metadata() throws -> (deviceID: String, lastScanAt: Date?) { ("fixture", nil) }
    func export(to: URL) throws {}
    func exportCSV(to: URL, fromDay: String?, throughDay: String?) throws {}
    func importFile(_ url: URL) throws {}
}

@MainActor final class Controlled<Value> {
    var calls = 0
    var active = 0
    var maximum = 0
    var continuations: [Int: CheckedContinuation<Value, Error>] = [:]
    var cooperative = false
    func run() async throws -> Value {
        calls += 1; active += 1; maximum = max(maximum, active)
        let ticket = calls
        defer { active -= 1 }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuations[ticket] = $0 }
        } onCancel: {
            Task { @MainActor in
                if self.cooperative { self.continuations.removeValue(forKey: ticket)?.resume(throwing: CancellationError()) }
            }
        }
    }
    func finish(_ value: Value, ticket: Int? = nil) {
        if let key = ticket ?? continuations.keys.sorted().first { continuations.removeValue(forKey: key)?.resume(returning: value) }
    }
}

@main struct RefreshSchedulingRegression {
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw MonitorError.message(message) }
    }
    @MainActor static func until(_ predicate: () -> Bool) async throws {
        for _ in 0..<10_000 { if predicate() { return }; await Task.yield() }
        throw MonitorError.message("Fixture condition did not complete")
    }
    static func reading(_ value: Int64) -> ConnectorResult {
        var snapshot = UsageSnapshot.empty(source: "fixture"); snapshot.inputTokens = value; snapshot.outputTokens = 0
        snapshot.periodEnd = Date(); snapshot.periodStart = Date().addingTimeInterval(-60)
        return .snapshot(snapshot)
    }
    @MainActor static func checkQuotaForecast(in directory: URL) async throws {
        let io = Controlled<ConnectorResult>()
        let store = MonitorStore(directory: directory, fetch: { _, _ in try await io.run() })
        var account = Account(provider: .openai, kind: .agent, name: "Forecast fixture", connection: .file)
        try store.upsert(account)
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let reset = now.addingTimeInterval(3_600)
        func quotaReading(_ age: TimeInterval, _ used: Double, source: String = "private exporter fixture") -> ConnectorResult {
            var snapshot = UsageSnapshot.empty(source: source)
            snapshot.observedAt = now.addingTimeInterval(-age)
            snapshot.quotas = [.init(id: "5h", title: "5 小时", usedPercent: used, resetsAt: reset, windowSeconds: 18_000)]
            return .snapshot(snapshot)
        }
        @MainActor func deliver(_ result: ConnectorResult) async throws {
            let ticket = io.calls + 1
            let id = account.id
            let refresh = Task { await store.refresh(id, userInitiated: true) }
            try await until { io.calls == ticket }
            io.finish(result, ticket: ticket)
            await refresh.value
        }

        try await deliver(quotaReading(2_700, 15))
        try await deliver(quotaReading(1_500, 35))
        let lastChanged = store.library.accounts[0].lastQuotaChangedAt
        try await deliver(quotaReading(300, 35))
        account = store.library.accounts[0]
        try check(account.history.count == 2 && account.lastQuotaChangedAt == lastChanged,
                  "Flat quota read changed regular change history or pacing")
        try check(account.snapshot?.observedAt == now.addingTimeInterval(-300) && account.quotaForecastHistory?.observations.count == 3,
                  "Flat quota read did not supply a newer forecast anchor")
        try check(account.snapshot?.source == "快照文件", "Private exporter source escaped into display")
        let originalKey = account.quotaForecastHistory?.sourceKey
        account.name = "Renamed forecast fixture"
        try store.upsert(account)
        let savedJSON = try String(contentsOf: store.dataURL, encoding: .utf8)
        try check(!savedJSON.contains("private exporter fixture"), "Private exporter source persisted as plaintext")
        let reloaded = MonitorStore(directory: directory, fetch: { _, _ in throw MonitorError.message("Unexpected fetch") })
        try check(reloaded.library.accounts.first?.quotaForecastHistory == account.quotaForecastHistory,
                  "Forecast evidence failed to survive rename and reload")

        try await deliver(quotaReading(240, 35, source: "second exporter fixture"))
        account = store.library.accounts[0]
        try check(account.quotaForecastHistory?.observations.count == 1 && account.quotaForecastHistory?.sourceKey != originalKey,
                  "Changing exporter origin mixed quota readings")
        let id = account.id
        let changed = Task { await store.refresh(id, userInitiated: true) }
        try await until { io.calls == 5 }
        account.plan = "Changed plan"
        try store.upsert(account)
        await changed.value
        io.finish(quotaReading(180, 50, source: "second exporter fixture"))
        try await until { io.active == 0 }
        try check(store.library.accounts[0].quotaForecastHistory == nil && store.library.accounts[0].history.count == 2,
                  "Prior configuration delivered evidence after the account edit")
        store.stop()
    }

    @MainActor static func checkFailedAccountSave(in directory: URL) async throws {
        var fetchCalls = 0
        let store = MonitorStore(directory: directory, fetch: { _, _ in
            fetchCalls += 1
            return reading(10)
        })
        var account = Account(provider: .copilot, kind: .agent, name: "Saved fixture", connection: .copilot)
        try store.upsert(account)
        try FileManager.default.removeItem(at: store.dataURL)
        try FileManager.default.createDirectory(at: store.dataURL, withIntermediateDirectories: false)
        account.name = "Uncommitted fixture draft"
        var failed = false
        do { try store.upsert(account) } catch { failed = true }
        try check(failed && store.library.accounts[0].name == "Saved fixture", "Failed disk replacement published or reported a successful account save")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        try check(!files.contains(where: { $0.hasPrefix(".library-") }), "Failed disk replacement left its stage behind")

        failed = false
        do { try store.upsert(account, key: "fixture input") } catch { failed = true }
        try check(failed, "Fixture expected failed disk replacement after credential mutation")
        await store.refresh(account.id, userInitiated: true)
        try check(fetchCalls == 0, "Refresh reused the previous config after a partial credential save")
        failed = false
        do { try store.validateCredentialRetry(for: account, key: "") } catch { failed = true }
        try check(failed, "Editor could test a partial credential save without explicit credentials")
        try FileManager.default.removeItem(at: store.dataURL)
        try store.upsert(account, key: "fixture input")
        await store.refresh(account.id, userInitiated: true)
        try check(fetchCalls == 1, "Successful credential retry did not restore refresh")
    }

    @MainActor static func checkAntigravityHistoricalImport(in directory: URL) async throws {
        try check(Connection.creationOptions(.gemini, .agent) == [.geminiApp, .agentLocal]
                  && Connection.creationOptions(.openai, .agent) == Connection.available(.openai, .agent),
                  "Only new Gemini Agent accounts should omit the file connection")
        var legacy = Library()
        legacy.accounts = [Account(provider: .gemini, kind: .agent, name: "Legacy file fixture", connection: .file)]
        let legacyData = try JSONCoding.encoder.encode(legacy)
        let legacyRoundTrip = try JSONCoding.decoder.decode(Library.self, from: legacyData)
        try MonitorStore.validate(legacyRoundTrip)
        try check(legacyRoundTrip.accounts.first?.connection == .file,
                  "Existing Gemini file connections must still decode and validate")

        var fetchCalls = 0
        let store = MonitorStore(directory: directory, fetch: { _, _ in
            fetchCalls += 1
            return .status("Fixture manual report guidance")
        })
        var account = Account(provider: .gemini, kind: .agent, name: "Fixture Gemini", connection: .geminiApp)
        try store.upsert(account)
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let reset = now.addingTimeInterval(2_700)
        let observations: [(TimeInterval, Double)] = [(3_720, 60), (1_920, 75), (120, 90)]
        for (age, used) in observations {
            var live = UsageSnapshot.empty(source: "Fixture verified source")
            live.observedAt = now.addingTimeInterval(-age)
            live.quotas = [.init(id: "verified", title: "Verified window", usedPercent: used,
                                 resetsAt: reset, windowSeconds: 18_000)]
            try store.updateSnapshot(live, for: account.id)
        }
        let before = store.library.accounts[0]
        let beforeForecast = QuotaForecast.evaluate(account: before, now: now)
        try check(beforeForecast.windows.first?.status == .risk, "Fixture must begin with a verified trend")
        var report = UsageSnapshot.empty(source: UsageSnapshot.embeddedAntigravityEntrySource)
        report.observedAt = now.addingTimeInterval(86_400)
        report.quotas = [.init(id: "report", title: "Historical window", usedPercent: 100, resetsAt: nil)]
        try store.importAntigravityReport(report, for: account.id)
        let after = store.library.accounts[0]
        guard let historical = after.historicalAntigravityReport else { throw MonitorError.message("Missing historical reference") }
        try check(historical.isUnverifiedAntigravityReport == true && historical.isHistoricalAntigravityReading,
                  "Import did not seal report provenance")
        try check(historical.observedAt >= now && historical.observedAt <= Date(),
                  "Import must use app import time without trusting the supplied timestamp")
        try check(after.snapshot == before.snapshot && after.history == before.history
                  && after.quotaForecastHistory == before.quotaForecastHistory
                  && after.lastAttempt == before.lastAttempt && after.lastQuotaChangedAt == before.lastQuotaChangedAt,
                  "Historical import changed the verified reading, forecast, ordinary history or pacing")
        try check(QuotaForecast.evaluate(account: after, now: now).windows.first?.estimatedExhaustedAt ==
                  beforeForecast.windows.first?.estimatedExhaustedAt, "Historical import changed the verified estimate")

        let saved = try Data(contentsOf: store.dataURL)
        try store.importAntigravityReport(report, for: account.id)
        let duplicate = try Data(contentsOf: store.dataURL)
        try check(duplicate == saved && store.library.accounts[0].historicalAntigravityReport == historical,
                  "Duplicate report rewrote the first import")
        var wrongMode = report
        for source in [UsageSnapshot.standaloneAntigravityManualSource, UsageSnapshot.standaloneAntigravityJSONSource] {
            wrongMode.source = source
            var mismatch: String?
            do { try store.importAntigravityReport(wrongMode, for: account.id) } catch { mismatch = error.localizedDescription }
            let afterWrongMode = try Data(contentsOf: store.dataURL)
            try check(mismatch?.contains("报告类型与账户连接方式不符") == true && afterWrongMode == saved
                      && store.library.accounts[0].historicalAntigravityReport == historical,
                      "A standalone source was accepted or changed the saved embedded account")
        }
        let reopened = MonitorStore(directory: directory, fetch: { _, _ in throw MonitorError.message("Unexpected fixture fetch") })
        let persisted = reopened.library.accounts[0]
        try check(persisted.snapshot == before.snapshot && persisted.history == before.history
                  && persisted.historicalAntigravityReport?.quotas == historical.quotas
                  && persisted.historicalAntigravityReport?.isUnverifiedAntigravityReport == true,
                  "Verified and historical records failed to reopen separately")

        await store.refreshDue()
        await store.refreshAll()
        await store.refreshAll(userInitiated: true)
        await store.refresh(account.id)
        await store.refresh(account.id, userInitiated: true)
        try check(fetchCalls == 0 && store.library.accounts[0].lastAttempt == before.lastAttempt,
                  "A refresh path touched a report-only account")

        account = store.library.accounts[0]
        account.connection = .agentLocal
        try store.upsert(account)
        try check(store.library.accounts[0].historicalAntigravityReport == nil, "The two report routes shared a reference")
        var mismatch: String?
        let beforeEmbeddedMismatch = try Data(contentsOf: store.dataURL)
        do { try store.importAntigravityReport(report, for: account.id) } catch { mismatch = error.localizedDescription }
        let afterEmbeddedMismatch = try Data(contentsOf: store.dataURL)
        try check(mismatch?.contains("报告类型与账户连接方式不符") == true && beforeEmbeddedMismatch == afterEmbeddedMismatch
                  && store.library.accounts[0].historicalAntigravityReport == nil,
                  "An embedded source was accepted or changed the saved standalone account")
        report.source = UsageSnapshot.standaloneAntigravityManualSource
        report.quotas[0].usedPercent = 50
        try store.importAntigravityReport(report, for: account.id)
        try check(store.library.accounts[0].historicalAntigravityReport?.quotas.first?.remaining == 50,
                  "Existing standalone text report was unavailable")

        report.source = UsageSnapshot.standaloneAntigravityJSONSource
        report.quotas[0].usedPercent = 55
        var rejectedLive = false
        do { try store.updateSnapshot(report, for: account.id) } catch { rejectedLive = true }
        try store.importAntigravityReport(report, for: account.id)
        let standalone = store.library.accounts[0]
        let latestReport = standalone.historicalAntigravityReport
        try check(rejectedLive && standalone.snapshot == nil && standalone.history == before.history
                  && standalone.quotaForecastHistory == nil && standalone.unassignedLegacyAntigravityReport == nil
                  && latestReport?.source == UsageSnapshot.standaloneAntigravityJSONSource
                  && latestReport?.isUnverifiedAntigravityReport == true && latestReport?.quotas.first?.remaining == 45
                  && standalone.stale() && store.health(of: standalone) == .historical,
                  "The standalone JSON report was not stored solely as the current historical reference for that route")
        let standaloneReopened = MonitorStore(directory: directory, fetch: { _, _ in throw MonitorError.message("Unexpected fixture fetch") })
        try check(standaloneReopened.library.accounts[0].historicalAntigravityReport?.source == latestReport?.source,
                  "Standalone JSON report source was lost on reopening")
        account.connection = .geminiApp
        try store.upsert(account)
        try check(store.library.accounts[0].historicalAntigravityReport == historical,
                  "Standalone JSON import altered the separately saved embedded report")
        account.connection = .agentLocal
        try store.upsert(account)
        try check(store.library.accounts[0].historicalAntigravityReport == latestReport,
                  "Standalone JSON reference was lost when switching between routes")

        try FileManager.default.removeItem(at: store.dataURL)
        try FileManager.default.createDirectory(at: store.dataURL, withIntermediateDirectories: false)
        report.quotas[0].usedPercent = 70
        var rejected = false
        do { try store.importAntigravityReport(report, for: account.id) } catch { rejected = true }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        try check(rejected && store.library.accounts[0].historicalAntigravityReport == latestReport
                  && !files.contains(where: { $0.hasPrefix(".library-") }),
                  "Failed report replacement published an uncommitted reading or left its stage")
        store.stop()
    }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RefreshSchedulingRegression-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await checkQuotaForecast(in: root.appendingPathComponent("forecast"))
        try await checkFailedAccountSave(in: root.appendingPathComponent("failed-save"))
        let agentID = UUID(), llmID = UUID(), customAPIID = UUID()
        var legacy = Library()
        legacy.accounts = [
            Account(id: agentID, provider: .openai, kind: .agent, name: "Codex", connection: .codex),
            Account(id: llmID, provider: .openai, kind: .llm, name: "Legacy API", connection: .file),
            Account(id: customAPIID, provider: .custom, kind: .agent, name: "Legacy custom API", connection: .customAPI)
        ]
        let legacyDirectory = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(legacy).write(to: legacyDirectory.appendingPathComponent("library.json"))
        let migrated = MonitorStore(directory: legacyDirectory, fetch: { _, _ in throw MonitorError.message("Unexpected fetch") })
        try check(migrated.library.accounts.map(\.id) == [agentID], "Legacy API account was not removed")
        try check(KeyVault.deleted == [llmID, customAPIID], "Legacy API credentials were not deleted exactly once")
        try check(migrated.active.allSatisfy { $0.kind == .agent && $0.provider != .custom }, "Non-agent account entered active set")
        for invalid in [
            Account(provider: .custom, kind: .llm, name: "Rejected LLM", connection: .file),
            Account(provider: .custom, kind: .agent, name: "Rejected custom API", connection: .customAPI)
        ] {
            var rejected = false
            do { try migrated.upsert(invalid) } catch { rejected = true }
            try check(rejected, "API upsert unexpectedly succeeded")
        }

        let io = Controlled<ConnectorResult>()
        let store = MonitorStore(directory: root.appendingPathComponent("quota"), fetch: { _, _ in try await io.run() })
        var account = Account(provider: .openai, kind: .agent, name: "Fixture", connection: .file)
        try store.upsert(account)
        store.library.autoRefresh = false
        await store.refreshAll(); await store.refreshDue(); await store.refresh(account.id)
        try check(io.calls == 0, "Automatic entry bypassed disabled preference")
        let manual = Task { await store.refresh(account.id, userInitiated: true) }
        try await until { io.calls == 1 }
        await store.refresh(account.id, userInitiated: true)
        try check(io.calls == 1, "Per-account single-flight failed")
        io.finish(reading(10)); await manual.value
        try check(store.library.accounts[0].snapshot?.totalTokens == 10, "Manual refresh blocked while auto disabled")

        store.library.autoRefresh = true
        let automatic = Task { await store.refresh(account.id) }
        try await until { io.calls == 2 }
        store.library.autoRefresh = false
        await automatic.value
        io.finish(reading(999)); try await until { io.active == 0 }
        try check(store.library.accounts[0].snapshot?.totalTokens == 10 && store.library.accounts[0].history.count == 1, "Cancelled automatic result overwrote history")
        store.library.autoRefresh = true
        let keepManual = Task { await store.refresh(account.id, userInitiated: true) }
        try await until { io.calls == 3 }
        store.library.autoRefresh = false
        io.finish(reading(20)); await keepManual.value
        try check(store.library.accounts[0].snapshot?.totalTokens == 20, "Disabling auto cancelled explicit manual request")

        let changed = Task { await store.refresh(account.id, userInitiated: true) }
        try await until { io.calls == 4 }
        account = store.library.accounts[0]; account.scopeID = "new-scope"
        try store.upsert(account)
        await changed.value
        io.finish(reading(888)); try await until { io.active == 0 }
        try check(store.library.accounts[0].snapshot == nil && store.library.accounts[0].lastAttempt == nil, "Changed source accepted old response")
        let disabled = Task { await store.refresh(account.id, userInitiated: true) }
        try await until { io.calls == 5 }
        store.library.accounts[0].enabled = false
        await disabled.value
        io.finish(reading(777)); try await until { io.active == 0 }
        try check(store.library.accounts[0].snapshot == nil && store.library.accounts[0].error == nil, "Disabled account accepted cancelled response")
        store.library.accounts[0].enabled = true
        let removed = Task { await store.refresh(account.id, userInitiated: true) }
        try await until { io.calls == 6 }
        store.remove(account.id); await removed.value
        io.finish(reading(666)); try await until { io.active == 0 }
        try check(store.library.accounts.isEmpty, "Removed account returned after cancellation")

        let scheduler = RefreshCoordinator<Int>(maximumConcurrent: 2, maximumPerService: 1)
        let jobs = Controlled<Int>()
        let a = Task { try await scheduler.perform(request: "shared", service: "one") { try await jobs.run() } }
        var joinedRegistered = false
        let joined = Task {
            joinedRegistered = true
            return try await scheduler.perform(request: "shared", service: "one") { throw MonitorError.message("Duplicate shared fetch") }
        }
        try await until { jobs.calls == 1 && joinedRegistered }
        a.cancel()
        _ = try? await a.value
        jobs.finish(42)
        let joinedValue = try await joined.value
        try check(joinedValue == 42, "One cancelled waiter cancelled another account's shared request")
        let one = Task { try await scheduler.perform(request: "one", service: "same") { try await jobs.run() } }
        try await until { jobs.calls == 2 }
        let two = Task { try await scheduler.perform(request: "two", service: "same") { try await jobs.run() } }
        let three = Task { try await scheduler.perform(request: "three", service: "other") { try await jobs.run() } }
        try await until { jobs.calls == 3 }
        try check(jobs.active == 2, "Global/service concurrency admission failed")
        one.cancel(); _ = try? await one.value
        for _ in 0..<30 { await Task.yield() }
        try check(jobs.calls == 3, "Cancelled but still-running operation released its slot early")
        jobs.finish(1, ticket: 2)
        try await until { jobs.calls == 4 }
        jobs.finish(2, ticket: 3); jobs.finish(3, ticket: 4)
        _ = try await two.value; _ = try await three.value
        try check(jobs.maximum == 2, "Operation concurrency exceeded budget")

        let queuedScheduler = RefreshCoordinator<Int>(maximumConcurrent: 1)
        let queuedIO = Controlled<Int>()
        let blocker = Task { try await queuedScheduler.perform(request: "blocker", service: "one") { try await queuedIO.run() } }
        try await until { queuedIO.calls == 1 }
        let queued = Task { try await queuedScheduler.perform(request: "queued", service: "two") { try await queuedIO.run() } }
        for _ in 0..<30 { await Task.yield() }
        queued.cancel(); _ = try? await queued.value
        queuedIO.finish(1); _ = try await blocker.value
        for _ in 0..<30 { await Task.yield() }
        try check(queuedIO.calls == 1, "Cancelled queued operation still started")

        let localIO = Controlled<ConnectorResult>()
        let local = MonitorStore(directory: root.appendingPathComponent("local"), fetch: { _, _ in try await localIO.run() })
        try local.upsert(Account(provider: .openai, kind: .agent, name: "Codex A", connection: .codex))
        try local.upsert(Account(provider: .openai, kind: .agent, name: "Codex B", connection: .codex))
        let localGroup = Task { await local.refreshAll(userInitiated: true) }
        try await until { localIO.calls == 1 }
        for _ in 0..<30 { await Task.yield() }
        localIO.finish(reading(30)); await localGroup.value
        try check(localIO.calls == 1 && local.library.accounts.allSatisfy { $0.snapshot?.totalTokens == 30 }, "Identical local source was fetched separately for duplicate accounts")
        local.stop()

        let historyIO = Controlled<UsageEngineScan>(); historyIO.cooperative = true
        let history = UsageAnalyticsStore(directory: root.appendingPathComponent("history"), scan: { _, _, _, _ in try await historyIO.run() })
        history.setAutomaticRefreshEnabled(false)
        history.refresh(userInitiated: false)
        try check(historyIO.calls == 0 && !history.isRefreshing, "History bypassed overall automatic preference")
        var settings = history.preferences; settings.automaticallyScan = false
        history.savePreferences(settings)
        for _ in 0..<30 { await Task.yield() }
        try check(historyIO.calls == 0, "Saving disabled history settings launched a scan")
        history.refresh()
        try await until { historyIO.calls == 1 }
        history.setAutomaticRefreshEnabled(false)
        historyIO.finish(.init())
        try await until { !history.isRefreshing }
        let ingested = await history.ledger.ingested
        try check(ingested == 1, "Manual history scan blocked by automatic preference")
        settings.automaticallyScan = true; history.savePreferences(settings)
        history.setAutomaticRefreshEnabled(true)
        history.refresh(userInitiated: false)
        try await until { historyIO.calls == 2 }
        history.setAutomaticRefreshEnabled(false)
        try await until { !history.isRefreshing }
        let cancelledIngested = await history.ledger.ingested
        try check(cancelledIngested == 1, "Cancelled automatic history scan reached ledger")
        history.setAutomaticRefreshEnabled(true)
        history.refresh(userInitiated: false)
        try await until { historyIO.calls == 3 }
        settings.automaticallyScan = false; history.savePreferences(settings)
        try await until { !history.isRefreshing }
        for _ in 0..<30 { await Task.yield() }
        try check(historyIO.calls == 3, "History settings queued an unauthorized reindex")
        history.stop(); store.stop()
        try await checkAntigravityHistoricalImport(in: root.appendingPathComponent("antigravity-import"))
        print("Refresh scheduling regression passed: quota evidence provenance and persistence, historical Antigravity import and atomic save failure, disabled gates, manual override, single-flight, cancellation, concurrency and history policy. Synthetic data only.")
    }
}
