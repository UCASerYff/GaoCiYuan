import Foundation
import Darwin

/// Only isolated /bin/sh fixtures and their sleep children; no app, UI, API,
/// credentials, process-name matching, or pre-existing processes are involved.
@main struct ConnectorCancellationRegression {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "ConnectorCancellationRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    final class Reader: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var bytes = Data()
        func start(_ handle: FileHandle) {
            DispatchQueue.global(qos: .utility).async {
                let value = (try? handle.readToEnd()) ?? Data()
                self.lock.lock(); self.bytes = value; self.lock.unlock(); self.done.signal()
            }
        }
        func result() -> Data { lock.lock(); defer { lock.unlock() }; return bytes }
    }
    struct Fixture {
        let token: ConnectorCancellation
        let pid: pid_t
        let child: pid_t
        let input: Pipe, output: Pipe
        func close() {
            token.finishGroup(pid)
            try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
        }
    }
    static func fixture(exitParent: Bool = false) throws -> Fixture {
        let input = Pipe(), output = Pipe(), token = ConnectorCancellation()
        let script = "/bin/sleep 30 & child=$!; printf '%s\\n' \"$child\"; " + (exitParent ? "exit 0" : "wait")
        let pid = try spawnQuotaProcess(path: "/bin/sh", arguments: ["-c", script], input: input, output: output)
        token.attachGroup(pid)
        let data = output.fileHandleForReading.availableData
        guard let text = String(data: data, encoding: .utf8), let child = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            token.finishGroup(pid); throw CocoaError(.fileReadCorruptFile)
        }
        return Fixture(token: token, pid: pid, child: child, input: input, output: output)
    }
    static func waitForEOF(_ value: Fixture, action: () -> Void) throws {
        let reader = Reader(); reader.start(value.output.fileHandleForReading)
        action()
        let finished = reader.done.wait(timeout: .now() + 3) == .success
        if !finished { value.token.finishGroup(value.pid) }
        try check(finished && reader.result().isEmpty, "stdout remained blocked by an owned child after cleanup")
    }
    static func main() throws {
        let first = try fixture(); defer { first.close() }
        try check(getpgid(first.pid) == first.pid && getpgid(first.child) == first.pid, "helper/child did not enter the dedicated owned process group")
        let started = ProcessInfo.processInfo.systemUptime
        try waitForEOF(first) { first.token.cancel() }
        first.token.finishGroup(first.pid)
        try check(ProcessInfo.processInfo.systemUptime - started < 3 && first.token.cancelled, "cancellation did not stop the query within budget")
        var status: Int32 = 0
        try check(waitpid(first.pid, &status, WNOHANG) == -1 && errno == ECHILD, "owned root was not reaped by finishGroup")

        let next = try fixture(); defer { next.close() }
        first.token.cancel(); first.token.finishGroup(first.pid)
        try check(kill(next.pid, 0) == 0 && getpgid(next.child) == next.pid, "old cancellation/finish affected a later unrelated fixture group")
        try waitForEOF(next) { next.token.finishGroup(next.pid) }

        let orphan = try fixture(exitParent: true); defer { orphan.close() }
        // The unreaped root keeps the group's identity owned even after exit.
        try waitForEOF(orphan) { orphan.token.finishGroup(orphan.pid) }

        let cancelledBeforeAttach = ConnectorCancellation(); cancelledBeforeAttach.cancel()
        let input = Pipe(), output = Pipe()
        let pid = try spawnQuotaProcess(path: "/bin/sh", arguments: ["-c", "/bin/sleep 30"], input: input, output: output)
        cancelledBeforeAttach.attachGroup(pid)
        let reader = Reader(); reader.start(output.fileHandleForReading)
        let stopped = reader.done.wait(timeout: .now() + 3) == .success
        cancelledBeforeAttach.finishGroup(pid)
        try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
        try check(stopped, "cancellation before attach left the spawned helper running")
        print("PASS connector process groups: owned root/child cancellation, stdout EOF, reaping, natural-parent exit, cancel-before-attach, repeated cleanup isolated from a later process group; no network/app/UI")
    }
}
