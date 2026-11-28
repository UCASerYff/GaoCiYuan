import Foundation

enum LegacyAccountMigration {
    static func prepare(_ data: Data) throws -> (library: Library, archived: [[String: Any]], needsRewrite: Bool) {
        guard var fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = (fields["accounts"] ?? []) as? [[String: Any]] else {
            throw MonitorError.message("不兼容或无效的存档。")
        }
        var preserved: [[String: Any]] = []
        var active: [[String: Any]] = []
        var retired = Set<UUID>()
        var removed = false
        for record in records {
            let id = (record["id"] as? String).flatMap(UUID.init(uuidString:))
            guard let rawKind = record["kind"] as? String, let kind = AccountKind.recognized(rawKind),
                  let rawProvider = record["provider"] as? String, let provider = Provider(rawValue: rawProvider),
                  record["id"] == nil || id != nil else {
                preserved.append(record)
                continue
            }
            if kind == .llm || provider == .custom {
                if let id { retired.insert(id) }
                removed = true
            } else if provider.integration?.kind == .llm {
                // An Agent-marked legacy provider is ambiguous. Keep its record and credential.
                preserved.append(record)
            } else {
                active.append(record)
            }
        }
        fields["accounts"] = active
        let filtered = try JSONSerialization.data(withJSONObject: fields)
        var library = try JSONCoding.decoder.decode(Library.self, from: filtered)
        let protected = Set(library.accounts.map(\.id)).union(preserved.compactMap {
            ($0["id"] as? String).flatMap(UUID.init(uuidString:))
        })
        let pending = Set(library.pendingLegacyCredentialIDs ?? []).union(retired).subtracting(protected)
        let ids = pending.sorted { $0.uuidString < $1.uuidString }
        let changed = removed || fields["station"] != nil || ids != (library.pendingLegacyCredentialIDs ?? [])
        library.pendingLegacyCredentialIDs = ids.isEmpty ? nil : ids
        return (library, preserved, changed)
    }
}
