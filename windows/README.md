# 搞词元 Windows 4.16

Windows 10（2004 及更新版本）和 Windows 11 的 x64 当前用户安装包。当前候选为 **4.16+1**，文件为 `GaoCiYuan-Windows-4.16-build1-x64-Setup.exe` 和同名 `.sha256`。核对 SHA-256 后运行安装程序。已有 Windows 版时，从通知区域退出应用，再沿用原安装目录升级。安装程序创建开始菜单入口，注册 `gaociyuan://analytics`，并在缺少 WebView2 时调用 Microsoft 签名的引导程序。卸载移除程序、快捷方式和协议注册，保留用户资料和凭据。Windows 安装包目前没有 Authenticode 签名。

构建 2 从原始书法图生成透明圆角、多尺寸 Windows 图标。开始菜单和固定任务栏继续使用同一个程序身份与主程序图标。运行中窗口和通知区域依据系统 DPI 选择图标，保留原托盘操作。应用内 Agent 软件标记在浅深色均保留原形，只有图片缺失时显示文字占位。

## 使用

- 从开始菜单打开「搞词元」。通过左侧导航切换总览、Agent 软件、用量分析、平台接入和设置。较窄窗口会收起导航文字，并将并排内容改为上下排列。
- 关闭主窗口后，搞词元留在 Windows 通知区域，图标也可能位于「显示隐藏的图标」中。点图标或选「打开搞词元」可继续操作。选「退出搞词元」时，已提交的操作会完成后再退出，有未保存修改时可取消并返回。若 Windows 无法注册通知区域图标，关闭主窗口会走同一个退出流程。
- 总览集中呈现剩余额度、下次重置、数据来源和需要处理的账户。Agent 软件页可在列表中快速选中账户，再在详情中核对额度、连接和读数。平台接入按可直接读额度、手动读取和其他连接路径组织。
- 总览的「额度可用性」列出预计可能在下次重置前用完的窗口。进入账户详情可核对实际读数、估算时间、来源、采样数、跨度和消耗速度。估算需至少 3 次有效读数且跨度至少 30 分钟，只有同一账户、来源和重置窗口的百分比读数参与计算。来源或窗口变更、补额、读数过期、变化不足或外推过远时，可能需要重新积累证据。升级前缺少来源记录的历史仍保留供查看。手动 Grok Bot 读数、余额、积分与费用继续原样显示。
- 桌面悬浮窗在紧凑视图中显示额度和余额，展开后可查看来源、重置时间和过期状态。可拖到左、右或顶部停靠，也可松开为浮动位置。点额度环打开总览中的对应账户。支持单双列、跟随指针所在显示器、检测到全屏窗口时隐藏以及浅深色外观。
- 可设置额度档位、余额下限、额度用尽、窗口重置及连续同步失败通知。Windows 原生通知受系统通知开关和勿扰设置控制。
- 平台接入支持按 Windows 安装目录、注册表、当前会话进程和 CLI 路径识别软件。自动建立的账户在用户首次成功手动同步后才参与定时连接。只需要快照时，选择「自动读取快照文件」并指定本机 JSON。快照的 `observedAt` 为 ISO 8601，额度、余额、词元或金额按实际已有字段显示。
- Grok Bot 仅在账户或悬浮窗的「读取本机额度」操作中读取 `%APPDATA%\GaoSeries\Token\grokbot-usage.json`。合同字段为 `schema: 1`、`source: "grok-bot-usage-report"`、ISO 8601 的 `capturedAt` 和 0–100 的已用百分比 `weeklyPercentUsed`。窗口显示 **剩余** 百分比。超过 6 小时或重置时间已过的成功读数会变淡。自动同步和批量刷新不读取此报告，成功的手动读数也不写进用量历史。

## Windows 支持的额度读取

