import Foundation
import AppKit
import CryptoKit

// 阶段 5A：自研轻量更新器（Sparkle 降级方案，理由见 CHANGELOG 与发布报告）。
// 流程：GET appcast.xml（https 或本地 file://，NoRedirect，ephemeral）→ 语义版本比较
// → 显示元数据；用户明确选择下载后才获取 zip → 验 Ed25519 → 仅提示，绝不自动安装。
// 托管地址是用户自己的配置项（默认空 = 不检查）；本仓库不指向任何远程。

// MARK: - 数据模型与纯函数（Smoke 可测）

struct AppcastItem: Equatable, Sendable {
    var version: String          // sparkle:shortVersionString 或 enclosure 的 sparkle:version
    var url: URL?                // enclosure 下载地址
    var signatureBase64: String? // sparkle:edSignature
    var expectedLength: Int64? = nil
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
        if scheme == "https", url.host != nil, url.user == nil, url.password == nil { return url }
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
    guard data.range(of: Data("<!DOCTYPE".utf8)) == nil,
          data.range(of: Data("<!ENTITY".utf8)) == nil else { return [] }
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
                if let length = attrs["length"] { current?.expectedLength = Int64(length) ?? -1 }
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
    parser.shouldResolveExternalEntities = false
    parser.delegate = delegate
    guard parser.parse() else { return [] }
    return delegate.items.filter { !$0.version.isEmpty && $0.version.utf8.count <= 100 }
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

// MARK: - Bounded, independently testable metadata/package operations

actor UpdateService {
    struct Limits: Sendable {
        var metadataBytes = 256 * 1024
        var packageBytes = 128 * 1024 * 1024
        var metadataSeconds: TimeInterval = 30
        var packageSeconds: TimeInterval = 300
        var metadataLifetime: TimeInterval = 5 * 60
        var failureCooldown: TimeInterval = 15 * 60
    }
    enum Resource: Sendable { case metadata, package }
    typealias Progress = @Sendable (Int64, Int64?) -> Void
    typealias Fetcher = @Sendable (URLRequest, Int, TimeInterval, Resource, Progress?) async throws -> (Data, HTTPURLResponse)
    enum Failure: LocalizedError {
        case noItems, badResponse, invalidURL, oversized, missingSignature, signature, deferred
        var errorDescription: String? {
            switch self {
            case .noItems: return "更新源没有可核验的版本信息。"
            case .badResponse: return "更新服务暂时无法完成请求。"
            case .invalidURL: return "更新地址无效，仅支持 HTTPS 或本地普通文件。"
            case .oversized: return "更新响应超过大小或时间预算，下载已停止。"
            case .missingSignature: return "请先配置有效的 Ed25519 公钥；更新源也必须提供有效签名，未开始下载。"
            case .signature: return "更新包签名或声明大小不符，已丢弃。"
            case .deferred: return "此更新请求刚刚失败，已暂停重复下载，请稍后再试。"
            }
        }
    }
    private struct Metadata { var items: [AppcastItem]; var expiresAt: Date }
    private struct Flight<Value: Sendable> { var id: UUID; var task: Task<Value, Error> }
    private let limits: Limits
    private let cacheDirectory: URL
    private let fetcher: Fetcher
    private let clock: @Sendable () -> Date
    private var metadata: [String: Metadata] = [:]
    private var metadataFlights: [String: Flight<[AppcastItem]>] = [:]
    private var packageFlights: [String: Flight<URL>] = [:]
    private var failedUntil: [String: Date] = [:]

    init(cacheDirectory: URL? = nil, limits: Limits = Limits(), fetcher: Fetcher? = nil,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GaoSeries/TokenUpdates", isDirectory: true)
        self.limits = limits
        self.fetcher = fetcher ?? { request, limit, timeout, resource, progress in
            try await Self.download(request, limit: limit, timeout: timeout, resource: resource, progress: progress)
        }
        self.clock = clock
    }

    /// Checking metadata never fetches an enclosure, even when a newer version is found.
    func checkMetadata(_ source: URL) async throws -> [AppcastItem] {
        try Task.checkCancellation()
        let key = "metadata:" + Self.digest(source.absoluteString)
        if let cached = metadata[key], cached.expiresAt > clock() { return cached.items }
        try checkBackoff(key)
        let flight: Flight<[AppcastItem]>
        if let current = metadataFlights[key] { flight = current }
        else {
            flight = Flight(id: UUID(), task: Task { try await self.readMetadata(source) })
            metadataFlights[key] = flight
        }
        do {
            let items = try await withTaskCancellationHandler(operation: { try await flight.task.value }, onCancel: { flight.task.cancel() })
            try Task.checkCancellation()
            guard !flight.task.isCancelled else { throw CancellationError() }
            if metadataFlights[key]?.id == flight.id {
                metadataFlights.removeValue(forKey: key)
                metadata[key] = Metadata(items: items, expiresAt: clock().addingTimeInterval(max(0, limits.metadataLifetime)))
                failedUntil.removeValue(forKey: key)
                if metadata.count > 4, let oldest = metadata.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key { metadata.removeValue(forKey: oldest) }
            }
            return items
        } catch {
            if metadataFlights[key]?.id == flight.id {
                metadataFlights.removeValue(forKey: key)
                if !(error is CancellationError) { failedUntil[key] = clock().addingTimeInterval(max(0, limits.failureCooldown)) }
            }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    /// This separate operation is called only after the user chooses to download.
    /// Identity includes the key/signature/URL as well as the version, so neither
    /// a changed source nor a replaced package can reuse an unrelated cached ZIP.
    func downloadExplicitly(_ item: AppcastItem, publicKey: String, progress: Progress? = nil) async throws -> URL {
        try Task.checkCancellation()
        guard let keyBytes = Data(base64Encoded: publicKey), keyBytes.count == 32,
              (try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)) != nil,
              let signature = item.signatureBase64.flatMap({ Data(base64Encoded: $0) }), signature.count == 64 else { throw Failure.missingSignature }
        guard let remote = item.url, allowedAppcastURL(remote.absoluteString) != nil else { throw Failure.invalidURL }
        let key = "package:" + Self.digest(item.version + "\n" + remote.absoluteString + "\n" + (item.signatureBase64 ?? "") + "\n" + publicKey + "\n" + (item.expectedLength.map(String.init) ?? "unknown"))
        let destination = cacheDirectory.appendingPathComponent(Self.digest(key) + ".zip")
        if let data = try? Self.readFile(destination, limit: limits.packageBytes),
           verifyUpdateSignature(item.signatureBase64, data: data, publicKeyBase64: publicKey),
           item.expectedLength.map({ $0 == Int64(data.count) }) ?? true {
            try Task.checkCancellation()
            progress?(Int64(data.count), Int64(data.count))
            return destination
        }
        // A previously cached file must pass the same verification as a new
        // download. Remove a corrupt/incomplete cache rather than retaining an
        // unverified ZIP under a filename that looks like a valid package.
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try Task.checkCancellation()
        try checkBackoff(key)
        let flight: Flight<URL>
        if let current = packageFlights[key] { flight = current }
        else {
            flight = Flight(id: UUID(), task: Task { try await self.readPackage(item, publicKey: publicKey, destination: destination, progress: progress) })
            packageFlights[key] = flight
        }
        do {
            let file = try await withTaskCancellationHandler(operation: { try await flight.task.value }, onCancel: { flight.task.cancel() })
            try Task.checkCancellation()
            guard !flight.task.isCancelled else { throw CancellationError() }
            if packageFlights[key]?.id == flight.id { packageFlights.removeValue(forKey: key); failedUntil.removeValue(forKey: key) }
            return file
        } catch {
            if packageFlights[key]?.id == flight.id {
                packageFlights.removeValue(forKey: key)
                if !(error is CancellationError) { failedUntil[key] = clock().addingTimeInterval(max(0, limits.failureCooldown)) }
            }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    func cancel() {
        for flight in metadataFlights.values { flight.task.cancel() }
        for flight in packageFlights.values { flight.task.cancel() }
        metadataFlights.removeAll(); packageFlights.removeAll()
    }
    private func checkBackoff(_ key: String) throws {
        if let until = failedUntil[key], until > clock() { throw Failure.deferred }
    }
    private func readMetadata(_ source: URL) async throws -> [AppcastItem] {
        let data = try await read(source, limit: limits.metadataBytes, timeout: limits.metadataSeconds, resource: .metadata, progress: nil)
        let items = parseAppcast(data)
        guard !items.isEmpty else { throw Failure.noItems }
        return items
    }
    private func readPackage(_ item: AppcastItem, publicKey: String, destination: URL, progress: Progress?) async throws -> URL {
        guard let remote = item.url else { throw Failure.invalidURL }
        if let length = item.expectedLength { guard length >= 0, length <= limits.packageBytes else { throw Failure.oversized } }
        let limit = item.expectedLength.map { min(limits.packageBytes, max(1, Int($0))) } ?? limits.packageBytes
        let data = try await read(remote, limit: limit, timeout: limits.packageSeconds, resource: .package, progress: progress)
        try Task.checkCancellation()
        guard item.expectedLength.map({ $0 == Int64(data.count) }) ?? true,
              verifyUpdateSignature(item.signatureBase64, data: data, publicKeyBase64: publicKey) else { throw Failure.signature }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        // Keep only a few verified, regenerable packages; user data/backups live elsewhere.
        if let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let owned = files.filter { $0.pathExtension == "zip" && $0.deletingPathExtension().lastPathComponent.count == 64 && $0 != destination }
                .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            for old in owned.dropFirst(2) { try? FileManager.default.removeItem(at: old) }
        }
        return destination
    }
    private func read(_ url: URL, limit: Int, timeout: TimeInterval, resource: Resource, progress: Progress?) async throws -> Data {
        try Task.checkCancellation()
        guard limit > 0, limit <= 128 * 1024 * 1024, timeout.isFinite, timeout > 0,
              allowedAppcastURL(url.absoluteString) != nil else { throw Failure.invalidURL }
        let data: Data
        if url.isFileURL { data = try Self.readFile(url, limit: limit); progress?(Int64(data.count), Int64(data.count)) }
        else {
            var request = URLRequest(url: url); request.timeoutInterval = timeout
            let (body, response) = try await fetcher(request, limit, timeout, resource, progress)
            try Task.checkCancellation()
            guard response.statusCode == 200, response.url == url else { throw Failure.badResponse }
            data = body
        }
        guard data.count <= limit else { throw Failure.oversized }
        try Task.checkCancellation()
        return data
    }
    private static func readFile(_ file: URL, limit: Int) throws -> Data {
        let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize, size <= limit else { throw Failure.oversized }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw Failure.oversized }
        return data
    }
    private static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private static func download(_ request: URLRequest, limit: Int, timeout: TimeInterval, resource: Resource, progress: Progress?) async throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.urlCache = nil
        config.httpShouldSetCookies = false; config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await BoundedHTTP.data(for: request, session: session, maxBytes: limit,
            timeout: timeout, category: resource == .metadata ? .updateMetadata : .updatePackage, progress: progress)
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        return (data, http)
    }
}

// MARK: - Runtime UI: metadata checks and explicit downloads are separate

@MainActor final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    @Published private(set) var checking = false
    @Published private(set) var downloading = false
    @Published private(set) var availableVersion: String?
    @Published private(set) var downloadReceivedBytes: Int64 = 0
    @Published private(set) var downloadExpectedBytes: Int64?
    @Published private(set) var lastError: String?
    private let service: UpdateService
    private var timer: Timer?
    private var initialCheck: Task<Void, Never>?
    private var checkTask: Task<[AppcastItem], Error>?
    private var downloadTask: Task<URL, Error>?
    private var downloadID: UUID?
    private var availableItem: AppcastItem?
    private var availableSource: String?
    private static let checkInterval: TimeInterval = 2 * 60 * 60

