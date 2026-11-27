import Foundation

@MainActor public final class TokenLifecycleWork {
    public static let shared = TokenLifecycleWork()

    private var draftChecks: [UUID: @MainActor () -> Bool] = [:]
    private var writes: Set<UUID> = []
    private var finishing = false
    private var whenIdle: (@MainActor () -> Void)?

    public var hasUnsavedDraft: Bool { draftChecks.values.contains { $0() } }
    public var hasPendingWrites: Bool { !writes.isEmpty }

    func observeDraft(_ id: UUID, isDirty: @escaping @MainActor () -> Bool) {
        draftChecks[id] = isDirty
    }

    func forgetDraft(_ id: UUID) {
        draftChecks.removeValue(forKey: id)
    }

    func beginWrite() -> UUID? {
        guard !finishing else { return nil }
        let id = UUID()
        writes.insert(id)
        return id
    }

    func endWrite(_ id: UUID) {
        guard writes.remove(id) != nil, writes.isEmpty, let whenIdle else { return }
        self.whenIdle = nil
        whenIdle()
    }

    public func finishAfterWrites(_ completion: @escaping @MainActor () -> Void) {
        guard !finishing else { return }
        finishing = true
        if writes.isEmpty { completion() }
        else { whenIdle = completion }
    }
}