| 平台 | Windows 数据来源 |
| --- | --- |
| Codex | 从用户已登录的官方 Codex CLI 读取本机 app-server 的账户额度，执行首次手动刷新后才开始周期读取。 [Codex app-server](https://learn.chatgpt.com/docs/app-server) |
| Claude Code | 用户在 Claude Code 启用官方 `statusLine`，调用已安装的 `GaoCiYuan-cli.exe --capture-claude-status`。账户编辑器提供完整命令，随后读取系统回传的额度快照。 [Claude Code status line](https://code.claude.com/docs/en/statusline) |
| Antigravity | 用户关联独立 CLI 中登录的 Google 邮箱，并在 CLI 启用一次官方 `statusLine`。之后 CLI 会把模型组额度推送到搞词元。 [Antigravity 状态栏数据](https://antigravity.google/docs/cli/statusline/) |
| 小米 MiMo | 用户在 Agent 套餐连接中提供个人 Token Plan 密钥，按选择的大陆、新加坡或欧洲服务区读官方额度。团队密钥不适用于此个人接口。 [MiMo Token Plan](https://mimo.mi.com/docs/zh-CN/api/asset/credits-get) |
| MiniMax | 使用已安装并授权的官方 `mmx` CLI 执行只读额度查询。 [MiniMax CLI](https://github.com/MiniMax-AI/cli/blob/main/src/commands/quota/show.ts) |
| OpenCode Go | 使用 Go 计划的独立密钥读取官方用量。 [OpenCode Go](https://opencode.ai/docs/console/go/#usage) |
| 阿里云百炼 | 使用用户授权登录的官方 `bl` CLI 读取个人 Token Plan 或 Coding Plan。 [百炼 CLI](https://help.aliyun.com/zh/model-studio/cli/usage-quota) |

### Antigravity 自动同步

在「平台接入」添加或打开现有「Antigravity 独立版」账户，填入并保存官方独立 CLI 显示的登录邮箱。从账户设置复制配置示例，将 `statusLine` 合并到 `%USERPROFILE%\.gemini\antigravity-cli\settings.json`。示例包含安装目录中的接收命令、当前邮箱的账户指纹，并以 `stack_with_default` 保留默认状态栏。如果已有自定义状态栏，把接收命令加入现有脚本，并将同一份标准输入传给它。搞词元不会修改该设置文件。 [官方 CLI 安装指南](https://antigravity.google/docs/getting-started?tab=cli) · [官方状态栏配置](https://antigravity.google/docs/cli/statusline/)

打开已登录的独立 CLI 后，它会在状态变化时推送。启用自动同步时，搞词元每分钟从本地缓存读取一次，只接收和配置指纹匹配的登录邮箱。切换 Google 账户后需要选用相应账户的状态栏配置。15 分钟未收到同邮箱的新读数会显示历史状态。没有推送的窗口或比例不填猜测值。该路径由正在运行的 CLI 提供读数，独立桌面应用和 Gemini 内置版不提供此回调。

历史报告仍可从「Agent 软件」的账户明细导入。选择 UTF-8 `.json` 或 `.txt` 文件（最多 64 KiB），核对目标账户并确认。 [官方额度说明](https://antigravity.google/docs/cli/commands/usage)

在自己的终端中确认已登录目标账户、`agy --version` 为 1.1.11 或较新版本，并且当前生效的 `disableSlashCommands` 为 `false`，再使用下列 PowerShell 命令导出。无法确认条件时，在交互界面直接运行 `/usage`，将额度面板内容保存为 UTF-8 `.txt` 文件。搞词元仅读取你选中的报告文件。 [CLI 1.1.11 发布说明](https://antigravity.google/changelog?tab=cli#v1111) [Google Antigravity 常见问题](https://antigravity.google/docs/faq)

```powershell
$antigravityUsage = agy -p '/usage' --output-format json
if ($LASTEXITCODE -eq 0) {
    $antigravityUsage | Set-Content -LiteralPath 'antigravity-usage.json' -Encoding utf8
}
```

总览和账户明细会标明历史报告、导入方式、导入时间和报告记录的剩余百分比。JSON 文件中如有可读的重置时间，会标在相应额度旁。两种格式均无法验证文件来源、所属账号或采集时间。报告单独留作历史参考，不参与实时额度、重置倒计时、预测或提醒。现有通用 JSON 快照连接仍可用。

Windows 自动发现仅识别独立版 Antigravity。旧的 Gemini 内置账户可从原账户明细展开历史额度，过期读数仍会显示。新建独立版账户即可配置 CLI 同步和导入独立版报告。

其余平台仍可建立 Agent 记录、查看接入说明并使用快照文件。Windows 实时读取目前未覆盖 Cursor、Copilot 个人额度、Grok 在线账户、Kimi、豆包、WorkBuddy、Zcode/GLM、DeepSeek Harness、Devin、Ollama Cloud、Command Code、OpenCode Zen、Cline、Factory、Zed、Kiro、Qoder 和 Trae，也未迁移 macOS 的辅助功能或登录态读取方式。

## 词元用量与资料

首次使用「立即采集」或保存来源设置后，用量分析按所选来源读取本机日志。支持 Codex、Claude Code、OpenCode、Gemini CLI、Kimi、OpenClaw、Pi、Qwen Code、Copilot OTLP 文件、Hermes Agent、Cline、Kilo、Oh My Pi、Grok Build 和 Factory Droid。可查看总量、日期趋势、热力图、软件与模型分布、会话明细，并导入和导出数值用量包。Windows 扫描来源少于 macOS Tokscale，Cursor 历史可随用量包合并去重。关闭模块的自动同步会暂停计划采集。公开价格更新仅在用户操作时下载公共定价表，也可手工指定模型单价。

资料保留在 `%APPDATA%\GaoSeries\Token`。已有 `library.json`、设置、凭据和快照账本 `usage-ledger.sqlite` 延续原路径，本机日志分析使用 `local-usage.sqlite`。导入再导出 Mac 格式 4 用量包时保留本地事件、覆盖范围和模型标记，用量按来源设备去重。凭据由 Windows 当前用户 DPAPI 保护。资料库有效落盘后才清理已退役账户的专属凭据，未知账户和仍被其他记录使用的凭据继续保留。资料库或设置文件无法读取时保留原文件。程序不创建升级备份。

## 应用内更新

设置中可配置团队发布的 Windows appcast（HTTPS 或本机 `file:` 地址）及 Base64 编码的 32 字节 Ed25519 公钥。建议在 enclosure 标注 `sparkle:os="windows"` 和 `sparkle:arch="x64"`，并提供版本、文件长度和 `sparkle:edSignature`。点击下载后，软件先验证签名和长度，再把包保存至资料目录下的 `updates`。安装由用户启动。Windows 发布尚未配置公共 appcast 和发布公钥，首次检查会显示未配置。

同一发行版本有多个 Windows 构建时，请在明确标注为 Windows 的条目同时声明营销版本及 PE 文件版本。例如 `sparkle:shortVersionString="4.15"` 和 `sparkle:version="4.15.3"`（或 `4.15.3.0`）代表 4.15 的第 3 个 Windows 构建。只有文件版本以完全相同的营销版本数字段开头时，才比较构建号。旧条目只声明营销版本也可继续使用。

## 构建与验证

使用独立的 Windows x64 CPython 3.12 环境和 Inno Setup 7 x64。build.ps1 会检查版本和 Microsoft 引导程序的 Authenticode 签名，执行回归，再生成安装包和 SHA-256。已有已验证的引导程序时可以用 `-WebViewBootstrapper` 指定文件。 [Inno Setup](https://jrsoftware.org/inno-setup/downloads) [WebView2 Runtime 分发](https://learn.microsoft.com/microsoft-edge/webview2/concepts/distribution)

```powershell
cd windows
py -3.12 -m venv .build-venv
& .build-venv/Scripts/python.exe -m pip install -r requirements-dev.txt
./build.ps1 -Python .build-venv/Scripts/python.exe -Iscc 'C:\Program Files\Inno Setup 7\ISCC.exe'
./smoke-installed.ps1
```

安装冒烟使用单独资料目录与合成凭据，核对快捷方式身份、图标索引和安装后的图标组。已有正式 Windows 安装时脚本会停止。在干净的 Windows 测试环境，可用 `-PreviousInstallerPath` 提供 4.15+3 的安装包，验证原地升级。直接运行 `GaoCiYuan-cli.exe` 会显示命令帮助，标准输出和错误输出使用 UTF-8。可用 `python launch.py --serve --no-browser --data-dir <隔离目录> --no-refresh` 运行只监听本机的测试入口。已构建 CLI 与 Edge 可通过 `node tests/visual-smoke.mjs <CLI 路径> 4.16+1 <截图目录>` 验证代表性页面与高 DPI 布局。

可用 PowerShell 7 运行 `./tests/smoke-tray.ps1 -Executable <已安装程序路径> -ExpectedFileVersion 4.16.1.0`，在独立 Windows 桌面与合成资料中验证托盘和退出行为。加 `-ProbeExplorer` 可在当前桌面用隐藏测试窗口核验 Windows Shell 的图标注册和删除。

Windows 桌面需要 Edge WebView2。程序启动时会探测 x64 WebView2，缺失时提示安装。明确选用的外部浏览器入口和无界面 CLI 仍可单独使用。Windows 用通知区域替代 macOS 菜单栏与 Dock。两端均已下线 WidgetKit。
