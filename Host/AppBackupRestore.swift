import AppKit
import Foundation

/// Validate before approval, then apply before any module opens its data on next launch.
enum AppBackupRestore {
    struct Job:Codable { var staged:URL;var safety:URL;var applying=false;var operations:[Operation]=[] }
    struct Operation:Codable { var source:URL;var destination:URL;var previous:URL;var hadPrevious:Bool }
    static var jobs:URL { if let test=ProcessInfo.processInfo.environment["GQNS_RESTORE_ROOT"] { return URL(fileURLWithPath:test) };return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("GaoSeriesRestore/Token") }
    static var pending:URL { jobs.appendingPathComponent("pending.json") }
    static func prepare(_ archive:URL) throws -> (URL,BackupIntegrity.Manifest) {
        let fm=FileManager.default
        try fm.createDirectory(at:jobs,withIntermediateDirectories:true)
        let root=jobs.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        do {
            // Reject path traversal and symlinks (checked again after extraction).
            let attributes=try run("/usr/bin/zipinfo",["-l",archive.path])
            guard !attributes.split(separator:"\n").contains(where: { $0.hasPrefix("l") }) else { throw CocoaError(.fileReadCorruptFile) }
            let listing=try run("/usr/bin/unzip",["-Z1",archive.path])
            guard listing.split(separator:"\n").allSatisfy({ line in
                let path=String(line); return !path.hasPrefix("/") && !path.split(separator:"/").contains("..")
            }) else { throw CocoaError(.fileReadCorruptFile) }
            _ = try run("/usr/bin/ditto",["-x","-k",archive.path,root.path])
            let manifest=try BackupIntegrity.verify(root)
            let current=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "3.63"
            guard manifest.version.compare(current,options:.numeric) != .orderedDescending,
                  fm.fileExists(atPath:root.appendingPathComponent("ApplicationSupport-Token").path),
                  fm.fileExists(atPath:root.appendingPathComponent("AppGroupContainer").path) else { throw CocoaError(.fileReadCorruptFile) }
            return (root,manifest)
        } catch { try? fm.removeItem(at:root);throw error }
    }
    static func schedule(_ staged:URL) throws {
        let job=Job(staged:staged,safety:jobs.appendingPathComponent("恢复前原始数据-"+UUID().uuidString))
        try JSONEncoder().encode(job).write(to:pending,options:.atomic)
    }
    static func applyPending() throws {
        let fm=FileManager.default
        guard fm.fileExists(atPath:pending.path) else { return }
        var job=try JSONDecoder().decode(Job.self,from:Data(contentsOf:pending))
        if job.applying { try rollback(job);try fm.removeItem(at:pending);throw CocoaError(.fileWriteUnknown) }
        _ = try BackupIntegrity.verify(job.staged)
        guard let app=AppDataLocations.appSupport,let group=AppDataLocations.groupContainer else { throw CocoaError(.fileNoSuchFile) }
        try fm.createDirectory(at:job.safety,withIntermediateDirectories:true)
        job.operations=[Operation(source:job.staged.appendingPathComponent("ApplicationSupport-Token"),destination:app,previous:job.safety.appendingPathComponent("ApplicationSupport"),hadPrevious:fm.fileExists(atPath:app.path))]
        let groupSource=job.staged.appendingPathComponent("AppGroupContainer")
        let incoming=try fm.contentsOfDirectory(at:groupSource,includingPropertiesForKeys:nil).filter { !$0.lastPathComponent.hasPrefix(".com.apple.") }
        let existing=try fm.contentsOfDirectory(at:group,includingPropertiesForKeys:nil).filter { !$0.lastPathComponent.hasPrefix(".com.apple.") }
        for name in Set(incoming.map(\.lastPathComponent)+existing.map(\.lastPathComponent)).sorted() {
            let dest=group.appendingPathComponent(name)
            job.operations.append(Operation(source:groupSource.appendingPathComponent(name),destination:dest,previous:job.safety.appendingPathComponent("Group-"+name),hadPrevious:fm.fileExists(atPath:dest.path)))
        }
        job.applying=true
        try JSONEncoder().encode(job).write(to:pending,options:.atomic)
        do {
            for op in job.operations {
                if op.hadPrevious { try fm.moveItem(at:op.destination,to:op.previous) }
                if fm.fileExists(atPath:op.source.path) { try fm.copyItem(at:op.source,to:op.destination) }
            }
            if let data=try? Data(contentsOf:job.staged.appendingPathComponent("preferences.plist")),let preferences=try PropertyListSerialization.propertyList(from:data,options:[],format:nil) as? [String:[String:Any]] {
                if let domain=preferences["standard"] {UserDefaults.standard.setPersistentDomain(domain,forName:Bundle.main.bundleIdentifier!)}
                if let domain=preferences["module"] {UserDefaults.standard.setPersistentDomain(domain,forName:"com.gaoseries.GaoCiYuan.Token")}
            }
            try fm.removeItem(at:pending)
            try? fm.removeItem(at:job.staged)
        } catch {
            try rollback(job)
            try fm.removeItem(at:pending)
            throw error
        }
    }
    private static func rollback(_ job:Job) throws {
        let fm=FileManager.default
        for op in job.operations.reversed() {
            if fm.fileExists(atPath:op.previous.path) {
                if fm.fileExists(atPath:op.destination.path) { try fm.removeItem(at:op.destination) }
                try fm.moveItem(at:op.previous,to:op.destination)
            } else if !op.hadPrevious,fm.fileExists(atPath:op.destination.path) { try fm.removeItem(at:op.destination) }
        }
    }
    private static func run(_ executable:String,_ arguments:[String]) throws -> String {
        let p=Process(),pipe=Pipe();p.executableURL=URL(fileURLWithPath:executable);p.arguments=arguments;p.standardOutput=pipe
        try p.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
        guard p.terminationStatus==0 else { throw CocoaError(.fileReadCorruptFile) }
        return String(data:data,encoding:.utf8) ?? ""
    }
}
