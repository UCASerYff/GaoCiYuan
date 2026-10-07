import Foundation
import CryptoKit
import Darwin

// The scanner uses a pinned Tokscale base plus the bundled GQNS dedup patch.
// Only numeric usage and project attribution leave this boundary; prompt text,
// conversation titles and credentials are never included in our stored models.
struct UsageAmounts: Codable, Sendable, Equatable {
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheRead: Int64 = 0
    var cacheWrite: Int64 = 0
    var reasoning: Int64 = 0
    var costUSD: Double? = nil
    var messageCount: Int64 = 0
    var totalTokens: Int64 { [input, output, cacheRead, cacheWrite, reasoning].reduce(0, Self.add) }
    var cachedInputRatio: Double? {
        let denominator = [input, cacheRead, cacheWrite].reduce(0, Self.add)
        return denominator > 0 ? Double(cacheRead) / Double(denominator) : nil
    }
    private static func add(_ a: Int64, _ b: Int64) -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(max(0, b))
        return overflow ? .max : sum
    }
}

struct UsageDayRow: Codable, Sendable, Equatable {
    var day: String
    var client: String
    var model: String
    var sessionID: String
    var amounts: UsageAmounts
}

struct UsageSessionRow: Codable, Sendable, Equatable {
    var client: String
    var sessionID: String
    var model: String
    var projectKey: String?
    var projectLabel: String?
    var firstActive: Date?
    var lastActive: Date?
    var amounts: UsageAmounts
    var timedTokens: Int64
    var timedDurationMS: Int64
}

struct UsageEngineScan: Codable, Sendable {
    var capturedAt: Date
    var days: [UsageDayRow]
    var sessions: [UsageSessionRow]
    var clients: [String]
    var warnings: [String]
    var dayFingerprints: [String: String] = [:]
    var cursorEvents: [CursorUsageEvent]? = nil
    var localUsage: LocalUsageBatch? = nil
}

// Provider response identities remain stable across copied logs and changing
// surfaces. Coverage is the raw (pre-dedup) source total used to reconcile v1/v2.
struct LocalUsageEvent: Codable, Sendable, Equatable {
    var eventID: String; var client: String; var sessionID: String; var model: String
    var timestamp: Date; var projectKey: String?; var projectLabel: String?
    var durationMS: Int64; var amounts: UsageAmounts
}
struct LocalUsageBatch: Codable, Sendable {
    var clients: [String]
    var events: [LocalUsageEvent]
    var coverageDays: [UsageDayRow]
    var coverageSessions: [UsageSessionRow]
    var baselineDays: [UsageDayRow]? = nil
    var baselineSessions: [UsageSessionRow]? = nil
}

struct UsageModelPrice: Codable, Sendable, Equatable {
    var model: String
    var inputPerMillion: Double? = nil
    var outputPerMillion: Double? = nil
    var cacheReadPerMillion: Double? = nil
    var cacheWritePerMillion: Double? = nil
    var cacheWrite1hPerMillion: Double? = nil
}

struct UsageEngineConfiguration: Codable, Sendable, Equatable {
    var enabledClientIDs: [String] = UsageClientDefinition.defaultIDs
    var customPaths: [String: [String]] = [:]
    var modelPrices: [UsageModelPrice] = []
}

struct UsageClientDefinition: Identifiable, Sendable {
    var id: String
    var name: String
    var paths: [String]
    var scanIDs: [String] = []
    var enabledByDefault: Bool = true
    var supportsCustomPaths: Bool = true
    var effectiveScanIDs: [String] { scanIDs.isEmpty ? [id] : scanIDs }
    var label: String { name }

