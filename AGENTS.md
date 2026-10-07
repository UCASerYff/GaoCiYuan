# 搞词元 后续发布规则

此项目是 V4.0 独立应用。每次后续改动版本号增加 0.01、构建号增加 1，版本以 Info.plist 为准。

- 使用 scripts/build.sh 构建本模块及应用，并以已授权 Apple Development 团队 5G96498KGJ 签名。桌面小组件已移除，不得重新引入 WidgetKit 扩展；悬浮窗须保留。
- 用户数据位于 ~/Library/Application Support/GaoSeries/Token/ 与 App Group 5G96498KGJ.com.gaoseries.GaoCiYuan；凭据保留原系统钥匙串服务。
- 发布前安全备份并核验所有数据、PDF、Word、照片等附件。不得将缺失或无法读取的数据当作空白数据覆盖。
- 安装新版本前注销旧的 com.gaoseries.GaoCiYuan.widgets 扩展；安装失败时恢复旧程序及扩展注册。验证业务记录、累计用量、附件及悬浮窗后，清理旧程序和中间构建。不能删除用户数据或其备份；保留 App Group 权限与数据以兼容原有备份。V4.01 已移除空间站，不得重新引入游戏依赖。
- 如需修改其他独立应用，单独更新其源码、版本及安装包，不引用已删除的整合版工程。
