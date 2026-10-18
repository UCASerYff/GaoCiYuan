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
enum Log { struct Sink { func error(_ text: String) {} }; static let store = Sink() }
func L(_ text: String) -> String { text }
enum KeyVault { static func save(_ value: String, id: UUID) throws {}; static func delete(_ id: UUID) {} }
enum MemberDiscovery { static func rememberRemoval(_ provider: Provider) {} }
enum Connectors { static func fetch(_ account: Account, userInitiated: Bool) async throws -> ConnectorResult { fatalError("Unexpected real fetch") } }
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
extension UTType { static let gaoBackup = UTType.json }
struct Preferences { static func read() -> Self { .init() }; func apply() {} }
struct PreparedTransfer { var library = Library(); var fileCount = 0; var preferences: Preferences? }
enum DataTransfer {
    static func export(to: URL, root: URL, library: Library, preferences: Preferences) throws { fatalError("Unexpected export") }
    static func prepare(_ url: URL) throws -> PreparedTransfer { fatalError("Unexpected restore") }
    static func restore(_ incoming: PreparedTransfer, to: URL) throws -> Library { fatalError("Unexpected restore") }
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
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RefreshSchedulingRegression-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let io = Controlled<ConnectorResult>()
        let store = MonitorStore(directory: root.appendingPathComponent("quota"), fetch: { _, _ in try await io.run() })
        var account = Account(provider: .custom, kind: .llm, name: "Fixture", connection: .file)
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
        print("Refresh scheduling regression passed: disabled startup/due gates, manual override, single-flight, source/disable/delete cancellation, stale-result rejection, shared waiters, service/global concurrency, non-cooperative cancellation slot retention, automatic history cancellation and no hidden settings reindex. No HTTP, credentials, app launch or smoke test.")
    }
}
