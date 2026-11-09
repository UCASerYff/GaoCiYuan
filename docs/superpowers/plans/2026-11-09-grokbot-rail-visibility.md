# Grok Bot 剩余额度与悬浮窗卸载过滤 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Grok Bot 悬浮环按剩余额度显示且不拼接“旧”，已卸载 Mac 应用的本地 Agent 只从悬浮窗隐藏，并保持点击圆环手动读取快照。

**Architecture:** 快照解析继续保存已用百分比，展示模型统一换算剩余量。`MemberDiscovery` 增加 Mac 应用存在性和纯悬浮窗可见性策略，`PanelRootView` 与 `FloatingPanelController` 共用同一份过滤后的账户数组；卸载不删除账户或历史。

**Tech Stack:** Swift 5、SwiftUI、AppKit、Foundation、macOS 14+、现有 swiftc 回归测试、zsh 构建脚本。

## Global Constraints

- 只修改 `/Users/yufeifan/Desktop/搞app/搞词元`；其他独立应用不改。
- `weeklyPercentUsed` JSON 合同保持不变；无有效读数显示 `—`，不得编造 0% 或 100%。
- 自动刷新不得打开 `grokbot-usage.json`；只有 `userInitiated: true` 才读取。
- 应用卸载后即使 CLI 存在也隐藏；纯 CLI 与 API 账户不做 Mac App 卸载过滤。
- 只隐藏悬浮窗圆环，不删除或禁用账户，不改自动发现标记、快照、历史、设置或钥匙串。
- 渲染、几何、溢出计数和点击命中共用同一过滤结果；首次扫描未完成时不得把未知当成卸载。
- 先写失败测试再实现；不跑无关通用冒烟。版本只从 4.10／11 升为 4.11／12。
- 新 `.app` 只能先出现在 `build.noindex`、`.release.noindex` 或 `.install.noindex`，保留完整安全备份和正式唯一入口。

---

### Task 1: Grok Bot 剩余额度展示模型

**Files:**
- Modify: `Sources/GrokBotUsageReport.swift`
- Modify: `Sources/FloatingPanel.swift`
- Test: `Tests/GrokBotUsageReportRegression.swift`

**Interfaces:**
- Consumes: 现有 `GrokBotUsageReport.ManualReading.weeklyPercentUsed`。
- Produces: `GrokBotUsageReport.remainingPercent(used: Double) -> Double`；`RingFace.remainingPercent: Double?`，其中 `fill` 是剩余比例，`label` 仅为数字百分比。

- [ ] **Step 1: 写失败回归测试**

把 84.8% 已用的圆环断言改为：

```swift
let expectedRemaining = 100.0 - stored.weeklyPercentUsed
require(abs(expectedRemaining - 15.2) < 0.000_001, "remaining conversion")
require(freshFace?.showsDash == false && freshFace?.remainingPercent == expectedRemaining && freshFace?.stale == false, "valid read did not fill remaining percent")
require(freshFace?.label == "15.2%", freshFace?.label ?? "")
require(abs((freshFace?.fill ?? 0) - 0.152) < 0.000_001, "fill was not the remaining fraction")
require(freshFace?.help.contains("已用 84.8%") == true, "remaining ring hid its source value")
require(staleFace?.stale == true && staleFace?.label == "15.2%" && staleFace?.showsDash == false, staleFace?.label ?? "missing stale face")
require(staleFace?.label.contains("旧") == false, "stale caption leaked into the number")
require(resetFace?.stale == true && resetFace?.remainingPercent == expectedRemaining, "past reset still looked live")
require(empty?.showsDash == true && empty?.label == "—" && empty?.fill == 0 && empty?.remainingPercent == nil, "missing read drew a percent")
```

同时把详情主文案断言改为 `本周剩余 15.2%（已用 84.8%`，并增加 0% 已用对应 100% 剩余、100% 已用对应 0% 剩余的边界断言。保留 `shouldReadOnRefresh(false) == false` 和 `shouldReadOnRefresh(true) == true` 断言。

- [ ] **Step 2: 编译运行并确认失败**

Run:

```bash
cd "/Users/yufeifan/Desktop/搞app/搞词元"
mkdir -p .test.noindex/grok
swiftc -parse-as-library Sources/GrokBotUsageReport.swift Tests/GrokBotUsageReportRegression.swift -o .test.noindex/grok/usage-report
.test.noindex/grok/usage-report
```

Expected: 编译失败，因为 `RingFace.remainingPercent` 尚不存在；不得通过改回旧断言消除失败。

- [ ] **Step 3: 实现最小剩余量模型**

在 `GrokBotUsageReport` 增加：