    // Cursor is explicit opt-in and never passed to the CLI account auto-sync.
    static let all: [Self] = [
        .init(id: "cursor", name: "Cursor（官方账户用量）", paths: ["Library/Application Support/Cursor/User/globalStorage/state.vscdb"], enabledByDefault: false, supportsCustomPaths: false),
        .init(id: "claude", name: "Claude Code", paths: [".claude/projects", ".claude/transcripts"]),
        .init(id: "codex", name: "Codex", paths: [".codex/sessions", ".codex/archived_sessions"]),
        .init(id: "opencode", name: "OpenCode", paths: [".local/share/opencode"], supportsCustomPaths: false),
        .init(id: "hermes", name: "Hermes Agent", paths: [".hermes/state.db"]),
        .init(id: "openclaw", name: "OpenClaw", paths: [".openclaw/agents", ".clawdbot/agents", ".moltbot/agents", ".moldbot/agents"]),
        .init(id: "antigravity", name: "Antigravity", paths: [".gemini/antigravity", ".gemini/antigravity-cli", ".gemini/antigravity-ide", ".gemini/antigravity-backup"], scanIDs: ["antigravity", "antigravity-cli", "antigravity-extension"]),
        .init(id: "cline", name: "Cline", paths: [".cline/data/sessions", "Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/tasks", ".config/Code/User/globalStorage/saoudrizwan.claude-dev/tasks", ".vscode-server/data/User/globalStorage/saoudrizwan.claude-dev/tasks"]),
        .init(id: "amp", name: "Amp", paths: [".local/share/amp/threads"]),
        .init(id: "droid", name: "Factory Droid", paths: [".factory/sessions"]),
        .init(id: "kimi", name: "Kimi", paths: [".kimi/sessions", ".kimi-code/sessions", "Library/Application Support/kimi-desktop"]),
        .init(id: "qwen", name: "Qwen CLI", paths: [".qwen/projects"]),
        .init(id: "grok", name: "Grok Build", paths: [".grok/sessions", ".grok/logs/unified.jsonl"]),
        .init(id: "copilot", name: "GitHub Copilot", paths: [".copilot", "Library/Application Support/Code/User/workspaceStorage"]),
        .init(id: "pi", name: "Pi", paths: [".pi/agent/sessions"]),
        .init(id: "omp", name: "Oh My Pi", paths: [".omp/agent/sessions"]),
        .init(id: "zed", name: "Zed", paths: [".local/share/zed/threads", "Library/Application Support/Zed"]),
        .init(id: "kilo", name: "Kilo", paths: [".local/share/kilo", ".config/Code/User/globalStorage/kilocode.kilo-code/tasks", ".vscode-server/data/User/globalStorage/kilocode.kilo-code/tasks"], scanIDs: ["kilo", "kilocode"]),
        .init(id: "commandcode", name: "Command Code（文本估算）", paths: [".commandcode/projects"]),
        .init(id: "mimo", name: "Xiaomi MiMo（可能含 Claude 导入副本）", paths: [".local/share/mimocode"], scanIDs: ["micode", "micode-desktop"], enabledByDefault: false),
        .init(id: "muse", name: "Muse Code", paths: [".local/share/muse/sessions"]),
        .init(id: "zcode", name: "ZCode", paths: [".zcode"]),
        .init(id: "kiro", name: "Kiro（部分估算）", paths: [".kiro/sessions", ".local/share/kiro-cli/data.sqlite3", "Library/Application Support/Kiro/User/globalStorage/kiro.kiroagent", "Library/Application Support/kiro/User/globalStorage/kiro.kiroagent"]),
        .init(id: "codebuddy", name: "CodeBuddy", paths: [".codebuddy/projects"]),
        .init(id: "workbuddy", name: "WorkBuddy", paths: [".workbuddy", ".workbuddy-ai"]),
        .init(id: "proma", name: "Proma", paths: [".proma/agent-sessions"], supportsCustomPaths: false),
        .init(id: "qodercn", name: "Qoder CN", paths: [".qoder-cn/projects", "Library/Application Support/QoderCN/SharedClientCache/cache/db/local.db"], enabledByDefault: false, supportsCustomPaths: false),
        .init(id: "reasonix", name: "Reasonix", paths: [".reasonix"]),
        .init(id: "dsh", name: "DeepSeek Harness", paths: [".dsh/sessions"]),
        .init(id: "cherrystudio", name: "Cherry Studio", paths: ["Library/Application Support/CherryStudio/Data/Agents/.claude/projects", "Library/Application Support/CherryStudio/.claude/projects"]),
        .init(id: "lmstudio", name: "LM Studio", paths: [".lmstudio/server-logs"]),
        .init(id: "unsloth", name: "Unsloth Studio", paths: [".unsloth/studio/studio.db"]),
        .init(id: "devin", name: "Devin", paths: [".local/share/devin/cli", "Library/Application Support/Devin/User/acp-events"], scanIDs: ["devin-cli", "devin-desktop"]),
        .init(id: "fx", name: "fx", paths: [".fx/sessions"]),
        .init(id: "mcode", name: "MiniMax Code", paths: [".minimax/v2/sessions", ".mavis/v2/sessions"], supportsCustomPaths: false),
        .init(id: "gemini", name: "Gemini CLI", paths: [".gemini/tmp"])
    ]
    static var defaultIDs: [String] { all.filter(\.enabledByDefault).map(\.id) }
    static func detectedIDs(customPaths: [String: [String]] = [:], homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        all.filter { item in
            (resolvedPaths(for: item, homeDirectory: homeDirectory, environment: environment) + (customPaths[item.id] ?? []))
                .contains { FileManager.default.fileExists(atPath: $0) }
        }.map(\.id)
    }
    static func resolvedPaths(for item: Self, homeDirectory: URL, environment: [String: String]) -> [String] {
        func value(_ key: String) -> String? { environment[key].flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } }
        func join(_ root: String, _ suffix: String) -> String { URL(fileURLWithPath: root).appendingPathComponent(suffix).path }
        var paths = item.paths.map { homeDirectory.appendingPathComponent($0).path }
        let roots: [(String, String)] = [(".codex", "CODEX_HOME"), (".claude", "CLAUDE_CONFIG_DIR"), (".gemini", "GEMINI_CLI_HOME"), (".hermes", "HERMES_HOME"), (".grok", "GROK_HOME"), (".dsh", "DSH_HOME"), (".lmstudio", "LM_STUDIO_HOME"), (".unsloth/studio", "UNSLOTH_STUDIO_HOME"), (".local/share", "XDG_DATA_HOME"), (".config", "XDG_CONFIG_HOME")]
        for (prefix, variable) in roots {
            if let root = value(variable) {
                let original = homeDirectory.appendingPathComponent(prefix).path
                paths = paths.map { $0 == original ? root : $0.hasPrefix(original + "/") ? join(root, String($0.dropFirst(original.count + 1))) : $0 }
            }
        }
        switch item.id {
        case "mcode":
            if let root = value("MINIMAX_DATA_DIR") ?? value("MAVIS_DATA_DIR") { paths = [join(root, "v2/sessions")] }
            else {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: homeDirectory.path)) ?? []
                paths += names.filter { $0.hasPrefix(".minimax-") || $0.hasPrefix(".mavis-") }.map { homeDirectory.appendingPathComponent($0 + "/v2/sessions").path }
            }
        case "qodercn":
            if let root = value("TOKEN_MONITOR_QODER_CN_PROJECTS_PATH") ?? value("QODERCN_CONFIG_DIR").map({ join($0, "projects") }) { paths[0] = root }
            if let db = value("TOKEN_MONITOR_QODER_CN_DB_PATH") { paths[1] = db }
        case "cline":
            if let root = value("CLINE_SESSION_DATA_DIR") ?? value("CLINE_DATA_DIR").map({ join($0, "sessions") }) ?? value("CLINE_DIR").map({ join($0, "data/sessions") }) { paths[0] = root }
        case "copilot": if let path = value("COPILOT_OTEL_FILE_EXPORTER_PATH") { paths.append(path) }
        case "kimi": if let root = value("KIMI_CODE_HOME") { paths.append(join(root, "sessions")) }
        case "reasonix": if let root = value("REASONIX_STATE_HOME") ?? value("REASONIX_HOME") { paths = [root] }
        default: break
        }
        if let root = value("TOKSCALE_HEADLESS_DIR"), ["codex", "mcode", "pi", "omp"].contains(item.id) { paths.append(join(root, item.id)) }
        return Array(Set(paths)).sorted()
    }

}

