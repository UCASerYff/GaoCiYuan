# 搞词元后续发布规则

此项目是独立 macOS 应用。每次后续改动版本号增加 0.01、构建号增加 1，版本以 `Info.plist` 为准。当前为 V4.13 / build 14。

- 改动前读取并核验当前软件运行状态、Git 工作区与版本；修改后同步 README 和相关验证。
- 使用 `scripts/build.sh` 构建，以已授权 Apple Development 身份 `A15B2B2D22B018CBC842063C9A8A589946647524`、团队 `5G96498KGJ` 签名。桌面小组件已移除，不得重新引入 WidgetKit 扩展；悬浮窗须保留。
- 新 `.app` 从生成起只能位于 `.noindex` 容器。正式可启动、可搜索入口仅为 `/Applications/搞词元.app`，Bundle ID 为 `com.gaoseries.GaoCiYuan`。
- 遵循工作区 2026-11-10 无备份规则：更新、安装、迁移和清理不创建或保留任何自动备份、手动导出备份、升级快照、恢复副本或旧程序回滚包；不运行 snapshot、预更新备份或回滚命令。应用不得重新加入完整资料备份、每日自动备份或 Claude 配置滚动备份。
- 安装脚本只做前置身份、签名、团队、指定要求、版本和进程核验，再在 `.install.noindex` 暂存并替换。前置失败不得触碰旧程序；替换后失败必须停止并如实报告，不自动恢复、不新造备份。
- `dist/` 只保留最新版发行 ZIP 和对应 SHA-256；验证完成后清理旧安装包、旧程序、临时副本、工作树和中间构建产物，保留最新版发行包、源码与测试。
- 用户现用数据位于 `~/Library/Application Support/GaoSeries/Token/` 与 App Group `5G96498KGJ.com.gaoseries.GaoCiYuan`，设置在原 UserDefaults 域，凭据保留原钥匙串服务。无备份规则不授权删除现用 Agent 账户、用量分析数据库、设置、附件、游戏进度或钥匙串凭据；缺失或不可读的数据不能当成空白覆盖。
- V4.13 起只管理 Agent 软件，不新增大模型 API 或自定义 API 账户；启动时永久删除旧 LLM／custom API 账户及专属凭据，保留真实 Agent 数据。用量分析继续保留。
- 安装前仅精确注销旧 `com.gaoseries.GaoCiYuan.widgets` 扩展，不全局重置系统登记。安装后验证业务记录、用量分析、附件、悬浮窗、真实 Spotlight 结果与 LaunchServices 唯一入口。
- GitHub 只推送源码、文档、测试及最新版 Release 安装包和摘要；不上传用户数据、私有验证资料、凭据或任何备份。只更新本应用，不改动其他独立应用。
