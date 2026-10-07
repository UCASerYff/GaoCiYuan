import AppKit
import SwiftUI

struct UsageSourceSettingsView: View {
    @EnvironmentObject private var store: UsageAnalyticsStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = UsageAnalyticsPreferences()
    @State private var priceDrafts: [UsagePriceDraft] = []
    @State private var sourceSearch = ""
    @State private var selectedClientID = "codex"
    @State private var detectedIDs = Set<String>()
    @State private var validationError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("用量采集设置").font(.title2.weight(.semibold))
                    Text("配置本机工具、数据目录和费用估算及可选的官方账户用量。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存并采集") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    cadenceSection
                    sourceSection
                    pathSection
                    pricingSection
                    exportSection
                    privacySection
                }.padding(22)
            }.background(Theme.canvas)
        }
        .frame(width: 760, height: 690)
        .onAppear {
            draft = store.preferences
            priceDrafts = draft.engine.modelPrices.map(UsagePriceDraft.init)
            refreshDetectedPaths()
        }
        .onChange(of: store.errorMessage) { _, value in
            if let value { validationError = value }
        }
        .alert("设置未保存", isPresented: Binding(get: { validationError != nil }, set: { if !$0 { validationError = nil } })) {
            Button("知道了") { validationError = nil }
        } message: { Text(validationError ?? "") }
    }

    private var cadenceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("采集频率").font(.headline)
            Toggle("应用运行时自动采集", isOn: $draft.automaticallyScan)
            HStack {
                Stepper("每 \(draft.refreshMinutes) 分钟", value: $draft.refreshMinutes, in: 2...60)
                    .frame(width: 230).disabled(!draft.automaticallyScan)
                Spacer()
                Text("初次读取完整历史可能需要几分钟。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.panel()
    }

    private var filteredSources: [UsageClientDefinition] {
        let search = sourceSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return UsageClientDefinition.all.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search)
        }
    }
    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("采集工具").font(.headline)
                Spacer()
                Text("已选择 \(draft.engine.enabledClientIDs.count) 项").font(.caption).foregroundStyle(.secondary)
                Button("恢复默认选择") { draft.engine.enabledClientIDs = UsageClientDefinition.defaultIDs }
                    .font(.caption)
            }
            TextField("查找工具", text: $sourceSearch).textFieldStyle(.roundedBorder)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 13) {
                ForEach(filteredSources) { client in
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(client.name, isOn: sourceBinding(client.id))
                            .font(.callout).toggleStyle(.checkbox)
                        Label(client.id == "cursor" ? (detectedIDs.contains(client.id) ? "发现编辑器，需有效登录和导出权限" : "需安装并登录 Cursor 编辑器") : (detectedIDs.contains(client.id) ? "发现本机数据路径" : "暂未发现默认路径"), systemImage: detectedIDs.contains(client.id) ? "folder.fill" : "folder")
                            .font(.caption2)
                            .foregroundStyle(detectedIDs.contains(client.id) ? Theme.teal : Color.secondary)
                            .padding(.leading, 21)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("发现路径只表示文件或目录存在，实际读取取决于日志格式和权限；没有采集到记录不代表实际用量为零。MiMo 的 Claude 导入副本可能重复，默认不采集。Cursor 官方账户用量默认关闭，启用后使用编辑器当前登录态读取完整分页历史。")
                .font(.caption).foregroundStyle(.secondary)
        }.panel()
    }

    private var selectedClient: UsageClientDefinition? { UsageClientDefinition.all.first { $0.id == selectedClientID } }
    private var currentPaths: [String] { draft.engine.customPaths[selectedClientID] ?? [] }
    private var pathSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("自定义数据目录").font(.headline)
                Spacer()
                Picker("工具", selection: $selectedClientID) {
                    ForEach(UsageClientDefinition.all.filter(\.supportsCustomPaths)) { client in
                        Text(client.name).tag(client.id)
                    }
                }.frame(width: 245)
                Button { chooseSourceDirectory() } label: { Label("添加目录", systemImage: "folder.badge.plus") }
                    .disabled(currentPaths.count >= 16)
            }
            if let client = selectedClient {
                Text("在工具默认目录之外，再读取这里指定的日志目录。也支持工具官方的环境变量目录（应用启动时继承）；添加目录后会选择该工具。")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("默认数据位置") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(client.paths, id: \.self) { Text("~/" + $0).font(.caption.monospaced()).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }.font(.caption).foregroundStyle(.secondary)
            }
            if currentPaths.isEmpty {
                Text("尚未添加额外目录").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(currentPaths, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(Theme.accent)
                        Text(path).font(.caption).lineLimit(2).truncationMode(.middle).help(path).textSelection(.enabled)
                        Spacer()
                        Button { removePath(path) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("移除此采集目录，已保存的历史仍然保留")
                    }
                }
            }
        }.panel()
    }

    private var pricingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("自定义模型价格").font(.headline)
                Spacer()
                Button { priceDrafts.append(.empty) } label: { Label("添加模型", systemImage: "plus") }
                    .disabled(priceDrafts.count >= 500)
            }
            Text("单位为美元 / 百万 Token。模型名需与明细中的名称完全一致；留空不设定此项，填写 0 表示该项免费。至少填写输入或输出价格；缺少计费类型时保留原估价。")
                .font(.caption).foregroundStyle(.secondary)
            if priceDrafts.isEmpty {
                Text("当前使用公开模型价格表；无法定价的模型显示“未定价”。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach($priceDrafts) { $row in
                UsagePriceEditor(row: $row) { priceDrafts.removeAll { $0.id == row.id } }
            }
        }.panel()
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("自动导出").font(.headline)
                Spacer()
                Button(store.automaticExportPath == nil ? "选择导出文件夹…" : "更换文件夹…") {
                    store.chooseAutomaticExportDirectory()
                }
                if store.automaticExportPath != nil {
                    Button("停用") { store.disableAutomaticExport() }
                }
            }
            if let path = store.automaticExportPath {
                Label(path, systemImage: "folder.fill").font(.caption).foregroundStyle(Theme.accent).textSelection(.enabled)
                Text("已启用：每次采集完成后更新导出文件。文件夹选择立即生效。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("尚未启用。选择后每次采集将自动写入 JSON，可使用你自己的同步盘文件夹。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("JSON 保留全部历史与设备标识，用于合并设备；CSV 按看板当前日期范围导出。导出内容包含项目名称、标识与用量元数据。")
                .font(.caption).foregroundStyle(.secondary)
        }.panel()
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("本地统计与开源来源", systemImage: "internaldrive").font(.headline)
            Text(UsageEngine.privacyNotice).font(.caption).foregroundStyle(.secondary)
            Text(CursorUsageBridge.notice).font(.caption).foregroundStyle(.secondary)
            Text("本地扫描不读取登录凭据。Cursor 仅在你启用后复用当前登录态，不保存密钥、不切换账号；导出记录按账户去重，保存在应用独立数据库。")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Link("Token Monitor", destination: URL(string: "https://github.com/Javis603/token-monitor")!)
                Link("Tokscale", destination: URL(string: "https://github.com/Javis603/tokscale")!)
                Text("MIT 开源许可随应用附带").foregroundStyle(.secondary)
            }.font(.caption)
        }.panel()
    }

    private func sourceBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { draft.engine.enabledClientIDs.contains(id) }, set: { enabled in
            if enabled, !draft.engine.enabledClientIDs.contains(id) { draft.engine.enabledClientIDs.append(id) }
            if !enabled { draft.engine.enabledClientIDs.removeAll { $0 == id } }
        })
    }
    private func refreshDetectedPaths() { detectedIDs = Set(UsageClientDefinition.detectedIDs(customPaths: draft.engine.customPaths)) }
    private func chooseSourceDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.message = "选择 \(selectedClient?.name ?? selectedClientID) 的额外日志目录。仅用于读取 Token 统计。"
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.map { $0.standardizedFileURL.path }
        guard added.allSatisfy({ path in
            path.hasPrefix("/") && path.count <= 4096 && path.rangeOfCharacter(from: CharacterSet(charactersIn: ",\n\r\0")) == nil
        }) else {
            validationError = "当前采集引擎不支持包含逗号或换行的目录名。请选择其他目录。"; return
        }
        let paths = Array(Set(currentPaths + added)).sorted()
        guard paths.count <= 16 else { validationError = "每个工具最多添加 16 个自定义目录。"; return }
        draft.engine.customPaths[selectedClientID] = paths
        if !draft.engine.enabledClientIDs.contains(selectedClientID) { draft.engine.enabledClientIDs.append(selectedClientID) }
        refreshDetectedPaths()
    }
    private func removePath(_ path: String) {
        draft.engine.customPaths[selectedClientID]?.removeAll { $0 == path }
        if draft.engine.customPaths[selectedClientID]?.isEmpty == true { draft.engine.customPaths.removeValue(forKey: selectedClientID) }
        refreshDetectedPaths()
    }
    private func save() {
        do {
            let prices = try priceDrafts.map { try $0.validated() }
            guard Set(prices.map(\.model)).count == prices.count else {
                throw UsagePriceValidationError.message("同一个模型只能填写一组自定义价格，请移除重复模型。")
            }
            draft.engine.modelPrices = prices
            store.savePreferences(draft)
        } catch { validationError = error.localizedDescription }
    }
}

