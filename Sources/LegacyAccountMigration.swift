import Foundation

enum LegacyAccountMigration {
    static func removingLLMAccounts(from library: Library) -> (library: Library, removedIDs: [UUID]) {
        var copy = library
        let removed = copy.accounts.filter { $0.kind == .llm || $0.provider == .custom }.map(\.id)
        copy.accounts.removeAll { $0.kind == .llm || $0.provider == .custom }
        return (copy, removed)
    }
}
