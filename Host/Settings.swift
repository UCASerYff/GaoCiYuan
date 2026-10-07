import AppKit
import SwiftUI
import Token
import UniformTypeIdentifiers

struct GeneralSettings:View {
    @AppStorage("gqns.language") private var language="system"
    @AppStorage("gqns.appearance") private var appearance="system"
    var body:some View {
        Form {
            Picker("语言",selection:$language) { Text("跟随系统").tag("system");Text("中文").tag("zh-Hans");Text("English").tag("en") }
            Picker("外观",selection:$appearance) { Text("跟随系统").tag("system");Text("浅色").tag("light");Text("深色").tag("dark") }
            LabeledContent("版本",value:"V"+(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "?"))
        }.formStyle(.grouped).onChange(of:appearance) { _,_ in AppAppearance.current.apply() }
    }
}
enum AppAppearance:String {
    case system,light,dark
    static var current:Self { Self(rawValue:UserDefaults.standard.string(forKey:"gqns.appearance") ?? "system") ?? .system }
    func apply() { guard let app=NSApp else { DispatchQueue.main.async {self.apply()};return };app.appearance=self == .system ? nil : NSAppearance(named:self == .dark ? .darkAqua : .aqua) }
}
enum AppDataLocations {
    static var appSupport:URL? { FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first?.appendingPathComponent("GaoSeries/Token",isDirectory:true) }
    static var groupContainer:URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:"5G96498KGJ.com.gaoseries.GaoCiYuan") }
}
struct DataSettings:View {
    @State private var busy=false
    @State private var status=""
    var body:some View {
        Form {
            Section("完整资料") {
                Text("包含业务历史、游戏进度、PDF、Word、图片及数据目录内的全部附件；密钥继续由系统钥匙串保管。")
                Button("导出完整资料…",action:export).disabled(busy)
                Button("从完整资料恢复…",action:restore).disabled(busy)
                if busy { ProgressView() }
                if !status.isEmpty { Text(status).textSelection(.enabled) }
            }
            Section("模块格式") {
                Button("导出模块备份…") { post("GaoSeries.token.export") }
                Button("恢复模块备份…") { post("GaoSeries.token.import") }
            }
            Section("数据目录") {
                Button("打开数据目录") { reveal(AppDataLocations.appSupport) }
                Button("打开小组件共享目录") { reveal(AppDataLocations.groupContainer) }
            }
        }.formStyle(.grouped)
    }
    private func reveal(_ url:URL?) { if let url { do {try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);NSWorkspace.shared.open(url)} catch {status=error.localizedDescription} } }
    private func export() {
        
        let panel=NSSavePanel();panel.allowedContentTypes=[.zip];panel.nameFieldStringValue="搞词元-完整资料.zip"
        guard panel.runModal() == .OK,let url=panel.url else {return}
        busy=true;status="正在备份并逐文件校验…"
        let support=AppDataLocations.appSupport,group=AppDataLocations.groupContainer
        Task { do {
            let result=try await Task.detached {try AppBackupExport.export(appSupport:support,group:group,destination:url)}.value
            busy=false;status="备份完成：\(result.fileCount) 个文件，全部 SHA-256 校验通过。"
        } catch {busy=false;status="备份失败：\(error.localizedDescription)"} }
    }
    private func restore() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.zip];panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url else {return}
        busy=true;status="正在校验完整资料…"
        Task { do {
            let (staged,manifest)=try await Task.detached {try AppBackupRestore.prepare(url)}.value
            busy=false
            let alert=NSAlert();alert.messageText="恢复这份完整资料？";alert.informativeText="已核验 \(manifest.files.count) 个文件。应用将在下次启动时恢复，当前数据会保留为安全副本。";alert.addButton(withTitle:"恢复并退出");alert.addButton(withTitle:"取消")
            if alert.runModal() == .alertFirstButtonReturn { try AppBackupRestore.schedule(staged);NSApp.terminate(nil) }
            else {try? FileManager.default.removeItem(at:staged);status="已取消"}
        } catch {busy=false;status="恢复未完成：\(error.localizedDescription)"} }
    }
}
