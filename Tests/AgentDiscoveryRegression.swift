import AppKit
import SwiftUI

// Compile with -D TESTING, Models, AgentTables, ProviderIntegrations,
// NativeMembers, GrokBotBridge and GrokBotUsageReport. All discovery observations and store writes
// are synthetic; no connector, CLI, credential, transcript or real app is used.
enum TokenBundle {
    static let bundle = Bundle.main
    static let defaults = UserDefaults(suiteName: "AgentDiscoveryRegression." + UUID().uuidString)!
}
enum Log {
    struct Sink { func error(_ text: String) {}; func info(_ text: String) {} }
    static let store = Sink(), connectors = Sink()
}
enum AlertRules { static func attention(_ account: Account, threshold: Double, at: Date) -> [String] { [] } }
enum AntigravityBridge { static func cachedDiscoverServer() -> Int? { nil } }
enum GeminiAntigravityBridge { static func isAgyRunning() -> Bool { false } }
enum DshBridge { static func credentialsAvailable() -> Bool { fatalError("Unexpected credential lookup") } }
func displayDate(_ date: Date, time: Bool) -> String { "fixture" }
enum DoubaoReaderPayload {
    static func parse(_ value: [String: Any]) -> DoubaoAX.Observation? { fatalError("Unexpected helper parsing") }
}
enum DoubaoAX {
    struct Observation {
        var currentUsedPercent: Double?, weeklyUsedPercent: Double?, weeklyResetAt: Date?
        var plan: String?, resetCredits: Int?, giftDeadline: Date?
        var weeklyRawLessThanOne = false, hasPageMarkers = false
    }
    enum CollectOutcome { case notRunning, needsPermission, foregroundBusy, throttled, noPage, observation(Observation) }
    static func collect(accountID: UUID, allowPrompt: Bool, allowNavigation: Bool) -> CollectOutcome {
        fatalError("Unexpected accessibility collection")
    }
}
@MainActor final class MonitorStore {
    var library = Library()
    var refreshCalls = 0
    func upsert(_ account: Account) throws {
        if let index = library.accounts.firstIndex(where: { $0.id == account.id }) { library.accounts[index] = account }
        else { library.accounts.append(account) }
    }
    func refresh(_ id: UUID, userInitiated: Bool = false) async { refreshCalls += 1 }
}
actor ControlledDiscovery {
    private(set) var calls = 0
    private var continuations: [Int: CheckedContinuation<[AgentObservation], Never>] = [:]
    func scan() async -> [AgentObservation] {
        calls += 1
        let ticket = calls
        return await withCheckedContinuation { continuations[ticket] = $0 }
    }
    func finish(_ ticket: Int, _ observations: [AgentObservation]) {
        continuations.removeValue(forKey: ticket)?.resume(returning: observations)
    }
}

