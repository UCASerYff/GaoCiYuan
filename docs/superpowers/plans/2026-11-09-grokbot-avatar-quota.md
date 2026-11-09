# Grok Bot 头像栏目额度读取 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 通过辅助功能读取 Grok Bot 左下角头像栏目的套餐和已用百分比，在搞词元中显示剩余额度，并支持手动立即读取与非前台自动读取。

**Architecture:** 新增 `GrokBotAX`，将纯文本解析、头像选择、导航节流与 AppKit／AX 操作放在同一专注文件；`GrokBotBridge` 只负责异步调用和结果映射。`ManualReading` 用可选来源与套餐字段兼容旧存档，新头像读数不借用旧快照的重置时间或共享口径。

**Tech Stack:** Swift 5、AppKit、ApplicationServices、CoreGraphics、SwiftUI、现有 swiftc 回归测试、zsh 构建脚本。

## Global Constraints

- 只修改 `/Users/yufeifan/Desktop/搞app/搞词元`，版本从 4.11／12 升为 4.12／13。
- 手动同步立即读取且不受自动节流；自动刷新仅在 Grok Bot 非前台时读取，自动打开栏目前按账户节流 5 分钟。
- 动作仅为按下左下角头像和直投 Escape；不点击套餐、设置、退出登录，不读聊天、网络、Cookie、凭证或私有数据库。
- 只接受 `<套餐> <0...100>% 已用` 完整匹配，剩余量为 `100 − used`；失败保留上次成功记录，不编造 0% 或 100%。
- 栏目未提供重置时间与共享范围，新记录必须分别使用 `resetsAt: nil`、`sharedWithOtherApps: false`。
- 新 `.app` 只能出现在 `.noindex` 容器；保留资料、钥匙串、完整备份、回滚与唯一正式入口。

---

### Task 1: 栏目解析与来源明确的剩余量展示

**Files:**
- Create: `Sources/GrokBotAX.swift`
- Create: `Tests/GrokBotAXRegression.swift`
- Modify: `Sources/GrokBotUsageReport.swift`
- Modify: `Tests/GrokBotUsageReportRegression.swift`

**Interfaces:**
- Produces: `GrokBotAX.Observation(plan: String, weeklyPercentUsed: Double)`。
- Produces: `GrokBotAX.parse(lines: [String]) -> Observation?`。
- Produces: `GrokBotUsageReport.ManualSource.avatarMenu` 与 `ManualReading.plan/source` 可选字段。
- Produces: `GrokBotUsageReport.avatarManualReading(plan:weeklyPercentUsed:capturedAt:) -> ManualReading`。
- Consumes: 既有 `remainingPercent(used:)`、`freshness(of:now:)` 和 `formatTimestamp(_:timeZone:)`。

- [ ] **Step 1: 写失败回归**

在 `Tests/GrokBotAXRegression.swift` 使用 `@main` 和 `require`，加入：

```swift
let observed = GrokBotAX.parse(lines: ["账户", "Premium 96% 已用", "设置"])
require(observed == GrokBotAX.Observation(plan: "Premium", weeklyPercentUsed: 96), "real avatar row")
require(GrokBotAX.parse(lines: ["SuperGrok 19.25% 已用"])?.weeklyPercentUsed == 19.25, "decimal")
for invalid in ["Premium 96% 剩余", "Premium 100.1% 已用", "Premium -0.1% 已用", "聊天提到 Premium 96% 已用", "Premium NaN% 已用"] {
    require(GrokBotAX.parse(lines: [invalid]) == nil, "accepted \(invalid)")
}
require(GrokBotAX.parse(lines: ["Premium 96% 已用", "SuperGrok 1% 已用"]) == nil, "conflicting rows")
```

在既有展示测试中把按钮断言改为“读取本机额度”／“正在读取本机额度…”，删除自动刷新禁止读取的旧断言，并增加：

```swift
let avatar = GrokBotUsageReport.avatarManualReading(plan: "Premium", weeklyPercentUsed: 96, capturedAt: now)
require(avatar.resetsAt == nil && !avatar.sharedWithOtherApps, "avatar invented reset or sharing")
let avatarText = GrokBotUsageReport.statusLine(avatar, now: now, timeZone: zone)
require(avatarText.contains("头像栏目") && avatarText.contains("额度剩余 4%（已用 96%）"), avatarText)
require(avatarText.contains("Premium") && !avatarText.contains("本周") && !avatarText.contains("平台未提供重置"), avatarText)
let avatarRing = GrokBotUsageReport.dedicatedRingFace(isGrokBotRoute: true, reading: avatar, now: now, timeZone: zone)
require(avatarRing?.label == "4%" && avatarRing?.fill == 0.04, "avatar ring")
```

