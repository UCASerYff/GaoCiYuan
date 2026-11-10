# 搞词元紧凑 Agent-only 改版 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 发布 V4.13／构建 14：紧凑顶部导航、仅 Agent 软件、删除旧 LLM API 数据、彻底移除备份功能并完成无备份安装与 GitHub 发布。

**Architecture:** 在 `MonitorStore` 解码后执行一次性 LLM 账户迁移并删除对应钥匙串项，账户写入与刷新入口同时限制为 Agent。`ContentView` 改为四页顶部导航，`ProviderCatalogView` 只暴露 Agent 连接和本地采集；备份模块及调用整体删除。安装脚本改为直接校验、暂存和替换，不再生成回滚副本。

**Tech Stack:** Swift 5、SwiftUI、AppKit、Charts、Security、SQLite3、zsh、Python 3、现有 swiftc 回归测试、GitHub CLI。

## Global Constraints

- 只修改 `/Users/yufeifan/Desktop/搞app/搞词元`；版本 `4.13`、构建 `14`、Bundle ID `com.gaoseries.GaoCiYuan`。
- 永久删除旧 LLM API 账户、快照、历史、预算、配置及账户 ID 对应的专属钥匙串凭据；Agent 数据与用量分析记录不删除。
- 不创建任何更新备份、回滚副本或自动滚动备份；失败停止并如实报告。
- 新 `.app` 只能先出现在 `.noindex` 容器；正式入口只能为 `/Applications/搞词元.app`。
- 保留悬浮窗、菜单栏、原资料目录、App Group、钥匙串服务和 Apple Development 团队 `5G96498KGJ`；不重新引入 WidgetKit 或游戏。
- 测试窗口随用随关；不自动登录第三方服务，不发起模型调用，不上传用户数据、凭据或备份。

---

### Task 1: 一次性删除 LLM 数据并封锁写入与刷新

**Files:**
- Create: `Sources/LegacyAccountMigration.swift`
- Modify: `Sources/MonitorStore.swift`
- Modify: `Tests/RefreshSchedulingRegression.swift`

**Interfaces:**
- Produces: `LegacyAccountMigration.removingLLMAccounts(from: Library) -> (library: Library, removedIDs: [UUID])`。
- Consumes: 既有 `Library`、`AccountKind`、`KeyVault.delete(_:)`、`AlertCenter.forget(account:)`。
- Guarantees: `MonitorStore.upsert` 只接受 `.agent`，`active` 与刷新只包含 `.agent`。

- [ ] **Step 1: 写失败回归**

在 `RefreshSchedulingRegression` 的钥匙串 stub 增加 `static var deleted: [UUID] = []`，`delete` 记录 ID。主测试开头写入包含一个 Agent 和一个 LLM 的 Library，再初始化 `MonitorStore`，加入：

```swift
let agentID = UUID(), llmID = UUID()
var legacy = Library()
legacy.accounts = [
    Account(id: agentID, provider: .openai, kind: .agent, name: "Codex", connection: .codex),
    Account(id: llmID, provider: .openai, kind: .llm, name: "Legacy API", connection: .file)
]
try JSONCoding.encoder.encode(legacy).write(to: root.appendingPathComponent("legacy/library.json"))
let migrated = MonitorStore(directory: root.appendingPathComponent("legacy"), fetch: { _, _ in throw MonitorError.message("Unexpected fetch") })
try check(migrated.library.accounts.map(\.id) == [agentID], "Legacy LLM account was not removed")
try check(KeyVault.deleted == [llmID], "Legacy LLM credential was not deleted exactly once")
try check(migrated.active.allSatisfy { $0.kind == .agent }, "Non-agent account entered active set")
do {
    try migrated.upsert(Account(provider: .custom, kind: .llm, name: "Rejected", connection: .file))
    throw MonitorError.message("LLM upsert unexpectedly succeeded")
} catch {}
```

把后续用于刷新测试的 fixture 从 `.llm` 改为 `.agent`，保留原有调度和取消断言。

