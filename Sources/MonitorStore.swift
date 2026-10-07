import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class MonitorStore: ObservableObject {
    @Published var library: Library
    @Published var refreshing = Set<UUID>()
    @Published var notice: String?
    private(set) var loadFailed = false
    let dataURL: URL
    let alerts: AlertCenter
    private var timer: Timer?
    private var revisions: [UUID:Int] = [:]
    // 阶段 3B：自适应节奏的信号记忆（内存态，重启后从封顶重新开始——只会偏保守，不会偏吵）。
    private var lastChanges: [UUID:Date] = [:]
    private var lastUserActions: [UUID:Date] = [:]
    init(directory: URL? = nil) {
        let root = directory
            ?? ProcessInfo.processInfo.environment["GAOCIYUAN_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("GaoSeries/Token")
        dataURL = root.appendingPathComponent("library.json")
        alerts = AlertCenter(directory: root)
        if FileManager.default.fileExists(atPath:dataURL.path) {
            do {
                let savedData = try Data(contentsOf: dataURL)
                var loaded = try JSONCoding.decoder.decode(Library.self, from: savedData)
                // Rewrite a valid legacy library once even when refresh is disabled.
                // Business validation below must succeed before anything is saved.
                let savedFields = try JSONSerialization.jsonObject(with: savedData) as? [String: Any]
                var changed = savedFields?.keys.contains("station") == true
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
            } catch { library = Library(); loadFailed = true; notice = "数据文件读取失败，原文件已保留，暂时禁止写入。请从备份恢复。\n\(error.localizedDescription)" }
        } else { library = Library() }
        if directory == nil {
            timer = Timer.scheduledTimer(withTimeInterval:60,repeats:true) { [weak self] _ in Task { @MainActor in await self?.refreshDue() } }
        }
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
    func upsert(_ account: Account, key: String = "") throws {
        guard !loadFailed else { throw MonitorError.message("请先恢复可用的数据备份。") }
        var copy = library
        var connectionChanged = false
        if let i = copy.accounts.firstIndex(where:{$0.id == account.id}) {
            var edited = account
            let current = copy.accounts[i]
            edited.history = current.history
            if current.connection == edited.connection && current.filePath == edited.filePath && current.scopeID == edited.scopeID && current.region == edited.region && key.isEmpty {
                edited.snapshot = current.snapshot; edited.lastAttempt = current.lastAttempt; edited.error = current.error; edited.statusNote = current.statusNote
            } else { edited.snapshot = nil; edited.lastAttempt = nil; edited.error = nil; edited.statusNote = nil }
            connectionChanged = current.connection != edited.connection
            copy.accounts[i] = edited
        } else { copy.accounts.append(account) }
        try Self.validate(copy)
        if !key.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { try KeyVault.save(key.trimmingCharacters(in:.whitespacesAndNewlines),id:account.id) }
        // 切换连接方式且未提供新密钥时，清理旧连接残留的钥匙串条目。
        else if connectionChanged { KeyVault.delete(account.id) }
        revisions[account.id,default:0] += 1; library = copy; save()
    }
    func remove(_ id: UUID) {
        guard !loadFailed else { return }
        // 3.33：移除可自动发现的 agent 账户时记住选择，下次扫描不再自动加回。
        if let provider = library.accounts.first(where: { $0.id == id })?.provider { MemberDiscovery.rememberRemoval(provider) }
        revisions[id,default:0] += 1; library.accounts.removeAll { $0.id == id }; save(); KeyVault.delete(id); alerts.forget(account: id)
    }
    func updateSnapshot(_ s: UsageSnapshot, for id: UUID) throws {
        guard !loadFailed else { throw MonitorError.message("存档不可写。") }
        try s.validate()
        guard let i = library.accounts.firstIndex(where:{$0.id == id}) else { return }
        // 历史幂等：快照值（额度、Token、费用、余额、来源、口径）不变时复用上一条 observedAt，
        // 不追加历史——比较时排除时间戳。重复读取同一文件/同一页面不产生新观测。
        if let current = library.accounts[i].snapshot {
            if current.sameObservation(as: s) {
                library.accounts[i].error = nil; library.accounts[i].statusNote = nil; library.accounts[i].lastAttempt = Date(); save()
                return
            }
        }
        library.accounts[i].history.append(s)
        if library.accounts[i].history.count > 300 { library.accounts[i].history.removeFirst(library.accounts[i].history.count - 300) }
        lastChanges[id] = Date()
        // 3.2 排序键：观测值（额度/余额/积分）真变了才更新，持久化随存档走。
        library.accounts[i].lastQuotaChangedAt = Date()
        library.accounts[i].snapshot = s
        library.accounts[i].error = nil; library.accounts[i].statusNote = nil; library.accounts[i].lastAttempt = Date(); save()
    }
    // 状态消息（软件运行中/暂未启动/使用中稍后补读等）：只更新状态展示，绝不写入快照与历史。
    func updateStatus(_ message: String, for id: UUID) {
        guard !loadFailed, let i = library.accounts.firstIndex(where:{$0.id == id}) else { return }
        library.accounts[i].statusNote = message; library.accounts[i].error = nil; library.accounts[i].lastAttempt = Date(); save()
    }
    func refresh(_ id: UUID, userInitiated: Bool = false) async {
        guard !loadFailed, !refreshing.contains(id), let a = library.accounts.first(where:{$0.id == id}), a.enabled else { return }
        if userInitiated { lastUserActions[id] = Date() }
        let revision = revisions[id,default:0]
        refreshing.insert(id); defer { refreshing.remove(id) }
        do {
            let result = try await Connectors.fetch(a, userInitiated: userInitiated)
            // Ignore responses after the user changed the account's connection while fetching.
            guard revisions[id,default:0] == revision, let current = library.accounts.first(where:{$0.id == id}), current.connection == a.connection, current.filePath == a.filePath else { return }
            switch result {
            case .snapshot(let s):
                let outcome: AlertOutcome
                // DeepSeek 分母模式：余额接口无百分比，按账户配置注入余额环（基线标记随账户持久化）。
                if a.connection == .deepseek, let i = library.accounts.firstIndex(where:{$0.id == id}) {
                    var snap = s
                    DeepSeekBasis.apply(account:&library.accounts[i], snapshot:&snap)
                    try updateSnapshot(snap,for:id)
                    outcome = .reading(snap)
                } else {
                    try updateSnapshot(s,for:id)
                    outcome = .reading(s)
                }
                // 一律传最新账户（快照已落地），不让告警评估抓到抓取前的旧副本。
                alerts.observe(account: library.accounts.first(where:{$0.id == id}) ?? a, outcome: outcome)
            case .status(let message):
                updateStatus(message,for:id)
                // 状态消息（软件运行中/暂未启动/稍后补读）是 neutral：不是故障，也不是可达性证据。
                alerts.observe(account: library.accounts.first(where:{$0.id == id}) ?? a, outcome: .neutral)
            }
        } catch {
            // 整轮 180 秒上限取消在途刷新不是账户故障：不计错误、不进连续失败、不覆盖旧读数。
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            if revisions[id,default:0] == revision, let i = library.accounts.firstIndex(where:{$0.id == id}), library.accounts[i].connection == a.connection {
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
        await refreshGroup(library.accounts.filter { $0.enabled }.map(\.id), userInitiated: userInitiated)
    }
    func refreshDue() async {
        guard library.autoRefresh else { return }
        // 固定/自适应是用户偏好，存 UserDefaults，不进 Library schema（保持存档兼容）。
        let fixed = TokenBundle.defaults.bool(forKey: "refreshFixedInterval")
        let ids = Self.dueIDs(accounts: active, fixed: fixed, refreshMinutes: library.refreshMinutes, changes: lastChanges, actions: lastUserActions)
        await refreshGroup(ids, userInitiated: false)
    }
    var active: [Account] { library.accounts.filter(\.enabled) }
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
    func exportBackup() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "搞词元-完整数据.gaociyuan"; panel.allowedContentTypes = [.gaoBackup]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // IO（逐文件 SHA-256 + 复制）卸载后台，面板在主线程，结果回到主线程提示。
        let snapshotLibrary = library, root = dataURL.deletingLastPathComponent(), preferences = Preferences.read()
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try DataTransfer.export(to:url,root:root,library:snapshotLibrary,preferences:preferences) }.value
                notice = "导出成功：账户、历史、设置和数据目录内的全部文档已打包。密钥仍保留在钥匙串。"
            } catch { notice = "导出失败：\(error.localizedDescription)" }
        }
    }
    func restoreBackup(from selectedURL: URL? = nil) {
        guard refreshing.isEmpty else { notice = "请等待当前同步完成后再导入。"; return }
        let url: URL
        if let selectedURL { url = selectedURL } else {
            let panel = NSOpenPanel(); panel.allowedContentTypes = [.gaoBackup,.json]; panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = false
            guard panel.runModal() == .OK, let picked = panel.url else { return }; url = picked
        }
        let root = dataURL.deletingLastPathComponent()
        Task {
            do {
                // 校验备份包（SHA-256 全量核验）在后台执行，确认对话框与存档切换回到主线程。
                let incoming = try await Task.detached(priority: .userInitiated) { try DataTransfer.prepare(url) }.value
                let alert = NSAlert(); alert.messageText = L("导入这份数据？"); alert.informativeText = L("将导入 \(incoming.library.accounts.count) 个账户及 \(incoming.fileCount) 个文档文件。当前数据会完整保留为用户备份，导入后暂停自动同步。API 密钥不随文件转移。"); alert.addButton(withTitle:L("导入")); alert.addButton(withTitle:L("取消"))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                let restored = try await Task.detached(priority: .userInitiated) { try DataTransfer.restore(incoming,to:root) }.value
                for id in Set(library.accounts.map(\.id) + restored.accounts.map(\.id)) { revisions[id,default:0] += 1 }
                library = restored; loadFailed = false; incoming.preferences?.apply()
                let unknownConnections = Connection.takeUnknownFallbacks()
                notice = "导入完成，原数据及所有文档均已保留。请检查账户连接后再开启自动同步。" + (unknownConnections.isEmpty ? "" : " 有 \(unknownConnections.count) 处连接方式无法识别，已回退为「本机软件自动读取」。")
            } catch { notice = "导入失败：\(error.localizedDescription)" }
        }
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
        for a in library.accounts {
            guard let s = a.snapshot else { continue }
            rows.append([a.name,a.provider.name,a.kind.rawValue,f.string(from:s.observedAt),s.periodStart.map(f.string) ?? "",s.periodEnd.map(f.string) ?? "",s.source,s.inputTokens.map(String.init) ?? "",s.outputTokens.map(String.init) ?? "",s.costs.map(\.text).joined(separator:"; "),s.balances.map(\.text).joined(separator:"; "),(s.creditBalances ?? []).map { $0.title + " " + $0.text }.joined(separator:"; ")])
        }
        do { try ("\u{FEFF}" + rows.map { $0.map(escape).joined(separator:",") }.joined(separator:"\r\n")).write(to:url,atomically:true,encoding:.utf8) } catch { notice = error.localizedDescription }
    }
}
