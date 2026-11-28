import AppKit
import CryptoKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class MonitorStore: ObservableObject {
    @Published var library: Library {
        didSet {
            reconcileRefreshTasks()
            if oldValue.autoRefresh != library.autoRefresh { automaticRefreshChanged?(library.autoRefresh) }
        }
    }
    @Published var refreshing = Set<UUID>()
    @Published var notice: String?
    private(set) var loadFailed = false
    let dataURL: URL
    let alerts: AlertCenter
    private var timer: Timer?
    private var revisions: [UUID:Int] = [:]
    private var incompleteCredentialSaves = Set<UUID>()
    private struct RefreshFlight {
        let token: UUID
        let account: Account
        let automatic: Bool
        let task: Task<Void, Never>
    }
    typealias Fetch = @MainActor (Account, Bool) async throws -> ConnectorResult
    private let fetch: Fetch
    private let refreshCoordinator = RefreshCoordinator<ConnectorResult>()
    private var refreshTasks: [UUID: RefreshFlight] = [:]
    private var suspended = false
    var automaticRefreshChanged: ((Bool) -> Void)?
    // 阶段 3B：自适应节奏的信号记忆（内存态，重启后从封顶重新开始——只会偏保守，不会偏吵）。
    private var lastChanges: [UUID:Date] = [:]
    private var lastUserActions: [UUID:Date] = [:]
    init(directory: URL? = nil, fetch: @escaping Fetch = { account, userInitiated in
        try await Connectors.fetch(account, userInitiated: userInitiated)
    }) {
        self.fetch = fetch
        let root = directory
            ?? ProcessInfo.processInfo.environment["GAOCIYUAN_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("GaoSeries/Token")
        dataURL = root.appendingPathComponent("library.json")
        alerts = AlertCenter(directory: root)
        if FileManager.default.fileExists(atPath:dataURL.path) {
            do {
                let savedData = try Data(contentsOf: dataURL)
                var loaded = try JSONCoding.decoder.decode(Library.self, from: savedData)
                // V4.13：永久删除旧 LLM API 账户及专属凭据，不创建迁移备份。
                let migration = LegacyAccountMigration.removingLLMAccounts(from: loaded)
                loaded = migration.library
                for id in migration.removedIDs {
                    KeyVault.delete(id)
                    alerts.forget(account: id)
                }
                // Rewrite a valid legacy library once even when refresh is disabled.
                // Business validation below must succeed before anything is saved.
                let savedFields = try JSONSerialization.jsonObject(with: savedData) as? [String: Any]
                var changed = savedFields?.keys.contains("station") == true || !migration.removedIDs.isEmpty
                for i in 0..<loaded.accounts.count {
                    let a = loaded.accounts[i]
                    if a.kind == .agent {
                        let legacyNames = ["ChatGPT / Codex", "OpenAI · ChatGPT", "ChatGPT/Codex", "Codex", "\(a.provider.name)", "\(a.provider.name) · \(a.provider.agentSoftware)"]
                        if legacyNames.contains(a.name) || (a.provider == .openai && a.name.contains("/")) {
                            loaded.accounts[i].name = a.provider.defaultAgentName
                            changed = true
                        }
                    }
                    // 币种归一：大写三字母；无法归一的回落 USD，避免小写币种让预算提醒静默失效。
                    let normalizedCurrency = a.currency.uppercased()
                    if normalizedCurrency.count == 3 && normalizedCurrency.unicodeScalars.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) && $0.isASCII }) {
                        if normalizedCurrency != a.currency { loaded.accounts[i].currency = normalizedCurrency; changed = true }
                    } else {
                        loaded.accounts[i].currency = "USD"; changed = true
                    }
                    if var snap = loaded.accounts[i].snapshot {
                        let hadStatus = snap.quotas.contains { $0.id.contains("status") || $0.title.contains("运行中") || $0.title.contains("未启动") }
                        if hadStatus {
                            snap.quotas.removeAll { $0.id.contains("status") || $0.title.contains("运行中") || $0.title.contains("未启动") }
                            loaded.accounts[i].snapshot = snap
                            changed = true
                        }
                    }
                    let prevHistoryCount = loaded.accounts[i].history.count
                    loaded.accounts[i].history = loaded.accounts[i].history.compactMap { snap in
                        var s = snap
                        s.quotas.removeAll { $0.id.contains("status") || $0.title.contains("运行中") || $0.title.contains("未启动") }
                        if !s.hasMeasuredValues {
                            return nil
                        }
                        return s
                    }.suffix(300).map { $0 }
                    if loaded.accounts[i].history.count != prevHistoryCount {
                        changed = true
                    }
                    if let forecast = loaded.accounts[i].quotaForecastHistory,
                       !forecast.sourceKey.hasPrefix(Self.quotaSourceIdentity(loaded.accounts[i]) + ":") {
                        loaded.accounts[i].quotaForecastHistory = nil
                    }
                }
                // 旧存档可能带有滑杆范围外的阈值：钳制回 5...50 而不是锁死存档。
                if !(5...50).contains(loaded.warningThreshold) { loaded.warningThreshold = min(50, max(5, loaded.warningThreshold)); changed = true }
                try Self.validate(loaded); library = loaded
                let unknownConnections = Connection.takeUnknownFallbacks()
                if !unknownConnections.isEmpty {
                    notice = "有 \(unknownConnections.count) 处连接方式无法识别，已回退为「本机软件自动读取」，请在账户设置中确认。"
                    Log.store.error("unknown connection values fell back to agentLocal")
                }
                if changed { save() }
            } catch { library = Library(); loadFailed = true; notice = "数据文件读取失败，原文件已保留，暂时禁止写入。请检查原文件后再试。\n\(error.localizedDescription)" }
        } else { library = Library() }
    }
    func start() {
        guard timer == nil, ProcessInfo.processInfo.environment["GAOQINIANSAN_INTEGRATION_TEST"] != "1" else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshDue() }
        }
    }
    func setSuspended(_ value: Bool) {
        suspended = value
        if value { cancelRefreshes() }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        setSuspended(true)
    }
    private func cancelRefreshes(automaticOnly: Bool = false) {
        for (_, flight) in refreshTasks where !automaticOnly || flight.automatic { flight.task.cancel() }
    }
    private func reconcileRefreshTasks() {
        for (id, flight) in refreshTasks {
            guard let current = library.accounts.first(where: { $0.id == id }), current.enabled,
                  Self.sameSource(current, flight.account), !suspended,
                  !flight.automatic || library.autoRefresh else { flight.task.cancel(); continue }
        }
    }
    nonisolated private static func sameSource(_ lhs: Account, _ rhs: Account) -> Bool {
        lhs.provider == rhs.provider && lhs.kind == rhs.kind && lhs.connection == rhs.connection &&
        lhs.filePath == rhs.filePath && lhs.scopeID == rhs.scopeID && lhs.region == rhs.region && lhs.customConfig == rhs.customConfig
    }
    nonisolated private static func quotaSourceIdentity(_ account: Account) -> String {
        let customConfig = account.customConfig.map { String(reflecting: $0) }
        let fields: [String?] = [account.id.uuidString, account.provider.rawValue, account.kind.rawValue,
                                 account.connection.rawValue, account.filePath, account.scopeID,
                                 account.region, account.plan, account.currency, customConfig]
        let key = fields.map { $0.map { "\($0.utf8.count):\($0)" } ?? "-" }.joined(separator: ";")
        return quotaSourceDigest(key)
    }
    nonisolated private static func quotaSourceDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    nonisolated private static func requestKey(_ account: Account) -> String {
        // These routes read the single logged-in account on this Mac and accept no
        // per-account credential/scope. Other routes must never share credentials.
        switch account.connection {
        case .codex, .cursor, .grokAccount, .devinApp: return "local." + account.connection.rawValue
        default: return account.id.uuidString
        }
    }
    nonisolated private static func serviceKey(_ account: Account) -> String {
        if account.connection == .customAPI, let url = account.customConfig?.url,
           let host = URL(string: url)?.host { return "host." + host.lowercased() }
        if [.newAPIQuota, .sub2APIQuota].contains(account.connection),
           let host = URL(string: account.filePath)?.host { return "host." + host.lowercased() }
        return "provider." + account.provider.rawValue
    }
    // 纯函数校验：不访问实例状态，标记 nonisolated 供 DataTransfer 后台线程直接调用。
    nonisolated static func validate(_ lib: Library) throws {
        guard lib.schema == 1, (1...60).contains(lib.refreshMinutes), (5...50).contains(lib.warningThreshold), Set(lib.accounts.map(\.id)).count == lib.accounts.count else { throw MonitorError.message("不兼容或无效的存档。") }
        for a in lib.accounts {
            guard Connection.available(a.provider,a.kind).contains(a.connection), !a.name.trimmingCharacters(in:.whitespaces).isEmpty,
                  a.budget.map({ $0.isFinite && $0 > 0 }) ?? true,
                  // 币种必须是大写三字母 ASCII（小写 "usd" 会让预算提醒静默失效）
                  a.currency.count == 3 && a.currency.unicodeScalars.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) && $0.isASCII }) else { throw MonitorError.message("账户设置无效。") }
            try a.snapshot?.validate(); for s in a.history { try s.validate() }
        }
    }
    func save() {
        guard !loadFailed else { return }
        for i in library.accounts.indices { library.accounts[i].history=Array(library.accounts[i].history.suffix(300)) }
        do {
            try FileManager.default.createDirectory(at:dataURL.deletingLastPathComponent(),withIntermediateDirectories:true)
            try JSONCoding.encoder.encode(library).write(to:dataURL,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:dataURL.path)
        } catch { notice = "保存失败：\(error.localizedDescription)" }
    }
    private static func fileError(at url: URL) -> NSError {
        let code = Int(errno)
        return NSError(domain: NSPOSIXErrorDomain, code: code, userInfo: [NSFilePathErrorKey: url.path])
    }
    private func stageAccountSave(_ candidate: Library) throws -> URL {
        let data = try JSONCoding.encoder.encode(candidate)
        let directory = dataURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = directory.appendingPathComponent(".library-\(UUID().uuidString).tmp")
        let fd = staged.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600)) }
        guard fd >= 0 else { throw Self.fileError(at: staged) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            return staged
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }
    private func replaceStagedAccountSave(_ staged: URL) throws {
        let result = staged.path.withCString { from in
            dataURL.path.withCString { to in Darwin.rename(from, to) }
        }
        guard result == 0 else { throw Self.fileError(at: dataURL) }
    }
    private func invalidateRefresh(for id: UUID) {
        revisions[id, default: 0] += 1
        refreshTasks[id]?.task.cancel()
    }
    func validateCredentialRetry(for account: Account, key: String) throws {
        if incompleteCredentialSaves.contains(account.id), account.connection.needsKey,
           key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MonitorError.message("上次保存未完成，请重新填写该连接的凭据后保存。")
        }
    }
    func upsert(_ account: Account, key: String = "") throws {
        guard !loadFailed else { throw MonitorError.message("数据文件不可写，请检查原文件后再试。") }
        guard account.kind == .agent, account.provider != .custom else { throw MonitorError.message("搞词元仅记录 Agent 软件，不支持 API 账户。") }
        try validateCredentialRetry(for: account, key: key)
        let enteredKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        var copy = library
        var connectionChanged = false
        if let i = copy.accounts.firstIndex(where:{$0.id == account.id}) {
            var edited = account
            let current = copy.accounts[i]
            edited.history = current.history
            edited.antigravityReports = current.antigravityReports
            let sameSource = Self.sameSource(current, edited)
            if sameSource && enteredKey.isEmpty {
                edited.snapshot = current.snapshot; edited.lastAttempt = current.lastAttempt; edited.error = current.error; edited.statusNote = current.statusNote; edited.grokBotManualReading = current.grokBotManualReading
            } else { edited.snapshot = nil; edited.lastAttempt = nil; edited.error = nil; edited.statusNote = nil; edited.grokBotManualReading = nil }
            edited.quotaForecastHistory = sameSource && current.plan == edited.plan && current.currency == edited.currency && enteredKey.isEmpty
                ? current.quotaForecastHistory : nil
            connectionChanged = current.connection != edited.connection
            copy.accounts[i] = edited
        } else {
            var created = account
            created.quotaForecastHistory = nil
            created.antigravityReports = nil
            copy.accounts.append(created)
        }
        try Self.validate(copy)
        for i in copy.accounts.indices { copy.accounts[i].history = Array(copy.accounts[i].history.suffix(300)) }
        let staged = try stageAccountSave(copy)
        defer { try? FileManager.default.removeItem(at: staged) }

        if !enteredKey.isEmpty { try KeyVault.save(enteredKey,id:account.id) }
        // 切换连接方式且未提供新密钥时，清理旧连接残留的钥匙串条目。
        else if connectionChanged { KeyVault.delete(account.id) }
        do {
            try replaceStagedAccountSave(staged)
        } catch {
            if !enteredKey.isEmpty || connectionChanged {
                incompleteCredentialSaves.insert(account.id)
                invalidateRefresh(for: account.id)
                if let i = library.accounts.firstIndex(where: { $0.id == account.id }) {
                    library.accounts[i].quotaForecastHistory = nil
                }
                throw MonitorError.message("账户未能保存，凭据可能已更新。请在退出应用前重试保存。\n\(error.localizedDescription)")
            }
            throw error
        }
        if let current = library.accounts.first(where: { $0.id == account.id }),
           !Self.sameSource(current, account) || current.enabled != account.enabled || current.plan != account.plan ||
           current.currency != account.currency || !enteredKey.isEmpty {
            invalidateRefresh(for: account.id)
        }
        incompleteCredentialSaves.remove(account.id)
        library = copy
    }
    func importAntigravityReport(_ snapshot: UsageSnapshot, for id: UUID) throws {
        guard !loadFailed else { throw MonitorError.message("资料库不可写，未导入 Antigravity 报告。") }
        guard let index = library.accounts.firstIndex(where: { $0.id == id && $0.usesAntigravityReport }) else {
            throw MonitorError.message("请选择已保存的 Gemini 或 Antigravity 账户导入报告。")
        }
        let account = library.accounts[index]
        guard account.antigravityManualSource == snapshot.source else {
            throw MonitorError.message("报告来源与账户连接方式不符。请选择对应模式的报告。")
        }
        guard !refreshing.contains(id) else {
            throw MonitorError.message("账户正在同步，请在同步完成后导入 Antigravity 报告。")
        }
        guard !snapshot.historicalChartQuotas.isEmpty else {
            throw MonitorError.message("报告没有可保存的 Antigravity 额度。")
        }
        var report = snapshot
        report.isUnverifiedAntigravityReport = true
        report.observedAt = Date()
        try report.validate()
        let key = account.connection.rawValue
        if account.antigravityReports?[key]?.sameObservation(as: report) == true { return }
        var candidate = library
        var reports = account.antigravityReports ?? [:]
        reports[key] = report
        candidate.accounts[index].antigravityReports = reports
        do {
            let staged = try stageAccountSave(candidate)
            defer { try? FileManager.default.removeItem(at: staged) }
            try replaceStagedAccountSave(staged)
        } catch {
            throw MonitorError.message("Antigravity 报告未能保存：\(error.localizedDescription)")
        }
        library = candidate
    }
    func remove(_ id: UUID) {
        guard !loadFailed else { return }
        // 3.33：移除可自动发现的 agent 账户时记住选择，下次扫描不再自动加回。
        if let account = library.accounts.first(where: { $0.id == id }) { MemberDiscovery.rememberRemoval(account) }
        incompleteCredentialSaves.remove(id)
        revisions[id,default:0] += 1; library.accounts.removeAll { $0.id == id }; save(); KeyVault.delete(id); alerts.forget(account: id)
    }
    func updateSnapshot(_ s: UsageSnapshot, for id: UUID, forecastOrigin: String? = nil) throws {
        guard !loadFailed else { throw MonitorError.message("存档不可写。") }
        guard !s.isHistoricalAntigravityReading else {
            throw MonitorError.message("请将 Antigravity 报告导入为历史参考。")
        }
        try s.validate()
        guard let i = library.accounts.firstIndex(where:{$0.id == id}) else { return }
        let now = Date()
        let key = Self.quotaSourceIdentity(library.accounts[i]) + ":" + Self.quotaSourceDigest(forecastOrigin ?? s.source)
        QuotaForecast.record(account: &library.accounts[i], snapshot: s, sourceKey: key, now: now)
        // Unchanged measurements keep the existing history and pacing. A newer actual read still refreshes the current timestamp.
        if let current = library.accounts[i].snapshot, current.sameObservation(as: s) {
            if s.observedAt > current.observedAt && s.observedAt <= now {
                library.accounts[i].snapshot?.observedAt = s.observedAt
            }
            library.accounts[i].error = nil; library.accounts[i].statusNote = nil; library.accounts[i].lastAttempt = now; save()
            return
        }
        library.accounts[i].history.append(s)
        if library.accounts[i].history.count > 300 { library.accounts[i].history.removeFirst(library.accounts[i].history.count - 300) }
        lastChanges[id] = now
        // 3.2 排序键：观测值（额度/余额/积分）真变了才更新，持久化随存档走。
        library.accounts[i].lastQuotaChangedAt = now
        library.accounts[i].snapshot = s
        library.accounts[i].error = nil; library.accounts[i].statusNote = nil; library.accounts[i].lastAttempt = now; save()
    }
    // 状态消息（软件运行中/暂未启动/使用中稍后补读等）：只更新状态展示，绝不写入快照与历史。
    func updateStatus(_ message: String, for id: UUID) {
        guard !loadFailed, let i = library.accounts.firstIndex(where:{$0.id == id}) else { return }
        library.accounts[i].statusNote = message; library.accounts[i].error = nil; library.accounts[i].lastAttempt = Date(); save()
    }
    func refresh(_ id: UUID, userInitiated: Bool = false) async {
        guard !Task.isCancelled, !loadFailed, !suspended, userInitiated || library.autoRefresh,
              !incompleteCredentialSaves.contains(id), !refreshing.contains(id),
              let a = library.accounts.first(where: { $0.id == id }), a.kind == .agent, a.provider != .custom, a.enabled,
              !a.usesAntigravityReport else { return }
        if userInitiated { lastUserActions[id] = Date() }
        let revision = revisions[id, default: 0], token = UUID()
        refreshing.insert(id)
        let task = Task { [self] in
            await performRefresh(a, revision: revision, token: token, userInitiated: userInitiated)
        }
        refreshTasks[id] = RefreshFlight(token: token, account: a, automatic: !userInitiated, task: task)
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    private func performRefresh(_ a: Account, revision: Int, token: UUID, userInitiated: Bool) async {
        let id = a.id
        defer {
            if refreshTasks[id]?.token == token { refreshTasks.removeValue(forKey: id); refreshing.remove(id) }
        }
        do {
            let result = try await refreshCoordinator.perform(request: Self.requestKey(a) + (userInitiated ? ".manual" : ".automatic"), service: Self.serviceKey(a)) { [fetch] in
                try await HTTPPolicyContext.$userInitiated.withValue(userInitiated) {
                    try await HTTPPolicyContext.$trigger.withValue(userInitiated ? "quota.manual" : "quota.automatic") {
                        try await fetch(a, userInitiated)
                    }
                }
            }
            try Task.checkCancellation()
            guard revisions[id, default: 0] == revision,
                  let current = library.accounts.first(where: { $0.id == id }), current.enabled,
                  Self.sameSource(current, a), userInitiated || library.autoRefresh, !suspended else { return }
            switch result {
            case .snapshot(var s):
                let forecastOrigin = s.source
                if a.connection == .file {
                    if s.isHistoricalAntigravityReading { s.isUnverifiedAntigravityReport = true }
                    s.source = "快照文件"
                }
                let outcome: AlertOutcome
                // DeepSeek 分母模式：余额接口无百分比，按账户配置注入余额环（基线标记随账户持久化）。
                if a.connection == .deepseek, let i = library.accounts.firstIndex(where:{$0.id == id}) {
                    var snap = s
                    DeepSeekBasis.apply(account:&library.accounts[i], snapshot:&snap)
                    try updateSnapshot(snap,for:id,forecastOrigin:forecastOrigin)
                    outcome = .reading(snap)
                } else {
                    try updateSnapshot(s,for:id,forecastOrigin:forecastOrigin)
                    outcome = .reading(s)
                }
                // 一律传最新账户（快照已落地），不让告警评估抓到抓取前的旧副本。
                alerts.observe(account: library.accounts.first(where:{$0.id == id}) ?? a, outcome: outcome)
            case .status(let message):
                // A background pass may only report whether Grok Bot is running.
                // It must not replace a snapshot sentence the user already read.
                if !userInitiated, GrokBotBridge.isUsageRoute(a),
                   library.accounts.first(where: { $0.id == id })?.grokBotManualReading != nil {
                    break
                }
                updateStatus(message,for:id)
                alerts.observe(account: library.accounts.first(where:{$0.id == id}) ?? a, outcome: .neutral)
            case .grokBotManual(let message, let reading):
                if let i = library.accounts.firstIndex(where: { $0.id == id }) {
                    library.accounts[i].grokBotManualReading = reading
                }
                updateStatus(message, for: id)
                alerts.observe(account: library.accounts.first(where:{$0.id == id}) ?? a, outcome: .neutral)
            }
        } catch {
            // 整轮 180 秒上限取消在途刷新不是账户故障：不计错误、不进连续失败、不覆盖旧读数。
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            if revisions[id, default: 0] == revision, !suspended, userInitiated || library.autoRefresh,
               let i = library.accounts.firstIndex(where: { $0.id == id }), library.accounts[i].enabled,
               Self.sameSource(library.accounts[i], a) {
                // 与 updateStatus 对称：落 error 时清掉旧 statusNote，避免「前台使用中」等状态残留盖住新错误。
                library.accounts[i].error = error.localizedDescription; library.accounts[i].statusNote = nil; library.accounts[i].lastAttempt = Date(); save()
                alerts.observe(account: library.accounts[i], outcome: AlertRules.standing(connection: a.connection, error: error.localizedDescription))
            }
        }
    }
    // 阶段 3B：到期判定（纯函数便于测试）。fixed=true 沿用 refreshMinutes 固定间隔；
    // 否则逐账户按 AdaptivePacer：读数刚动过或用户刚手动刷过 → 地板 2 分钟，安静越久等越久，
    // 服务端计费类（本机看不见钱在烧）封顶 5 分钟，其余封顶 30 分钟。
    nonisolated static func dueIDs(accounts: [Account], fixed: Bool, refreshMinutes: Int, changes: [UUID:Date], actions: [UUID:Date], now: Date = Date()) -> [UUID] {
        accounts.filter { a in
            let due: TimeInterval = fixed
                ? TimeInterval(refreshMinutes * 60)
                : AdaptivePacer.interval(
                    signals: AdaptivePacer.Signals(lastChange: changes[a.id], lastUserAction: actions[a.id]),
                    isWatched: a.kind == .agent, now: now)
            return now.timeIntervalSince(a.lastAttempt ?? .distantPast) >= due
        }.map(\.id)
    }
    // 一批账户并行刷新，整轮 180 秒上限：一个挂住的连接器不该拖住整批的下一次到期判定。
    private func refreshGroup(_ ids: [UUID], userInitiated: Bool) async {
        guard !ids.isEmpty else { return }
        await withTaskGroup(of:Void.self) { race in
            race.addTask { await withTaskGroup(of:Void.self) { group in
                for id in ids { group.addTask { await self.refresh(id, userInitiated: userInitiated) } }
            } }
            race.addTask { try? await Task.sleep(nanoseconds: 180_000_000_000) }
            await race.next()
            race.cancelAll()
        }
    }
    func refreshAll(userInitiated: Bool = false) async {
        guard !suspended, userInitiated || library.autoRefresh else { return }
        await refreshGroup(active.filter { !$0.usesAntigravityReport }.map(\.id), userInitiated: userInitiated)
    }
    func refreshDue() async {
        guard !suspended, library.autoRefresh else { return }
        // 固定/自适应是用户偏好，存 UserDefaults，不进 Library schema（保持存档兼容）。
        let fixed = TokenBundle.defaults.bool(forKey: "refreshFixedInterval")
        let ids = Self.dueIDs(accounts: active.filter { !$0.usesAntigravityReport }, fixed: fixed,
                              refreshMinutes: library.refreshMinutes, changes: lastChanges, actions: lastUserActions)
        await refreshGroup(ids, userInitiated: false)
    }
    var active: [Account] { library.accounts.filter { $0.enabled && $0.kind == .agent && $0.provider != .custom } }
    /// 3.2：按「最近一次额度/余额/积分变化时间」倒序（刚消耗的排最上）。
    /// 从未变化的账户用首次观测时间兜底；键相同保持库序（enumerated 显式决胜，不依赖 sorted 稳定性）。
    nonisolated static func recentChangeOrder(_ accounts: [Account]) -> [Account] {
        func key(_ a: Account) -> Date {
            a.lastQuotaChangedAt ?? a.history.first?.observedAt ?? a.snapshot?.observedAt ?? .distantPast
        }
        return accounts.enumerated().sorted { lhs, rhs in
            let lk = key(lhs.element), rk = key(rhs.element)
            if lk != rk { return lk > rk }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
    /// 3.36：统一健康分类的唯一入口——模块顶部、聚合条、导出（总览简报）全部走它。
    func health(of a: Account) -> AccountHealth {
        if !a.warnings(threshold: library.warningThreshold).isEmpty { return .needsAction }
        if a.usesAntigravityReport && a.snapshot?.isHistoricalAntigravityReading != false {
            return a.historicalAntigravityReport != nil || a.unassignedLegacyAntigravityReport != nil ? .historical : .ok
        }
        if a.error != nil {
            // 凭证类（不自愈）或连续失败才算「需处理」；单次读取失败/服务未启动是「暂时无法同步」。
            if a.errorIsCredential { return .needsAction }
            let consecutive = alerts.memory.accounts[a.id.uuidString].map { $0.failures >= AlertMemory.failuresBeforeSaying } ?? false
            return consecutive ? .needsAction : .syncPaused
        }
        if a.snapshot != nil, a.stale() { return .historical }
        return .ok
    }
    /// 三态计数（与总览简报同一份）。
    var healthCounts: (needsAction: Int, syncPaused: Int, historical: Int) {
        var result = (needsAction: 0, syncPaused: 0, historical: 0)
        for a in active {
            switch health(of: a) {
            case .needsAction: result.needsAction += 1
            case .syncPaused: result.syncPaused += 1
            case .historical: result.historical += 1
            case .ok: break
            }
        }
        return result
    }
    var alertAccounts: [Account] {
        active.filter { health(of: $0) == .needsAction }
    }
    func exportCSV() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "搞词元-用量快照.csv"; panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func escape(_ text: String) -> String {
            let safe = ["=","+","-","@"].contains(text.first.map(String.init) ?? "") ? "'" + text : text
            return "\"" + safe.replacingOccurrences(of:"\"",with:"\"\"") + "\""
        }
        let f = ISO8601DateFormatter()
        var rows = [["账户","平台","类型","更新时间","统计开始","统计结束","来源","输入Token","输出Token","费用","余额","积分余额"]]
        for a in library.accounts where a.kind == .agent && a.provider != .custom {
            guard let s = a.snapshot else { continue }
            rows.append([a.name,a.provider.name,a.kind.rawValue,f.string(from:s.observedAt),s.periodStart.map(f.string) ?? "",s.periodEnd.map(f.string) ?? "",s.source,s.inputTokens.map(String.init) ?? "",s.outputTokens.map(String.init) ?? "",s.costs.map(\.text).joined(separator:"; "),s.balances.map(\.text).joined(separator:"; "),(s.creditBalances ?? []).map { $0.title + " " + $0.text }.joined(separator:"; ")])
        }
        do { try ("\u{FEFF}" + rows.map { $0.map(escape).joined(separator:",") }.joined(separator:"\r\n")).write(to:url,atomically:true,encoding:.utf8) } catch { notice = error.localizedDescription }
    }
}
