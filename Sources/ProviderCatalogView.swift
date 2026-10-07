import SwiftUI

struct ProviderCatalogView: View {
    @EnvironmentObject private var analytics: UsageAnalyticsStore
    var addAccount: (Provider, AccountKind) -> Void
    @State private var query = ""
    @State private var section = "all"
    private var collectors: [UsageClientDefinition] {
        UsageClientDefinition.all.filter { matches($0.name + " " + $0.id) }
    }
    private var providers: [Provider] { Provider.allCases.filter { $0 != .custom && matches($0.name + " " + $0.agentSoftware) } }
    private func matches(_ text: String) -> Bool { query.isEmpty || text.localizedCaseInsensitiveContains(query) }
    private let columns = [GridItem(.adaptive(minimum: 310), alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("工具与账户接入").font(.title3.weight(.semibold))
                    Text("本地用量读取实际日志；账户额度查询套餐和余额。两者独立，按需连接。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("采集设置") { analytics.showSourceSettings = true }
            }
            HStack {
                TextField("搜索工具或平台", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                Picker("接入能力", selection: $section) {
                    Text("全部").tag("all"); Text("本地用量").tag("usage"); Text("账户额度").tag("limits")
                }.pickerStyle(.segmented).frame(maxWidth: 360)
            }
            if section != "limits" {
                HStack {
                    Label("本地用量 · \(UsageClientDefinition.all.count) 类来源", systemImage: "chart.bar.xaxis").font(.headline)
                    Spacer()
                    Text("客户端变体合并显示").font(.caption).foregroundStyle(.secondary)
                }
                Text("自动分析工具留下的 Token、模型和会话用量。没有日志的工具不会显示成零用量；同一工具的 CLI 与桌面端按实际数据格式归并。")
                    .font(.callout).foregroundStyle(.secondary)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(collectors) { tool in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "terminal").font(.title3).foregroundStyle(Theme.accent).frame(width: 28)
                            VStack(alignment: .leading, spacing: 7) {
                                Text(tool.name).font(.callout.weight(.semibold))
                                Text(tool.paths.map { "~/" + $0 }.joined(separator: " · "))
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                                Tag(text: analytics.preferences.engine.enabledClientIDs.contains(tool.id) ? "已选择采集" : "未选择采集", color: analytics.preferences.engine.enabledClientIDs.contains(tool.id) ? Theme.teal : .secondary)
                            }
                            Spacer(minLength: 0)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                if collectors.isEmpty { Text("未找到匹配的本地用量来源。").foregroundStyle(.secondary) }
            }
            if section != "usage" {
                Label("账户额度与余额", systemImage: "gauge.with.dots.needle.33percent").font(.headline)
                Text("有些平台仅提供余额，有些提供套餐额度窗口。新增接口需要对应账户凭据，添加账户后可先测试连接。凭据仅保存在本机钥匙串。")
                    .font(.callout).foregroundStyle(.secondary)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(providers) { provider in
                        VStack(alignment: .leading, spacing: 14) {
                            HStack { ProviderMark(provider: provider, size: 32); Text(provider.name).font(.headline); Spacer() }
                            Text(provider.note).font(.caption).foregroundStyle(.secondary).lineLimit(5).help(provider.note)
                            Spacer(minLength: 0)
                            if let integration = provider.integration {
                                Text(integration.connection.displayName).font(.caption2).foregroundStyle(Theme.teal)
                                Button("连接 \(integration.name)") { addAccount(provider, integration.kind) }
                            } else {
                                HStack {
                                    if provider.creationKinds.contains(.agent) {
                                        Button("添加 Agent 账户") { addAccount(provider, .agent) }
                                    }
                                    if provider.creationKinds.contains(.llm) {
                                        Button("添加 API 账户") { addAccount(provider, .llm) }
                                    }
                                }
                            }
                        }.frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading).panel()
                    }
                }
                if providers.isEmpty { Text("未找到匹配的账户连接器。").foregroundStyle(.secondary) }
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("其他余额接口").font(.headline)
                        Text("自定义 GET 地址、鉴权请求头与 JSON 数值路径。").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("添加自定义账户") { addAccount(.custom, .agent) }
                }.panel()
                DisclosureGroup("本机软件发现") { MemberDiscoveryPanel().padding(.top, 12) }
            }
        }
    }
}