```swift
static func remainingPercent(used: Double) -> Double {
    max(0, min(100, 100 - used))
}
```

将 `RingFace.usedPercent` 改名为 `remainingPercent`，并把 `dedicatedRingFace` 的核心计算改为：

```swift
let remaining = remainingPercent(used: reading.weeklyPercentUsed)
let remainingText = percentText(remaining)
let usedText = percentText(reading.weeklyPercentUsed)
let label = remainingText + "%"
let help = (stale ? "快照已过期，" : "") + "剩余 \(remainingText)%，由已用 \(usedText)% 换算。采集于 \(made.capturedText)。不是实时读数。"
return RingFace(showsDash: false, remainingPercent: remaining, fill: min(1, max(0, remaining / 100)), stale: stale, label: label, help: help)
```

无读数分支使用 `remainingPercent: nil`。`displayLine` 以 `本周剩余 X%（已用 Y%）` 为主文案，保留共享、重置和采集时间。`FloatingPanel.swift` 将 `grokUsedRing` 改名 `grokRemainingRing`，只改名和更新注释，弧长仍读取同一个 `face.fill`，因此现在表达剩余量。

- [ ] **Step 4: 运行 Grok 回归并确认通过**

Run: 同 Step 2 的编译和运行命令。

Expected: 输出 `{"passed":true,"cases":"parse-staleness-validation-file-ring"}`。

- [ ] **Step 5: 提交**

```bash
git add Sources/GrokBotUsageReport.swift Sources/FloatingPanel.swift Tests/GrokBotUsageReportRegression.swift
git commit -m "Show Grok Bot remaining quota on the rail"
```

### Task 2: 可测试的本机应用可见性策略

**Files:**
- Modify: `Sources/AgentTables.swift`
- Modify: `Sources/NativeMembers.swift`
- Test: `Tests/AgentDiscoveryRegression.swift`

**Interfaces:**
- Consumes: `Account.kind`、`Account.connection`、`Account.showInRail` 和自动发现结果。
- Produces:
  - `AgentPlatformTable.hasMacApplicationIdentity(Provider) -> Bool`
  - `MemberDiscovery.isMacApplicationInstalled(Provider, in: [NSRunningApplication]) -> Bool`
  - `AgentObservation.isMacAppInstalled: Bool`
  - `MemberDiscovery.railVisibleAccounts(_:observations:discoveryCompleted:) -> [Account]`
  - `MemberDiscovery.railVisibleAccounts(_:) -> [Account]`

- [ ] **Step 1: 写失败策略测试**

在 `AgentDiscoveryRegression` 构造 Bot、Grok 账号池、xAI API、纯 CLI Qwen 账户，并添加：

```swift
let appObservation = AgentObservation(id: "grok", provider: .grok, softwareName: "Grok Bot", isRunning: false, cliPath: "/fixture/grok", status: "未启动", snapshot: nil, isMacAppInstalled: false)
try check(!MemberDiscovery.railVisibleAccounts([bot], observations: [appObservation], discoveryCompleted: true).contains(bot), "CLI kept an uninstalled Mac app on the rail")
try check(MemberDiscovery.railVisibleAccounts([bot], observations: [], discoveryCompleted: false).contains(bot), "unknown first scan was treated as uninstall")
try check(MemberDiscovery.railVisibleAccounts([pool, api], observations: [], discoveryCompleted: true).count == 2, "account pool or API was filtered as a Mac app")
let qwen = Account(provider: .qwen, kind: .agent, name: "Qwen CLI", connection: .agentLocal)
let qwenObservation = AgentObservation(id: "qwen", provider: .qwen, softwareName: "Qwen", isRunning: false, cliPath: "/fixture/qwen", status: "未启动", snapshot: nil, isMacAppInstalled: false)
try check(MemberDiscovery.railVisibleAccounts([qwen], observations: [qwenObservation], discoveryCompleted: true).contains(qwen), "CLI-only provider requires a Mac app")
let installed = AgentObservation(id: "grok", provider: .grok, softwareName: "Grok Bot", isRunning: false, cliPath: nil, status: "未启动", snapshot: nil, isMacAppInstalled: true)
let visible = MemberDiscovery.railVisibleAccounts([bot, pool, api], observations: [installed], discoveryCompleted: true)
try check(visible.map(\.id) == [bot.id, pool.id, api.id], "filtered order and click identity changed")
```

再加一个 `showInRail = false` 账户，确认任何扫描状态下都隐藏。现有 `observation(running:)` fixture 显式设置 `isMacAppInstalled: true`。

- [ ] **Step 2: 编译运行并确认失败**

Run:

