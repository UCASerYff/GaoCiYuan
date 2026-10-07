import Foundation
import AppKit
import CryptoKit

// 阶段 5A：自研轻量更新器（Sparkle 降级方案，理由见 CHANGELOG 与发布报告）。
// 流程：GET appcast.xml（https 或本地 file://，NoRedirect，ephemeral）→ 语义版本比较
// → 下载 zip → CryptoKit 验 Ed25519（公钥缺失或验签失败一律丢弃）→ 仅提示用户，绝不自动安装。
// 托管地址是用户自己的配置项（默认空 = 不检查）；本仓库不指向任何远程。

// MARK: - 数据模型与纯函数（Smoke 可测）

struct AppcastItem: Equatable {
    var version: String          // sparkle:shortVersionString 或 enclosure 的 sparkle:version
    var url: URL?                // enclosure 下载地址
    var signatureBase64: String? // sparkle:edSignature
}

// 语义版本点分比较：逐段按整数比，缺段补 0；非数字段按 0 处理。
// "2" 与 "2.0" 相等；"2.0.1" > "2.0"；前导 "v/V" 容忍。
func isNewerVersion(_ candidate: String, than current: String) -> Bool {
    func parts(_ v: String) -> [Int] {
        var s = v.trimmingCharacters(in: .whitespacesAndNewlines)
        if let f = s.first, f == "v" || f == "V" { s.removeFirst() }
        return s.split(separator: ".").map { Int($0) ?? 0 }
    }
    let a = parts(candidate), b = parts(current)
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}

// 宽松 URL 解析：先直接解析，失败再百分号编码重试（本地 appcast 里常见未编码的中文路径）。
func tolerantURL(_ raw: String) -> URL? {
    if let url = URL(string: raw) { return url }
    let encoded = raw.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: ":/?#[]@!$&'()*+,;=%").union(.alphanumerics))
    return encoded.flatMap { URL(string: $0) }
}

// 更新源地址校验：只允许 https（用户自托管）或 file（本地测试/内网分发）；其余一律拒绝。
// 本地路径可能含中文等非 ASCII 字符：先直接解析，失败再按 URL 规则百分号编码后重试。
func allowedAppcastURL(_ string: String) -> URL? {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: ":/?#[]@!$&'()*+,;=%").union(.alphanumerics))
    let candidates = [URL(string: trimmed), encoded.flatMap { URL(string: $0) }]
    for case let url? in candidates {
        guard let scheme = url.scheme?.lowercased() else { continue }
        if scheme == "file" { return url }
        if scheme == "https", url.host != nil { return url }
    }
    return nil
}

// Ed25519 验签（Sparkle 同款算法）：公钥/签名均为 base64；任何一步失败都返回 false，不抛错。
func verifyUpdateSignature(_ signatureBase64: String?, data: Data, publicKeyBase64: String) -> Bool {
    guard let signatureBase64,
          let sig = Data(base64Encoded: signatureBase64),
          let keyData = Data(base64Encoded: publicKeyBase64),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return false }
    return key.isValidSignature(sig, for: data)
}