@main struct AgentDiscoveryRegression {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw MonitorError.message(message) }
    }
    @MainActor static func until(_ condition: () async -> Bool) async throws {
        for _ in 0..<20_000 {
            if await condition() { return }
            await Task.yield()
        }
        throw MonitorError.message("Synthetic discovery did not settle")
    }
    static func observation(running: Bool) -> AgentObservation {
        .init(id: "grok", provider: .grok, softwareName: "Grok Bot", isRunning: running,
              cliPath: nil, status: running ? "软件运行中" : "未启动", snapshot: nil)
    }
    @MainActor static func main() async throws {
        let suite = "AgentDiscoveryRegression." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // Other routes are already concluded in this isolated preferences suite,
        // so this Grok-only fixture never enters their credential/path checks.
        let completedProviders: [Provider] = [.openai, .claude, .gemini, .kimi, .doubao, .dsh, .workbuddy]
        for provider in completedProviders {
            defaults.set(true, forKey: MemberDiscovery.autoAddFlagKey(provider))
        }
        try check(AgentPlatformTable.identity(.grok).appNames.contains("Grok Bot.app"), "Grok Bot installation filename missing")
        try check(AgentPlatformTable.matchesRunning(.grok, bundle: "com.anysphere.sand", name: "renamed"), "Exact Bot bundle not recognized")
        try check(AgentPlatformTable.matchesRunning(.grok, bundle: "", name: "grok bot"), "Bot process name not recognized")
        try check(!AgentPlatformTable.matchesRunning(.grok, bundle: "com.qoder.app", name: "qoder"), "Unrelated app recognized as Grok")

        let api = Account(provider: .grok, kind: .llm, name: "API fixture", connection: .xai)
        let pool = Account(provider: .grok, kind: .agent, name: "Pool fixture", connection: .grokAccount)
        let bot = Account(provider: .grok, kind: .agent, name: "Bot fixture", connection: .agentLocal)
        defaults.set(true, forKey: "autoAdd.grok.done")
        MemberDiscovery.rememberRemoval(api, defaults: defaults)
        MemberDiscovery.rememberRemoval(pool, defaults: defaults)
        try check(!MemberDiscovery.autoAddDone(.grok, defaults: defaults), "Pool/API/legacy flag suppressed Bot")
        try check(MemberDiscovery.matchesAutomaticRoute(bot, provider: .grok), "Bot route missing")
        try check(!MemberDiscovery.matchesAutomaticRoute(api, provider: .grok) && !MemberDiscovery.matchesAutomaticRoute(pool, provider: .grok), "Grok routes were conflated")
        let other = Account(provider: .openai, kind: .llm, name: "Other fixture", connection: .openai)
        defaults.removeObject(forKey: MemberDiscovery.autoAddFlagKey(.openai))
        MemberDiscovery.rememberRemoval(other, defaults: defaults)
        try check(MemberDiscovery.autoAddDone(.openai, defaults: defaults), "Existing provider removal semantics changed")

        let coldStore = MonitorStore()
        coldStore.library.autoRefresh = false
        let cold = MemberDiscovery(defaults: defaults, scanOperation: { [observation(running: false)] })
        cold.configure(coldStore)
        try await until { coldStore.library.accounts.contains { $0.provider == .grok } && !cold.scanning }
        try check(coldStore.library.accounts.count == 1 && coldStore.refreshCalls == 0, "Cold detection did not add just the installed Bot")
        cold.stop()
        defaults.removeObject(forKey: MemberDiscovery.autoAddFlagKey(.grok))

        let controlled = ControlledDiscovery()
        let store = MonitorStore()
        store.library.autoRefresh = false
        store.library.accounts = [api, pool]
        let discovery = MemberDiscovery(defaults: defaults, scanOperation: { await controlled.scan() })
        defer { discovery.stop() }
        discovery.configure(store)
        try await until { await controlled.calls == 1 }
        // An install/launch that lands during an earlier scan must not disappear.
        discovery.requestScan(); discovery.requestScan(); discovery.requestScan()
        await controlled.finish(1, [])
        try await until { await controlled.calls == 2 }
        await controlled.finish(2, [observation(running: false)])
        try await until { !discovery.scanning && store.library.accounts.count == 3 }
        for _ in 0..<20 { await Task.yield() }
        let coalescedCalls = await controlled.calls
        try check(coalescedCalls == 2, "Event burst was not coalesced")
        guard let added = store.library.accounts.first(where: { MemberDiscovery.matchesAutomaticRoute($0, provider: .grok) }) else {
            throw MonitorError.message("Installed Bot was not auto-added beside API and pool")
        }
        try check(added.autoDiscovered && added.showInRail && added.snapshot == nil && added.history.isEmpty, "Discovery invented usage or hid rail account")
        try check(added.statusNote == GrokBotBridge.status(installed: true, running: false), "Disabled refresh lost honest initial Bot status")
        try check(store.refreshCalls == 0, "Discovery bypassed autoRefresh=false")

        // Post only synthetic lifecycle notifications; these do not open apps.
        let events: [(NotificationCenter, Notification.Name, Bool)] = [
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didLaunchApplicationNotification, true),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didTerminateApplicationNotification, false),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification, false),
            (.default, NSApplication.didBecomeActiveNotification, false),
        ]
        for (offset, event) in events.enumerated() {
            let ticket = offset + 3
            event.0.post(name: event.1, object: nil)
            try await until { await controlled.calls == ticket }
            await controlled.finish(ticket, [observation(running: event.2)])
            try await until { !discovery.scanning && discovery.observations.first?.isRunning == event.2 }
        }
        try check(store.library.accounts.count == 3 && store.refreshCalls == 0, "Hot detection duplicated Bot or fetched with automatic refresh disabled")
        discovery.stop()
        for event in events { event.0.post(name: event.1, object: nil) }
        for _ in 0..<50 { await Task.yield() }
        let stoppedCalls = await controlled.calls
        try check(stoppedCalls == 6, "Stopped discovery retained lifecycle observers")

        MemberDiscovery.rememberRemoval(added, defaults: defaults)
        store.library.accounts.removeAll { $0.id == added.id }
        discovery.configure(store)
        try await until { await controlled.calls == 7 }
        await controlled.finish(7, [observation(running: true)])
        try await until { !discovery.scanning }
        try check(store.library.accounts.count == 2 && !store.library.accounts.contains(where: { MemberDiscovery.matchesAutomaticRoute($0, provider: .grok) }), "Removed Bot was resurrected")
        try check(MemberDiscovery.autoAddFlagKey(.grok) == "autoAdd.grokBot.done", "Bot flag shared with account pool")
        print("{\"passed\":true,\"syntheticScans\":8,\"autoRefreshOffFetches\":0,\"snapshotCount\":0}")
    }
}
