import Foundation
import CryptoKit
import UniformTypeIdentifiers

extension UTType { static let gaoBackup = UTType(exportedAs:"com.gaoseries.gaociyuan.backup",conformingTo:.package) }
struct Preferences: Codable, Equatable {
    var appearance: String
    var language: String
    var autoMembership: Bool? = nil
    var codexPath: String
    static func read(_ defaults: UserDefaults = TokenBundle.defaults) -> Self {
        .init(appearance:defaults.string(forKey:"appearance") ?? "system",language:defaults.string(forKey:"language") ?? "zh-Hans",autoMembership:defaults.object(forKey:"autoMembership") as? Bool ?? true,codexPath:defaults.string(forKey:"codexPath") ?? "")
    }
    func apply(_ defaults: UserDefaults = TokenBundle.defaults) {
        defaults.set(["system","light","dark"].contains(appearance) ? appearance : "system",forKey:"appearance")
        defaults.set(language == "en" ? "en" : "zh-Hans",forKey:"language")
        defaults.set(autoMembership ?? true,forKey:"autoMembership")
        defaults.set(FileManager.default.isExecutableFile(atPath:codexPath) ? codexPath : "",forKey:"codexPath")
    }
}
struct TransferManifest: Codable {
    var format = 1
    var appVersion = AppInfo.version
    var createdAt = Date()
    var preferences: Preferences
    var files: [String:String]
}
struct PreparedTransfer {
    var library: Library
    var preferences: Preferences?
    var packageRoot: URL?
    var fileCount: Int
}
enum DataTransfer {
    static let fm = FileManager.default
    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom:url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount:1_048_576), !data.isEmpty { hash.update(data:data) }
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
    static func files(_ root: URL) throws -> [String:URL] {
        var result: [String:URL] = [:]
        if fm.fileExists(atPath:root.path) { let v = try root.resourceValues(forKeys:[.isSymbolicLinkKey,.isDirectoryKey]); guard v.isSymbolicLink != true, v.isDirectory == true else { throw MonitorError.message("数据目录不是有效的普通目录。") } }
        guard fm.fileExists(atPath:root.path) else { return result }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        var failure: Error?
        guard let it = fm.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.isDirectoryKey],options:[],errorHandler:{ _,error in failure = error; return false }) else { throw MonitorError.message("无法读取数据目录。") }
        for case let url as URL in it {
            let attr = try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.isDirectoryKey])
            guard attr.isSymbolicLink != true else { throw MonitorError.message("数据包含符号链接，请先将实际文件复制到数据目录。") }
            if attr.isRegularFile == true {
                let canonicalFile = url.standardizedFileURL.resolvingSymlinksInPath()
                guard canonicalFile.path.hasPrefix(root.path + "/") else { throw MonitorError.message("备份文件路径无效。") }
                let path = String(canonicalFile.path.dropFirst(root.path.count + 1))
                guard safe(path) else { throw MonitorError.message("备份文件路径无效。") }
                result[path] = url
            } else if attr.isDirectory != true { throw MonitorError.message("数据目录包含不支持的特殊文件。") }
        }
        if let failure { throw failure }
        return result
    }
    static func safe(_ relative: String) -> Bool { !relative.isEmpty && !relative.hasPrefix("/") && !relative.split(separator:"/",omittingEmptySubsequences:false).contains(where:{$0 == ".." || $0 == "." || $0.isEmpty}) }
    static func copy(_ source: URL, _ destination: URL) throws {
        try fm.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
        if fm.fileExists(atPath:destination.path) { try fm.removeItem(at:destination) }
        try fm.copyItem(at:source,to:destination)
    }
    /// SQLite backups include committed WAL rows in one verified file. Sidecars are never
    /// copied separately because copying an in-flight WAL can produce an inconsistent archive.
    private static func copySnapshot(_ root: URL, to destination: URL) throws {
        for (name, url) in try files(root) {
            if name.hasSuffix("-wal") || name.hasSuffix("-shm") || name.hasSuffix("-journal") { continue }
            let target = destination.appendingPathComponent(name)
            if ["sqlite", "sqlite3", "db"].contains(url.pathExtension.lowercased()) {
                try fm.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
                if fm.fileExists(atPath:target.path) { try fm.removeItem(at:target) }
                try UsageLedger.snapshotDatabase(from:url,to:target)
            } else { try copy(url,target) }
        }
    }
    static func export(to destination: URL, root: URL, library: Library, preferences: Preferences) throws {
        try UsageLedger.withExclusiveAccess { try exportLocked(to:destination,root:root,library:library,preferences:preferences) }
    }
    private static func exportLocked(to destination: URL, root: URL, library: Library, preferences: Preferences) throws {
        try MonitorStore.validate(library)
        let dest = destination.standardizedFileURL.resolvingSymlinksInPath()
        let dataRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        guard dest.path != dataRoot.path && !dest.path.hasPrefix(dataRoot.path + "/") else { throw MonitorError.message("请将备份保存在应用数据目录之外。") }
        let stage = dest.deletingLastPathComponent().appendingPathComponent(".gaociyuan-export-\(UUID().uuidString)")
        defer { try? fm.removeItem(at:stage) }
        let data = stage.appendingPathComponent("Data")
        try fm.createDirectory(at:data,withIntermediateDirectories:true)
        try copySnapshot(dataRoot,to:data)
        var portable = library
        for index in portable.accounts.indices {
            let account = portable.accounts[index]
            guard account.connection == .file, !account.filePath.isEmpty else { continue }
            let source = URL(fileURLWithPath:account.filePath).standardizedFileURL
            if fm.fileExists(atPath:source.path) {
                guard (try source.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true else { throw MonitorError.message("快照路径是符号链接，请选择实际文件。") }
                let relative = "ImportedSnapshots/\(account.id.uuidString).json"
                try copy(source,data.appendingPathComponent(relative)); portable.accounts[index].filePath = "backup://" + relative
            } // missing external file remains explicit, never manufacture its contents
        }
        try JSONCoding.encoder.encode(portable).write(to:data.appendingPathComponent("library.json"),options:.atomic)
        var hashes: [String:String] = [:]
        for (name,url) in try files(data) { hashes[name] = try digest(url) }
        let manifest = TransferManifest(preferences:preferences,files:hashes)
        try JSONCoding.encoder.encode(manifest).write(to:stage.appendingPathComponent("manifest.json"),options:.atomic)
        _ = try prepare(stage)
        // Keep the previous export until the new package has been verified and moved successfully.
        let old = dest.deletingLastPathComponent().appendingPathComponent(".gaociyuan-previous-\(UUID().uuidString)")
        let exists = fm.fileExists(atPath:dest.path)
        if exists { try fm.moveItem(at:dest,to:old) }
        do { try fm.moveItem(at:stage,to:dest) } catch { if exists { try? fm.moveItem(at:old,to:dest) }; throw error }
        if exists { try? fm.removeItem(at:old) }
    }
    static func prepare(_ url: URL) throws -> PreparedTransfer {
        if url.pathExtension.lowercased() == "json" {
            let library = try JSONCoding.decoder.decode(Library.self,from:Data(contentsOf:url)); try MonitorStore.validate(library)
            return .init(library:library,packageRoot:nil,fileCount:0)
        }
        let manifestURL = url.appendingPathComponent("manifest.json")
        guard (try manifestURL.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true else { throw MonitorError.message("备份清单不能是符号链接。") }
        let manifest = try JSONCoding.decoder.decode(TransferManifest.self,from:Data(contentsOf:manifestURL))
        guard manifest.format == 1, manifest.files.keys.allSatisfy(safe) else { throw MonitorError.message("不支持的备份格式或文件路径。") }
        let dataRoot = url.appendingPathComponent("Data")
        let actual = try files(dataRoot)
        guard Set(actual.keys) == Set(manifest.files.keys), actual["library.json"] != nil else {
            throw MonitorError.message("备份文件缺失或清单不一致。")
        }
        for (name,file) in actual { guard try digest(file) == manifest.files[name] else { throw MonitorError.message("备份文件校验失败，未导入任何数据。") } }
        for (_,file) in actual where ["sqlite","sqlite3","db"].contains(file.pathExtension.lowercased()) { try UsageLedger.verifyDatabase(file) }
        let library = try JSONCoding.decoder.decode(Library.self,from:Data(contentsOf:dataRoot.appendingPathComponent("library.json"))); try MonitorStore.validate(library)
        for a in library.accounts where a.filePath.hasPrefix("backup://") {
            let rel = String(a.filePath.dropFirst(9)); guard safe(rel), actual[rel] != nil else { throw MonitorError.message("备份中的快照引用无效。") }
        }
        return .init(library:library,preferences:manifest.preferences,packageRoot:url,fileCount:actual.count - 1)
    }
    static func restore(_ incoming: PreparedTransfer, to root: URL) throws -> Library {
        let library = try UsageLedger.withExclusiveAccess {
            let value = try restoreLocked(incoming,to:root)
            UsageLedger.invalidateScans()
            return value
        }
        NotificationCenter.default.post(name:UsageLedger.didRestoreNotification,object:nil)
        return library
    }
    private static func restoreLocked(_ incoming: PreparedTransfer, to root: URL) throws -> Library {
        let parent = root.deletingLastPathComponent()
        try fm.createDirectory(at:parent,withIntermediateDirectories:true)
        let stage = parent.appendingPathComponent(".gaociyuan-restore-\(UUID().uuidString)")
        let rollback = parent.appendingPathComponent("GaoCiYuan-UserBackup-\(UUID().uuidString)")
        defer { try? fm.removeItem(at:stage) }
        try fm.createDirectory(at:stage,withIntermediateDirectories:true)
        // Merge existing documents first; conflicting old files remain in the full rollback backup.
        try copySnapshot(root,to:stage)
        if let package = incoming.packageRoot {
            _ = try prepare(package) // recheck immediately before changing anything
            try copySnapshot(package.appendingPathComponent("Data"),to:stage)
        }
        var library = incoming.library
        for index in library.accounts.indices where library.accounts[index].filePath.hasPrefix("backup://") {
            let relative = String(library.accounts[index].filePath.dropFirst(9))
            guard safe(relative) else { throw MonitorError.message("备份中的快照引用无效。") }
            library.accounts[index].filePath = root.appendingPathComponent(relative).path
        }
        library.autoRefresh = false
        try JSONCoding.encoder.encode(library).write(to:stage.appendingPathComponent("library.json"),options:.atomic)
        try MonitorStore.validate(library)
        let exists = fm.fileExists(atPath:root.path)
        if exists { try fm.moveItem(at:root,to:rollback) }
        do { try fm.moveItem(at:stage,to:root) } catch { if exists { try? fm.moveItem(at:rollback,to:root) }; throw error }
        // 用户要求保留数据与资料备份；恢复前的完整原目录继续保留。
        return library
    }
    static func rotateRollbackBackups(in parent: URL, keep: Int = 3) {
        guard let entries = try? fm.contentsOfDirectory(at:parent,includingPropertiesForKeys:[.creationDateKey]) else { return }
        let rollbacks = entries.filter { $0.lastPathComponent.hasPrefix("GaoCiYuan-UserBackup-") }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys:[.creationDateKey]).creationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys:[.creationDateKey]).creationDate) ?? .distantPast
                return da > db
            }
        for old in rollbacks.dropFirst(keep) { try? fm.removeItem(at:old) }
    }
}
