import AppKit
import SwiftUI
import ApplicationServices

struct AgentObservation: Identifiable {
    var id: String
    var provider: Provider
    var softwareName: String
    var isRunning: Bool
    var cliPath: String?
    var status: String
    var snapshot: UsageSnapshot?
    var isMacAppInstalled: Bool = false
}

private final class DoubaoHelperCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    func run(_ value: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try value.run()
        process = value
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    func clear() { lock.lock(); process = nil; lock.unlock() }
}

enum DoubaoBridge {
    // AX 遍历、导航与解析已收敛到 DoubaoAX（与 doubao-reader 助手编译同一文件）。
    // V2.1 升级到 Kimi 桥标准：前台避让 / 5 分钟 per-account 导航节流 / 读完按「返回」恢复 / 不再 unhide。

    // quota id 沿用 V1.x 映射（当前时段→"doubao-5 小时"、近 7 天→"doubao-每周"），历史图表不断档。
    static func snapshot(_ obs: DoubaoAX.Observation) throws -> UsageSnapshot {
        var s = UsageSnapshot.empty(source: "豆包 本机服务")
        if let cur = obs.currentUsedPercent {
            s.quotas.append(Quota(id: "doubao-5 小时", title: "豆包 · 当前时段", usedPercent: cur))
        }
        if let weekly = obs.weeklyUsedPercent {
            s.quotas.append(Quota(id: "doubao-每周", title: "豆包 · 近 7 天", usedPercent: weekly, resetsAt: obs.weeklyResetAt, windowSeconds: 604_800))
        }
        guard !s.quotas.isEmpty else {
            throw MonitorError.message("豆包订阅与额度管理页未读取到额度区块（页面结构可能已变化）。上次数据已保留。")
        }
        var parts = ["豆包 桌面端账户弹层（2.31.2 起）/ 订阅与额度管理页（辅助功能只读）；页面显示已用百分比，界面按剩余展示"]
        if let p = obs.plan { parts.append("套餐：\(p)") }
        if obs.weeklyRawLessThanOne { parts.append("近 7 天页面原话「已用 <1%」，按不足 1% 处理") }
        if let rc = obs.resetCredits { parts.append("剩余额度重置机会 \(rc) 次") }
        parts.append("未读取到的字段不编造，以页面实际显示为准。")
        s.note = parts.joined(separator: "；")
        if let gd = obs.giftDeadline { s.deadlines = [Deadline(label: "豆包赠送时长", date: gd)] }
        try s.validate()
        return s
    }

