import Foundation

/// P0-1 修复：「导出全部数据」核心流程（与界面解耦，可命令行验收）。
/// 旧实现把两个目录直接传给 `ditto -c -k`（不支持多源，报错 Can't archive multiple sources），
/// 且打包前先删目标 zip——打包失败等于把旧备份也弄丢了。
/// 新流程：两个数据目录先复制进同一临时根 → 对临时根单源打包到临时 zip →
/// 解压临时 zip 逐项核对（文件数 + 逐文件大小）→ 全部通过后才替换目标文件。
enum AppBackupExport {
    struct Summary {
        let fileCount: Int
        let totalBytes: Int64
        let zipBytes: Int64
    }

    enum ExportError: LocalizedError {
        case noSources
        case copyFailed(String)
        case dittoFailed(String)
        case verifyFailed(String)
        case replaceFailed(String)
        var errorDescription: String? {
            switch self {
            case .noSources: return "没有可导出的数据目录"
            case .copyFailed(let d): return "暂存复制失败：\(d)"
            case .dittoFailed(let d): return d
            case .verifyFailed(let d): return "备份校验失败：\(d)"
            case .replaceFailed(let d): return "写入目标失败：\(d)"
            }
        }
    }

    /// 后台队列调用。appSupport / group 任一存在即可；destination 已存在时先保留旧文件，
    /// 新 zip 验证通过后才替换。
    @discardableResult
    static func export(appSupport: URL?, group: URL?, destination: URL) throws -> Summary {
        let fileManager = FileManager.default
        let workRoot = fileManager.temporaryDirectory
            .appendingPathComponent("gqns-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: workRoot) }
        let payload = workRoot.appendingPathComponent("payload", isDirectory: true)
        let stagedZip = workRoot.appendingPathComponent("backup.zip")
        let verifyDir = workRoot.appendingPathComponent("verify", isDirectory: true)
        try fileManager.createDirectory(at: payload, withIntermediateDirectories: true)

        var copied = 0
        if let appSupport, fileManager.fileExists(atPath: appSupport.path) {
            do {
                try BackupIntegrity.copySnapshot(from: appSupport, to: payload.appendingPathComponent("ApplicationSupport-Token", isDirectory: true))
                copied += 1
            } catch { throw ExportError.copyFailed(error.localizedDescription) }
        }
        if let group, fileManager.fileExists(atPath: group.path) {
            do {
                try BackupIntegrity.copySnapshot(from: group, to: payload.appendingPathComponent("AppGroupContainer", isDirectory: true))
                copied += 1
            } catch { throw ExportError.copyFailed(error.localizedDescription) }
        }
        guard copied > 0 else { throw ExportError.noSources }

        let preferences:[String:[String:Any]] = ["standard":UserDefaults.standard.persistentDomain(forName:Bundle.main.bundleIdentifier!) ?? [:],"module":UserDefaults.standard.persistentDomain(forName:"com.gaoseries.GaoCiYuan.Token") ?? [:]]
        try PropertyListSerialization.data(fromPropertyList:preferences,format:.binary,options:0).write(to:payload.appendingPathComponent("preferences.plist"))
        let hashes = try BackupIntegrity.manifest(payload)
        let manifest = BackupIntegrity.Manifest(version:Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "3.63",files:hashes)
        try JSONEncoder().encode(manifest).write(to:payload.appendingPathComponent("gqns-manifest.json"),options:.atomic)
        // 单源打包（ditto 多源会报 Can't archive multiple sources）。
        try ditto(arguments: ["-c", "-k", "--sequesterRsrc", payload.path, stagedZip.path])

        // 校验：能解压，且解压结果与暂存源逐项一致（文件数 + 逐文件大小）。
        try fileManager.createDirectory(at: verifyDir, withIntermediateDirectories: true)
        try ditto(arguments: ["-x", "-k", stagedZip.path, verifyDir.path])
        _ = try BackupIntegrity.verify(verifyDir)
        let sourceManifest = try Self.manifest(of: payload)
        let extractedManifest = try Self.manifest(of: verifyDir)
        guard sourceManifest.count == extractedManifest.count else {
            throw ExportError.verifyFailed("文件数不符（源 \(sourceManifest.count) / 解压 \(extractedManifest.count)）")
        }
        for (path, size) in sourceManifest {
            guard extractedManifest[path] == size else {
                throw ExportError.verifyFailed("文件不符：\(path)")
            }
        }

        // Stage beside the destination, then replace with a single same-volume rename.
        let sibling=destination.deletingLastPathComponent().appendingPathComponent(".gqns-"+UUID().uuidString+".zip")
        defer { try? fileManager.removeItem(at:sibling) }
        do {
            try fileManager.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
            try fileManager.copyItem(at:stagedZip,to:sibling)
            guard try BackupIntegrity.hash(stagedZip)==BackupIntegrity.hash(sibling) else { throw CocoaError(.fileReadCorruptFile) }
            if fileManager.fileExists(atPath:destination.path) { _ = try fileManager.replaceItemAt(destination,withItemAt:sibling) }
            else { try fileManager.moveItem(at:sibling,to:destination) }
        } catch { throw ExportError.replaceFailed(error.localizedDescription) }

        let zipBytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Summary(fileCount: sourceManifest.count,
                       totalBytes: sourceManifest.values.reduce(0, +),
                       zipBytes: Int64(zipBytes))
    }

    /// 相对路径 → 文件大小（递归，跳过目录与符号链接指向的目录）。
    private static func manifest(of root: URL) throws -> [String: Int64] {
        let root=root.resolvingSymlinksInPath()
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }
        var result: [String: Int64] = [:]
        for case let originalURL as URL in enumerator {
            let url=originalURL.resolvingSymlinksInPath()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            result[relative] = Int64(values.fileSize ?? 0)
        }
        return result
    }

    private static func ditto(arguments: [String]) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        process.standardError = errorPipe
        try process.run()
        // 先读空 stderr 再等退出，避免管道缓冲写满时互相等待。
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ExportError.dittoFailed(detail.isEmpty ? "ditto 退出码 \(process.terminationStatus)" : detail)
        }
    }
}
