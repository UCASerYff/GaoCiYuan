# 搞词元 Windows 4.13

Windows 10（2004 及更新版本）和 Windows 11 的 x64 当前用户安装包。正式版本为 **4.13**，Windows 构建号为 **3**。从 Release 下载 `GaoCiYuan-Windows-4.13-build3-x64-Setup.exe` 和同名 `.sha256`，核对 SHA-256 后运行安装程序。已有 4.13+2 时，退出应用并沿用原安装目录升级。安装程序创建开始菜单入口，注册 `gaociyuan://analytics`，并在缺少 WebView2 时调用 Microsoft 签名的引导程序。卸载移除程序、快捷方式和协议注册，保留用户资料和凭据。此 Windows 发布包目前没有 Authenticode 签名。

## 使用

- 从开始菜单打开「搞词元」。通过左侧导航切换总览、Agent 软件、用量分析、平台接入和设置。较窄窗口会收起导航文字，并将并排内容改为上下排列。关闭主窗口后可从 Windows 通知区域重新打开，也可在通知区域退出。
- 总览集中呈现剩余额度、下次重置、数据来源和需要处理的账户。Agent 软件页可在列表中快速选中账户，再在详情中核对额度、连接和读数。平台接入按可直接读额度、手动读取和其他连接路径组织。
- 桌面悬浮窗在紧凑视图中显示额度和余额，展开后可查看来源、重置时间和过期状态。可拖到左、右或顶部停靠，也可松开为浮动位置。点额度环打开总览中的对应账户。支持单双列、跟随指针所在显示器、检测到全屏窗口时隐藏以及浅深色外观。
- 可设置额度档位、余额下限、额度用尽、窗口重置及连续同步失败通知。Windows 原生通知受系统通知开关和勿扰设置控制。
- 平台接入支持按 Windows 安装目录、注册表、当前会话进程和 CLI 路径识别软件。自动建立的账户在用户首次成功手动同步后才参与定时连接。只需要快照时，选择「自动读取快照文件」并指定本机 JSON。快照的 `observedAt` 为 ISO 8601，额度、余额、词元或金额按实际已有字段显示。
- Grok Bot 仅在账户或悬浮窗的「读取本机额度」操作中读取 `%APPDATA%\GaoSeries\Token\grokbot-usage.json`。合同字段为 `schema: 1`、`source: "grok-bot-usage-report"`、ISO 8601 的 `capturedAt` 和 0–100 的已用百分比 `weeklyPercentUsed`。窗口显示 **剩余** 百分比。超过 6 小时或重置时间已过的成功读数会变淡。自动同步和批量刷新不读取此报告，成功的手动读数也不写进用量历史。

## Windows 支持的额度读取