```bash
cd "/Users/yufeifan/Desktop/搞app/搞词元"
mkdir -p .test.noindex/discovery/cache
swiftc -parse-as-library -D TESTING -module-cache-path .test.noindex/discovery/cache \
  Sources/Models.swift Sources/AgentTables.swift Sources/ProviderIntegrations.swift \
  Sources/NativeMembers.swift Sources/GrokBotBridge.swift Sources/GrokBotUsageReport.swift \
  Tests/AgentDiscoveryRegression.swift -framework AppKit -framework SwiftUI -framework ApplicationServices \
  -o .test.noindex/discovery/agent-discovery
.test.noindex/discovery/agent-discovery
```

Expected: 编译失败，因为 `isMacAppInstalled` 和 `railVisibleAccounts` 尚不存在。

- [ ] **Step 3: 实现应用检测与纯过滤策略**

`AgentPlatformTable` 增加：

```swift
static func hasMacApplicationIdentity(_ provider: Provider) -> Bool {
    let id = identity(provider)
    return !id.exactBundles.isEmpty || !id.appNames.isEmpty
}
```

`AgentObservation` 增加 `var isMacAppInstalled: Bool = false`。`MemberDiscovery` 增加应用检测，忽略 CLI，并要求 LaunchServices 或运行进程返回的 `.app` 路径实际存在：

```swift
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
```

`collectObservations` 设置 `isMacAppInstalled: Self.isMacApplicationInstalled(p, in: runningApps)`。新增 `@Published private(set) var discoveryCompleted = false`，配置新 store 时置 false，只有有效扫描结果落地时置 true。

过滤策略仅对以下本地连接生效：`.agentLocal`、`.codex`、`.claudeDesktop`、`.cursor`、`.devinApp`、`.dshHarness`、`.workbuddyLocal`、`.geminiApp`、`.kimiDesktop`。实现：

```swift
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
```

- [ ] **Step 4: 运行发现回归并确认通过**

Run: 同 Step 2。

Expected: 输出包含 `"passed":true`、`"autoRefreshOffFetches":0` 和 `"snapshotCount":0`，所有新增可见性断言通过。

- [ ] **Step 5: 提交**

```bash
git add Sources/AgentTables.swift Sources/NativeMembers.swift Tests/AgentDiscoveryRegression.swift
git commit -m "Filter uninstalled agents from rail accounts"
```

### Task 3: 悬浮窗统一接线与手动重扫

**Files:**
- Modify: `Sources/FloatingPanel.swift`
- Test: `Tests/AgentDiscoveryRegression.swift`
- Test: `Tests/GrokBotUsageReportRegression.swift`

**Interfaces:**
- Consumes: Task 2 的 `MemberDiscovery.railVisibleAccounts(_:)` 和 `requestScan()`。
- Produces: SwiftUI 与 AppKit 使用同一账户过滤入口；展开悬浮窗会请求发现重扫。

- [ ] **Step 1: 保持并核对过滤后身份测试**

确认 Task 2 的 `visible.map(\.id)` 断言同时覆盖第一个圆环和后续点击索引；先运行两个回归，若失败则回到对应任务修复，不在 UI 层另写一套过滤规则。

- [ ] **Step 2: 接入同一份可见账户列表**

`PanelRootView` 增加：

```swift
@ObservedObject private var discovery = MemberDiscovery.shared
private var railVisible: [Account] { discovery.railVisibleAccounts(store.active) }
```

删除原来的 `store.active.filter(\.showInRail)`。在现有 `expanded` 的 `onChange` 后增加：

```swift
.onChange(of: expanded) { _, isExpanded in
    if isExpanded { discovery.requestScan() }
}
```

`FloatingPanelController.onClick` 与 `shownCount` 均改用：

```swift
let visible = MemberDiscovery.shared.railVisibleAccounts(store.active)
```

`shownCount` 返回 `min(MemberDiscovery.shared.railVisibleAccounts(store.active).count, RailGeometry.capacity)`。不得在控制器重新按 CLI 或安装状态过滤。

- [ ] **Step 3: 运行相关回归和框架编译**

Run: Task 1 和 Task 2 的测试命令，然后：

```bash
cd "/Users/yufeifan/Desktop/搞app/搞词元"
./scripts/build_framework.sh
```

Expected: 两个测试均输出 passed；框架编译退出码 0，`FloatingPanel.swift` 无 actor isolation 或符号错误。

- [ ] **Step 4: 提交**

```bash
git add Sources/FloatingPanel.swift Tests/AgentDiscoveryRegression.swift Tests/GrokBotUsageReportRegression.swift
git commit -m "Share rail visibility and rescan on expand"
```

