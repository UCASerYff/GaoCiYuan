import SwiftUI
import AppKit
import UserNotifications
import Token

@main struct StandaloneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var dataError: String?
    init() {
        if TokenStatusLineBridge.runIfRequested() {exit(0)}
        AppAppearance.current.apply()
        TokenStatusLineBridge.repairPathIfNeeded()
    }
    var body: some Scene {
        Window("搞词元 V\(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "?")",id:"main") {
            TokenModuleView()
                .frame(minWidth:880,minHeight:560)
                .modifier(WindowToolbarOpaqueBackground())
                .background(MainWindowReference(delegate: delegate))
                .modifier(AppSceneActions(delegate: delegate, isMainWindow: true))
                .task { TokenModuleRuntime.start() }
                .onReceive(NotificationCenter.default.publisher(for:Notification.Name("GaoSeries.dataError"))) { dataError=$0.userInfo?["message"] as? String }
                .alert("数据操作未完成",isPresented:Binding(get:{dataError != nil},set:{if !$0 {dataError=nil}})) { Button("知道了") {dataError=nil} } message:{Text(dataError ?? "")}
                .onOpenURL { url in
                    guard url.scheme == "gaociyuan" else { return }
                    delegate.requestMainWindow(route: TokenModuleRuntime.page(for: url).map { ["page": $0] })
                }
        }
        .defaultSize(width:1120,height:720)
        .handlesExternalEvents(matching:["*"])
        Settings {
            TabView {
                TokenSettingsView().tabItem { Label("模块设置",systemImage:"slider.horizontal.3") }
                GeneralSettings().tabItem { Label("外观",systemImage:"paintpalette") }
                DataSettings().tabItem { Label("数据",systemImage:"externaldrive") }
            }.frame(width:820,height:740)
        }
        MenuBarExtra {
            Button("打开搞词元") { delegate.requestMainWindow() }
            Divider()
            Button("退出搞词元") { NSApp.terminate(nil) }
        } label: {
            TokenModuleMenuLabel().modifier(AppSceneActions(delegate: delegate, isMainWindow: false))
        }
    }
}

@MainActor private struct AppSceneActions: ViewModifier {
    let delegate: AppDelegate
    let isMainWindow: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var sceneID = UUID()

    func body(content: Content) -> some View {
        content.onAppear {
            let showWindow = openWindow
            let showSettings = openSettings
            delegate.registerSceneActions(persistent: !isMainWindow,
                                          openMain: { showWindow(id: "main") }, openSettings: { showSettings() })
            if isMainWindow { delegate.mainViewAppeared(sceneID) }
        }.onDisappear {
            if isMainWindow { delegate.mainViewDisappeared(sceneID) }
        }
    }
}

@MainActor private struct MainWindowReference: NSViewRepresentable {
    let delegate: AppDelegate

    func makeNSView(context: Context) -> WindowReferenceView {
        let view = WindowReferenceView()
        view.appDelegate = delegate
        return view
    }

    func updateNSView(_ view: WindowReferenceView, context: Context) {}

