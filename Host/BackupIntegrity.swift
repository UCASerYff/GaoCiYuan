import Foundation
import CryptoKit

/// Streaming checksums keep large PDFs and Word attachments out of resident memory.
enum BackupIntegrity {
    struct Manifest: Codable { var appID="com.gaoseries.GaoCiYuan"; var format=1; var version:String; var createdAt=Date(); var files:[String:String] }
    static func hash(_ file:URL) throws -> String {
        let handle=try FileHandle(forReadingFrom:file);defer { try? handle.close() }
        var digest=SHA256()
        while let data=try handle.read(upToCount:1_048_576),!data.isEmpty { digest.update(data:data) }
        return digest.finalize().map { String(format:"%02x",$0) }.joined()
    }
    static func files(_ root:URL) throws -> [URL] {
        let root=root.resolvingSymlinksInPath()
        let fm=FileManager.default
        guard let e=fm.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey]) else { throw CocoaError(.fileReadUnknown) }
        var result:[URL]=[]
        for case let file as URL in e {
            let v=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            guard v.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
            if v.isRegularFile == true { result.append(file.resolvingSymlinksInPath()) }
        }
        return result
    }
    static func manifest(_ root:URL) throws -> [String:String] {
        let root=root.resolvingSymlinksInPath()
        var result:[String:String]=[:]
        for file in try files(root) where file.path != root.appendingPathComponent("gqns-manifest.json").path {
            result[String(file.path.dropFirst(root.path.count+1))]=try hash(file)
        }
        return result
    }
    static func verify(_ root:URL) throws -> Manifest {
        let m=try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:root.appendingPathComponent("gqns-manifest.json")))
        let actual=try manifest(root)
        guard m.appID == "com.gaoseries.GaoCiYuan",m.format == 1,!m.files.isEmpty,actual==m.files else {
            let differences=Set(actual.keys).union(m.files.keys).filter { actual[$0] != m.files[$0] }.sorted().prefix(5).joined(separator:", ")
            throw NSError(domain:"GQNS.Backup",code:1,userInfo:[NSLocalizedDescriptionKey:"备份文件校验不一致："+differences])
        }
        for file in try files(root) where file.pathExtension == "sqlite" {
            guard DailyBackup.integrityCheck(file)=="ok" else { throw CocoaError(.fileReadCorruptFile) }
        }
        return m
    }
    static func copySnapshot(from source:URL,to target:URL) throws {
        let source=source.resolvingSymlinksInPath()
        let fm=FileManager.default
        try fm.createDirectory(at:target,withIntermediateDirectories:true)
        for file in try files(source) {
            let relative=String(file.path.dropFirst(source.path.count+1))
            // Container metadata belongs to macOS; journals are folded into SQLite snapshots.
            if relative.hasPrefix(".com.apple.") || file.lastPathComponent.hasSuffix("-wal") || file.lastPathComponent.hasSuffix("-shm") { continue }
            let dest=target.appendingPathComponent(relative)
            try fm.createDirectory(at:dest.deletingLastPathComponent(),withIntermediateDirectories:true)
            if file.pathExtension == "sqlite" {
                try DailyBackup.vacuumInto(source:file,destination:dest)
                guard DailyBackup.integrityCheck(dest)=="ok" else { throw CocoaError(.fileReadCorruptFile) }
            } else {
                // Atomic writers are safe; concurrent non-atomic attachment changes are detected.
                try fm.copyItem(at:file,to:dest)
                guard try hash(file)==hash(dest) else { throw CocoaError(.fileReadCorruptFile) }
            }
        }
    }
}