    init(service: UpdateService = UpdateService()) { self.service = service }
    static var appcastURLString: String {
        get { TokenBundle.defaults.string(forKey: "updateAppcastURL") ?? "" }
        set { TokenBundle.defaults.set(newValue, forKey: "updateAppcastURL") }
    }
    static var publicKeyBase64: String {
        get { TokenBundle.defaults.string(forKey: "updateEdDSAPublicKey") ?? "" }
        set { TokenBundle.defaults.set(newValue, forKey: "updateEdDSAPublicKey") }
    }
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { await self?.checkNow(userInitiated: false) }
        }
        initialCheck = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.checkNow(userInitiated: false)
        }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        initialCheck?.cancel(); initialCheck = nil
        checkTask?.cancel(); downloadTask?.cancel()
    }
    func cancelDownload() { downloadTask?.cancel() }
    func configurationChanged() {
        checkTask?.cancel(); downloadTask?.cancel()
        availableItem = nil; availableVersion = nil; availableSource = nil; lastError = nil
    }

    func checkNow(userInitiated: Bool) async {
        guard !checking else { return }
        let source = Self.appcastURLString
        guard let url = allowedAppcastURL(source) else {
            if userInitiated && !source.isEmpty { lastError = L("更新源地址无效，仅支持 https 或本地文件。") }
            return
        }
        checking = true; lastError = nil
        let service = self.service
        let task = Task {
            try await HTTPPolicyContext.$userInitiated.withValue(userInitiated) {
                try await HTTPPolicyContext.$trigger.withValue("update.check") {
                    try await HTTPPolicyContext.$operationIdentity.withValue(UUID().uuidString) { try await service.checkMetadata(url) }
                }
            }
        }
        checkTask = task
        defer { checking = false; checkTask = nil }
        do {
            let items = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation()
            guard source == Self.appcastURLString, !task.isCancelled else { return }
            guard let latest = items.max(by: { isNewerVersion($1.version, than: $0.version) }) else { throw UpdateService.Failure.noItems }
            guard isNewerVersion(latest.version, than: AppInfo.version) else {
                availableItem = nil; availableVersion = nil; availableSource = nil
                if userInitiated { alert(L("已是最新版本"), L("当前版本") + " \(AppInfo.version)") }
                return
            }
            availableItem = latest; availableVersion = latest.version; availableSource = source
            // A scheduled check only records availability. It never downloads or opens a modal.
            if userInitiated && confirmDownload(latest) { await downloadAvailableUpdate() }
        } catch is CancellationError { }
        catch {
            lastError = (error as? UpdateService.Failure)?.errorDescription ?? L("暂时无法检查更新，请稍后再试。")
            if userInitiated { alert(L("更新检查失败"), lastError ?? "") }
        }
    }
    func downloadAvailableUpdate() async {
        guard !downloading, let item = availableItem, availableSource == Self.appcastURLString else { return }
        let key = Self.publicKeyBase64, source = Self.appcastURLString, id = UUID()
        downloading = true; downloadID = id; downloadReceivedBytes = 0; downloadExpectedBytes = item.expectedLength; lastError = nil
        let progress: UpdateService.Progress = { [weak self] received, expected in
            Task { @MainActor in
                guard self?.downloadID == id else { return }
                self?.downloadReceivedBytes = received; self?.downloadExpectedBytes = expected
            }
        }
        let service = self.service
        let task = Task {
            try await HTTPPolicyContext.$userInitiated.withValue(true) {
                try await HTTPPolicyContext.$trigger.withValue("update.download") {
                    try await HTTPPolicyContext.$operationIdentity.withValue(UUID().uuidString) {
                        try await service.downloadExplicitly(item, publicKey: key, progress: progress)
                    }
                }
            }
        }
        downloadTask = task
        defer { downloading = false; downloadTask = nil; downloadID = nil }
        do {
            let zip = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation()
            guard !task.isCancelled, key == Self.publicKeyBase64, source == Self.appcastURLString else { return }
            prompt(item: item, zipURL: zip)
        } catch is CancellationError { }
        catch {
            lastError = (error as? UpdateService.Failure)?.errorDescription ?? L("更新包下载未完成，已有数据保持不变。")
            alert(L("更新下载未完成"), lastError ?? "")
        }
    }
    private func confirmDownload(_ item: AppcastItem) -> Bool {
        let a = NSAlert(); a.messageText = L("发现新版本") + " \(item.version)"
        a.informativeText = L("检查仅获取版本信息。选择下载后才获取更新包（最多 128 MB），验证签名后由你手动安装。")
        a.addButton(withTitle: L("下载并验证")); a.addButton(withTitle: L("稍后"))
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }
    private func prompt(item: AppcastItem, zipURL: URL) {
        let a = NSAlert(); a.messageText = L("发现新版本") + " \(item.version)"
        a.informativeText = L("当前版本") + " \(AppInfo.version)\n" + L("更新包已下载并通过签名校验；请在 Finder 中解压后手动替换应用。")
        a.addButton(withTitle: L("在 Finder 中显示")); a.addButton(withTitle: L("稍后"))
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([zipURL]) }
    }
    private func alert(_ title: String, _ message: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = message
        NSApp.activate(ignoringOtherApps: true); a.runModal()
    }
}
