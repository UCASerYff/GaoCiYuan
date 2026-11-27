import Foundation

@main struct TokenLifecycleWorkRegression {
    @MainActor static func main() {
        let work = TokenLifecycleWork()
        let accountDraft = UUID()
        let usageDraft = UUID()
        var accountName = "Initial"
        var customSourcesChanged = false
        work.observeDraft(accountDraft) { accountName != "Initial" }
        work.observeDraft(usageDraft) { customSourcesChanged }
        precondition(!work.hasUnsavedDraft)

        accountName = "Edited"
        precondition(work.hasUnsavedDraft)
        accountName = "Initial"
        precondition(!work.hasUnsavedDraft)
        customSourcesChanged = true
        precondition(work.hasUnsavedDraft)
        work.forgetDraft(usageDraft)
        precondition(!work.hasUnsavedDraft)

        let first = work.beginWrite()!
        let second = work.beginWrite()!
        var exitReplies = 0
        precondition(work.hasPendingWrites)
        work.finishAfterWrites { exitReplies += 1 }
        precondition(exitReplies == 0 && work.beginWrite() == nil)
        work.endWrite(first)
        work.endWrite(first)
        precondition(exitReplies == 0 && work.hasPendingWrites)
        work.endWrite(second)
        precondition(exitReplies == 1 && !work.hasPendingWrites)
        work.finishAfterWrites { exitReplies += 1 }
        precondition(exitReplies == 1)

        let idle = TokenLifecycleWork()
        idle.finishAfterWrites { exitReplies += 1 }
        precondition(exitReplies == 2 && idle.beginWrite() == nil)
        print("Live drafts and pending-write termination passed")
    }
}