    // helper 兜底：主进程读取失败时试独立 helper（其 TCC 授权与主 app 相互独立）。
    private static func readFromDedicatedHelper(cancellation: DoubaoHelperCancellation) -> DoubaoAX.Observation? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let helper = appSupport?.appendingPathComponent("GaoSeries/Token/bin/doubao-reader").path ?? ""
        guard !helper.isEmpty, FileManager.default.isExecutableFile(atPath: helper) else { return nil }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: helper)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        // 35s 硬超时（对齐 Codex）：helper 卡死时 SIGKILL，不允许无限期 waitUntilExit。
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 35)
        timer.setEventHandler { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        timer.resume()
        defer { timer.cancel(); if p.isRunning { p.terminate() }; cancellation.clear() }
        do {
            try cancellation.run(p)
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard !data.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let obs = DoubaoReaderPayload.parse(obj) else { return nil }
            return obs.hasPageMarkers ? obs : nil
        } catch is CancellationError { return nil }
        catch {
            Log.connectors.error("doubao helper read failed")
        }
        return nil
    }

    private static func readFromDedicatedHelper() async throws -> DoubaoAX.Observation? {
        try Task.checkCancellation()
        let cancellation = DoubaoHelperCancellation()
        let result: DoubaoAX.Observation? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: readFromDedicatedHelper(cancellation: cancellation))
                }
            }
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
        return result
    }

    static func fetch(_ account: Account, userInitiated: Bool = false) async throws -> ConnectorResult {
        try Task.checkCancellation()
        // 自动采集不弹授权窗口，也不通过旧版 helper 隐式导航原应用。
        let allowPrompt = userInitiated
        // AX 遍历含 usleep 与子进程等待，卸载到后台队列，不占协作线程池与主线程。
        let accountID = account.id
        let outcome: DoubaoAX.CollectOutcome = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: DoubaoAX.collect(accountID: accountID, allowPrompt: allowPrompt, allowNavigation: userInitiated))
            }
        }
        try Task.checkCancellation()
        switch outcome {
        case .notRunning:
            return .status("豆包 暂未启动。启动本机软件后自动读取，不预填额度。")
        case .needsPermission:
            // 未授权是可操作的硬状态：走 error 以触发授权引导按钮，上次数据保留。
            throw MonitorError.message("豆包 本机服务 · 需在「系统设置 - 隐私与安全性 - 辅助功能」中勾选允许「搞词元」，允许后点立即同步即可读取。上次数据已保留。")
        case .foregroundBusy:
            // 设计内跳过，不是失败：状态消息，不触发总览告警与菜单栏红点。
            return .status("豆包前台使用中，稍后自动补读；上次数据已保留。")
        case .throttled:
            return .status("距上次自动导航不足 5 分钟，本次沿用上次数据。")
        case .noPage:
            guard userInitiated else {
                return .status("当前页面未显示豆包额度，自动同步保留上次数据；可手动点「立即同步」读取。")
            }
            if let obs = try await readFromDedicatedHelper() {
                return .snapshot(try snapshot(obs))
            }
            throw MonitorError.message("未能读取豆包订阅与额度管理页（页面结构可能已变化）。上次数据已保留。")
        case .observation(let obs):
            return .snapshot(try snapshot(obs))
        }
    }
}

@MainActor final class MemberDiscovery: ObservableObject {
    static let shared = MemberDiscovery()
    @Published var observations: [AgentObservation] = []
    @Published var scanning = false
    @Published private(set) var discoveryCompleted = false
    private weak var store: MonitorStore?

    private var rescanTimer: Timer?
    private var scanRequest: Task<Void, Never>?
    private var scanWork: Task<[AgentObservation], Never>?
    private var generation = 0
    private var rescanPending = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var activationObserver: NSObjectProtocol?
    private let defaults: UserDefaults
    private let scanOperation: @Sendable () async -> [AgentObservation]

    init() {
        defaults = TokenBundle.defaults
        scanOperation = { Self.collectObservations() }
    }

    // Isolated fixtures supply observations instead of querying this Mac's apps.
    init(defaults: UserDefaults, scanOperation: @escaping @Sendable () async -> [AgentObservation]) {
        self.defaults = defaults
        self.scanOperation = scanOperation
    }

