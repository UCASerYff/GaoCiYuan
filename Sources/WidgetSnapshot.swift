import Foundation

struct GaoCiYuanWidgetSnapshot: Codable, Equatable {
    static let groupID = "5G96498KGJ.com.gaoseries.GaoCiYuan"
    static let fileName = "usage-summary.json"

    struct QuotaItem: Codable, Identifiable, Equatable {
        let id: String
        let title: String
        let remaining: Double
        let resetsAt: Date?
    }

    struct AccountItem: Codable, Identifiable, Equatable {
        let id: String
        let provider: String
        let mark: String
        let name: String
        let kind: String
        let quotas: [QuotaItem]
        let balances: [String]
        let costs: [String]
        let totalTokens: Int64?
        let observedAt: Date?
        let stale: Bool
        let failed: Bool
        /// 3.36：统一健康分类（needsAction/syncPaused/historical/ok），主 app 总览简报与模块顶部共用。
        /// 可选以兼容旧版导出文件（nil 时读取方按 failed/stale 退化推断）。
        let health: String?
        var eligibleQuotas: [QuotaItem] {
            quotas.filter {
                !$0.id.localizedCaseInsensitiveContains("reserve") &&
                !$0.title.localizedCaseInsensitiveContains("reserve")
            }.sorted { $0.remaining < $1.remaining }
        }
        var lowestRemaining: Double? { eligibleQuotas.first?.remaining ?? quotas.map(\.remaining).min() }
    }

    let updatedAt: Date
    let english: Bool
    let warningThreshold: Double
    let accounts: [AccountItem]

    init(updatedAt: Date, english: Bool, warningThreshold: Double = 20, accounts: [AccountItem]) {
        self.updatedAt = updatedAt
        self.english = english
        self.warningThreshold = warningThreshold
        self.accounts = accounts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        english = try c.decode(Bool.self, forKey: .english)
        // 旧版本导出的摘要没有阈值字段，回落到默认 20，与历史行为一致。
        warningThreshold = try c.decodeIfPresent(Double.self, forKey: .warningThreshold) ?? 20
        accounts = try c.decode([AccountItem].self, forKey: .accounts)
    }

    // 只保留真实可达的位置：App Group 容器与小组件自身容器。
    // 已删除 ~/Documents 与 Application Support 两条死兜底路径——ad-hoc 签名下小组件读不到应用容器外的文件。
    static var candidateURLs: [URL] {
        var list: [URL] = []
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            list.append(group.appendingPathComponent(fileName))
        }
        return list
    }

    static var fileURL: URL? {
        candidateURLs.first
    }
}

/// Independent actual-usage summary; never add account quota snapshots to these totals.
struct ActualTokenWidgetSnapshot: Codable {
    struct Day: Codable, Identifiable { let day: String; let tokens: Int64; var id: String { day } }
    let updatedAt: Date
    let day: String
    let totalTokens: Int64
    let input: Int64
    let output: Int64
    let cacheRead: Int64
    let estimatedUSD: Double?
    let days: [Day]
    static let fileName = "actual-token-usage.json"
    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: GaoCiYuanWidgetSnapshot.groupID)?.appendingPathComponent(fileName)
    }
}
