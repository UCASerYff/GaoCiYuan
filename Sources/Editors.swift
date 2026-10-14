import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AccountEditor: View {
    @EnvironmentObject var store: MonitorStore
    @Environment(\.dismiss) var dismiss
    @State var account: Account
    @State private var key = ""
    @State private var budget = ""
    @State private var error: String?
    @State private var testing = false
    @State private var testResult: String?
    @State private var copilotBusy = false
    @State private var copilotCode: String?
    @State private var copilotTask: Task<Void, Never>?
    private var isExisting: Bool { store.library.accounts.contains { $0.id == account.id } }
    private var selectableProviders: [Provider] {
        Provider.allCases.filter { isExisting || $0.creationKinds.contains(account.kind) }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            HStack { Text(L("账户设置")).font(.title2.weight(.semibold)); Spacer(); Tag(text:account.provider.name,color:account.provider.color) }
            Form {
                Picker(L("平台"),selection:$account.provider) { ForEach(selectableProviders) { Text(L($0.name)).tag($0) } }.disabled(isExisting)
                if account.kind == .agent {
                    HStack { Text(L("专属 Agent 软件")); Spacer(); Text(account.provider.agentSoftware).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.teal) }
                }
                TextField(L("账户名称"),text:$account.name)
                TextField(L("套餐 / 组织备注"),text:$account.plan,prompt:Text(account.kind == .agent ? L("如 Plus、Pro、Max、Coding Plan") : L("如组织名称或项目名")))
                Picker(L("连接方式"),selection:$account.connection) { ForEach(Connection.available(account.provider,account.kind),id:\.self) { Text(L($0 == .kimiDesktop ? "Kimi 桌面订阅页（推荐 · 免 Key）" : $0 == .geminiApp ? "Gemini App 中的 Antigravity（推荐）" : ($0 == .agentLocal && account.provider == .gemini ? "Antigravity 独立 App" : $0.rawValue))).tag($0) } }
                integrationSettings
                if account.connection.needsKey {
                    if [.aliyun,.volc,.xai,.volcArk].contains(account.connection) {
                        TextField(L(account.connection == .xai ? "Team ID" : "AccessKey ID"),text:Binding(get:{account.scopeID ?? ""},set:{account.scopeID = $0}))
                    }
                    if [.minimax,.glm].contains(account.connection) {
                        Picker(L("服务地区"),selection:Binding(get:{account.region ?? "cn"},set:{account.region = $0})) { Text(L("国内站")).tag("cn"); Text(L("国际站")).tag("global") }
                    }
                    if account.connection == .copilot {
                        HStack(spacing:12) {
                            Button(L(copilotBusy ? "等待浏览器授权…" : "登录 GitHub")) { copilotLogin() }.disabled(copilotBusy)
                            if copilotBusy { Button(L("取消")) { copilotTask?.cancel(); copilotBusy = false; copilotCode = nil } }
                            if let copilotCode { Text(L("浏览器中输入代码：")).foregroundStyle(.secondary) + Text(copilotCode).font(.callout.weight(.bold)).monospacedDigit() }
                        }
                        Text(L("点「登录 GitHub」后代码已复制到剪贴板并打开授权页，输入代码即完成；只索取 read:user 权限（读不了代码仓库），令牌仅存本机钥匙串，与 gh CLI 的凭证无关。授权页会显示 VS Code Copilot 插件的名字——这是它公开的客户端，不是官方集成。")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        SecureField(L(account.connection.credentialLabel ?? ([.aliyun,.volc,.volcArk].contains(account.connection) ? "AccessKey Secret" : account.connection == .xai ? "Management Key" : account.connection == .kimiCoding ? "Kimi Code Key" : "API 密钥")),text:$key,prompt:Text(L("留空保留已存密钥")))
                        Text(L(account.connection.integration != nil ? "凭据仅保存在本机钥匙串，查询失败会保留上次数据；内部控制台接口可能随平台升级而变动。" : account.connection == .kimiCoding ? "使用 Kimi Code 订阅专用 Key（kimi.com 控制台获取，通常 sk-kimi- 开头），与 Moonshot 开放平台按量 Key 互不通用。密钥仅保存在本机钥匙串。" : account.connection == .openai || account.connection == .anthropic ? "需要组织 Admin Key，普通模型调用 Key 无法读取组织账单。密钥仅保存在本机钥匙串。" : "使用对应套餐或云平台的查询凭据；云余额接口需要财务只读权限，普通模型 Key 不适用。密钥仅保存在本机钥匙串。")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if account.connection == .file {
                    HStack { TextField(L("快照文件"),text:$account.filePath); Button(L("选择…")) { let p = NSOpenPanel(); p.allowedContentTypes = [.json]; if p.runModal() == .OK { account.filePath = p.url?.path ?? "" } } }
                    Text(L("读取标准 JSON 快照，不是任意平台原始账单。格式示例见设置页，可由外部脚本持续更新。")).font(.caption).foregroundStyle(.secondary)
                }
                if account.connection == .deepseek {
                    Picker(L("余额分母"),selection:Binding(get:{account.balanceBasis ?? "sinceTopUp"},set:{account.balanceBasis = $0})) {
                        Text(L("充值以来峰值（默认 · 实测）")).tag("sinceTopUp")
                        Text(L("仅余额（无分母）")).tag("balanceOnly")
                        Text(L("我的预算")).tag("budget")
                    }
                    Text(L("DeepSeek 余额接口不含百分比。「充值以来峰值」以本机观测到的余额峰值为分母，余额上升视为充值重新计满；「我的预算」以上方本月预算数字为分母。")).font(.caption).foregroundStyle(.secondary)
                }
                if account.connection == .geminiApp {
                    Text(L("自动读取本机 Gemini 桌面端内置的 Antigravity 服务与配额（5 小时 / 每周额度池）。Gemini 运行且开启 Antigravity 时自动同步，无需配置 Key。")).font(.callout).foregroundStyle(.secondary)
                }
                if account.connection == .agentLocal {
                    if account.provider == .gemini {
                        Text(L("自动读取独立版 Antigravity（或 Antigravity IDE）本机会话与配额池。软件运行中自动保持同步。")).font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text(L("自动检测本机 \(account.provider.agentSoftware) 软件与 CLI 状态，自动保持同步，无需手动录入。")).font(.callout).foregroundStyle(.secondary)
                    }
                }
                if account.connection == .codex {
                    Text(L("复用本机 Codex 已登录的会员账号，通过官方服务读取所有额度池。不读取聊天、不发起模型调用。")).font(.callout).foregroundStyle(.secondary)
                }
                if account.connection == .claudeDesktop {
                    Text(L("借用本机 Claude 桌面端（Electron）的登录会话读取官方用量，适合主要在桌面端使用 Claude 的场景。默认关闭，仅在你显式选择时启用，首次需一次钥匙串授权。只读会话键与当前组织，不读取聊天内容。")).font(.callout).foregroundStyle(.secondary)
                }
                if account.connection == .cursor {
                    Text(L("复用本机 Cursor 编辑器已登录的账号：读取编辑器自己保存的登录令牌，拼出官方账号接口认可的会话，不读取浏览器 Cookie。Cursor 会自动续期令牌；提示过期时打开一次 Cursor 即可。只读额度与余额，不发起模型调用。")).font(.callout).foregroundStyle(.secondary)
                }
                if account.connection == .grokAccount {
                    Text(L("借用本机 Grok CLI 已登录的账号，读取全 Grok 产品共用的账号额度池（网页聊天/Imagine/语音/API/CLI 同一个池）。CLI 令牌约 6 小时有效、使用中自动续期；提示过期时在 Grok CLI 中使用一次即可。与 Grok Bot（CLI 账单）是两笔账。")).font(.callout).foregroundStyle(.secondary)
                }
                if account.connection == .volcArk {
                    Text(L("火山方舟 Coding Plan / Agent Plan 官方签名接口（按公开实现对接，未对真实账号验证）。需要火山引擎 AccessKey 对：AccessKey ID 填上行、Secret 填下行，两条套餐接口独立查询，一条被拒不影响另一条。")).font(.callout).foregroundStyle(.secondary)
                }
                if account.connection == .mimoCoding {
                    Text(L("小米 MiMo Coding Plan 控制台会话（按公开实现对接，未对真实账号验证）：在 platform.xiaomimimo.com 登录后，从浏览器开发者工具复制完整 Cookie 头粘贴到密钥框。只保留 serviceToken/userId 等必需项，其余 Cookie 不出本机；会话过期后需重新复制。")).font(.callout).foregroundStyle(.secondary)
                }
                if account.connection == .devinApp {
                    Text(L("只读读取本机 Devin 应用（前身为 Windsurf）启动时保存的套餐缓存：每日/每周额度与超额余额，观测时间即最近一次启动，超过 24 小时未启动视为过旧。无需任何凭证；与账单 API 路独立，互不回退。")).font(.callout).foregroundStyle(.secondary)
                }
                if account.connection == .devinApi {
                    Text(L("Devin 账单接口（按公开实现对接，未对真实账号验证）：从 app.devin.ai 浏览器开发者工具复制 Authorization 请求头与组织名（或组织设置页地址），以「token 组织」格式粘贴到密钥框。接口报已用百分比，与本机缓存报的剩余相反。")).font(.callout).foregroundStyle(.secondary)
                }
                if account.connection == .ollamaCloud {
                    Text(L("Ollama Cloud 账号额度（按公开实现对接，未对真实账号验证）：在 ollama.com 登录后，从浏览器开发者工具复制完整 Cookie 头粘贴到密钥框。只保留 wos-session 等认证项，其余 Cookie 不出本机；读取设置页的 Session（5 小时）与 Weekly（每周）用量。")).font(.callout).foregroundStyle(.secondary)
                }
                if account.connection == .commandCode {
                    Text(L("Command Code 账单接口（按公开实现对接，未对真实账号验证）：粘贴 API Key，或留空复用本机 command-code CLI（cmd auth login）保存的登录。美元计价：5 小时/每周滚动窗、组织支出上限、套餐月度额度（授权额为公开价目表，估算口径）与余额。")).font(.callout).foregroundStyle(.secondary)
                }
                if account.connection == .dshHarness {
                    Text(L("自动检测本机 DeepSeek Harness（dsh）软件与登录凭证，经平台官方接口按量查询钱包余额、赠金与累计消费。凭证只用于拼一次请求头，不落盘、不写日志；提示过期时打开一次 DeepSeek Harness 重新登录即可。")).font(.callout).foregroundStyle(.secondary)
                }
                if account.connection == .workbuddyLocal {
                    Text(L("经辅助功能只读读取本机 WorkBuddy 桌面端左下角账户弹层的积分余额（积分制：1000 积分满环，低于按比例）。后台读取 + 5 分钟节流，前台使用中不打扰，读完按 Escape 关闭弹层；零网络、零凭证，积分值不写日志。需在系统设置中授予辅助功能权限。")).font(.callout).foregroundStyle(.secondary)
                }
                if account.connection == .customAPI {
                    let cfg = Binding<CustomAPIConfig>(get: { account.customConfig ?? CustomAPIConfig() }, set: { account.customConfig = $0 })
                    TextField(L("余额查询 URL（GET）"),text:cfg.url,prompt:Text(L("https://…/balance")))
                    Picker(L("鉴权方式"),selection:cfg.auth) { Text(L("无")).tag("none"); Text(L("Bearer Token")).tag("bearer"); Text(L("自定义请求头")).tag("header") }
                    if cfg.wrappedValue.auth == "header" { TextField(L("请求头名"),text:cfg.headerName,prompt:Text(L("如 x-api-key"))) }
                    if cfg.wrappedValue.auth != "none" {
                        SecureField(L(cfg.wrappedValue.auth == "bearer" ? "Token" : "请求头值"),text:$key,prompt:Text(L("留空保留已存凭证")))
                        Text(L("凭证仅保存在本机钥匙串，只在查询请求头中使用，不写日志。")).font(.caption).foregroundStyle(.secondary)
                    }
                    TextField(L("余额字段路径"),text:cfg.fieldPath,prompt:Text(L("如 data.balance 或 data.list[0].balance")))
                    HStack { TextField(L("满环基准值"),value:cfg.baseline,format:.number); TextField(L("单位符号"),text:cfg.unit,prompt:Text(L("¥、$、积分、tokens…"))) }
                    TextField(L("赠送/第二字段路径（选填）"),text:cfg.secondPath)
                    Text(L("GET 该地址读取 JSON，按点分路径（支持 [0] 数组下标）取余额；悬浮条圆环填充 = min(余额/基准, 1)，轮询 5 分钟，失败保留上次数据。")).font(.caption).foregroundStyle(.secondary)
                }
                if account.provider == .claude && account.connection == .agentLocal {
                    Text(L("自动链：官方 OAuth 接口（本机登录凭证）→ 状态栏推送（可在设置中一键连接）→ 本地记录。登录过期时建议在设置中连接状态栏推送。")).font(.callout).foregroundStyle(.secondary)
                }
                if account.connection == .kimiDesktop {
                    Text(L("经系统辅助功能只读读取本机 Kimi 桌面端「设置 › 订阅 › 我的订阅」页面的会员月度额度池与 Kimi Code 用量；本机读取，无需 Key。Kimi 前台使用中不打扰，后台自动导航读取，未运行时保留上次状态。")).font(.callout).foregroundStyle(.secondary)
                }
                if account.kind == .llm {
                    HStack { TextField(L("本月预算（可选）"),text:$budget); Picker(L("币种"),selection:$account.currency) { Text(L("USD")).tag("USD"); Text(L("CNY")).tag("CNY"); Text(L("EUR")).tag("EUR") }.frame(width:140) }
                }
                Toggle(L("显示在悬浮条"),isOn:$account.showInRail)
                Toggle(L("启用此账户"),isOn:$account.enabled)
            }.formStyle(.grouped)
            HStack(spacing:12) {
                Button(L(testing ? "测试中…" : "测试连接")) { test() }.disabled(testing)
                if let testResult { Text(L(testResult)).font(.caption).foregroundStyle(testResult.hasPrefix("连接失败") ? .red : Theme.teal).fixedSize(horizontal:false,vertical:true) }
            }
            Text(L(account.provider.note)).font(.caption).foregroundStyle(.secondary)
            if let error { Text(L(error)).font(.callout).foregroundStyle(.red) }
            HStack { Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button(L("保存账户")) { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(26).frame(width:600).onAppear { budget = account.budget.map { String($0) } ?? "" }
            .onChange(of:account.provider) { _, p in
                key = ""; testResult = nil; account.scopeID = nil; account.region = nil; account.filePath = ""
                account.name = account.kind == .agent ? p.defaultAgentName : p.defaultLLMName
                account.connection = Connection.available(p,account.kind)[0]
            }
            .onChange(of:account.kind) { _, k in
                account.name = k == .agent ? account.provider.defaultAgentName : account.provider.defaultLLMName
                account.connection = Connection.available(account.provider,k)[0]
            }
    }
    @ViewBuilder private var integrationSettings: some View {
        if let integration = account.connection.integration {
            if account.connection == .openCodeQuota {
                Picker("套餐", selection: regionBinding("zen")) { Text("Zen · 控制台会话").tag("zen"); Text("Go · API Key").tag("go") }
                if account.region != "go" { TextField("工作区 ID（选填）", text: scopeBinding, prompt: Text("wrk_…")) }
            }
            if account.connection == .qoderQuota {
                Picker("服务地区", selection: regionBinding("global")) { Text("国际站 qoder.com").tag("global"); Text("中国站 qoder.com.cn").tag("cn") }
            }
            if account.connection == .alibabaPlan {
                Picker("套餐区域", selection: regionBinding("cn")) {
                    Text("国内 · 团队").tag("cn"); Text("国内 · 个人").tag("cn-personal")
                    Text("国际 · 团队").tag("intl"); Text("国际 · 个人").tag("intl-personal")
                }
            }
            if account.connection == .traeQuota { TextField("Device ID（选填）", text: scopeBinding) }
            if account.connection == .kiroQuota { TextField("kiro-cli 路径（选填）", text: scopeBinding, prompt: Text("默认查找本机安装")) }
            if [.newAPIQuota, .sub2APIQuota].contains(account.connection) {
                TextField("服务地址", text: $account.filePath, prompt: Text("https://你的服务地址"))
            }
            if account.connection == .newAPIQuota {
                Picker("查询对象", selection: regionBinding("api-key")) { Text("API Key 额度").tag("api-key"); Text("账户总额度").tag("account") }
                if account.region == "account" { TextField("用户 ID", text: scopeBinding) }
            }
            Text(integration.help).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var scopeBinding: Binding<String> { Binding(get: { account.scopeID ?? "" }, set: { account.scopeID = $0 }) }
    private func regionBinding(_ fallback: String) -> Binding<String> { Binding(get: { account.region ?? fallback }, set: { account.region = $0 }) }
    private func validateDestinationChange() throws {
        guard key.isEmpty, let old = store.library.accounts.first(where: { $0.id == account.id }) else { return }
        if account.connection.needsKey && old.connection != account.connection {
            throw MonitorError.message("切换连接方式后，请填写该连接的凭据。")
        }
        if [.newAPIQuota, .sub2APIQuota].contains(account.connection), old.filePath != account.filePath {
            throw MonitorError.message("更换服务地址后，请重新填写对应服务的凭据。")
        }
        let defaults: [Connection: String] = [.qoderQuota: "global", .alibabaPlan: "cn", .openCodeQuota: "zen", .newAPIQuota: "api-key"]
        if let fallback = defaults[account.connection], (old.region ?? fallback) != (account.region ?? fallback) {
            throw MonitorError.message("切换服务地区、套餐或凭据类型后，请重新填写对应凭据。")
        }
    }
    func test() {
        do { try validateDestinationChange() } catch { testResult = error.localizedDescription; return }
        testing = true; testResult = nil
        let candidate = account, draftKey = key
        Task {
            do {
                let result = try await Connectors.fetch(candidate, userInitiated:true, keyOverride:draftKey.isEmpty ? nil : draftKey)
                await MainActor.run {
                    switch result {
                    case .snapshot(let s): testResult = s.hasMeasuredValues ? "连接成功 ✓" : "连接成功，暂未读取到额度数据。"
                    case .status(let note): testResult = note
                    }
                    testing = false
                }
            } catch {
                await MainActor.run { testResult = "连接失败：\(error.localizedDescription)"; testing = false }
            }
        }
    }
    func copilotLogin() {
        copilotBusy = true; testResult = nil; error = nil
        copilotTask = Task {
            do {
                let prompt = try await GitHubDeviceLogin.start()
                await MainActor.run {
                    copilotCode = prompt.userCode
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt.userCode, forType:.string)
                    NSWorkspace.shared.open(prompt.verificationURL)
                }
                let token = try await GitHubDeviceLogin.awaitToken(prompt)
                try Task.checkCancellation()
                try KeyVault.save(token, id: account.id)
                await MainActor.run { copilotBusy = false; copilotCode = nil; testResult = "GitHub 已登录 ✓ 保存账户后生效。" }
            } catch {
                await MainActor.run {
                    copilotBusy = false; copilotCode = nil
                    if !(error is CancellationError) { testResult = "连接失败：\(error.localizedDescription)" }
                }
            }
        }
    }
    func save() {
        do {
            try validateDestinationChange()
            if [.newAPIQuota, .sub2APIQuota].contains(account.connection) {
                guard let u = URL(string: account.filePath), u.scheme == "https", u.host != nil, u.user == nil, u.password == nil, u.query == nil, u.fragment == nil else { throw MonitorError.message("请填写不含密码、查询参数或片段的 HTTPS 服务地址。") }
                if account.connection == .newAPIQuota && account.region == "account" {
                    guard let id = account.scopeID, !id.isEmpty, id.allSatisfy(\.isNumber) else { throw MonitorError.message("账户模式需填写数字用户 ID。") }
                }
            }
            account.name = account.name.trimmingCharacters(in:.whitespacesAndNewlines)
            if !budget.isEmpty { guard let n = Double(budget), n.isFinite, n > 0 else { throw MonitorError.message("预算请输入大于 0 的数字。") }; account.budget = n } else { account.budget = nil }
            if account.connection == .file && !FileManager.default.fileExists(atPath:account.filePath) { throw MonitorError.message("请选择可读取的 JSON 文件。") }
            if [.aliyun,.volc,.xai,.volcArk].contains(account.connection) {
                guard let scope = account.scopeID?.trimmingCharacters(in:.whitespacesAndNewlines), !scope.isEmpty, scope.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { throw MonitorError.message("请填写有效的 Team ID 或 AccessKey ID。") }; account.scopeID = scope
            }
            if account.connection.needsKey && key.isEmpty { _ = try KeyVault.read(account.id) }
            if account.connection == .customAPI {
                guard let cfg = account.customConfig else { throw MonitorError.message("请完善自定义 API 配置。") }
                guard let u = URL(string: cfg.url.trimmingCharacters(in:.whitespacesAndNewlines)), ["https","http"].contains(u.scheme ?? ""), u.host != nil else { throw MonitorError.message("余额查询 URL 无效（需 http/https 地址）。") }
                _ = try CustomBridge.parsePath(cfg.fieldPath)
                if !cfg.secondPath.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { _ = try CustomBridge.parsePath(cfg.secondPath) }
                guard cfg.baseline.isFinite && cfg.baseline > 0 else { throw MonitorError.message("满环基准值需为大于 0 的数字。") }
                if cfg.auth == "header" && cfg.headerName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { throw MonitorError.message("自定义请求头需填写头名。") }
                if cfg.auth != "none" && key.isEmpty { _ = try KeyVault.read(account.id) }
            }
            if let old = store.library.accounts.first(where:{$0.id == account.id}), old.connection != account.connection || old.filePath != account.filePath {
                account.snapshot = nil; account.error = nil; account.lastAttempt = nil
            }
            try store.upsert(account,key:key); dismiss()
            if account.enabled { let id = account.id; Task { await store.refresh(id) } }
        } catch { self.error = error.localizedDescription }
    }
}
struct SettingsPanel: View {
    @EnvironmentObject var store: MonitorStore
    // 语言已收拢到 app 级设置中心（gqns.language），此处不再有语言 Picker。
    @AppStorage("codexPath", store: TokenBundle.defaults) var codexPath = ""
    @AppStorage("notifyThreshold", store: TokenBundle.defaults) var notifyThreshold = 0
    @AppStorage("notifyOnReset", store: TokenBundle.defaults) var notifyOnReset = false
    @AppStorage("notifyOnFailure", store: TokenBundle.defaults) var notifyOnFailure = false
    @AppStorage("notifyLowBalance", store: TokenBundle.defaults) var notifyLowBalance = 0.0
    @AppStorage("refreshFixedInterval", store: TokenBundle.defaults) var refreshFixedInterval = false
    @AppStorage("panelEnabled", store: TokenBundle.defaults) var panelEnabled = true
    @AppStorage("panelBotDot", store: TokenBundle.defaults) var panelBotDot = true
    @AppStorage("panelHideFullScreen", store: TokenBundle.defaults) var panelHideFullScreen = false
    @AppStorage("panelFollowDisplay", store: TokenBundle.defaults) var panelFollowDisplay = false
    @AppStorage("panelDoubleColumn", store: TokenBundle.defaults) var panelDoubleColumn = false
    @AppStorage("updateAppcastURL", store: TokenBundle.defaults) var updateAppcastURL = ""
    @AppStorage("updateEdDSAPublicKey", store: TokenBundle.defaults) var updatePublicKey = ""
    // 任一开关打开时才请求系统通知授权（启动弹权限框是拿到永久拒绝的最短路径）。
    func askNotificationPermission() {
        if AlertSettings.read().wantsAlerts { Task { _ = await AlertCenter.requestAuthorization() } }
    }
    /// 悬浮条显示开关（3.3）：逐账户持久化在 Account.showInRail；upsert 在同连接方式下保留快照。
    func railVisibility(_ id: UUID) -> Binding<Bool> {
        Binding(get: { store.library.accounts.first(where: { $0.id == id })?.showInRail ?? true },
                set: { v in
                    guard let a = store.library.accounts.first(where: { $0.id == id }), a.showInRail != v else { return }
                    var edited = a; edited.showInRail = v
                    try? store.upsert(edited)
                })
    }
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            VStack(alignment:.leading,spacing:18) {
                Label(L("同步与提醒"),systemImage:"arrow.triangle.2.circlepath").font(.headline)
                Toggle(L("应用运行时自动同步"),isOn:$store.library.autoRefresh).onChange(of:store.library.autoRefresh) { _, _ in store.save() }
                Toggle(L("固定间隔同步"),isOn:$refreshFixedInterval)
                if refreshFixedInterval {
                    Picker(L("同步间隔"),selection:$store.library.refreshMinutes) { ForEach([1,5,10,15,30,60],id:\.self) { Text(L("\($0) 分钟")).tag($0) } }.frame(maxWidth:340).onChange(of:store.library.refreshMinutes) { _, _ in store.save() }
                } else {
                    Text(L("按活跃度自适应同步（2–30 分钟；服务端计费类封顶 5 分钟）")).font(.caption).foregroundStyle(.secondary)
                }
                HStack { Text(L("剩余额度提醒阈值")); Slider(value:$store.library.warningThreshold,in:5...50,step:5).frame(width:200); Text(L("\(Int(store.library.warningThreshold))%")).monospacedDigit() }.onChange(of:store.library.warningThreshold) { _, _ in store.save() }
                Text(L("提醒阈值按剩余 % 让总览、菜单栏与浮动条变色；系统通知按下方「额度告警阈值」的已用 % 档位另算。关闭应用后停止同步。手动账户不会被自动更新。")).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth:.infinity,alignment:.leading).panel()
            VStack(alignment:.leading,spacing:18) {
                Label(L("屏幕边缘浮动条"),systemImage:"menubar.rectangle").font(.headline)
                Toggle(L("显示浮动条"),isOn:$panelEnabled).onChange(of:panelEnabled) { _, _ in FloatingPanelManager.shared.settingsChanged() }
                if panelEnabled {
                    Toggle(L("活跃状态圆点"),isOn:$panelBotDot).onChange(of:panelBotDot) { _, _ in FloatingPanelManager.shared.settingsChanged() }
                    Toggle(L("全屏时隐藏"),isOn:$panelHideFullScreen).onChange(of:panelHideFullScreen) { _, _ in FloatingPanelManager.shared.settingsChanged() }
                    Toggle(L("跟随活跃显示器"),isOn:$panelFollowDisplay).onChange(of:panelFollowDisplay) { _, _ in FloatingPanelManager.shared.settingsChanged() }
                    Picker(L("停靠位置"),selection:Binding(
                        get: { FloatingPanelManager.shared.placement?.dock ?? .edge(.right) },
                        set: { FloatingPanelManager.shared.placement?.update(dock:$0) })) {
                        Text(L("左")).tag(PanelDock.edge(.left)); Text(L("右")).tag(PanelDock.edge(.right)); Text(L("顶部")).tag(PanelDock.edge(.top)); Text(L("浮动")).tag(PanelDock.floating)
                    }.frame(maxWidth:340)
                    // 3.31：单列/双列布局——双列把环按两列网格排，托盘更宽更矮，适合账户多的时候。
                    Picker(L("悬浮条布局"), selection: $panelDoubleColumn) {
                        Text(L("单列")).tag(false); Text(L("双列")).tag(true)
                    }.frame(maxWidth: 340).onChange(of: panelDoubleColumn) { _, _ in FloatingPanelManager.shared.settingsChanged() }
                    Text(L("空闲时收成屏幕边缘的细条（有需要留意的账户时发红光），悬停展开；可直接拖动换位或贴边，右键有更多选项。")).font(.caption).foregroundStyle(.secondary)
                    if !store.active.isEmpty {
                        Divider()
                        Text(L("悬浮条显示")).font(.callout.weight(.medium))
                        ForEach(store.active) { a in
                            Toggle(a.name, isOn: railVisibility(a.id))
                        }
                        Text(L("关闭后该账户不出现在悬浮条 rail 与托盘；总览卡片与自动同步不受影响。")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxWidth:.infinity,alignment:.leading).panel()
            VStack(alignment:.leading,spacing:18) {
                Label(L("系统通知"),systemImage:"bell").font(.headline)
                Picker(L("额度告警阈值"),selection:$notifyThreshold) { Text(L("关闭")).tag(0); ForEach([75,80,90,95],id:\.self) { Text("\($0)%").tag($0) } }.frame(maxWidth:340).onChange(of:notifyThreshold) { _, _ in askNotificationPermission() }
                Toggle(L("窗口重置时提醒我"),isOn:$notifyOnReset).onChange(of:notifyOnReset) { _, _ in askNotificationPermission() }
                Toggle(L("连续同步失败时提醒我"),isOn:$notifyOnFailure).onChange(of:notifyOnFailure) { _, _ in askNotificationPermission() }
                HStack { Text(L("低余额提醒")); TextField(L("关闭"),value:$notifyLowBalance,format:.number).frame(width:90).onChange(of:notifyLowBalance) { _, _ in askNotificationPermission() }; Text(L("按账户币种，余额跌破时提醒；0 或留空为关闭。")).font(.caption).foregroundStyle(.secondary) }
                Text(L("「已用尽」只看平台自己的裁决，不用算术推断；每扇窗每档最多一条，窗口有翻篇证据后才重新提醒；连续失败满 3 轮报一次；授权只在打开任一开关时请求，点击通知打开主窗口。此处阈值按已用 % 触发系统通知；上方「剩余额度提醒阈值」只管界面变色，不发通知。")).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth:.infinity,alignment:.leading).panel()
            VStack(alignment:.leading,spacing:18) {
                Label(L("外观与连接"),systemImage:"paintpalette").font(.headline)
                HStack { Text(L("Codex 程序")); Text(L(codexPath.isEmpty ? "自动查找已安装的 Codex" : codexPath)).font(.caption).foregroundStyle(.secondary).lineLimit(1); Spacer(); Button(L("选择…")) { let p = NSOpenPanel(); if p.runModal() == .OK, let url = p.url { codexPath = url.path } }; Button(L("自动")) { codexPath = "" } }
            }.frame(maxWidth:.infinity,alignment:.leading).panel()
            VStack(alignment:.leading,spacing:18) {
                Label(L("Claude Code 状态栏推送"),systemImage:"antenna.radiowaves.left.and.right").font(.headline)
                Text(L("把搞词元注册为 Claude Code 的官方状态栏命令后，即使本机登录过期，额度也会在每次会话响应后自动推送。修改前会备份 ~/.claude/settings.json（settings.json.gaociyuan-backup），已有状态栏命令会链式保留，断开后自动恢复。")).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Circle().fill(ClaudeStatusLine.isInstalled ? Theme.teal : Color.secondary).frame(width:8,height:8)
                    Text(L(ClaudeStatusLine.isInstalled ? "已连接状态栏推送" : "未连接状态栏推送")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if ClaudeStatusLine.isInstalled {
                        Button(L("断开并恢复")) { _ = ClaudeStatusLine.uninstall(); store.notice = L("已断开 Claude Code 状态栏推送，原状态栏命令已恢复。") }
                    } else {
                        Button(L("连接状态栏")) { store.notice = ClaudeStatusLine.install() ? L("已连接 Claude Code 状态栏推送。") : L("无法读取 ~/.claude/settings.json，未做任何修改。请检查该文件后重试。") }
                    }
                }
            }.frame(maxWidth:.infinity,alignment:.leading).panel()
            VStack(alignment:.leading,spacing:18) {
                Label(L("检查更新"),systemImage:"arrow.down.circle").font(.headline)
                HStack { Text(L("更新源地址")); TextField(L("留空则不自动检查"),text:$updateAppcastURL).frame(maxWidth:380) }
                HStack { Text(L("签名公钥")); TextField(L("Ed25519 公钥（Base64）"),text:$updatePublicKey).frame(maxWidth:380) }
                HStack { Button(L("立即检查")) { Task { await UpdateChecker.shared.checkNow(userInitiated:true) } }; Text(L("每 2 小时自动检查一次；发现新版本只提示并验证签名，绝不自动安装。")).font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth:.infinity,alignment:.leading).panel()
            VStack(alignment:.leading,spacing:18) {
                Label(L("数据与备份"),systemImage:"externaldrive").font(.headline)
                Text(L("完整数据包含账户、历史、外观与语言设置，以及数据目录中的全部 PDF 和其他文档。API 密钥保留在钥匙串，不随备份导出。")).font(.callout).foregroundStyle(.secondary)
                HStack { Button(L("导出完整数据…")) { store.exportBackup() }; Button(L("导入数据…")) { store.restoreBackup() }; Button(L("导出账户快照 CSV")) { store.exportCSV() }; Button(L("打开数据目录")) { NSWorkspace.shared.open(store.dataURL.deletingLastPathComponent()) } }
                Divider()
                Text(L("通用快照文件")).font(.headline)
                Text(L("所有平台均可连接标准 JSON 快照。外部脚本更新文件后，应用会定时读取；observedAt 表示实际观测时间，不能用刷新时间冒充。")).font(.callout).foregroundStyle(.secondary)
                Button(L("导出快照格式示例…")) { exportExample() }
            }.frame(maxWidth:.infinity,alignment:.leading).panel()
            VStack(alignment:.leading,spacing:10) { Text(L("搞词元 V\(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "")")).font(.headline); Text(L("macOS 原生应用")).foregroundStyle(.secondary); Text(L("会员限额并非固定 Token 数；官方账单可能延迟。通用快照不代表所有平台已实现自动登录。自动接口均只读取，不调用模型、不充值、不修改订阅。")).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth:.infinity,alignment:.leading).panel()
        }
    }
    func exportExample() {
        var s = UsageSnapshot.empty(source:"自定义采集器")
        s.periodStart = Calendar.current.date(from:Calendar.current.dateComponents([.year,.month],from:Date())); s.periodEnd = Date()
        s.note = "格式示例：请填入真实数据。Token 未知可保留 null；费用和余额未知保留空数组。"
        s.quotas = []
        let p = NSSavePanel(); p.nameFieldStringValue = "用量快照示例.json"; p.allowedContentTypes = [.json]
        if p.runModal() == .OK, let url = p.url { do { try JSONCoding.encoder.encode(s).write(to:url,options:.atomic) } catch { store.notice = error.localizedDescription } }
    }
}
