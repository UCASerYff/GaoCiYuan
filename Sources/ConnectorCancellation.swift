import Foundation
import Darwin

/// The PID remains an unreaped child until cleanup, so its independently created
/// process-group ID cannot be reused by an unrelated process during cancellation.
final class ConnectorCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var group: pid_t?
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func check() throws { if cancelled { throw CancellationError() } }
    func attachGroup(_ pid: pid_t) {
        lock.lock(); group = pid; let cancel = stopped; lock.unlock()
        if cancel { terminateGroup(pid) }
    }
    func cancel() {
        lock.lock(); stopped = true; let pid = group; lock.unlock()
        if let pid { terminateGroup(pid) }
    }
    func finishGroup(_ pid: pid_t) {
        // Hold ownership through group shutdown and waitpid; a concurrent cancel
        // cannot obtain an already reaped/recycled PID.
        lock.lock(); defer { lock.unlock() }
        guard group == pid else { return }
        kill(-pid, SIGTERM); kill(-pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        group = nil
    }
    private func terminateGroup(_ pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        guard group == pid else { return }
        kill(-pid, SIGTERM); kill(-pid, SIGKILL)
    }
}

/// Uses posix_spawn's atomic SETPGROUP instead of racing setpgid after exec.
func spawnQuotaProcess(path: String, arguments: [String], input: Pipe, output: Pipe) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { throw CocoaError(.executableNotLoadable) }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawnattr_init(&attributes) == 0 else { throw CocoaError(.executableNotLoadable) }
    defer { posix_spawnattr_destroy(&attributes) }
    guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
          posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw CocoaError(.executableNotLoadable) }
    posix_spawn_file_actions_adddup2(&actions, input.fileHandleForReading.fileDescriptor, STDIN_FILENO)
    posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
    let strings = ([path] + arguments).map { strdup($0) }
    defer { for string in strings { free(string) } }
    var argv = strings + [nil]
    let environmentStrings = ProcessInfo.processInfo.environment.map { strdup($0.key + "=" + $0.value) }
    defer { for string in environmentStrings { free(string) } }
    var environment = environmentStrings + [nil]
    var pid: pid_t = 0
    let result = argv.withUnsafeMutableBufferPointer {
        let arguments = $0.baseAddress!
        return environment.withUnsafeMutableBufferPointer { env in
            posix_spawn(&pid, path, &actions, &attributes, arguments, env.baseAddress!)
        }
    }
    guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
    try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
    return pid
}