### Task 4: 版本、备份、构建安装与发布

**Files:**
- Modify: `Info.plist`
- Modify: `README.md`
- Create: `验证记录/2026-11-09-grokbot-rail.noindex/` 下的私有验证收据
- Artifact: `dist/GaoCiYuan-4.11.zip`
- Artifact: `dist/GaoCiYuan-4.11.zip.sha256`

**Interfaces:**
- Consumes: Tasks 1–3 已提交的代码与测试。
- Produces: 正式 `/Applications/搞词元.app` 4.11／12、可回滚旧版、GitHub `v4.11` Release。

- [ ] **Step 1: 更新版本和说明**

`Info.plist` 只把 `CFBundleShortVersionString` 改为 `4.11`、`CFBundleVersion` 改为 `12`。`README.md` 标题和下载文件名改为 4.11，并新增：

```markdown
## V4.11

- Grok Bot 圆环按本周剩余百分比显示，由快照已用百分比换算；环下数字不再拼接“旧”，过期快照仍以灰色和非实时说明区分。
- 点击 Grok Bot 圆环或详情按钮才读取最近一次本地快照，自动刷新不读取额度文件。
- 已卸载 Mac 应用对应的本地 Agent 只从悬浮窗隐藏，即使 CLI 仍在也隐藏；账户、历史、设置和凭据保留，重新安装后恢复显示。纯 CLI 与 API 账户不受影响。
- 版本升至 V4.11，构建号升至 12，沿用现有资料路径和钥匙串身份。
```

- [ ] **Step 2: 完整备份并核验真实资料**

复制既有 `验证记录/2026-11-05-claude-grok.noindex/preupdate_backup.py` 到本轮验证目录，把归档名和 manifest 版本从 4.07 改为 4.11，再执行：

```bash
python3 验证记录/2026-11-09-grokbot-rail.noindex/preupdate_backup.py backup 验证记录/2026-11-09-grokbot-rail.noindex/preupdate-backup.noindex
```

Expected: 输出真实账户数、历史数、账本行数、外部快照数和 verifiedFiles；任何目录缺失、读取失败或 live state 变化都停止，不按空白覆盖。

- [ ] **Step 3: 获取构建租约并构建打包**

```bash
python3 "/Users/yufeifan/Desktop/搞app/合并迁移-2026-11-02/build_lease.py" acquire --owner gaociyuan-v411 --purpose "Grok Bot rail 4.11 build"
cd "/Users/yufeifan/Desktop/搞app/搞词元"
./scripts/build.sh
./scripts/package.sh
```

Expected: 签名验证通过，ZIP 不含 WidgetKit 扩展，`dist/GaoCiYuan-4.11.zip.sha256` 校验通过。使用返回 token 释放租约；失败也释放本人持有的租约。

- [ ] **Step 4: 安装并做受影响的原生验收**

正常退出本人启动的搞词元后运行 `./scripts/install.sh`。不得强退用户未知进程。安装后核验 4.11／12、Team `5G96498KGJ`、Designated Requirement 与旧版一致、回滚 ZIP 可解压且内容一致。启动后验证：Grok Bot 已用 84.8% 时环下为 15.2%、无“旧”前缀；点击圆环才更新读取时间；卸载过滤只影响悬浮窗且资料保持。不能真实卸载用户软件来测试，使用已缺席应用或隔离发现 fixture 验证，并在收据中区分合成与真实证据。

- [ ] **Step 5: 数据保留、唯一入口和清理**

运行备份脚本 `verify-running`，核对账户 ID、历史、showInRail、偏好、账本和 App Group 未回退。真实 UID501 会话核对 Spotlight 与 LaunchServices 只指向 `/Applications/搞词元.app`；清除本轮展开的构建 App、`.release.noindex`、`.install.noindex` 和旧本地安装包，保留最新 ZIP、源码、用户资料与压缩回滚。测试窗口随用随关。

- [ ] **Step 6: 提交、推送和 Release**

```bash
git add Info.plist README.md docs/superpowers/plans/2026-11-09-grokbot-rail-visibility.md
git commit -m "Release GaoCiYuan 4.11"
git push origin main
gh release create v4.11 dist/GaoCiYuan-4.11.zip dist/GaoCiYuan-4.11.zip.sha256 --title "搞词元 V4.11" --notes "Grok Bot 剩余额度圆环、卸载应用悬浮窗过滤与点击手动同步。"
```

Expected: 推送成功，Release 两个资产存在；匿名下载后 SHA-256 与本地一致。若发布或匿名核验失败，不声称完整交付，保留恢复能力并报告阻断。
