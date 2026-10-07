import SwiftUI
import AppKit
import UserNotifications
import Token

@main struct StandaloneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var route: URL?
    @State private var revision = 0
    @State private var dataError: String?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    init() {
        if TokenStatusLineBridge.runIfRequested() {exit(0)}
        do { try AppBackupRestore.applyPending() } catch {
            let alert=NSAlert();alert.messageText="数据恢复未完成";alert.informativeText=error.localizedDescription+"\n当前数据和恢复前副本已保留。";alert.runModal();exit(1)
        }
        AppAppearance.current.apply()
        TokenStatusLineBridge.repairPathIfNeeded()
    }
    static func activate() {
        NSApp.activate(ignoringOtherApps:true)
        if let w=NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) ?? NSApp.windows.first(where:{$0.styleMask.contains(.titled) && !($0 is NSPanel)}) {
            if w.isMiniaturized { w.deminiaturize(nil) };w.makeKeyAndOrderFront(nil)
        }
    }
    var body: some Scene {
        Window("搞词元 V\(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "?")",id:"main") {
            TokenModuleView(route:route,routeRevision:revision)
                .frame(minWidth:1040,minHeight:720)
                .modifier(WindowToolbarOpaqueBackground())
                .task { TokenModuleRuntime.start() }
                .onReceive(NotificationCenter.default.publisher(for:Notification.Name("GaoSeries.dataError"))) { dataError=$0.userInfo?["message"] as? String }
                .alert("数据操作未完成",isPresented:Binding(get:{dataError != nil},set:{if !$0 {dataError=nil}})) { Button("知道了") {dataError=nil} } message:{Text(dataError ?? "")}
                .onReceive(NotificationCenter.default.publisher(for:Notification.Name("GaoSeries.app.openSettings"))) { _ in openSettings() }
                .onReceive(NotificationCenter.default.publisher(for:Notification.Name("appOpenSettings"))) { _ in openSettings() }
                .onReceive(NotificationCenter.default.publisher(for:Notification.Name("Standalone.showWindow"))) { _ in openWindow(id:"main");Self.activate() }
                .onReceive(NotificationCenter.default.publisher(for:Notification.Name("gaociyuan.openMainWindow"))) { note in NotificationCenter.default.post(name:Notification.Name("gaociyuan.presentRequested"),object:nil,userInfo:note.userInfo);openWindow(id:"main");Self.activate() }
                .onOpenURL { url in
                    route=url;revision &+= 1;openWindow(id:"main");Self.activate()
                    
                }
        }
        .defaultSize(width:1380,height:860)
        .handlesExternalEvents(matching:["*"])
        .commands {
            CommandGroup(after:.newItem) {  }
            CommandMenu("数据") {
                Button("导出模块备份…") { post("GaoSeries.token.export") }
                Button("恢复模块备份…") { post("GaoSeries.token.import") }
                Divider()
                Button("完整资料备份与恢复…") { openSettings() }
            }
        }
        Settings {
            TabView {
                TokenSettingsView().tabItem { Label("模块设置",systemImage:"slider.horizontal.3") }
                GeneralSettings().tabItem { Label("外观",systemImage:"paintpalette") }
                DataSettings().tabItem { Label("数据",systemImage:"externaldrive") }
            }.frame(width:820,height:740)
        }
        MenuBarExtra { Button("打开搞词元") {openWindow(id:"main");Self.activate()};Divider();Button("退出搞词元") {NSApp.terminate(nil)} } label:{TokenModuleMenuLabel()}
    }
}
func post(_ name:String) { NotificationCenter.default.post(name:Notification.Name(name),object:nil) }
final class AppDelegate:NSObject,NSApplicationDelegate,UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification:Notification) { UNUserNotificationCenter.current().delegate=self }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        
        return .terminateNow
    }
    func userNotificationCenter(_ center:UNUserNotificationCenter,willPresent notification:UNNotification,withCompletionHandler completionHandler:@escaping(UNNotificationPresentationOptions)->Void) { completionHandler([.banner,.list,.sound]) }
    func userNotificationCenter(_ center:UNUserNotificationCenter,didReceive response:UNNotificationResponse,withCompletionHandler completionHandler:@escaping()->Void) {
        DispatchQueue.main.async { NotificationCenter.default.post(name:Notification.Name("gaociyuan.presentRequested"),object:nil,userInfo:response.notification.request.content.userInfo);post("Standalone.showWindow");completionHandler() }
    }
}
private struct WindowToolbarOpaqueBackground:ViewModifier {
    func body(content:Content)->some View {
        if #available(macOS 15.0,*) { content.toolbarBackground(Color(nsColor:.windowBackgroundColor),for:.windowToolbar).toolbarBackgroundVisibility(.visible,for:.windowToolbar) }
        else { content.toolbarBackground(Color(nsColor:.windowBackgroundColor),for:.windowToolbar) }
    }
}
