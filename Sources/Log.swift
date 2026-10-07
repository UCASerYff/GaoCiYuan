import OSLog

// 脱敏日志约定：只记录连接器名与错误类别等静态文案，
// 绝不记录额度数值、凭据、Cookie、路径细节或页面内容。
enum Log {
    static let connectors = Logger(subsystem: "com.gaoseries.GaoCiYuan", category: "connectors")
    static let store = Logger(subsystem: "com.gaoseries.GaoCiYuan", category: "store")
}