- [ ] **Step 2: 运行并确认失败**

Run:

```bash
swiftc -parse-as-library Sources/GrokBotUsageReport.swift Sources/GrokBotAX.swift Sources/AXShared.swift Tests/GrokBotAXRegression.swift -framework AppKit -framework ApplicationServices -framework CoreGraphics -o .test.noindex/grok-avatar/parser
```

Expected: 编译失败，因为 `GrokBotAX`、`avatarManualReading` 和新来源尚不存在；不得删除新断言。

- [ ] **Step 3: 实现纯解析**

在 `GrokBotAX.swift` 建立 `Observation: Equatable` 和完整匹配解析：逐行去空白，正则 `^([^\\d%]+?)\\s+(0(?:\\.\\d+)?|[1-9]\\d*(?:\\.\\d+)?)%\\s*已用$`，套餐去空白且长度为 1...64、不得含控制字符；数值必须有限且位于 0...100。相同候选去重，不同候选返回 `nil`。

- [ ] **Step 4: 扩展展示模型**

在 `GrokBotUsageReport` 增加：

```swift
enum ManualSource: String, Codable { case legacySnapshot, avatarMenu }
```

给 `ManualReading` 末尾增加 `var plan: String? = nil` 与 `var source: ManualSource? = nil`。旧文件读取写入 `.legacySnapshot` 和原套餐。`avatarManualReading` 创建 `resetsAt: nil`、`sharedWithOtherApps: false`、`source: .avatarMenu` 的记录。`statusLine` 对 `.avatarMenu` 使用“Grok Bot 头像栏目（采集于 …）· 额度剩余 X%（已用 Y%）· 套餐 …”，旧来源继续调用原 `presentation`。按钮改为“读取本机额度”，空读数帮助改为“尚未读取 Grok Bot 本机额度”。

- [ ] **Step 5: 运行两组回归并提交**

Run: Task 1 Step 2 的编译与生成二进制；再运行既有 `GrokBotUsageReportRegression`。
Expected: 两个二进制均退出 0，真实 fixture 输出 `{"passed":true,"used":96,"remaining":4}`。

```bash
git add Sources/GrokBotAX.swift Sources/GrokBotUsageReport.swift Tests/GrokBotAXRegression.swift Tests/GrokBotUsageReportRegression.swift
git commit -m "Parse Grok Bot avatar quota"
```

### Task 2: 后台头像导航、自动节流与同步接线

**Files:**
- Modify: `Sources/GrokBotAX.swift`
- Modify: `Sources/GrokBotBridge.swift`
- Modify: `Sources/Connectors.swift`
- Modify: `Sources/FloatingPanel.swift`
- Modify: `Sources/Models.swift`
- Test: `Tests/GrokBotAXRegression.swift`
- Test: `Tests/AgentDiscoveryRegression.swift`

**Interfaces:**
- Produces: `GrokBotAX.CollectOutcome`：`notRunning`、`needsPermission`、`foregroundBusy`、`throttled`、`unavailable`、`observation(Observation)`。
- Produces: `GrokBotAX.collect(accountID:allowPrompt:allowNavigation:userInitiated:now:) -> CollectOutcome`。
- Produces: `GrokBotBridge.fetch(_ account: Account, now: Date, userInitiated: Bool) async throws -> ConnectorResult`。
- Consumes: Task 1 的 `avatarManualReading`；既有 `ConnectorResult.grokBotManual(status:reading:)`。

- [ ] **Step 1: 增加头像选择与节流失败测试**

增加纯值 `AvatarCandidate(title:x:y:windowHeight:)` 和 `chooseAvatar(_:) -> AvatarCandidate?`：仅保留标题非空、位于窗口下 20% 的候选，先取最大 y，再取最小 x。测试头像 `(x:16,y:832)` 胜过输入框 `(x:351,y:832)`，顶部“分享”和空标题被排除。

用两个固定 UUID 验证 `navigationThrottled(_:now:)`：未导航为 false，`markNavigated` 后 299 秒为 true、300 秒为 false；账户 B 不受账户 A 节流。测试结束只清理测试 UUID 的内存导航记录，不触碰用户设置。

- [ ] **Step 2: 确认新增选择测试失败**

Run: Task 1 Step 2。
Expected: 编译失败，因为 `AvatarCandidate`、`chooseAvatar` 和节流接口尚不存在。

- [ ] **Step 3: 实现受限 AX 导航**

`runningApp` 只认 `com.anysphere.sand`。`windowLines` 使用 `AXShared.collectTexts`；AX 遍历深度不超过 `AXShared.maxDepth`。`accountButton` 收集有标题的 `AXPopUpButton` 位置并映射为候选。`sendEscape` 使用虚拟键 53 的 `CGEvent.postToPid`。