private struct UsagePriceEditor: View {
    @Binding var row: UsagePriceDraft
    let remove: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("模型完整名称，如 gpt-5", text: $row.model).textFieldStyle(.roundedBorder)
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }.buttonStyle(.borderless)
                    .help("移除此自定义价格")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], alignment: .leading, spacing: 10) {
                priceField("输入", text: $row.input)
                priceField("输出", text: $row.output)
                priceField("缓存读取", text: $row.cacheRead)
                priceField("缓存写入", text: $row.cacheWrite)
                priceField("缓存写入 · 1 小时", text: $row.cacheWrite1h)
            }
        }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
    private func priceField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            TextField("不覆盖", text: text).textFieldStyle(.roundedBorder)
                .font(.callout.monospacedDigit())
        }
    }
}

private enum UsagePriceValidationError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { message } else { nil } }
}
private struct UsagePriceDraft: Identifiable {
    let id = UUID()
    var model: String
    var input: String
    var output: String
    var cacheRead: String
    var cacheWrite: String
    var cacheWrite1h: String
    static var empty: Self { .init(model: "", input: "", output: "", cacheRead: "", cacheWrite: "", cacheWrite1h: "") }
    init(model: String, input: String, output: String, cacheRead: String, cacheWrite: String, cacheWrite1h: String) {
        self.model = model; self.input = input; self.output = output
        self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.cacheWrite1h = cacheWrite1h
    }
    init(_ price: UsageModelPrice) {
        model = price.model; input = Self.string(price.inputPerMillion); output = Self.string(price.outputPerMillion)
        cacheRead = Self.string(price.cacheReadPerMillion); cacheWrite = Self.string(price.cacheWritePerMillion)
        cacheWrite1h = Self.string(price.cacheWrite1hPerMillion)
    }
    private static func string(_ value: Double?) -> String { value.map { String($0) } ?? "" }
    func validated() throws -> UsageModelPrice {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 300 else { throw UsagePriceValidationError.message("请填写自定义价格对应的模型名称（最多 300 字）。") }
        let inputValue = try number(input, field: "输入", model: name)
        let outputValue = try number(output, field: "输出", model: name)
        guard inputValue != nil || outputValue != nil else {
            throw UsagePriceValidationError.message("\(name)：至少填写输入或输出价格，免费时请明确填写 0。")
        }
        return .init(model: name, inputPerMillion: inputValue, outputPerMillion: outputValue,
                     cacheReadPerMillion: try number(cacheRead, field: "缓存读取", model: name),
                     cacheWritePerMillion: try number(cacheWrite, field: "缓存写入", model: name),
                     cacheWrite1hPerMillion: try number(cacheWrite1h, field: "1 小时缓存写入", model: name))
    }
    private func number(_ raw: String, field: String, model: String) throws -> Double? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        guard let parsed = Double(value), parsed.isFinite, parsed >= 0 else {
            throw UsagePriceValidationError.message("\(model) 的\(field)价格“\(value)”无效。请输入不小于 0 的数字，小数使用英文句点。")
        }
        return parsed
    }
}