| 平台 | Windows 数据来源 |
| --- | --- |
| Codex | 从用户已登录的官方 Codex CLI 读取本机 app-server 的账户额度，执行首次手动刷新后才开始周期读取。 [Codex app-server](https://learn.chatgpt.com/docs/app-server) |
| Claude Code | 用户在 Claude Code 启用官方 `statusLine`，调用已安装的 `GaoCiYuan-cli.exe --capture-claude-status`。账户编辑器提供完整命令，随后读取系统回传的额度快照。 [Claude Code status line](https://code.claude.com/docs/en/statusline) |
| 小米 MiMo | 用户在 Agent 套餐连接中提供个人 Token Plan 密钥，按选择的大陆、新加坡或欧洲服务区读官方额度。团队密钥不适用于此个人接口。 [MiMo Token Plan](https://mimo.mi.com/docs/zh-CN/api/asset/credits-get) |
| MiniMax | 使用已安装并授权的官方 `mmx` CLI 执行只读额度查询。 [MiniMax CLI](https://github.com/MiniMax-AI/cli/blob/main/src/commands/quota/show.ts) |
| OpenCode Go | 使用 Go 计划的独立密钥读取官方用量。 [OpenCode Go](https://opencode.ai/docs/console/go/#usage) |
| 阿里云百炼 | 使用用户授权登录的官方 `bl` CLI 读取个人 Token Plan 或 Coding Plan。 [百炼 CLI](https://help.aliyun.com/zh/model-studio/cli/usage-quota) |

其余平台仍可建立 Agent 记录、查看接入说明并使用快照文件。Windows 实时读取目前未覆盖 Cursor、Copilot 个人额度、Grok 在线账户、Gemini/Antigravity 应用、Kimi、豆包、WorkBuddy、Zcode/GLM、DeepSeek Harness、Devin、Ollama Cloud、Command Code、OpenCode Zen、Cline、Factory、Zed、Kiro、Qoder 和 Trae，也未迁移 macOS 的辅助功能或登录态读取方式。

## 词元用量与资料

首次使用「立即采集」或保存来源设置后，用量分析按所选来源读取本机日志。支持 Codex、Claude Code、OpenCode、Gemini CLI、Kimi、OpenClaw、Pi、Qwen Code、Copilot OTLP 文件、Hermes Agent、Cline、Kilo、Oh My Pi、Grok Build 和 Factory Droid。可查看总量、日期趋势、热力图、软件与模型分布、会话明细，并导入和导出数值用量包。Windows 扫描来源少于 macOS Tokscale，Cursor 历史可随用量包合并去重。关闭模块的自动同步会暂停计划采集。公开价格更新仅在用户操作时下载公共定价表，也可手工指定模型单价。

资料保留在 `%APPDATA%\GaoSeries\Token`。已有 `library.json`、设置、凭据和快照账本 `usage-ledger.sqlite` 延续原路径与结构，本机日志分析使用单独的 `local-usage.sqlite`。凭据由 Windows 当前用户 DPAPI 保护，原版使用的凭据管理器目标名称继续有效。旧 LLM/自定义 API 账户及其独占凭据按 v4.13 规则移除。资料库损坏或 schema 不兼容时禁止覆盖。程序不创建升级备份。

## 应用内更新

设置中可配置团队发布的 Windows appcast（HTTPS 或本机 `file:` 地址）及 Base64 编码的 32 字节 Ed25519 公钥。建议在 enclosure 标注 `sparkle:os="windows"` 和 `sparkle:arch="x64"`，并提供版本、文件长度和 `sparkle:edSignature`。点击下载后，软件先验证签名和长度，再把包保存至资料目录下的 `updates`。安装由用户启动。Windows 发布尚未配置公共 appcast 和发布公钥，首次检查会显示未配置。

## 构建与验证

使用独立的 Windows x64 CPython 3.12 环境和 Inno Setup 7 x64。build.ps1 会检查版本和 Microsoft 引导程序的 Authenticode 签名，执行回归，再生成安装包和 SHA-256。已有已验证的引导程序时可以用 `-WebViewBootstrapper` 指定文件。 [Inno Setup](https://jrsoftware.org/inno-setup/downloads) [WebView2 Runtime 分发](https://learn.microsoft.com/microsoft-edge/webview2/concepts/distribution)

```powershell
cd windows
py -3.12 -m venv .build-venv
& .build-venv/Scripts/python.exe -m pip install -r requirements-dev.txt
./build.ps1 -Python .build-venv/Scripts/python.exe -Iscc 'C:\Program Files\Inno Setup 7\ISCC.exe'
./smoke-installed.ps1
```

安装冒烟使用单独资料目录与合成凭据。已有正式 Windows 安装时，冒烟脚本会停止。在干净的 Windows 测试环境可传入 `-PreviousInstallerPath <4.13+2 安装包路径>`，按顺序安装两个构建并验证资料。可额外用 `python launch.py --serve --no-browser --data-dir <隔离目录> --no-refresh` 运行只监听本机的测试入口。已构建 CLI 与 Edge 可通过 `node tests/visual-smoke.mjs <CLI 路径> 4.13+3 <截图目录>` 验证代表性页面与高 DPI 布局。

v4.13 Windows 的附带差异包括原生窗口边框、字体与部分图标、部分平台提示的英文译文，以及悬浮窗视觉效果。Mac 专属的 WidgetKit、Dock/菜单栏集成、CLI 活跃指示点和网络诊断导出未迁移。安装、卸载、更新签名和核心交互在隔离资料下验收；未使用实际 Agent 订阅账户或 macOS 真机。