- [ ] **Step 2: 编译并确认失败**

Run:

```bash
mkdir -p .test.noindex/agent-only
swiftc -swift-version 5 -parse-as-library Sources/Models.swift Sources/AgentTables.swift Sources/ProviderIntegrations.swift Sources/Pacing.swift Sources/RefreshCoordinator.swift Sources/MonitorStore.swift Sources/LegacyAccountMigration.swift Sources/UsageAnalyticsStore.swift Tests/RefreshSchedulingRegression.swift -framework SwiftUI -framework AppKit -framework UniformTypeIdentifiers -lsqlite3 -o .test.noindex/agent-only/refresh
```

Expected: 编译失败，因为 `LegacyAccountMigration.swift` 尚不存在；不删除新断言。

- [ ] **Step 3: 实现纯迁移与存储边界**

创建：

```swift
import Foundation

enum LegacyAccountMigration {
    static func removingLLMAccounts(from library: Library) -> (library: Library, removedIDs: [UUID]) {
        var copy = library
        let removed = copy.accounts.filter { $0.kind == .llm }.map(\.id)
        copy.accounts.removeAll { $0.kind == .llm }
        return (copy, removed)
    }
}
```

`MonitorStore` 解码后、规范化前调用迁移；对每个 removed ID 执行 `KeyVault.delete` 和 `alerts.forget`，非空时置 `changed = true`。读取失败文案改为“数据文件读取失败，原文件已保留，暂时禁止写入。请检查原文件后再试。”；`upsert` 增加 `guard account.kind == .agent else { throw MonitorError.message("搞词元仅记录 Agent 软件。") }`，其余读取失败提示去掉备份引导。`refresh` 的账户 guard 增加 `a.kind == .agent`，`refreshAll` 过滤 `.agent`，`active` 改为：

```swift
var active: [Account] { library.accounts.filter { $0.enabled && $0.kind == .agent } }
```

- [ ] **Step 4: 运行回归并提交**

Run: Step 2 编译命令，随后 `.test.noindex/agent-only/refresh`。
Expected: 退出 0；旧 LLM 与凭据删除，Agent fixture 的所有原调度断言继续通过。

```bash
git add Sources/LegacyAccountMigration.swift Sources/MonitorStore.swift Tests/RefreshSchedulingRegression.swift
git commit -m "Remove legacy LLM accounts and credentials"
```

### Task 2: 四页紧凑顶部导航与视觉收紧

**Files:**
- Modify: `Sources/ContentView.swift`
- Modify: `Sources/Theme.swift`
- Modify: `Host/AppMain.swift`
- Create: `Tests/CompactAgentUIRegression.swift`

**Interfaces:**
- Produces: `Page.overview`、`Page.agent`、`Page.analytics`、`Page.providers` 四个 `CaseIterable` 页面。
- Consumes: Task 1 的 Agent-only `store.active` 和账户库。
- Removes: `Page.llm`、`Page.history`、侧栏切换、`AccountHistoryChart` 和 API 新增入口。

- [ ] **Step 1: 写源码结构失败回归**

新建 Swift 源码检查，读取 `Sources/ContentView.swift` 并 `require`：包含 `case overview = "总览"`、`.agent = "Agent 软件"` 与四页导航；不包含 `case overview = "用量总览"`、`llm = "LLM"`、`history = "用量记录"`、`AccountHistoryChart`、`sidebarHidden`。检查 `Theme.swift` 含动态深浅色，`Host/AppMain.swift` 含 `minWidth:880,minHeight:560`。

- [ ] **Step 2: 运行并确认失败**

Run:

```bash
swiftc -parse-as-library Tests/CompactAgentUIRegression.swift -o .test.noindex/agent-only/ui && .test.noindex/agent-only/ui
```

Expected: 因旧六页、侧栏和大窗口断言失败。

- [ ] **Step 3: 实现顶部导航**

