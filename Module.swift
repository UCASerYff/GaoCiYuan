import SwiftUI
import Foundation
import UserNotifications

public final class TokenBundleMarker: NSObject {}
enum TokenBundle {
    static let bundle = Bundle(for: TokenBundleMarker.self)
    static let defaults = UserDefaults(suiteName: ProcessInfo.processInfo.environment["GAOQINIANSAN_INTEGRATION_TEST"] == "1" ? "com.gaoseries.GaoCiYuan.test.Token" : "com.gaoseries.GaoCiYuan.Token") ?? .standard
}

public enum TokenStatusLineBridge {
    public static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains(ClaudeStatusLine.modeArgument) else { return false }
        ClaudeStatusLine.runAsStatusLine()
        return true
    }

    public static func repairPathIfNeeded() {
        ClaudeStatusLine.repairPathIfNeeded()
    }
}

@MainActor private enum TokenRuntime {
    static let store = MonitorStore()
    static let activity = AgentActivityMonitor()
    static let analytics = UsageAnalyticsStore(directory: store.dataURL.deletingLastPathComponent())
    static var started = false
    static func start() {
        guard !started, ProcessInfo.processInfo.environment["GAOQINIANSAN_INTEGRATION_TEST"] != "1" else { return }
        started = true
        // 点击系统通知打开主窗口（代理全程仅这一个用途；授权只在用户打开通知开关时请求）。
        // The application owns the single notification delegate.
        activity.start()
        analytics.start()
        // 3.33：app 启动即开始 agent 自动发现（扫描 + 定期重扫在 configure 内启动）。
        MemberDiscovery.shared.configure(store)
        Task {
            _ = await store.exportWidgetSnapshot()
            await store.refreshAll()
        }
    }
}

public enum TokenModuleRuntime {
    @MainActor public static func start() { TokenRuntime.start() }
}

public struct TokenModuleView: View {
    @ObservedObject private var store = TokenRuntime.store
    @ObservedObject private var activity = TokenRuntime.activity
    // 订阅 app 级语言键：值变化时本视图重渲染，.id/locale 随之按解析结果更新。
    @AppStorage(GQNSLanguage.key) private var appLanguage = "system"
    private let route: URL?
    private let routeRevision: Int
    @State private var handledRevision = 0
    public init(route: URL? = nil, routeRevision: Int = 0) {
        self.route = route
        self.routeRevision = routeRevision
        // 旧版模块级语言偏好（Token 套件的 language 键）一次性迁移到 app 级 gqns.language。
        GQNSLanguage.migrateLegacy(defaults: TokenBundle.defaults, legacyKey: "language")
    }
    public var body: some View {
        ContentView()
            .id(GQNSLanguage.localeIdentifier)
            .environment(\.locale, Locale(identifier: GQNSLanguage.localeIdentifier))
            .environmentObject(store)
            .environmentObject(activity)
            .environmentObject(TokenRuntime.analytics)
            .modifier(WidgetSetup(store: store))
            .modifier(FloatingPanelSetup(store: store, activity: activity))
            .onAppear(perform: handleRoute)
            .onChange(of: routeRevision) { _, _ in handleRoute() }
            .onAppear { TokenRuntime.start() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.token.import"))) { _ in store.restoreBackup() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.token.export"))) { _ in store.exportBackup() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.token.csv"))) { _ in store.exportCSV() }
    }
    private func handleRoute() {
        guard routeRevision > handledRevision, let route else { return }
        handledRevision = routeRevision
        if route.scheme == "gaociyuan", route.host == "analytics" {
            NotificationCenter.default.post(name: Notification.Name("gaociyuan.presentRequested"), object: nil, userInfo: ["page": Page.analytics.rawValue])
        } else if route.isFileURL && route.pathExtension.lowercased() == "gaociyuan" {
            store.restoreBackup(from: route)
        }
    }
}

public struct TokenModuleMenuLabel: View {
    @ObservedObject private var store = TokenRuntime.store
    public init() {}
    public var body: some View {
        Image(nsImage: TokenMenuBarIcon.image(hasAlert: !store.alertAccounts.isEmpty))
    }
}

/// 搞词元设置页（app 级设置中心嵌入用）：内容与模块原「设置」侧栏页（SettingsPanel）一致，
/// store 由 framework 内 singleton 注入，外部嵌入无需提供环境对象。
public struct TokenSettingsView: View {
    @ObservedObject private var store = TokenRuntime.store
    @AppStorage(GQNSLanguage.key) private var appLanguage = "system"
    public init() {}
    public var body: some View {
        SettingsPanel()
            .environmentObject(store)
            .id(GQNSLanguage.localeIdentifier)
            .environment(\.locale, Locale(identifier: GQNSLanguage.localeIdentifier))
    }
}