`collect` 的顺序：运行检查 → 辅助功能检查（仅手动允许弹授权）→ 设置 `AXManualAccessibility` → 自动读取时先检查前台并跳过 → 直接解析已展开栏目 → `allowNavigation` 检查 → 前台检查 → 自动导航节流 → 头像 AXPress → `usleep(900_000)` → 重读 → Escape。只有本次成功按下头像后才发送 Escape；解析不到返回 `.unavailable`。手动路径不记录也不检查自动节流。

- [ ] **Step 4: 替换文件读取并接通自动路径**

`AgentBridge` 的 Grok 分支改为 `try await GrokBotBridge.fetch(account, userInitiated: userInitiated)`。桥在后台线程调用 `GrokBotAX.collect`，自动与手动都允许导航，只有手动允许授权弹窗。成功时返回 `.grokBotManual(status:statusLine(...), reading:avatarManualReading(...))`。

未运行、前台占用、节流或自动未读到栏目返回 `.status`，保留上次读数且不制造告警；手动未授权或读取失败抛出可操作错误。生产路径删除 `GrokBotUsageFileProvider` 参数和 `provider.load`，旧文件类型仅供存档兼容回归。

- [ ] **Step 5: 更新注释并运行回归**

将 `FloatingPanel`、`Models` 和 `ConnectorResult` 附近“只读上次快照／只能手动”的旧注释改为“头像栏目读取，支持非前台自动同步”，不改圆环剩余量语义。运行 Task 1 两组测试及既有 AgentDiscovery 编译测试；Expected: 全部退出 0，新测试确认自动导航节流与前台跳过策略。

```bash
git add Sources/GrokBotAX.swift Sources/GrokBotBridge.swift Sources/Connectors.swift Sources/FloatingPanel.swift Sources/Models.swift Tests/GrokBotAXRegression.swift
git commit -m "Read Grok Bot quota from avatar menu"
```

### Task 3: 真实读取、版本发布与恢复能力

**Files:**
- Modify: `Info.plist`
- Modify: `README.md`
- Test: 真实 Grok Bot 4% 剩余读取与自动策略
- Artifacts: `dist/GaoCiYuan-4.12.zip`、`dist/GaoCiYuan-4.12.zip.sha256`、`rollback.noindex/`、`验证记录/`

**Interfaces:**
- Consumes: Task 2 的手动与自动同步路径。
- Preserves: 原资料目录、App Group、钥匙串服务、账户 ID、历史和悬浮窗设置。

- [ ] **Step 1: 更新版本与文档**

`CFBundleShortVersionString` 改为 `4.12`，`CFBundleVersion` 改为 `13`。README 新增 V4.12：头像栏目 AX 读取、剩余量展示、手动立即读取、非前台自动读取与 5 分钟节流、失败保留、未提供重置时间不编造；下载文件名改为 4.12。

- [ ] **Step 2: 构建前完整备份并运行测试**

使用上一轮保留的 `验证记录/2026-11-09-grokbot-rail.noindex/preupdate_backup.py` 复制为本轮备份脚本，先生成新目录的 preupdate 备份，再运行 Grok、AgentDiscovery 回归与 `./scripts/build_framework.sh`。Expected: 所有命令退出 0，备份收据包含账户、历史、设置、账本与附件清单。

- [ ] **Step 3: 构建签名安装并核验资料**

Run: `./scripts/build.sh && ./scripts/package.sh && ./scripts/install.sh`。
Expected: 正式 `/Applications/搞词元.app` 为 4.12／13、团队 `5G96498KGJ`，DR 与旧版一致，无 WidgetKit 扩展；运行资料验证通过，回滚 ZIP 摘要与收据匹配。

- [ ] **Step 4: 真实 Grok Bot 验收**

在 Grok Bot 运行且栏目收起时，从搞词元点击“读取本机额度”。Expected: 头像栏目后台展开并收起，账户状态显示 Premium 已用 96%、剩余 4%，悬浮圆环标签为 `4%`，旧 `15.2%` 被替换。另以真实或可控桥测试确认非前台自动读取成功、前台使用中跳过且导航节流有效。失败则保留旧版回滚能力，不声称真实验收通过。

- [ ] **Step 5: 唯一入口、提交、合并和 Release**

清理展开的 build／release／install App，Spotlight 与 LaunchServices 只能保留 `/Applications/搞词元.app`。提交版本文档，合并后重跑核心测试，保留发行包、资料备份与恢复收据，推送 `main`，创建 `v4.12` Release 并上传 ZIP／SHA256。匿名下载后必须逐字节与本地 ZIP 一致；私有备份不得上传。
