import Foundation

// These stubs isolate account compatibility from unrelated logging and alert UI.
enum TokenBundle { static let bundle = Bundle.main }
enum Log { struct Sink { func error(_ message: String) {} }; static let store = Sink() }
enum AlertRules { static func attention(_ account: Account, threshold: Double, at: Date) -> [String] { [] } }

@main struct ProviderCatalogRegression {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw MonitorError.message(message) }
    }
    static func main() throws {
        let decoder = JSONCoding.decoder, encoder = JSONCoding.encoder
        // New routes remain independently selectable, serializable and compatible
        // with old account snapshots which do not contain creditBalances.
        for (provider, spec) in ProviderIntegration.entries {
            let account = Account(provider: provider, kind: spec.kind, name: spec.name, connection: spec.connection)
            let encoded = try encoder.encode(account)
            let decoded = try decoder.decode(Account.self, from: encoded)
            try check(decoded.provider == provider && decoded.connection == spec.connection, "new account route lost on decode")
            try check(Connection.available(provider, spec.kind).first == spec.connection, "new route unavailable")
            try check(spec.connection.needsKey == (provider != .kiro), "credential requirement incorrect")
            try check(!provider.name.isEmpty && !provider.note.isEmpty, "catalogue metadata missing")
        }
        try check(Connection.takeUnknownFallbacks().isEmpty, "new connections fell back to software detection")
        for (provider, kind, connection) in [(Provider.openai, AccountKind.agent, Connection.codex), (.qwen, .llm, .aliyun), (.custom, .agent, .customAPI), (.cursor, .agent, .cursor), (.gemini, .agent, .geminiApp), (.gemini, .agent, .agentLocal)] {
            let old = Account(provider: provider, kind: kind, name: "Existing", connection: connection)
            let decoded = try decoder.decode(Account.self, from: encoder.encode(old))
            try check(Connection.available(decoded.provider, decoded.kind).contains(decoded.connection), "existing account route invalidated")
        }
        for provider in [Provider.qwen, .hy, .deepseek] {
            try check(provider.creationKinds == [.llm], "duplicate Agent creation entry remains")
            let old = Account(provider: provider, kind: .agent, name: "Legacy", connection: .agentLocal)
            let decoded = try decoder.decode(Account.self, from: encoder.encode(old))
            try check(decoded.id == old.id && Connection.available(provider, .agent).contains(decoded.connection), "legacy account invalidated")
        }
        try check(AgentPlatformTable.matchesRunning(.qoder, bundle: "com.qoder.app", name: "qoder"), "Qoder identity missing")
        try check(!AgentPlatformTable.matchesRunning(.qwen, bundle: "com.qoder.app", name: "qoder"), "Qoder discovered under Qwen")
        try check(!AgentPlatformTable.hasSoftwareIdentity(.hy), "empty Hunyuan identity creates software")
        try check(!AgentPlatformTable.matchesRunning(.deepseek, bundle: "com.deepseek.dsh", name: "deepseek harness"), "Harness matches ordinary DeepSeek")
        var snapshot = UsageSnapshot.empty(source: "fixture")
        var oldJSON = try JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as! [String: Any]
        oldJSON.removeValue(forKey: "creditBalances")
        let legacy = try decoder.decode(UsageSnapshot.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        try legacy.validate()
        try check(legacy.creditBalances == nil, "old snapshots gained invented credits")
        snapshot.creditBalances = [.init(id: "credits", title: "账户积分", unit: "Credits", value: 12.5)]
        try snapshot.validate()
        let roundTrip = try decoder.decode(UsageSnapshot.self, from: encoder.encode(snapshot))
        try check(roundTrip.creditBalances == snapshot.creditBalances && roundTrip.balances.isEmpty, "credits treated as currency")
        try check(roundTrip.hasMeasuredValues && !legacy.hasMeasuredValues, "credit-only history would be removed on reload")
        try check(!legacy.sameObservation(as: snapshot), "credit change omitted from history detection")
        let duplicate = snapshot.creditBalances![0]
        snapshot.creditBalances?.append(duplicate)
        do { try snapshot.validate(); throw MonitorError.message("duplicate credits accepted") } catch {
            try check(error.localizedDescription != "duplicate credits accepted", "duplicate credits accepted")
        }
        // Old libraries and native backup packages embed a game payload beside
        // business data. Removing it must preserve every account/history field.
        var reading = UsageSnapshot.empty(source: "Compatibility fixture")
        let observed = Date(timeIntervalSince1970: 1_700_000_100)
        reading.observedAt = observed
        reading.periodStart = observed.addingTimeInterval(-60)
        reading.periodEnd = observed
        reading.inputTokens = 345_678
        reading.outputTokens = 901
        reading.costs = [.init(currency: "USD", value: 7.25)]
        reading.balances = [.init(currency: "USD", value: 23.5)]
        var legacyAccount = Account(provider: .custom, kind: .llm, name: "Existing ledger", connection: .file)
        legacyAccount.snapshot = reading
        legacyAccount.history = [reading]
        legacyAccount.filePath = "backup://ImportedSnapshots/fixture.json"
        var currentLibrary = Library()
        currentLibrary.accounts = [legacyAccount]
        currentLibrary.refreshMinutes = 17
        currentLibrary.warningThreshold = 35
        currentLibrary.autoRefresh = false
        let businessOnly = try JSONSerialization.jsonObject(with: encoder.encode(currentLibrary)) as! [String: Any]
        // Unknown values, including invalid historical game values, are ignored;
        // they must not prevent opening the unrelated account data.
        for removedPayload: Any in [
            ["gameVersion": 2, "researchPoints": 42, "flight": ["planet": 0]],
            ["gameVersion": -1, "researchPoints": "invalid old game value"],
            NSNull()
        ] {
            var previousLibrary = businessOnly
            previousLibrary["station"] = removedPayload
            let decodedLibrary = try decoder.decode(Library.self, from: JSONSerialization.data(withJSONObject: previousLibrary))
            let upgraded = try JSONSerialization.jsonObject(with: encoder.encode(decodedLibrary)) as! [String: Any]
            try check(upgraded["station"] == nil, "removed game payload persisted")
            try check(NSDictionary(dictionary: upgraded).isEqual(to: businessOnly), "removing game changed account history or settings")
            try check(decodedLibrary.accounts[0].snapshot?.totalTokens == 346_579, "recorded tokens changed during migration")
            try decodedLibrary.accounts[0].snapshot?.validate()
            for record in decodedLibrary.accounts[0].history { try record.validate() }
        }
        print("Provider catalog regression passed: legacy libraries drop removed game fields while preserving accounts/history/settings; routes, credits, observation deduplication, invalid credit rejection.")
    }
}