`ContentView` 使用 `VStack(spacing: 0)`：第一行是 28 pt 图标、“搞词元”、四页紧凑 `Picker`/自绘按钮、刷新和添加 Agent；第二行是当前页短标题及必要操作。删除侧栏、侧栏 toolbar、页面大图标页头和 22–26 pt 垂直留白，内容改为 `padding(16)`、栈间距 `12`，卡片网格最小宽度约 `300`、最小窗口 `880×560`。

页面只保留：总览统计（启用 Agent、已发现软件、需处理）、Agent 列表、既有 `UsageDashboard`、平台目录。空状态和账户卡不再出现 LLM API 文案；添加菜单只执行：

```swift
Button("添加 Agent 软件") { edit = newAccount(.openai, .agent) }
```

保留搜索、告警定位、账户编辑、删除确认、Grok 状态与手动同步。`newAccount` 只允许 Agent，默认币种逻辑可保留给 Agent 连接器。

- [ ] **Step 4: 收紧视觉系统**

`Theme` 增加基于 `NSColor(name:dynamicProvider:)` 的 `canvas`、`panel`、`accent`、`teal`、`ink`：浅色暖灰画布、近白卡片、墨青文字、青绿强调；深色使用相应高对比色。`panel()` 改为 14 pt 内边距、12 pt 圆角和轻描边；`StatCard` 数字约 24 pt、垂直间距 8；`QuotaRow` 保持真实额度和陈旧语义，不改数据。

`AppMain` 主窗口改为 `.frame(minWidth:880,minHeight:560)`、`.defaultSize(width:1120,height:720)`；工具栏背景使用 `Theme.canvas` 可公开访问的动态色或等效 NSColor，不增加侧栏切换。

- [ ] **Step 5: 构建验证并提交**

Run: Step 2 与 `./scripts/build.sh`。
Expected: 源码回归退出 0，完整 SwiftUI 编译签名成功。

```bash
git add Sources/ContentView.swift Sources/Theme.swift Host/AppMain.swift Tests/CompactAgentUIRegression.swift
git commit -m "Redesign compact agent-only navigation"
```

### Task 3: Agent 平台目录与备份功能彻底移除

**Files:**
- Modify: `Sources/ProviderCatalogView.swift`
- Modify: `Sources/Models.swift`
- Modify: `Sources/Editors.swift`
- Modify: `Sources/ClaudeCode.swift`
- Modify: `Module.swift`
- Modify: `Host/AppMain.swift`
- Modify: `Host/Settings.swift`
- Modify: `Sources/MonitorStore.swift`
- Modify: `Info.plist`
- Delete: `Sources/DataTransfer.swift`
- Delete: `Host/AppBackupExport.swift`, `Host/AppBackupRestore.swift`, `Host/BackupIntegrity.swift`, `Host/DailyBackup.swift`
- Delete: `Tests/BackupSafetyRegression.swift`, `Tests/UsageTransferRegression.swift`

**Interfaces:**
- Produces: `Provider.creationKinds == [.agent]`（仅实际存在 Agent 连接的平台进入目录）。
- Removes: `exportBackup`、`restoreBackup`、备份通知、备份 deep link、备份 UTType、Claude 设置滚动备份。
- Preserves: `exportCSV`、标准 Agent 快照导入、本地用量采集设置。

- [ ] **Step 1: 增加失败断言**

扩展 `CompactAgentUIRegression`：平台源码不得包含 `addAccount(provider, .llm)`、`添加 API 账户`、`自定义 API`；`Module.swift`、菜单、设置和 MonitorStore 不得包含 `exportBackup(`、`restoreBackup(`、`GaoSeries.token.import`、`GaoSeries.token.export`；`ClaudeCode.swift` 不得包含 `backupFile`、`.bak.1`、`.bak.2`、`.bak.3`。

Run Step 2 的 UI 测试。Expected: 新断言失败。

- [ ] **Step 2: 统一 Agent 目录**