    func configure(_ store: MonitorStore) {
        guard self.store !== store || rescanTimer == nil else { return }
        generation += 1
        self.store = store
        discoveryCompleted = false
        scanRequest?.cancel()
        scanWork?.cancel()
        requestScan()
        if workspaceObservers.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didWakeNotification] {
                workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.requestScan() }
                })
            }
            activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.requestScan() }
            }
        }
        // 3.33：定期重扫（10 分钟）——新装/新登录的 agent 在下一轮自动接入，无需用户手动添加。
        if rescanTimer == nil {
            rescanTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.requestScan()
                }
            }
        }
    }

    func stop() {
        generation += 1
        rescanTimer?.invalidate(); rescanTimer = nil
        scanRequest?.cancel(); scanWork?.cancel()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        rescanPending = false
        store = nil
    }

    /// An event during a scan requests one subsequent pass, rather than being lost
    /// at the scanning guard or cancelling a useful in-flight discovery.
    func requestScan() {
        guard store != nil else { return }
        if scanning { rescanPending = true; return }
        guard scanRequest == nil else { rescanPending = true; return }
        scanRequest = Task { [weak self] in
            guard let self else { return }
            await self.scan()
            self.scanRequest = nil
            if self.rescanPending, self.store != nil { self.requestScan() }
        }
    }

    nonisolated static func railVisibleAccounts(_ accounts: [Account], observations: [AgentObservation], discoveryCompleted: Bool) -> [Account] {
        let local: Set<Connection> = [.agentLocal, .codex, .claudeDesktop, .cursor, .devinApp, .dshHarness, .workbuddyLocal, .geminiApp, .kimiDesktop]
        return accounts.filter { account in
            guard account.showInRail else { return false }
            guard discoveryCompleted, account.kind == .agent, local.contains(account.connection), AgentPlatformTable.hasSoftwareIdentity(account.provider) else { return true }
            guard let observation = observations.first(where: { $0.provider == account.provider }) else { return false }
            return !AgentPlatformTable.hasMacApplicationIdentity(account.provider) || observation.isMacAppInstalled
        }
    }

    func railVisibleAccounts(_ accounts: [Account]) -> [Account] {
        Self.railVisibleAccounts(accounts, observations: observations, discoveryCompleted: discoveryCompleted)
    }

    nonisolated static func isMacApplicationInstalled(_ p: Provider, in runningApps: [NSRunningApplication]) -> Bool {
        guard AgentPlatformTable.hasMacApplicationIdentity(p) else { return false }
        let fm = FileManager.default
        for app in runningApps where AgentPlatformTable.matchesRunning(p, bundle: (app.bundleIdentifier ?? "").lowercased(), name: (app.localizedName ?? "").lowercased()) {
            if let url = app.bundleURL, url.pathExtension == "app", fm.fileExists(atPath: url.path) { return true }
        }
        for bid in AgentPlatformTable.identity(p).exactBundles {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid), fm.fileExists(atPath: url.path) { return true }
        }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        for dir in ["/Applications", "\(home)/Applications"] {
            for name in AgentPlatformTable.identity(p).appNames where fm.fileExists(atPath: "\(dir)/\(name)") { return true }
        }
        return false
    }

    nonisolated static func isAgentRunning(_ p: Provider, in runningApps: [NSRunningApplication]) -> Bool {
        for app in runningApps {
            if app.isTerminated { continue }
            let bundle = (app.bundleIdentifier ?? "").lowercased()
            if bundle.hasPrefix("com.apple.") { continue }
            let name = (app.localizedName ?? "").lowercased()
            if name.hasPrefix("dock extra") || name.hasPrefix("程序坞") { continue }
            if app.activationPolicy == .prohibited && bundle.isEmpty { continue }
            if AgentPlatformTable.matchesRunning(p, bundle: bundle, name: name) { return true }
        }
        if p == .gemini, (AntigravityBridge.cachedDiscoverServer() != nil || GeminiAntigravityBridge.isAgyRunning()) {
            return true
        }
        return false
    }

    nonisolated static func isAgentInstalled(_ p: Provider, in runningApps: [NSRunningApplication]) -> Bool {
        guard AgentPlatformTable.hasSoftwareIdentity(p) else { return false }
        if isAgentRunning(p, in: runningApps) { return true }

        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? ""

        let cliCandidates = AgentPlatformTable.cliCandidates(p, home: home, appSupport: appSupport, includeDedicatedHelper: true)
        if cliCandidates.contains(where: { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }) {
            return true
        }

        let identity = AgentPlatformTable.identity(p)
        for bid in identity.exactBundles {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) != nil {
                return true
            }
        }
        let appDirs = ["/Applications", "\(home)/Applications"]
        for dir in appDirs {
            for name in identity.appNames {
                let full = "\(dir)/\(name)"
                if FileManager.default.fileExists(atPath: full) {
                    return true
                }
            }
        }
        return false
    }

    nonisolated private static func collectObservations() -> [AgentObservation] {
        let runningApps = NSWorkspace.shared.runningApplications
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        var result: [AgentObservation] = []
        for p in Provider.allCases {
            if Task.isCancelled { break }
            guard Self.isAgentInstalled(p, in: runningApps) else { continue }
            let isRunning = Self.isAgentRunning(p, in: runningApps)
            let candidates = AgentPlatformTable.cliCandidates(p, home: home, appSupport: "", includeDedicatedHelper: false)
            let cli = candidates.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
            result.append(AgentObservation(id: p.rawValue, provider: p, softwareName: p.agentSoftware,
                                           isRunning: isRunning, cliPath: cli,
                                           status: isRunning ? "软件运行中" : "未启动", snapshot: nil,
                                           isMacAppInstalled: Self.isMacApplicationInstalled(p, in: runningApps)))
        }
        return result
    }

    func scan() async {
        guard !Task.isCancelled else { return }
        if scanning { rescanPending = true; return }
        repeat {
            rescanPending = false
            let version = generation
            scanning = true
            // Discovery can spawn ps/lsof; keep it away from the main actor.
            let operation = scanOperation
            let worker = Task.detached(priority: .utility) { await operation() }
            scanWork = worker
            let list = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            scanWork = nil
            scanning = false
            guard !Task.isCancelled else { return }
            if !worker.isCancelled, version == generation {
                observations = list
                discoveryCompleted = true
                autoAddAccountsIfNeeded()
            }
        } while rescanPending && store != nil
    }

    /// dsh 自动接入：检测到本机 DeepSeek Harness 已安装且登录凭证可解析时，自动建立一个
    /// agent 账户（幂等）。用户手动移除后不再复活——dsh.autoAdded 一旦置位就不再自动加；
    /// 想再接回可在账户编辑里手动添加。
    /// 3.33：表驱动 agent 自动发现接入（取代旧版 dsh/WorkBuddy 两个专用函数，旧标记键仍兼容）。
    /// 检测到本机已安装/运行的 agent（且通路可行）且库里还没有该 provider 的账户时，
    /// 自动创建账户接入用量监控与悬浮条（showInRail 默认开），打 autoDiscovered 标记。
    /// 「流程结论」标记（autoAdd.<provider>.done）一旦置位不再自动加：已存在账户、
    /// 已自动添加过、或用户手动移除过（rememberRemoval）都会置位——记住用户的选择。
    private struct AutoAddSpec {
        var provider: Provider
        var connection: Connection
        var currency: String
    }
    nonisolated private static let autoAddSpecs: [AutoAddSpec] = [
        AutoAddSpec(provider: .openai, connection: .codex, currency: "USD"),
        AutoAddSpec(provider: .claude, connection: .agentLocal, currency: "USD"),
        AutoAddSpec(provider: .gemini, connection: .geminiApp, currency: "USD"),
        AutoAddSpec(provider: .grok, connection: .agentLocal, currency: "USD"),
        AutoAddSpec(provider: .kimi, connection: .kimiDesktop, currency: "CNY"),
        AutoAddSpec(provider: .doubao, connection: .agentLocal, currency: "CNY"),
        AutoAddSpec(provider: .dsh, connection: .dshHarness, currency: "CNY"),
        AutoAddSpec(provider: .workbuddy, connection: .workbuddyLocal, currency: "CNY"),
    ]
    nonisolated static func autoAddFlagKey(_ p: Provider) -> String {
        p == .grok ? "autoAdd.grokBot.done" : "autoAdd.\(p.rawValue).done"
    }
    nonisolated static func autoAddDone(_ p: Provider, defaults: UserDefaults = TokenBundle.defaults) -> Bool {
        if defaults.bool(forKey: autoAddFlagKey(p)) { return true }
        // 旧版一次性标记键兼容（3.2x 的 dsh/WorkBuddy 专用流程）。
        switch p {
        case .dsh: return defaults.bool(forKey: "dsh.autoAdded")
        case .workbuddy: return defaults.bool(forKey: "workbuddy.autoAdded")
        default: return false
        }
    }
    /// The Grok Bot route is independent of the Grok account pool and xAI API.
    nonisolated static func matchesAutomaticRoute(_ account: Account, provider: Provider) -> Bool {
        guard account.provider == provider else { return false }
        return provider != .grok || (account.kind == .agent && account.connection == .agentLocal)
    }
    /// 用户移除 Bot 后不再自动接入；删除账号池/API 不改变 Bot 的选择。
    nonisolated static func rememberRemoval(_ account: Account, defaults: UserDefaults = TokenBundle.defaults) {
        let p = account.provider
        guard autoAddSpecs.contains(where: { $0.provider == p }) else { return }
        guard matchesAutomaticRoute(account, provider: p) else { return }
        defaults.set(true, forKey: autoAddFlagKey(p))
    }
    /// 各 agent 的接入可行性信号（绝不触发钥匙串授权弹窗，只看不碰凭证）：
    /// 默认要求「已安装/运行中」；dsh 额外要求凭证文件可解析；
    /// Claude Code 有 ~/.claude/.credentials.json 登录凭证即接入（不要求应用仍在），
    /// 否则要求已安装且 ~/.claude 已初始化。
    nonisolated static func autoAddEligible(_ p: Provider, installed: Bool) -> Bool {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        switch p {
        case .dsh:
            return installed && DshBridge.credentialsAvailable()
        case .claude:
            if FileManager.default.fileExists(atPath: "\(home)/.claude/.credentials.json") { return true }
            return installed && FileManager.default.fileExists(atPath: "\(home)/.claude")
        default:
            return installed
        }
    }
    private func autoAddAccountsIfNeeded() {
        guard let store else { return }
        for spec in Self.autoAddSpecs {
            if let existing = store.library.accounts.first(where: { Self.matchesAutomaticRoute($0, provider: spec.provider) }) {
                // 已有账户（手动或更早版本添加）：结论化，不改动其 autoDiscovered 标记。
                if !Self.autoAddDone(spec.provider, defaults: defaults) { defaults.set(true, forKey: Self.autoAddFlagKey(spec.provider)) }
                // Bot discovery events also update its local status in the rail.
                if spec.provider == .grok, store.library.autoRefresh {
                    Task { await store.refresh(existing.id) }
                }
                continue
            }
            guard !Self.autoAddDone(spec.provider, defaults: defaults) else { continue }
            let installed = observations.contains { $0.provider == spec.provider }
            guard Self.autoAddEligible(spec.provider, installed: installed) else { continue }
            var account = Account(provider: spec.provider, kind: .agent, name: spec.provider.defaultAgentName,
                                  connection: spec.connection, currency: spec.currency)
            account.autoDiscovered = true
            if spec.provider == .grok {
                let running = observations.contains { $0.provider == .grok && $0.isRunning }
                account.statusNote = GrokBotBridge.status(installed: installed, running: running)
            }
            do {
                try store.upsert(account)
                defaults.set(true, forKey: Self.autoAddFlagKey(spec.provider))
                Log.store.info("auto-discovered agent account added")
                if store.library.autoRefresh { Task { await store.refresh(account.id) } }
            } catch {
                Log.store.error("auto-add account failed")
            }
        }
    }
}

