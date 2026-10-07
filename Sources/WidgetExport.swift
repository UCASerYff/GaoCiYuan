import Foundation
import AppKit
import WidgetKit

extension MonitorStore {
    private func reloadWidgets() {
        // 版本去重：只在应用版本变化时 reloadAllTimelines，避免每次保存都耗尽 WidgetKit reload 预算；
        // 小组件自身按 timeline（约 5 分钟）主动读取摘要文件。
        let release = TokenBundle.bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let key = "lastWidgetSnapshotRelease"
        guard TokenBundle.defaults.string(forKey:key) != release else { return }
        WidgetCenter.shared.reloadAllTimelines()
        TokenBundle.defaults.set(release,forKey:key)
    }

    @discardableResult
    func exportWidgetSnapshot() async -> Bool {
        #if !TESTING
        guard ProcessInfo.processInfo.environment["GAOCIYUAN_DATA_DIR"] == nil else { return false }
        let urls = GaoCiYuanWidgetSnapshot.candidateURLs
        guard !urls.isEmpty else { return false }
        let english = GQNSLanguage.isEnglish
        let threshold = library.warningThreshold
        let accounts = active // 值类型快照，随后的安装检测与写盘全部卸载到后台队列
        // 3.36：health(of:) 读 alerts.memory（MainActor），在进后台队列前算好映射。
        let healthMap: [UUID: String] = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, health(of: $0).rawValue) })
        let written: Bool = await Task.detached(priority: .utility) {
            let runningApps = NSWorkspace.shared.runningApplications
            let eligibleAccounts = accounts.filter { account in
                if account.kind == .agent && account.provider.integration == nil {
                    return MemberDiscovery.isAgentInstalled(account.provider, in: runningApps)
                }
                return true
            }
            // 3.32：按最近变化倒序导出，与悬浮条/总览卡片同序（lastQuotaChangedAt 新口径）。
            let items = MonitorStore.recentChangeOrder(eligibleAccounts).prefix(12).map { account in
                let snapshot = account.snapshot
                // 与图表同一口径：状态行与已过期（重置已过）窗口不进小组件——死数字挂着等于说谎。
                // 3.32：改用 displayQuotas——Antigravity/Codex 非凭证类失败时保留上次快照（含过期窗），与 app 内卡片一致。
                let rawQuotas = account.displayQuotas
                let filteredQuotas = rawQuotas.filter {
                    !$0.id.localizedCaseInsensitiveContains("reserve") &&
                    !$0.title.localizedCaseInsensitiveContains("reserve")
                }.sorted { $0.remaining < $1.remaining }
                return GaoCiYuanWidgetSnapshot.AccountItem(
                    id:account.id.uuidString,provider:account.provider.name,mark:account.provider.mark,
                    name:account.name,kind:account.kind.rawValue,
                    quotas:Array(filteredQuotas.prefix(8)).map { .init(id:$0.id,title:$0.title,remaining:$0.remaining,resetsAt:$0.resetsAt) },
                    balances:(snapshot?.balances ?? []).map(\.text) + (snapshot?.creditBalances ?? []).map { $0.title + " " + $0.text },costs:(snapshot?.costs ?? []).map(\.text),
                    totalTokens:snapshot?.totalTokens,observedAt:snapshot?.observedAt,
                    stale:account.stale(),failed:account.error != nil,health:healthMap[account.id])
            }
            let value = GaoCiYuanWidgetSnapshot(updatedAt:Date(),english:english,warningThreshold:threshold,accounts:Array(items))
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(value) else { return false }

            var exported = false
            for target in urls {
                do {
                    try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
                    try data.write(to:target,options:.atomic)
                    exported = true
                } catch { Log.store.error("widget snapshot write failed") }
            }
            return exported
        }.value
        if written {
            reloadWidgets()
        }
        return written
        #else
        return false
        #endif
    }
}