`ProviderCatalogView` 的 `providers` 过滤 `provider.creationKinds.contains(.agent)`，添加动作固定 `.agent`；删除自定义 API 卡片。目录保留本地用量来源、采集设置、本机软件发现和 Agent 账户连接。`Provider.creationKinds` 对纯 API 平台返回 `[]`，其余真实 Agent 平台返回 `[.agent]`，不再返回 `.llm`。`Provider.note` 删除 API 推广和双类型说明，只描述实际 Agent 软件及连接边界。

- [ ] **Step 3: 删除备份实现与调用**

从 `MonitorStore` 删除两个备份方法及 `UniformTypeIdentifiers` 中只服务备份的引用，CSV 只遍历 Agent。`Module` 删除 import/export 接收器和 `.gaociyuan` 文件恢复路由；`AppMain` 删除启动恢复、数据菜单；`DataSettings` 只保留打开两个数据目录；`Editors` 的“数据与备份”改为“数据”，只保留 CSV、数据目录和标准快照示例。`Info.plist` 删除 `CFBundleDocumentTypes` 与 `UTExportedTypeDeclarations`。删除上述备份实现和测试文件，不让死代码继续创建备份。

- [ ] **Step 4: 移除 Claude 设置备份**

删除 `backupFile` 与整个滚动备份代码；`writeSettings` 只保留 JSON 序列化和 `.atomic` 写入。界面文案改为“已有状态栏命令会链式保留，断开时恢复该命令；设置文件采用原子写入，不创建备份副本。”按钮“断开并恢复”保留既有 `previousCommand` 机制。

- [ ] **Step 5: 回归、构建并提交**

Run: UI 回归、`RefreshSchedulingRegression`、`ProviderCatalogRegression`、`./scripts/build.sh`。
Expected: 全部退出 0；无备份符号导致编译错误，无 LLM 平台新增入口。

```bash
git add Sources/ProviderCatalogView.swift Sources/Models.swift Sources/Editors.swift Sources/ClaudeCode.swift Sources/MonitorStore.swift Module.swift Host/AppMain.swift Host/Settings.swift Info.plist Tests/CompactAgentUIRegression.swift
git add -u Sources/DataTransfer.swift Host Tests/BackupSafetyRegression.swift Tests/UsageTransferRegression.swift
git commit -m "Unify agent catalog and remove backup features"
```

### Task 4: 无备份构建安装脚本与版本文档

**Files:**
- Modify: `scripts/install.sh`
- Modify: `scripts/package.sh`
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `Info.plist`

**Interfaces:**
- Produces: 仅支持无参数安装的 `scripts/install.sh`；无 `--rollback`、无 `rollback.noindex`。
- Artifacts: `dist/GaoCiYuan-4.13.zip` 与 `dist/GaoCiYuan-4.13.zip.sha256`。

- [ ] **Step 1: 静态失败检查**

用 Python 读取脚本并断言：不包含 `ROLLBACK`、`BACKUP`、`SAFETY`、`--rollback`、`application.zip`、`receipt.json`；包含 `.install.noindex`、签名团队、`verify_app` 和正式目标路径。当前脚本应检查失败。

- [ ] **Step 2: 重写直接安装流程**

保留 `set -euo pipefail`、`umask 077`、进程精确停止检查、Bundle ID／团队／DR／版本核验、旧 Widget 精确注销、`.install.noindex` 暂存和 LaunchServices 注册。删除回滚模式、旧程序移动备份、ZIP 归档与收据；旧目标通过身份核验后，在新暂存包核验完成时 `rm -rf "$TARGET"`，再 `mv` 新包。任一前置校验失败时不得触碰旧目标；替换开始后失败则停止并报告，不自动恢复、不创建备份。

- [ ] **Step 3: 更新版本与文档**

Info.plist 改为 `4.13`／`14`。README 下载名和标题改为 V4.13，新增：紧凑四页、Agent-only、旧 LLM 数据与专属凭据删除、备份功能与既有备份清理；删除备份恢复操作说明和历史版本中“保留备份／回滚”的现行指引，历史事实可简写但不得作为当前功能宣传。AGENTS.md 与根工作区最新无备份规则一致。package 脚本只保留最新 4.13 ZIP／SHA256，旧包在发布收尾精确删除。