// appcast.xml 解析：兼容 Sparkle 命名空间（sparkle:version / sparkle:shortVersionString /
// sparkle:edSignature / sparkle:releaseNotesLink），坏 XML 返回空数组而不是崩溃。
func parseAppcast(_ data: Data) -> [AppcastItem] {
    final class Delegate: NSObject, XMLParserDelegate {
        var items: [AppcastItem] = []
        var current: AppcastItem?
        var inItem = false, inTitle = false
        var text = ""
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes attrs: [String: String] = [:]) {
            let key = qName ?? name
            if key == "item" { inItem = true; current = AppcastItem(version: "", url: nil, signatureBase64: nil) }
            if inItem && key == "title" { inTitle = true; text = "" }
            if inItem && key == "enclosure", let raw = attrs["url"] {
                current?.url = tolerantURL(raw)
                if current?.version.isEmpty ?? true {
                    current?.version = attrs["sparkle:shortVersionString"] ?? attrs["shortVersionString"] ?? attrs["sparkle:version"] ?? attrs["version"] ?? ""
                }
                current?.signatureBase64 = attrs["sparkle:edSignature"] ?? attrs["edSignature"]
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if inTitle { text += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
            let key = qName ?? name
            if key == "title" {
                inTitle = false
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if current?.version.isEmpty ?? true { current?.version = t }
            }
            if key == "item", let item = current { inItem = false; items.append(item); current = nil }
        }
    }
    let delegate = Delegate()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse() else { return [] }
    return delegate.items.filter { !$0.version.isEmpty }
}

// CHANGELOG 版本节校验：节头形如 "## 2.0.0"、"## [2.0.0]"、"## V1.8.0 …"，整行匹配版本号。
func changelogHasVersion(_ changelog: String, version: String) -> Bool {
    let v = version.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !v.isEmpty else { return false }
    for line in changelog.split(separator: "\n") {
        var s = line.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("##") else { continue }
        s = s.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        if let f = s.first, f == "v" || f == "V" { s.removeFirst() }
        // 版本 token = 数字与点的最长前缀，兼容「## 2.0.0（日期）」「## [1.8.0] 日期」等节头；
        // 整 token 相等才算命中，防 "1.8" 误中 "1.80"、"2.0" 误中 "2.0.0"。
        let token = String(s.prefix(while: { $0.isNumber || $0 == "." }))
        if token == v { return true }
    }
    return false
}

// MARK: - 运行时检查器

@MainActor final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    @Published private(set) var checking = false
    @Published private(set) var lastError: String?   // 已消毒，可直接展示
    private var timer: Timer?
    private static let checkInterval: TimeInterval = 2 * 60 * 60 // 2 小时

    static var appcastURLString: String {
        get { TokenBundle.defaults.string(forKey: "updateAppcastURL") ?? "" }
        set { TokenBundle.defaults.set(newValue, forKey: "updateAppcastURL") }
    }
    static var publicKeyBase64: String {
        get { TokenBundle.defaults.string(forKey: "updateEdDSAPublicKey") ?? "" }
        set { TokenBundle.defaults.set(newValue, forKey: "updateEdDSAPublicKey") }
    }

    // 启动后 60 秒做首次检查，之后每 2 小时一次；未配置更新源则什么都不做。
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { await self?.checkNow(userInitiated: false) }
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            await self?.checkNow(userInitiated: false)
        }
    }

    func checkNow(userInitiated: Bool) async {
        guard !checking else { return }
        guard let url = allowedAppcastURL(Self.appcastURLString) else {
            if userInitiated && !Self.appcastURLString.isEmpty {
                lastError = L("更新源地址无效，仅支持 https 或本地文件。")
                alert(L("更新检查失败"), L("更新源地址无效，仅支持 https 或本地文件。"))
            }
            return // 未配置 = 静默不检查
        }
        checking = true; lastError = nil
        defer { checking = false }
        do {
            let items = try await fetchAppcast(url)
            guard let latest = items.max(by: { isNewerVersion($1.version, than: $0.version) }) else {
                throw UpdateError.noItems
            }
            guard isNewerVersion(latest.version, than: AppInfo.version) else {
                if userInitiated { alert(L("已是最新版本"), L("当前版本") + " \(AppInfo.version)") }
                return
            }
            guard let zip = try await downloadAndVerify(latest) else {
                // 验签失败/公钥缺失：下载已删除，只提示失败，绝不展示未验证的包
                Log.store.error("update package signature verification failed")
                lastError = L("更新包签名校验失败，已丢弃。")
                alert(L("更新检查失败"), L("更新包签名校验失败，已丢弃。"))
                return
            }
            prompt(item: latest, zipURL: zip)
        } catch {
            lastError = L("暂时无法检查更新，请稍后再试。")
            if userInitiated { alert(L("更新检查失败"), L("暂时无法检查更新，请稍后再试。")) }
        }
    }

    enum UpdateError: Error { case noItems, badResponse }

    // https 走 Connectors 同款策略（ephemeral + NoRedirect + 超时）；file:// 直接读盘。
    private func fetchAppcast(_ url: URL) async throws -> [AppcastItem] {
        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
            let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (d, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw UpdateError.badResponse }
            data = d
        }
        let items = parseAppcast(data)
        if items.isEmpty { throw UpdateError.noItems }
        return items
    }

    // 下载 zip 并验 Ed25519；公钥未配置或验签失败返回 nil（文件已清理）。成功返回本地路径。
    private func downloadAndVerify(_ item: AppcastItem) async throws -> URL? {
        guard let remote = item.url else { return nil }
        let data: Data
        if remote.isFileURL {
            data = try Data(contentsOf: remote)
        } else {
            guard remote.scheme?.lowercased() == "https" else { return nil }
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 300
            let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (d, response) = try await session.data(from: remote)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw UpdateError.badResponse }
            data = d
        }
        guard verifyUpdateSignature(item.signatureBase64, data: data, publicKeyBase64: Self.publicKeyBase64) else { return nil }
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("GaoCiYuanUpdates", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent("搞词元-\(item.version).zip")
        try data.write(to: dest, options: .atomic)
        return dest
    }

    // 只提示不自动装：用户自己选择在 Finder 中打开 zip 手动替换。
    private func prompt(item: AppcastItem, zipURL: URL) {
        let a = NSAlert()
        a.messageText = L("发现新版本") + " \(item.version)"
        a.informativeText = L("当前版本") + " \(AppInfo.version)\n" + L("更新包已下载并通过签名校验；请在 Finder 中解压后手动替换应用。")
        a.addButton(withTitle: L("在 Finder 中显示"))
        a.addButton(withTitle: L("稍后"))
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([zipURL])
        }
    }

    private func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
