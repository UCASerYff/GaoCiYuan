# 搞词元 后续发布规则

此项目是 V4.0 独立应用。每次后续改动版本号增加 0.01、构建号增加 1，版本以 Info.plist 为准。

- 约定工作流程：
  1. 改动前：优先读取并核验当前软件运行状态、Git 工作区状态与 Info.plist 当前版本号。
  2. 修改后：版本号在 Info.plist 中递增 0.01、构建号增加 1，并同步更新相关文档（如 README.md）。
  3. 产物规范：安装包（dist/ 目录下的 ZIP 与 SHA256）及所有附属源码完整保留在当前项目文件夹下。
  4. 卸载与清理：更新版本时卸载/替换旧版程序，安装校验通过后彻底清理旧程序、历史回滚备份、中间生成文件及构建缓存（如 build.noindex、.release.noindex、.install.noindex、rollback/ 等），绝不删除或损坏用户数据。
  5. 代码与发布推送：全部工作完成后，提交并推送（git push）至对应 GitHub 仓库。
- 使用 scripts/build.sh 构建本模块及应用，并以已授权 Apple Development 团队 5G96498KGJ 签名。桌面小组件已移除，不得重新引入 WidgetKit 扩展；悬浮窗须保留。
- 用户数据位于 ~/Library/Application Support/GaoSeries/Token/ 与 App Group 5G96498KGJ.com.gaoseries.GaoCiYuan；凭据保留原系统钥匙串服务。
- 发布前安全备份并核验所有数据、PDF、Word、照片等附件。不得将缺失或无法读取的数据当作空白数据覆盖。
- 安装新版本前注销旧的 com.gaoseries.GaoCiYuan.widgets 扩展；安装失败时恢复旧程序及扩展注册。验证业务记录、累计用量、附件及悬浮窗后，清理旧程序和中间构建。不能删除用户数据或其备份；保留 App Group 权限与数据以兼容原有备份。V4.01 已移除空间站，不得重新引入游戏依赖。
- 如需修改其他独立应用，单独更新其源码、版本及安装包，不引用已删除的整合版工程。