enum UsageEngineFailure: LocalizedError {
    case missingBinary, timeout, cancelled, oversized, malformed, invalidConfiguration(String), process(Int32)
    var errorDescription: String? {
        switch self {
        case .missingBinary: return "本地用量采集引擎缺失，请重新安装当前版本。"
        case .timeout: return "本地用量采集超过 180 秒，已停止本次采集。已有历史保持不变。"
        case .cancelled: return "已取消本地用量采集。"
        case .oversized: return "采集结果超过安全大小上限，请减少同时采集的工具。已有历史保持不变。"
        case .malformed: return "采集结果不完整，已有历史保持不变。"
        case .invalidConfiguration(let message): return message
        case .process(let code): return "本地用量引擎未能完成采集（退出码 \(code)）。已有历史保持不变。"
        }
    }
}

private final class UsageEngineBundleMarker: NSObject {}
private final class UsageScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws { lock.lock(); let value = cancelled; lock.unlock(); if value { throw UsageEngineFailure.cancelled } }
}

enum UsageEngine {
    static let revision = "37e347fedf8fee1059742e9fffa2deb8b4ad3bc9+gqns-3.66"
    static let sourceSHA256 = "3989f5d1eee31842070f484f5fbf996e52ac38c1b86596d7abee64bb8bc2e2c0"
    static let privacyNotice = "本地工具仅分析本机用量记录，不上传会话、提示词或项目路径。Cursor 需单独启用，仅向 cursor.com 官方接口发送现有登录态读取用量。引擎会下载 LiteLLM、OpenRouter 和 models.dev 的公开价格表；费用为估算，并非订阅实际账单。分析数据库不保存正文、标题和原始路径；引擎可重建缓存含会话标题与项目路径，仅保存在本机。"
    static var defaultConfigurationDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GaoSeries/TokenUsageEngine", isDirectory: true)
    }

    static func scan(configuration: UsageEngineConfiguration, engineURL: URL? = nil,
                     configurationDirectory: URL? = nil, homeDirectory: URL? = nil,
                     knownDayFingerprints: [String: String] = [:],
                     onProgress: (@Sendable (String, Int, Int) -> Void)? = nil) async throws -> UsageEngineScan {
        let cancellation = UsageScanCancellation()
        var result = try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .utility) {
                try scanSynchronously(configuration: configuration, engineURL: engineURL,
                    configurationDirectory: configurationDirectory, homeDirectory: homeDirectory,
                    knownDayFingerprints: knownDayFingerprints, cancellation: cancellation, onProgress: onProgress)
            }.value
        }, onCancel: { cancellation.cancel() })
        if configuration.enabledClientIDs.contains("cursor") {
            try Task.checkCancellation()
            do {
                let batch = try await CursorUsageBridge.fetch(onProgress: onProgress)
                result.cursorEvents = batch.events
                if batch.unmeteredEvents > 0 { result.warnings.append("Cursor 官方导出中有 \(batch.unmeteredEvents) 条事件没有 Token 计量，未计入用量或费用，不能视为零用量。") }
                result.clients.append("cursor")
                result.warnings.append("Cursor 费用采用官方计量价值（含套餐内用量），不是实际扣款；仅覆盖官方仍可导出的历史，数据可能延迟。")
            } catch is CancellationError { throw CancellationError() }
            catch { result.warnings.append("Cursor 用量未更新：" + error.localizedDescription + " 已入库历史保留。") }
        }
        return result
    }

    private static func scanSynchronously(configuration: UsageEngineConfiguration, engineURL: URL?,
        configurationDirectory: URL?, homeDirectory: URL?, knownDayFingerprints: [String: String],
        cancellation: UsageScanCancellation, onProgress: (@Sendable (String, Int, Int) -> Void)?) throws -> UsageEngineScan {
        let clients = try validatedClients(configuration).filter { $0 != "cursor" }
        if clients.isEmpty { return .init(capturedAt: Date(), days: [], sessions: [], clients: [], warnings: []) }
        let binary = engineURL ?? Bundle(for: UsageEngineBundleMarker.self).url(forResource: "tokscale", withExtension: nil, subdirectory: "UsageEngine")
        guard let binary, FileManager.default.isExecutableFile(atPath: binary.path) else { throw UsageEngineFailure.missingBinary }
        let configRoot = configurationDirectory ?? defaultConfigurationDirectory
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let selectedDefinitions = UsageClientDefinition.all.filter { clients.contains($0.id) }
        let scanClients = selectedDefinitions.flatMap(\.effectiveScanIDs).joined(separator: ",")
        var environment = safeEnvironment()
        environment["TOKSCALE_CONFIG_DIR"] = configRoot.path
        environment["TOKSCALE_EXTRA_DIRS"] = try extraDirectories(configuration)
        try writePricing(configuration.modelPrices, directory: configRoot)
        let base = ["--client", scanClients, "--no-spinner"] + (homeDirectory.map { ["--home", $0.path] } ?? [])
        let runID = UUID().uuidString
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gqns-usage-\(runID)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let capturedAt = Date()
        onProgress?("正在发现历史日期", 0, 0)
        let graph = try runJSON(RawGraph.self, binary: binary, arguments: ["graph"] + base,
                               environment: environment, temporary: temporary, cancellation: cancellation)
        guard graph.contributions.count <= 100_000 else { throw UsageEngineFailure.oversized }
        let fingerprintEncoder = JSONEncoder(); fingerprintEncoder.outputFormatting = [.sortedKeys]
        let fingerprintSeed = try fingerprintEncoder.encode(configuration).base64EncodedString() + revision
        var fingerprints: [String: String] = [:]
        for day in graph.contributions {
            guard validDay(day.date) else { throw UsageEngineFailure.malformed }
            // Graph client rows originate in hash maps. Sort their canonical
            // encoding so arbitrary iteration order cannot invalidate history.
            let rowSignatures = try day.clients.map { try fingerprintEncoder.encode($0).base64EncodedString() }.sorted()
            let contents = Data((day.date + rowSignatures.joined(separator: "\n")).utf8)
            fingerprints[day.date] = SHA256.hash(data: Data(fingerprintSeed.utf8) + contents).map { String(format: "%02x", $0) }.joined()
        }
        let calendar = Calendar.current
        let today = dayKey(capturedAt)
        let yesterday = dayKey(calendar.date(byAdding: .day, value: -1, to: capturedAt) ?? capturedAt)
        let changedDays = fingerprints.keys.filter { $0 == today || $0 == yesterday || knownDayFingerprints[$0] != fingerprints[$0] }.sorted()
        var days: [UsageDayRow] = []
        var warningCount = 0
        // A day+session key prevents deletion of one source session swallowing
        // later usage in another session. Never distribute all-time sessions by
        // their last-used date: a session can span multiple calendar days.
        for (offset, day) in changedDays.enumerated() {
            try cancellation.check()
            onProgress?("正在分析 \(day)", offset, changedDays.count)
            let report = try runJSON(RawReport.self, binary: binary,
                arguments: ["--json", "--group-by", "client,workspace,session,model", "--since", day, "--until", day] + base,
                environment: environment, temporary: temporary, cancellation: cancellation)
            warningCount += report.warnings?.count ?? 0
            days.append(contentsOf: try decodeReport(report, prices: configuration.modelPrices).map {
                UsageDayRow(day: day, client: $0.client, model: $0.model, sessionID: $0.sessionID, amounts: $0.amounts)
            })
            guard days.count <= 1_000_000 else { throw UsageEngineFailure.oversized }
            onProgress?("已分析 \(day)", offset + 1, changedDays.count)
        }
        onProgress?("正在汇总会话与项目", changedDays.count, changedDays.count)
        environment["GQNS_USAGE_EVENTS"] = "1"
        let report = try runJSON(RawReport.self, binary: binary,
            arguments: ["--json", "--group-by", "client,workspace,session,model", "--since", "1970-01-01"] + base,
            environment: environment, temporary: temporary, cancellation: cancellation)
        warningCount += report.warnings?.count ?? 0
        let sessions = try decodeReport(report, prices: configuration.modelPrices)
        let affected = clients.filter { ["kimi", "antigravity"].contains($0) }
        guard affected.isEmpty || report.localRecords != nil else { throw UsageEngineFailure.malformed }
        let local = try decodeLocalRecords(report.localRecords ?? [], clients: affected, prices: configuration.modelPrices)
        var warnings: [String] = []
        if warningCount > 0 { warnings.append("部分工具的数据源有采集提示，当前结果可能不完整。") }
        if sessions.contains(where: { $0.amounts.totalTokens > 0 && $0.amounts.costUSD == nil }) {
            warnings.append("部分模型没有可验证价格，费用显示为未定价，不按零费用计入。")
        }
        if sessions.contains(where: { ["commandcode", "kiro"].contains($0.client) }) { warnings.append("Command Code 的词元来自文本估算，Kiro 部分记录也可能含估算值；统计精度取决于工具日志。") }
        if clients.contains("mimo") { warnings.append("MiMo 可能保存 Claude 导入的副本，同时启用这两个工具时可能重复统计。") }
        return .init(capturedAt: capturedAt, days: days, sessions: sessions, clients: clients,
                     warnings: warnings, dayFingerprints: fingerprints, localUsage: affected.isEmpty ? nil : local)
    }

    static func decodeReportData(_ data: Data, prices: [UsageModelPrice] = []) throws -> [UsageSessionRow] {
        try decodeReport(JSONDecoder().decode(RawReport.self, from: data), prices: prices)
    }

    private static func decodeReport(_ report: RawReport, prices: [UsageModelPrice]) throws -> [UsageSessionRow] {
        guard report.entries.count <= 1_000_000 else { throw UsageEngineFailure.oversized }
        var metadata: [String: RawSession] = [:]
        for item in report.sessions ?? [] { metadata[item.client + "\u{0}" + item.sessionId] = item }
        var workspaces: [String: RawWorkspace] = [:]
        for item in report.workspaces ?? [] { workspaces[item.workspaceKey] = item }
        let disjointReasoning: Set<String> = ["reasonix", "codex", "droid", "dsh", "zcode", "opencode", "muse", "codebuddy", "workbuddy"]
        let rows = try report.entries.map { row in
            guard !row.client.isEmpty, !row.model.isEmpty, row.client.count <= 100, row.model.count <= 300,
                  [row.input, row.output, row.cacheRead, row.cacheWrite, row.reasoning, row.messageCount].allSatisfy({ $0 >= 0 }),
                  row.cost.isFinite, row.cost >= 0 else { throw UsageEngineFailure.malformed }
            let sessionID = row.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Session-grouped rows are expected to identify a source session.
            // Missing identity must not collapse unrelated history into one key.
            guard !sessionID.isEmpty, sessionID.count <= 4096 else { throw UsageEngineFailure.malformed }
            let reasoning = disjointReasoning.contains(row.client) ? row.reasoning : 0
            var amounts = UsageAmounts(input: row.input, output: row.output, cacheRead: row.cacheRead,
                cacheWrite: row.cacheWrite, reasoning: reasoning, costUSD: row.cost > 0 ? row.cost : nil, messageCount: row.messageCount)
            // A positive upstream cost wins even when a partial custom price
            // looks free; the scanner may have retained a billed 1-hour cache
            // component which this grouped row cannot separately identify.
            if row.cost == 0 && (amounts.totalTokens == 0 || explicitlyFree(row: row, prices: prices)) { amounts.costUSD = 0 }
            let meta = metadata[row.client + "\u{0}" + sessionID]
            let workspace = row.workspaceKey.flatMap { workspaces[$0] }
            let projectPath = workspace?.path.flatMap { $0.hasPrefix("/") ? $0 : nil }
            let projectKey = projectPath.map { SHA256.hash(data: Data(URL(fileURLWithPath: $0).standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined() }
            let projectLabel = projectPath.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : String($0.prefix(160)) }
            let client = canonicalClient(row.client)
            let stableSessionID = client == row.client ? sessionID : row.client + ":" + sessionID
            return UsageSessionRow(client: client, sessionID: stableSessionID, model: row.model,
                projectKey: projectKey, projectLabel: projectLabel,
                firstActive: date(meta?.firstActiveMs), lastActive: date(meta?.lastActiveMs), amounts: amounts,
                timedTokens: min(amounts.totalTokens, max(0, row.performance?.timedTokens ?? 0)),
                timedDurationMS: max(0, row.performance?.totalDurationMs ?? 0))
        }
        // Workspace is a report dimension but not a session identity. A
        // session which changes directory can produce several rows; sum those
        // rows before handing the snapshot to the ledger's high-water merge.
        var combined: [String: UsageSessionRow] = [:]
        func add(_ lhs: Int64, _ rhs: Int64) -> Int64 {
            let (value, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? .max : value
        }
        for row in rows {
            let key = row.client + "\u{0}" + row.sessionID + "\u{0}" + row.model
            guard var saved = combined[key] else { combined[key] = row; continue }
            saved.amounts.input = add(saved.amounts.input, row.amounts.input)
            saved.amounts.output = add(saved.amounts.output, row.amounts.output)
            saved.amounts.cacheRead = add(saved.amounts.cacheRead, row.amounts.cacheRead)
            saved.amounts.cacheWrite = add(saved.amounts.cacheWrite, row.amounts.cacheWrite)
            saved.amounts.reasoning = add(saved.amounts.reasoning, row.amounts.reasoning)
            saved.amounts.messageCount = add(saved.amounts.messageCount, row.amounts.messageCount)
            if let left = saved.amounts.costUSD, let right = row.amounts.costUSD, (left + right).isFinite {
                saved.amounts.costUSD = left + right
            } else { saved.amounts.costUSD = nil }
            saved.timedTokens = add(saved.timedTokens, row.timedTokens)
            saved.timedDurationMS = add(saved.timedDurationMS, row.timedDurationMS)
            saved.firstActive = [saved.firstActive, row.firstActive].compactMap { $0 }.min()
            saved.lastActive = [saved.lastActive, row.lastActive].compactMap { $0 }.max()
            if saved.projectKey != row.projectKey { saved.projectKey = nil; saved.projectLabel = nil }
            combined[key] = saved
        }
        return combined.keys.sorted().compactMap { combined[$0] }
    }

    private static func canonicalClient(_ id: String) -> String {
        switch id {
        case "antigravity-cli", "antigravity-extension": return "antigravity"
        case "micode", "micode-desktop": return "mimo"
        case "kilocode": return "kilo"
        case "devin-cli", "devin-desktop": return "devin"
        default: return id
        }
    }
    private static func explicitlyFree(row: RawEntry, prices: [UsageModelPrice]) -> Bool {
        guard let price = prices.last(where: { $0.model == row.model }) else { return false }
        return (row.input == 0 || price.inputPerMillion == 0)
            && ((row.output == 0 && row.reasoning == 0) || price.outputPerMillion == 0)
            && (row.cacheRead == 0 || price.cacheReadPerMillion == 0)
            && (row.cacheWrite == 0 || (price.cacheWritePerMillion == 0 && price.cacheWrite1hPerMillion == 0))
    }
    private static func date(_ milliseconds: Int64?) -> Date? {
        guard let milliseconds, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
    private static func dayKey(_ value: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: value)
    }
    private static func validDay(_ value: String) -> Bool {
        value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }
    private static func validatedClients(_ configuration: UsageEngineConfiguration) throws -> [String] {
        let supported = Set(UsageClientDefinition.all.map(\.id))
        guard configuration.enabledClientIDs.allSatisfy(supported.contains) else {
            throw UsageEngineFailure.invalidConfiguration("存在当前引擎不支持的工具，请重新选择采集工具。")
        }
        return UsageClientDefinition.all.map(\.id).filter { configuration.enabledClientIDs.contains($0) }
    }
    private static func extraDirectories(_ configuration: UsageEngineConfiguration) throws -> String {
        var result: [String] = []
        for item in UsageClientDefinition.all where configuration.enabledClientIDs.contains(item.id) {
            let paths = configuration.customPaths[item.id] ?? []
            guard paths.count <= 16, paths.isEmpty || item.supportsCustomPaths else {
                throw UsageEngineFailure.invalidConfiguration("\(item.name) 不支持这些自定义扫描目录。")
            }
            for path in Set(paths).sorted() {
                guard path.hasPrefix("/"), path.count <= 4096,
                      path.rangeOfCharacter(from: CharacterSet(charactersIn: ",\n\r\0")) == nil else {
                    throw UsageEngineFailure.invalidConfiguration("扫描目录必须是绝对路径，且不能含逗号或换行。")
                }
                let ids = item.id == "kilo" ? ["kilocode"] : item.id == "antigravity" ? ["antigravity", "antigravity-cli"] : item.effectiveScanIDs
                result.append(contentsOf: ids.map { $0 + ":" + path })
            }
        }
        guard result.count <= 128 else { throw UsageEngineFailure.invalidConfiguration("自定义扫描目录过多。") }
        return result.joined(separator: ",")
    }
    private static func safeEnvironment() -> [String: String] {
        let allowed = Set(["PATH", "TMPDIR", "LANG", "LC_ALL", "TZ", "HOME", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "CODEX_HOME", "CLAUDE_CONFIG_DIR", "GROK_HOME", "HERMES_HOME", "KIMI_CODE_HOME", "UNSLOTH_STUDIO_HOME", "LM_STUDIO_HOME", "DSH_HOME", "REASONIX_STATE_HOME", "REASONIX_HOME", "GEMINI_CLI_HOME", "MINIMAX_DATA_DIR", "MAVIS_DATA_DIR", "TOKEN_MONITOR_QODER_CN_DB_PATH", "TOKEN_MONITOR_QODER_CN_PROJECTS_PATH", "QODERCN_CONFIG_DIR", "CLINE_SESSION_DATA_DIR", "CLINE_DATA_DIR", "CLINE_DIR", "COPILOT_OTEL_FILE_EXPORTER_PATH", "TOKSCALE_HEADLESS_DIR"])
        return ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private static func writePricing(_ prices: [UsageModelPrice], directory: URL) throws {
        var models: [String: [String: Double]] = [:]
        guard prices.count <= 500 else { throw UsageEngineFailure.invalidConfiguration("自定义价格最多支持 500 个模型。") }
        for price in prices {
            guard !price.model.isEmpty, price.model.count <= 300 else { throw UsageEngineFailure.invalidConfiguration("价格配置缺少模型名称。") }
            let values: [(String, Double?)] = [("input_cost_per_million_tokens", price.inputPerMillion), ("output_cost_per_million_tokens", price.outputPerMillion), ("cache_read_input_token_cost_per_million_tokens", price.cacheReadPerMillion), ("cache_creation_input_token_cost_per_million_tokens", price.cacheWritePerMillion), ("cache_creation_input_token_cost_per_million_tokens_above_1hr", price.cacheWrite1hPerMillion)]
            guard values.allSatisfy({ $0.1 == nil || ($0.1!.isFinite && $0.1! >= 0) }), price.inputPerMillion != nil || price.outputPerMillion != nil else {
                throw UsageEngineFailure.invalidConfiguration("模型价格必须为非负数，并至少填写输入或输出价格。")
            }
            models[price.model] = Dictionary(uniqueKeysWithValues: values.compactMap { key, value in value.map { (key, $0) } })
        }
        let data = try JSONSerialization.data(withJSONObject: ["models": models], options: [.sortedKeys])
        let url = directory.appendingPathComponent("custom-pricing.json")
        if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func runJSON<T: Decodable>(_ type: T.Type, binary: URL, arguments: [String], environment: [String: String], temporary: URL, cancellation: UsageScanCancellation) throws -> T {
        try cancellation.check()
        let output = temporary.appendingPathComponent(UUID().uuidString + ".json")
        let errorOutput = temporary.appendingPathComponent(UUID().uuidString + ".stderr")
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: errorOutput.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: output); try? FileManager.default.removeItem(at: errorOutput) }
        let out = try FileHandle(forWritingTo: output), err = try FileHandle(forWritingTo: errorOutput)
        defer { try? out.close(); try? err.close() }
        let process = Process(); process.executableURL = binary; process.arguments = arguments
        process.environment = environment; process.standardOutput = out; process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(180)
        do {
            while process.isRunning {
                try cancellation.check()
                if Date() >= deadline { throw UsageEngineFailure.timeout }
                let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let errorSize = (try? errorOutput.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 200 * 1024 * 1024 || errorSize > 1024 * 1024 { throw UsageEngineFailure.oversized }
                Thread.sleep(forTimeInterval: 0.1)
            }
        } catch {
            if process.isRunning { process.terminate() }
            let grace = Date().addingTimeInterval(1)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UsageEngineFailure.process(process.terminationStatus) }
        try out.synchronize()
        let size = (try output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 200 * 1024 * 1024 else { throw UsageEngineFailure.oversized }
        do { return try JSONDecoder().decode(type, from: Data(contentsOf: output, options: .mappedIfSafe)) }
        catch { throw UsageEngineFailure.malformed }
    }

    private struct RawReport: Decodable {
        var entries: [RawEntry]
        var localRecords: [RawLocalRecord]?
        var sessions: [RawSession]?
        var workspaces: [RawWorkspace]?
        var warnings: [String]?
    }
    private struct RawLocalRecord: Decodable {
        var eventId: String; var client: String; var sessionId: String; var model: String
        var timestamp: Int64; var input: Int64; var output: Int64
        var cacheRead: Int64; var cacheWrite: Int64; var messageCount: Int64
        var cost: Double; var durationMs: Int64; var workspacePath: String?
    }
    static func decodeLocalReportData(_ data: Data, clients: [String], prices: [UsageModelPrice] = []) throws -> LocalUsageBatch {
        let report = try JSONDecoder().decode(RawReport.self, from: data)
        guard let records = report.localRecords else { throw UsageEngineFailure.malformed }
        return try decodeLocalRecords(records, clients: clients, prices: prices)
    }
    private static func decodeLocalRecords(_ records: [RawLocalRecord], clients: [String], prices: [UsageModelPrice]) throws -> LocalUsageBatch {
        guard records.count <= 1_000_000 else { throw UsageEngineFailure.oversized }
        var events: [String: LocalUsageEvent] = [:]
        var days: [String: UsageDayRow] = [:], sessions: [String: UsageSessionRow] = [:]
        func add(_ a: UsageAmounts, _ b: UsageAmounts) throws -> UsageAmounts {
            func sum(_ a: Int64, _ b: Int64) throws -> Int64 { let (v,o)=a.addingReportingOverflow(b); if o {throw UsageEngineFailure.oversized}; return v }
            return try .init(input:sum(a.input,b.input),output:sum(a.output,b.output),cacheRead:sum(a.cacheRead,b.cacheRead),cacheWrite:sum(a.cacheWrite,b.cacheWrite),costUSD:a.costUSD.flatMap { l in b.costUSD.map { l + $0 } },messageCount:sum(a.messageCount,b.messageCount))
        }
        for raw in records {
            guard clients.contains(raw.client), ["kimi","antigravity"].contains(raw.client),
                  raw.eventId.count == 64, raw.eventId.allSatisfy({$0.isHexDigit}),
                  !raw.sessionId.isEmpty, raw.sessionId.count <= 4096, !raw.model.isEmpty, raw.model.count <= 300,
                  raw.timestamp > 0, [raw.input,raw.output,raw.cacheRead,raw.cacheWrite,raw.messageCount,raw.durationMs].allSatisfy({$0 >= 0}),
                  raw.cost.isFinite, raw.cost >= 0 else {throw UsageEngineFailure.malformed}
            let token = RawEntry(client:raw.client,model:raw.model,sessionId:raw.sessionId,input:raw.input,output:raw.output,cacheRead:raw.cacheRead,cacheWrite:raw.cacheWrite,reasoning:0,messageCount:raw.messageCount,cost:raw.cost)
            let amounts = UsageAmounts(input:raw.input,output:raw.output,cacheRead:raw.cacheRead,cacheWrite:raw.cacheWrite,costUSD:raw.cost > 0 ? raw.cost : explicitlyFree(row:token,prices:prices) ? 0 : nil,messageCount:raw.messageCount)
            let time = Date(timeIntervalSince1970:Double(raw.timestamp)/1000)
            let path = raw.workspacePath.flatMap {$0.hasPrefix("/") ? $0 : nil}
            let key = path.map { SHA256.hash(data:Data(URL(fileURLWithPath:$0).standardizedFileURL.path.utf8)).map {String(format:"%02x",$0)}.joined() }
            let label = path.map {String(URL(fileURLWithPath:$0).lastPathComponent.prefix(160))}
            let event = LocalUsageEvent(eventID:raw.eventId,client:raw.client,sessionID:raw.sessionId,model:raw.model,timestamp:time,projectKey:key,projectLabel:label,durationMS:raw.durationMs,amounts:amounts)
            let identity = raw.client + ":" + raw.eventId
            if var old = events[identity] {
                guard old.model == event.model else {throw UsageEngineFailure.malformed}
                old.amounts.input=max(old.amounts.input,amounts.input); old.amounts.output=max(old.amounts.output,amounts.output)
                old.amounts.cacheRead=max(old.amounts.cacheRead,amounts.cacheRead); old.amounts.cacheWrite=max(old.amounts.cacheWrite,amounts.cacheWrite)
                old.amounts.messageCount=max(old.amounts.messageCount,amounts.messageCount)
                old.amounts.costUSD = [old.amounts.costUSD,amounts.costUSD].compactMap {$0}.max()
                old.durationMS=max(old.durationMS,event.durationMS)
                events[identity]=old
            } else {events[identity]=event}
            let sessionKey = raw.client + "\0" + raw.sessionId + "\0" + raw.model
            let day = dayKey(time), dayIdentity = day + "\0" + sessionKey
            if var saved = days[dayIdentity] {saved.amounts=try add(saved.amounts,amounts);days[dayIdentity]=saved}
            else {days[dayIdentity] = .init(day:day,client:raw.client,model:raw.model,sessionID:raw.sessionId,amounts:amounts)}
            if var saved = sessions[sessionKey] {
                saved.amounts=try add(saved.amounts,amounts);saved.firstActive=min(saved.firstActive ?? time,time);saved.lastActive=max(saved.lastActive ?? time,time)
                sessions[sessionKey]=saved
            } else {sessions[sessionKey] = .init(client:raw.client,sessionID:raw.sessionId,model:raw.model,projectKey:key,projectLabel:label,firstActive:time,lastActive:time,amounts:amounts,timedTokens:raw.durationMs > 0 ? amounts.totalTokens : 0,timedDurationMS:raw.durationMs)}
        }
        return .init(clients:clients,events:events.keys.sorted().compactMap {events[$0]},coverageDays:days.keys.sorted().compactMap {days[$0]},coverageSessions:sessions.keys.sorted().compactMap {sessions[$0]})
    }
    private struct RawEntry: Decodable {
        var client: String; var model: String; var sessionId: String?
        var workspaceKey: String?; var workspaceLabel: String?
        var input: Int64; var output: Int64; var cacheRead: Int64; var cacheWrite: Int64
        var reasoning: Int64; var messageCount: Int64; var cost: Double
        var performance: RawPerformance?
    }
    private struct RawPerformance: Decodable { var timedTokens: Int64; var totalDurationMs: Int64 }
    private struct RawSession: Decodable { var client: String; var sessionId: String; var firstActiveMs: Int64; var lastActiveMs: Int64 }
    private struct RawWorkspace: Decodable { var workspaceKey: String; var label: String; var path: String? }
    private struct RawGraph: Decodable { var contributions: [RawGraphDay] }
    private struct RawGraphDay: Codable {
        var date: String
        var clients: [RawGraphClient]
    }
    private struct RawGraphClient: Codable {
        var client: String; var modelId: String; var tokens: RawTokens; var cost: Double; var messages: Int64
    }
    private struct RawTokens: Codable { var input: Int64; var output: Int64; var cacheRead: Int64; var cacheWrite: Int64; var reasoning: Int64 }
}