- [ ] **Step 4: 构建、打包并提交**

Run:

```bash
./scripts/build.sh && ./scripts/package.sh
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build.noindex/搞词元.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' build.noindex/搞词元.app/Contents/Info.plist
```

Expected: 输出 `4.13` 和 `14`，`codesign --verify --deep --strict` 通过，ZIP SHA256 通过。

```bash
git add scripts/install.sh scripts/package.sh README.md AGENTS.md Info.plist
git commit -m "Release GaoCiYuan 4.13 without backups"
```

### Task 5: 真实资料迁移、安装、唯一入口、清理与发布

**Files:**
- Verify: `~/Library/Application Support/GaoSeries/Token/library.json`（只核验 Agent 与业务结构，不打印凭据）
- Delete: 项目 `rollback.noindex/`、旧 `dist` 包、`build.noindex/`、`.install.noindex/`、`.release.noindex/`、`.test.noindex/`、`.worktrees/` 中间产物
- Delete: 可明确识别的搞词元备份与 Claude 状态栏备份，不碰现用 `settings.json`
- Release: GitHub `UCASerYff/GaoCiYuan` 的 `v4.13`

**Interfaces:**
- Consumes: Task 4 的签名 ZIP 和直接安装脚本。
- Produces: 正式 V4.13 安装、单一搜索入口、远端源码和 Release。

- [ ] **Step 1: 退出旧版并记录非敏感资料基线**

只记录文件存在性、Agent／LLM 账户数量、数据库与附件数量及摘要，不输出名称、凭据或私有正文。正常退出旧搞词元；删除项目旧回滚和旧构建前核对真实路径与类型，不创建备份。运行安装脚本后启动新版完成一次性迁移，再核验 LLM 账户数为 0、Agent ID 集合与基线一致、用量数据库和附件未丢失。

- [ ] **Step 2: 业务与视觉验收**

用本机界面检查四页、紧凑深浅色、搜索、Agent 卡片、用量分析和平台目录；确认无 LLM、用量记录、备份／恢复入口。检查悬浮窗与菜单栏仍在，关闭本轮测试窗口。不能确认的真实第三方额度不声称通过，不自动打开 Grok／Claude 或发起付费调用。

- [ ] **Step 3: 清理备份与中间产物**

精确删除搞词元自动／手动备份、应用管理的安全副本、Claude `settings.json.gaociyuan-backup` 与 `.bak.1`–`.bak.3`；保留 `~/.claude/settings.json` 和 Agent 资料。清除旧 App 副本、旧安装包、展开构建和暂存目录，只保留最新 4.13 ZIP／SHA256 与源码。对删除项逐项核对路径，不能递归匹配普通用户文档。

- [ ] **Step 4: 核验唯一安装入口**

Run:

```bash
mdfind 'kMDItemCFBundleIdentifier == "com.gaoseries.GaoCiYuan"'
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -dump | python3 -c 'import sys; lines=sys.stdin.read().splitlines(); print("\n".join(x for i,x in enumerate(lines) if "com.gaoseries.GaoCiYuan" in x or (i and "搞词元.app" in x)))'
codesign --verify --deep --strict /Applications/搞词元.app
```

Expected: 实际用户会话中有效应用路径只有 `/Applications/搞词元.app`；备份 ZIP 不算可启动入口。若 Spotlight 未收敛，继续精确复核，不宣称唯一性完成。

- [ ] **Step 5: 推送源码与 Release**

`git status --short` 只能有所需源码／文档变更；确认没有 `library.json`、数据库、附件、钥匙串、备份或验证私有资料被跟踪。推送 `main`，创建 `v4.13` Release 并上传最新 ZIP／SHA256；下载远端附件核对 SHA256 与本地一致。Expected: 远端源码和安装包可查，用户数据未上传。
