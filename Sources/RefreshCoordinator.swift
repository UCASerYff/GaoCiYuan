import Foundation

/// Limits connector operations and shares only requests with an explicitly identical source.
/// A cancelled operation keeps its slot until it actually exits; a slow, non-cooperative
/// connector therefore cannot cause replacement requests to exceed the limit.
@MainActor final class RefreshCoordinator<Value> {
    private struct Job {
        let id: UUID
        let request: String
        let service: String
        let operation: @MainActor () async throws -> Value
        var waiters: [UUID: CheckedContinuation<Value, Error>]
        var task: Task<Void, Never>?
    }
    private let maximumConcurrent: Int
    private let maximumPerService: Int
    private var jobs: [UUID: Job] = [:]
    private var shared: [String: UUID] = [:]
    private var queue: [UUID] = []
    private var running = 0
    private var runningByService: [String: Int] = [:]

    init(maximumConcurrent: Int = 3, maximumPerService: Int = 1) {
        self.maximumConcurrent = max(1, maximumConcurrent)
        self.maximumPerService = max(1, maximumPerService)
    }

    func perform(request: String, service: String,
                 operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if let existing = shared[request], jobs[existing] != nil {
                    jobs[existing]?.waiters[waiter] = continuation
                } else {
                    let id = UUID()
                    jobs[id] = Job(id: id, request: request, service: service, operation: operation,
                                   waiters: [waiter: continuation], task: nil)
                    shared[request] = id
                    queue.append(id)
                    drain()
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(waiter: waiter) }
        }
    }

    private func cancel(waiter: UUID) {
        guard let id = jobs.first(where: { $0.value.waiters[waiter] != nil })?.key,
              var job = jobs[id], let continuation = job.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        jobs[id] = job
        guard job.waiters.isEmpty else { return }
        if shared[job.request] == id { shared.removeValue(forKey: job.request) }
        if let task = job.task {
            task.cancel()
        } else {
            jobs.removeValue(forKey: id)
            queue.removeAll { $0 == id }
        }
        drain()
    }

    private func drain() {
        while running < maximumConcurrent,
              let index = queue.firstIndex(where: { id in
                  guard let job = jobs[id] else { return false }
                  return runningByService[job.service, default: 0] < maximumPerService
              }) {
            let id = queue.remove(at: index)
            guard let job = jobs[id] else { continue }
            running += 1
            runningByService[job.service, default: 0] += 1
            jobs[id]?.task = Task {
                let result: Result<Value, Error>
                do { try Task.checkCancellation(); result = .success(try await job.operation()) }
                catch { result = .failure(error) }
                self.finish(id: id, result: result)
            }
        }
    }

    private func finish(id: UUID, result: Result<Value, Error>) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        if shared[job.request] == id { shared.removeValue(forKey: job.request) }
        running -= 1
        runningByService[job.service, default: 0] -= 1
        for continuation in job.waiters.values { continuation.resume(with: result) }
        drain()
    }
}
