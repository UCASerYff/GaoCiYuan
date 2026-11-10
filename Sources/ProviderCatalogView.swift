import SwiftUI

struct ProviderCatalogView: View {
    @EnvironmentObject private var analytics: UsageAnalyticsStore
    var addAccount: (Provider, AccountKind) -> Void
    @State private var query = ""
    private var collectors: [UsageClientDefinition] {
        UsageClientDefinition.all.filter { matches($0.name + " " + $0.id) }
    }
    private var providers: [Provider] {
        Provider.allCases.filter { $0.creationKinds == [.agent] && matches($0.name + " " + $0.agentSoftware) }
    }
    private func matches(_ text: String) -> Bool {
        query.isEmpty || text.localizedCaseInsensitiveContains(query)
    }
    private let columns = [GridItem(.adaptive(minimum: 280), alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("搜索 Agent 软件或本地来源", text: $query)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                Spacer()
                Button("采集设置") { analytics.showSourceSettings = true }.controlSize(.small)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(providers) { provider in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 9) {
                            ProviderMark(provider: provider, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.agentSoftware).font(.headline)
                                Text(provider.company).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        Text(provider.note).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(4).frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
                        HStack {
                            if let integration = provider.integration {
                                Text(integration.connection.displayName)
                                    .font(.caption2).foregroundStyle(Theme.teal).lineLimit(1)
                            } else {
                                Text("本机发现 · 额度连接")
                                    .font(.caption2).foregroundStyle(Theme.teal)
                            }
                            Spacer()
                            Button("接入") { addAccount(provider, .agent) }.controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading).panel()
                }
            }
            if providers.isEmpty {
                Text("未找到匹配的 Agent 软件。").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80).panel()
            }
            DisclosureGroup {
                MemberDiscoveryPanel().padding(.top, 10)
            } label: {
                Label("本机软件发现", systemImage: "desktopcomputer").font(.headline)
            }
            .panel()
            Divider().padding(.vertical, 2)
            HStack {
                Label("本地用量采集 · \(UsageClientDefinition.all.count) 类来源", systemImage: "chart.xyaxis.line").font(.headline)
                Spacer()
                Text("CLI 与桌面端按实际日志格式归并").font(.caption).foregroundStyle(.secondary)
            }
            Text("只分析 Agent 软件留下的 Token、模型和会话记录；没有日志时不显示成零用量。")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(collectors) { tool in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "terminal").font(.callout).foregroundStyle(Theme.accent).frame(width: 24)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(tool.name).font(.callout.weight(.semibold))
                            Text(tool.paths.map { "~/" + $0 }.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                            Tag(text: analytics.preferences.engine.enabledClientIDs.contains(tool.id) ? "已选择采集" : "未选择采集",
                                color: analytics.preferences.engine.enabledClientIDs.contains(tool.id) ? Theme.teal : .secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).panel()
                }
            }
            if collectors.isEmpty { Text("未找到匹配的本地用量来源。").foregroundStyle(.secondary) }
        }
    }
}
