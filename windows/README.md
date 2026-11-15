# 搞词元 Windows 版

营销版本与当前 Mac 版相同，为 **4.13**。Windows 构建号为 **1**，程序打印 `4.13+1`。代码只在 `windows/`，不改 Mac 版的 Swift 源码、签名或 `Info.plist`。

## 运行

需要 Windows 10/11 和 Python 3.12。界面是只监听 `127.0.0.1` 的本地网页。

```powershell
cd windows
py -3.12 -m pip install -r requirements-dev.txt
py -3.12 -m pytest -q
py -3.12 launch.py --serve
```

`build.ps1` 会先跑测试，再用 PyInstaller 打出 `dist/GaoCiYuan.exe`、`dist/GaoCiYuan-cli.exe` 和 `dist/GaoCiYuan-Windows-4.13.zip`。

资料目录是 `%APPDATA%\GaoSeries\Token\`。账户写在 `library.json`。密钥不进这个文件。

## 资料与凭据

- 账户、快照和最近 300 条历史在 `library.json`，schema 为 1。不认识的字段会保留；已废弃的 `station` 会去掉。
- 文件损坏或 schema 不是 1 时只读，不会用空库覆盖。
- 打开资料库时删除旧的 LLM / 自定义 API 账户，并删掉它们的凭据。不制作备份。
- Windows 上凭据用 DPAPI 保护，长度允许时同时写入凭据管理器，目标名以 `GaoCiYuan:com.gaoseries.GaoQiNianSan.credentials:` 开头。

## Grok Bot

没有公开的每周用量接口。只有点击「读取本机额度」才会读取：

`%APPDATA%\GaoSeries\Token\grokbot-usage.json`

自动刷新、后台计时和其他账户的快照导入都不会打开它。文件要由用户另行写成，约定与 Mac 版相同：`schema` 1、`source` 为 `grok-bot-usage-report`、`weeklyPercentUsed` 为 0 到 100 的已用百分比。缺文件、读失败或字段不符时不显示百分比，也不写成 0。上次成功的读数会留下。

圆环弧长和环下数字是剩余百分比，由已用百分比换算，与当前 Mac 悬浮窗一致。超过 6 小时或重置时间已过则变淡，数字里不写「旧」，也不算实时额度。这次读数不进入用量历史。

## 和 Mac 版的差异

| 功能 | Windows 版 |
| --- | --- |
| 总览、Agent 列表、平台目录、设置、悬浮条 | 有。悬浮条在页面右侧，不是系统级置顶面板 |
| 快照文件里的额度、Token 和费用 | 有。重复读数不追加历史 |
| Grok Bot 手动快照、剩余圆环、过期变淡 | 有。只在点击时读取约定文件 |
| 凭据 | Windows 凭据管理器 + DPAPI |
| 用量分析 | 汇总已导入快照。没有 Tokscale，不扫描各 Agent 的本地日志 |
| Codex、Claude、Cursor、豆包、Kimi、WorkBuddy 等在线或辅助功能读取 | 不调用。这些读取依赖 macOS 登录态、辅助功能或本机应用。手动刷新只说明原因，不写百分比 |
| 菜单栏、Dock、深链 `gaociyuan://`、更新签名、已卸载 Mac 应用隐藏 | 没有对应的 Windows 行为 |
| 系统通知 | 只在页面里显示提醒，不弹 Windows 通知 |
| 连续失败计数 | 非凭证错误累计到 3 次后标为需处理 |

不使用未公开接口，也不伪造用量。