#if !TESTING
struct MemberDiscoveryPanel: View {
    @ObservedObject var discovery = MemberDiscovery.shared
    @EnvironmentObject var store: MonitorStore
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Label(L("本机 Agent 软件状态"),systemImage:"cpu").font(.headline)
                Spacer()
                Button(L("刷新检测")) { Task { await discovery.scan() } }.disabled(discovery.scanning)
            }
            Text(L("自动检测实际安装的软件和 CLI；账户配置不会被当作软件安装记录。")).font(.callout).foregroundStyle(.secondary)
            if discovery.observations.isEmpty {
                Text(L("暂未检测到本机已安装的 Agent 软件（如 Codex、Claude Code、Antigravity 等）。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth:.infinity,alignment:.leading)
                    .background(Theme.canvas,in:RoundedRectangle(cornerRadius:8))
            } else {
                LazyVGrid(columns:[GridItem(.adaptive(minimum:220),alignment:.top)],spacing:10) {
                    ForEach(discovery.observations) { obs in
                        HStack(spacing:8) {
                            ProviderMark(provider:obs.provider,size:24)
                            VStack(alignment:.leading,spacing:2) {
                                Text(obs.softwareName).font(.caption.weight(.semibold)).lineLimit(1)
                                Text(L(obs.status)).font(.system(size:10)).foregroundStyle(obs.isRunning ? Theme.teal : .secondary)
                            }
                            Spacer()
                        }.padding(8).background(Theme.canvas,in:RoundedRectangle(cornerRadius:8))
                    }
                }
            }
        }.frame(maxWidth:.infinity,alignment:.leading).panel()
        .onAppear { discovery.configure(store) }
    }
}
#endif