    final class WindowReferenceView: NSView {
        weak var appDelegate: AppDelegate?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { appDelegate?.rememberMainWindow(window) }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var observers: [NSObjectProtocol] = []
    private var openMain: (() -> Void)?
    private var openSettings: (() -> Void)?
    private var hasPersistentSceneActions = false
    private weak var mainWindow: NSWindow?
    private var wantsMain = false
    private var wantsSettings = false
    private var pendingRoute: [String: String]?
    private var visibleMain: UUID?
    private var routeDeliveryScheduled = false
    private var terminationPending = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let window = event.object as? NSWindow, window === self.mainWindow else { return }
                self.visibleMain = nil
            }
        })
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let window = event.object as? NSWindow, window === self.mainWindow else { return }
                self.deliverRoute()
            }
        })
        observers.append(center.addObserver(forName: Notification.Name("gaociyuan.openMainWindow"), object: nil, queue: .main) { [weak self] event in
            let route = Self.presentationRoute(from: event.userInfo)
            MainActor.assumeIsolated { self?.requestMainWindow(route: route) }
        })
        observers.append(center.addObserver(forName: Notification.Name("GaoSeries.app.openSettings"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.wantsSettings = true
                self.openRequestedScenes()
            }
        })
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        requestMainWindow()
        return false
    }

    func registerSceneActions(persistent: Bool, openMain: @escaping () -> Void, openSettings: @escaping () -> Void) {
        if persistent || !hasPersistentSceneActions {
            self.openMain = openMain
            self.openSettings = openSettings
            hasPersistentSceneActions = persistent
        }
        openRequestedScenes()
    }

    func rememberMainWindow(_ window: NSWindow) {
        mainWindow = window
    }

    func mainViewAppeared(_ id: UUID) {
        visibleMain = id
        deliverRoute()
    }

    func mainViewDisappeared(_ id: UUID) {
        if visibleMain == id { visibleMain = nil }
    }

    func requestMainWindow(route: [String: String]? = nil) {
        if let route, !route.isEmpty { pendingRoute = route }
        wantsMain = true
        openRequestedScenes()
        deliverRoute()
    }

    private func openRequestedScenes() {
        if wantsMain, let mainWindow, mainWindow.isVisible || mainWindow.isMiniaturized {
            wantsMain = false
            NSApp.activate()
            if mainWindow.isMiniaturized { mainWindow.deminiaturize(nil) }
            mainWindow.makeKeyAndOrderFront(nil)
        } else if wantsMain, let openMain {
            wantsMain = false
            openMain()
            NSApp.activate()
        }
        if wantsSettings, let openSettings {
            wantsSettings = false
            openSettings()
            NSApp.activate()
        }
    }

    private func deliverRoute() {
        guard canDeliverRoute, pendingRoute != nil, !routeDeliveryScheduled else { return }
        routeDeliveryScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.routeDeliveryScheduled = false
            guard self.canDeliverRoute, let route = self.pendingRoute else { return }
            self.pendingRoute = nil
            NotificationCenter.default.post(name: Notification.Name("gaociyuan.presentRequested"), object: nil, userInfo: route)
        }
    }

    private var canDeliverRoute: Bool { visibleMain != nil || mainWindow?.isKeyWindow == true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPending { return .terminateLater }
        let work = TokenLifecycleWork.shared
        guard work.hasUnsavedDraft || work.hasPendingWrites else { return .terminateNow }
        terminationPending = true
        DispatchQueue.main.async { [weak self] in self?.resolveQuit(sender, work: work) }
        return .terminateLater
    }

    private func resolveQuit(_ sender: NSApplication, work: TokenLifecycleWork) {
        if work.hasUnsavedDraft {
            let english = TokenModuleRuntime.usesEnglish
            let alert = NSAlert()
            alert.messageText = english ? "Quit with unsaved changes?" : "退出并丢弃未保存的修改？"
            alert.informativeText = english ? "Quitting discards changes you are still editing." : "退出将丢弃当前编辑中尚未保存的修改。"
            let cancel = alert.addButton(withTitle: english ? "Cancel" : "取消")
            cancel.keyEquivalent = "\u{1b}"
            alert.addButton(withTitle: english ? "Discard and Quit" : "丢弃并退出").hasDestructiveAction = true
            alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
            sender.activate()
            guard alert.runModal() == .alertSecondButtonReturn else {
                terminationPending = false
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
        }
        work.finishAfterWrites { sender.reply(toApplicationShouldTerminate: true) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        let route = Self.presentationRoute(from: response.notification.request.content.userInfo)
        DispatchQueue.main.async { [weak self] in
            self?.requestMainWindow(route: route)
            completionHandler()
        }
    }

    nonisolated private static func presentationRoute(from userInfo: [AnyHashable: Any]?) -> [String: String]? {
        guard let userInfo else { return nil }
        return userInfo.reduce(into: [:]) { route, entry in
            if let key = entry.key as? String, ["page", "account"].contains(key), let value = entry.value as? String {
                route[key] = value
            }
        }
    }
}
private struct WindowToolbarOpaqueBackground:ViewModifier {
    func body(content:Content)->some View {
        if #available(macOS 15.0,*) { content.toolbarBackground(Color(nsColor:.windowBackgroundColor),for:.windowToolbar).toolbarBackgroundVisibility(.visible,for:.windowToolbar) }
        else { content.toolbarBackground(Color(nsColor:.windowBackgroundColor),for:.windowToolbar) }
    }
}
