import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum UsageRange: String, CaseIterable, Identifiable {
    case today, week, month30, calendarMonth, all
    var id: String { rawValue }
    var title: String { switch self { case .today: "今天"; case .week: "近 7 天"; case .month30: "近 30 天"; case .calendarMonth: "本月"; case .all: "全部" } }
    var fromDay: String? {
        let cal = Calendar.current; let now = Date()
        switch self {
        case .today: return Self.day(now)
        case .week: return Self.day(cal.date(byAdding: .day, value: -6, to: now) ?? now)
        case .month30: return Self.day(cal.date(byAdding: .day, value: -29, to: now) ?? now)
        case .calendarMonth: return Self.day(cal.dateInterval(of: .month, for: now)?.start ?? now)
        case .all: return nil
        }
    }
    static func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year,.month,.day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0,c.month ?? 0,c.day ?? 0)
    }
}
enum UsageExportFormat { case csv, json }

struct UsageAnalyticsPreferences: Codable {
    var engine = UsageEngineConfiguration()
    var automaticallyScan = true
    var refreshMinutes = 5
}

@MainActor final class UsageAnalyticsStore: ObservableObject {
    @Published var selectedRange: UsageRange = .month30
    @Published private(set) var dashboard = UsageLedgerDashboard.empty
    @Published private(set) var sessionSummary = UsageLedgerSessionSummary.empty
    @Published private(set) var sessions = UsageLedgerSessionPage.empty
    @Published private(set) var isRefreshing = false
    @Published var errorMessage: String?
    @Published private(set) var warnings: [String] = []
    @Published private(set) var lastScanAt: Date?
    @Published private(set) var progressMessage: String?
    @Published var showSourceSettings = false
    @Published private(set) var preferences = UsageAnalyticsPreferences()
    @Published private(set) var automaticExportPath: String?
    let directory: URL
    let ledger: UsageLedger
    private var timer: Timer?
    private var restoreObserver: NSObjectProtocol?
    private var started = false
    private var revision = 0
    private var queryRevision = 0
    private var settingsFailed = false
    private var scanTask: Task<Void, Never>?
    private var scanToken: UUID?
    private var scanIsAutomatic = false
    private var automaticRefreshEnabled = true
    private var suspended = false
    private var pendingAutomaticScan = false
    private var needsReindex = false
    typealias Scan = (UsageEngineConfiguration, URL, [String: String], @escaping @Sendable (String, Int, Int) -> Void) async throws -> UsageEngineScan
    private let scan: Scan
    @Published private(set) var isLoadingSessions = false
    @Published private(set) var sessionOffset = 0
    private var lastAttemptAt = Date.distantPast
    private var settingsURL: URL { directory.appendingPathComponent("usage-settings.json") }
    init(directory: URL, scan: @escaping Scan = { configuration, cache, known, progress in
        try await UsageEngine.scan(configuration: configuration, configurationDirectory: cache,
                                   knownDayFingerprints: known, onProgress: progress)
    }) {
        self.directory = directory
        self.scan = scan
        ledger = UsageLedger(directory: directory)
        readPreferences()
        automaticExportPath = TokenBundle.defaults.string(forKey: "actualUsageAutoExportDirectory")
        restoreObserver = NotificationCenter.default.addObserver(forName: UsageLedger.didRestoreNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.revision += 1; self.scanTask?.cancel(); self.pendingAutomaticScan = false
                self.readPreferences()
                // An imported backup must not silently authorize writes to an external folder.
                self.disableAutomaticExport()
                self.reload()
            }
        }
    }
    private func readPreferences() {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            preferences = UsageAnalyticsPreferences(); settingsFailed = false; return
        }
        do { preferences = try JSONDecoder().decode(UsageAnalyticsPreferences.self, from: Data(contentsOf: settingsURL)); settingsFailed = false }
        catch { settingsFailed = true; errorMessage = "用量采集设置读取失败，原文件已保留。请检查完整备份。" }
    }
    func start() {
        guard !started, ProcessInfo.processInfo.environment["GAOQINIANSAN_INTEGRATION_TEST"] != "1" else { return }
        started = true
        reload()
        if mayAutomaticallyScan { refresh(userInitiated: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.mayAutomaticallyScan,
                      Date().timeIntervalSince(max(self.lastScanAt ?? .distantPast, self.lastAttemptAt)) >= Double(max(2, self.preferences.refreshMinutes)) * 60 else { return }
                self.refresh(userInitiated: false)
            }
        }
    }
    private var mayAutomaticallyScan: Bool {
        automaticRefreshEnabled && preferences.automaticallyScan && !settingsFailed && !suspended
    }
    func setAutomaticRefreshEnabled(_ enabled: Bool) {
        automaticRefreshEnabled = enabled
        if !enabled {
            pendingAutomaticScan = false
            if scanIsAutomatic { scanTask?.cancel() }
        }
    }
    func setSuspended(_ value: Bool) {
        suspended = value
        if value { pendingAutomaticScan = false; revision += 1; scanTask?.cancel() }
    }
    func stop() {
        timer?.invalidate(); timer = nil; started = false
        setSuspended(true)
    }
    private func finishScan(_ token: UUID) {
        guard scanToken == token else { return }
        scanToken = nil; scanTask = nil; scanIsAutomatic = false
        isRefreshing = false; progressMessage = nil
        if pendingAutomaticScan && mayAutomaticallyScan {
            pendingAutomaticScan = false
            refresh(forceReindex: needsReindex, userInitiated: false)
        }
    }
    func refresh(forceReindex: Bool = false, userInitiated: Bool = true) {
        guard !isRefreshing, !settingsFailed, !suspended, userInitiated || mayAutomaticallyScan else { return }
        lastAttemptAt = .now
        isRefreshing = true; errorMessage = nil; progressMessage = "正在检查本机用量日志…"
        let version = revision; let generation = UsageLedger.restoreGeneration(); let configuration = preferences.engine
        let reindex = forceReindex || needsReindex, token = UUID()
        scanToken = token; scanIsAutomatic = !userInitiated
        scanTask = Task { [self] in
            defer { self.finishScan(token) }
            do {
                try Task.checkCancellation()
                let known = reindex ? [:] : try await ledger.knownDayFingerprints()
                try Task.checkCancellation()
                let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("GaoSeries/TokenUsageEngine")
                let scan = try await HTTPPolicyContext.$userInitiated.withValue(userInitiated) {
                    try await HTTPPolicyContext.$trigger.withValue(userInitiated ? "history.manual" : "history.automatic") {
                        try await self.scan(configuration, cache, known, { [weak self] text, done, total in
                            Task { @MainActor in
                                guard let self, self.revision == version, self.scanToken == token else { return }
                                self.progressMessage = total > 0 ? "\(text) · \(done)/\(total) 天" : text
                            }
                        })
                    }
                }
                try Task.checkCancellation()
                guard version == revision else { return }
                try await ledger.ingest(scan, expectedGeneration: generation)
                try Task.checkCancellation()
                guard version == revision else { return }
                needsReindex = false
                lastScanAt = scan.capturedAt; warnings = scan.warnings
                reload()
                if let path = automaticExportPath {
                    do {
                        let identity = try await ledger.metadata().deviceID
                        let target = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("搞词元-用量-\(identity).json")
                        try await ledger.export(to: target)
                    } catch {
                        if !Task.isCancelled, version == revision { errorMessage = "用量已保存，但自动导出失败：" + error.localizedDescription }
                    }
                }
            } catch is CancellationError {} catch {
                if version == revision && !Task.isCancelled { errorMessage = "采集未完成，已保存的历史仍然保留。\n" + error.localizedDescription }
            }
        }
    }
    func reload() {
        queryRevision += 1; let request = queryRevision; let from = selectedRange.fromDay
        Task {
            do {
                let result = try await ledger.dashboard(fromDay: from, throughDay: UsageRange.day(.now))
                let summary = try await ledger.sessionSummary()
                let page = try await ledger.sessionPage(offset: 0, limit: 50)
                guard request == queryRevision else { return }
                dashboard = result; sessionSummary = summary; sessions = page; sessionOffset = 0
                lastScanAt = try await ledger.metadata().lastScanAt
            } catch { guard request == queryRevision else { return }; errorMessage = "用量历史读取失败：" + error.localizedDescription }
        }
    }
    func loadNextSessions() { loadSessionPage(offset: sessionOffset + 50) }
    func loadPreviousSessions() { loadSessionPage(offset: max(0, sessionOffset - 50)) }
    private func loadSessionPage(offset: Int) {
        guard !isLoadingSessions, offset >= 0, offset < sessions.totalCount else { return }
        isLoadingSessions = true; let request = queryRevision
        Task {
            defer { isLoadingSessions = false }
            do {
                let page = try await ledger.sessionPage(offset: offset, limit: 50)
                guard request == queryRevision else { return }
                sessions = page; sessionOffset = offset
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func savePreferences(_ candidate: UsageAnalyticsPreferences) {
        guard (2...60).contains(candidate.refreshMinutes) else { errorMessage = "自动采集间隔应为 2–60 分钟。"; return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(candidate).write(to: settingsURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
            let engineChanged = preferences.engine != candidate.engine
            let wasAutomatic = preferences.automaticallyScan
            preferences = candidate; settingsFailed = false
            showSourceSettings = false
            if engineChanged {
                // Prices are not part of source fingerprints; next authorized scan reindexes.
                needsReindex = true; revision += 1; scanTask?.cancel()
            } else if !candidate.automaticallyScan && scanIsAutomatic { scanTask?.cancel() }
            pendingAutomaticScan = mayAutomaticallyScan && (engineChanged || !wasAutomatic)
            if pendingAutomaticScan && !isRefreshing {
                pendingAutomaticScan = false
                refresh(forceReindex: needsReindex, userInitiated: false)
            }
        } catch { errorMessage = "采集设置保存失败：" + error.localizedDescription }
    }
    func chooseAutomaticExportDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = "每次采集后更新本机 JSON。可选择同步盘文件夹；文件包含项目与用量元数据，不包含对话正文或密钥。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        automaticExportPath = url.path; TokenBundle.defaults.set(url.path, forKey: "actualUsageAutoExportDirectory")
    }
    func disableAutomaticExport() { automaticExportPath = nil; TokenBundle.defaults.removeObject(forKey: "actualUsageAutoExportDirectory") }
    func exportUsage(format: UsageExportFormat) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [format == .json ? .json : .commaSeparatedText]
        panel.nameFieldStringValue = "搞词元-用量-\(UsageRange.day(.now)).\(format == .json ? "json" : "csv")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let from = selectedRange.fromDay
        Task {
            do {
                if format == .json { try await ledger.export(to: url) }
                else { try await ledger.exportCSV(to: url, fromDay: from, throughDay: UsageRange.day(.now)) }
            } catch { errorMessage = "导出失败：" + error.localizedDescription }
        }
    }
    func importUsage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        panel.message = "选择另一台设备导出的搞词元用量 JSON；相同设备与会话重复导入不会重复累计。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await ledger.importFile(url); reload() }
            catch { errorMessage = "合并失败，现有记录保持不变：" + error.localizedDescription }
        }
    }
}
