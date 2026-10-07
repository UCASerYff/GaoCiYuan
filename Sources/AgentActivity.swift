import Foundation

// 阶段 4B：活跃指示（Active Turn）。移植 Pulse Usage/AgentActivity.swift 的设计（见 pulse-分析报告 §8）。
//
// 「最近 N 秒有写入」双向都不准：慢工具几分钟不写（误判闲），写完后继续转 N 秒（误判忙）。
// 两家 CLI 在记录里直接写明 turn 状态，所以只读最新 transcript 的尾部，答案是精确的：
// - Claude Code：assistant 记录的 stop_reason——tool_use=在等工具、end_turn=结束；
//   尾部 user 记录=轮到模型，除非它是中断记录（[Request interrupted by user）。
// - Codex：task_started/task_complete/turn_aborted 包夹 turn；tool call 与其 output 区分
//   在跑工具还是在等模型。
// 宽限分级（Pulse 按 3110+2783 个真实 turn 测量）：等模型 90s、等工具 5 分钟——
// 从记录自己的时间戳起算而非文件 mtime（Claude Code 在 turn 结束后还写 bookkeeping）。

enum AgentActivity {
    /// 活跃判定针对本机 CLI，不按账户枚举：Claude 系账户看 .claude，Codex（OpenAI agent）看 .codex。
    enum Subject: String, CaseIterable, Sendable {
        case claude, codex

        /// 账户对应的活跃主体；非 agent 账户与不写 transcript 的平台为 nil。
        init?(account: Account) {
            guard account.kind == .agent else { return nil }
            switch account.provider {
            case .claude: self = .claude
            case .openai: self = .codex
            default: return nil
            }
        }
    }

    struct State: Sendable, Equatable {
        var lastWrite: Date?
        var isWorking: Bool
    }

    /// 进行中的 turn 在等什么——决定它的「工作中」声明可以比记录本身多活多久。
    /// 等模型：中位 7s、99% 在 70s 内 → 90s。等工具：shell/构建/测试不写文件，实测最长 15 分钟 → 5 分钟。
    enum Wait: Equatable {
        case tool
        case model

        var grace: TimeInterval {
            switch self {
            case .tool: 5 * 60
            case .model: 90
            }
        }
    }

    /// 尾部看不出名堂（格式变了/还太新）时回落「30 秒内写过」。
    static let unknownFormatWindow: TimeInterval = 30

    /// 根目录可注入（测试指向临时目录）。
    static var claudeRoot: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
    static var codexRoot: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")

    static func root(for subject: Subject) -> URL {
        switch subject {
        case .claude: claudeRoot
        case .codex: codexRoot
        }
    }

    // MARK: - 3.39 分层采样：全量枚举低频化

    /// 实测 ~/.codex 可达 1.1 万个文件——每 2 秒全目录递归枚举会让 CPU 常驻两位数。
    /// 文件清单按主体缓存 60 秒；2 秒活跃档只重新 stat 缓存清单里「仍可能活着」的
    /// 少数文件（最新 8 个 + 仍在最长宽限期内的），几次系统调用几乎免费。
    /// 新 session 文件的发现靠低频全量枚举补充；UI 进入视野（悬浮条展开/主窗口可见）
    /// 时由 AgentActivityMonitor 强制补一次即时全量。
    static let fileListTTL: TimeInterval = 60
    /// 快路径每次最多重新 stat 的最新文件数（覆盖「两个终端同时跑」还有富余）。
    private static let fastPathRestatCount = 8
    private static let cacheLock = NSLock()
    private static var fileListCache: [Subject: (scannedAt: Date, files: [(url: URL, modified: Date)])] = [:]

    static func states(now: Date = Date()) -> [Subject: State] {
        states(now: now, forceFullScan: false)
    }

    static func states(now: Date, forceFullScan: Bool) -> [Subject: State] {
        var states: [Subject: State] = [:]
        for subject in Subject.allCases {
            let files = transcriptsCached(for: subject, now: now, forceFullScan: forceFullScan)
            var state = State(lastWrite: files.first?.modified, isWorking: false)
            // 任意活跃 session 都算：两个终端可以同时跑，最新文件不一定是忙的那个。
            // 过滤阈值是最长宽限，更老的文件不值得打开。
            for file in files where now.timeIntervalSince(file.modified) <= Wait.tool.grace {
                switch verdict(for: file.url, subject: subject) {
                case .working(let wait, let at):
                    // 从记录自己的时间戳起算，不是文件 mtime。
                    state.isWorking = now.timeIntervalSince(at ?? file.modified) <= wait.grace
                case .finished:
                    continue
                case .unknown:
                    state.isWorking = now.timeIntervalSince(file.modified) <= unknownFormatWindow
                }
                if state.isWorking { break }
            }
            states[subject] = state
        }
        return states
    }

    /// 缓存新鲜则走快路径（重 stat 少数活文件），过期或强制才全量枚举。
    private static func transcriptsCached(for subject: Subject, now: Date, forceFullScan: Bool) -> [(url: URL, modified: Date)] {
        cacheLock.lock()
        let cached = fileListCache[subject]
        cacheLock.unlock()
        if !forceFullScan, let cached, now.timeIntervalSince(cached.scannedAt) < fileListTTL {
            return refreshKnownFiles(cached.files, now: now)
        }
        let files = transcripts(for: subject)
        cacheLock.lock()
        fileListCache[subject] = (scannedAt: now, files: files)
        cacheLock.unlock()
        return files
    }

    /// 快路径：最新 fastPathRestatCount 个 + 仍在宽限期内的文件重新 stat（发现持续写入与 turn 结束）；
    /// 更老的文件沿用缓存 mtime——它们已经超出最长宽限，mtime 变化也不改变判定。
    private static func refreshKnownFiles(_ files: [(url: URL, modified: Date)], now: Date) -> [(url: URL, modified: Date)] {
        var result: [(url: URL, modified: Date)] = []
        result.reserveCapacity(files.count)
        for (index, file) in files.enumerated() {
            if index < fastPathRestatCount || now.timeIntervalSince(file.modified) <= Wait.tool.grace {
                let fresh = (try? file.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? file.modified
                result.append((url: file.url, modified: fresh))
            } else {
                result.append(file)
            }
        }
        return result.sorted { $0.modified > $1.modified }
    }

    // MARK: - 读尾部

    enum Verdict: Equatable {
        /// 有 turn 在进行，在等 wait，时间点是下这条记录的时刻（无时间戳=半识别的格式）。
        case working(Wait, at: Date?)
        case finished
        case unknown
    }

    /// 从 transcript 末尾倒着找第一条有结论的记录：20MB 的文件只花几 KB。
    static func verdict(for url: URL, subject: Subject) -> Verdict {
        for line in tail(of: url).reversed() {
            guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }

            switch subject {
            case .claude:
                switch record["type"] as? String {
                case "assistant":
                    let stop = (record["message"] as? [String: Any])?["stop_reason"] as? String
                    guard let stop else {
                        // 无 stop_reason 是 subagent 内联记录：后台 agent 比启动它的 turn 活得久，
                        // 它常是文件最后一行。按「等模型」处理，只给 model 宽限。
                        return .working(.model, at: stamp(of: record))
                    }
                    return stop == "tool_use"
                        ? .working(.tool, at: stamp(of: record))
                        : .finished
                case "user":
                    // 按 Esc 结束 turn 会留下中断记录；读成普通 prompt 意思正好相反。
                    if isClaudeInterruption(record) { return .finished }
                    // 否则是 prompt 或工具结果回来：下一步都轮到模型。
                    return .working(.model, at: stamp(of: record))
                default:
                    // bookkeeping（queued/附件/窗口标题）对 turn 无话可说。
                    continue
                }

            case .codex:
                switch (record["payload"] as? [String: Any])?["type"] as? String {
                case "task_complete", "turn_aborted":
                    return .finished
                case "task_started":
                    return .working(.model, at: stamp(of: record))
                // 调用与结果分两条记录：尾部停在哪条，就是 turn 的哪一半在跑。
                case "function_call", "custom_tool_call", "local_shell_call",
                     "web_search_call", "tool_search_call":
                    return .working(.tool, at: stamp(of: record))
                case "function_call_output", "custom_tool_call_output", "tool_search_output":
                    return .working(.model, at: stamp(of: record))
                default:
                    continue
                }
            }
        }
        return .unknown
    }

    /// Claude Code 把被中断的 turn 记成一条说明性的 user 消息——这是文件里唯一区分
    /// 「用户停掉的 turn」与「马上要被回答的 prompt」的标记。
    static func isClaudeInterruption(_ record: [String: Any]) -> Bool {
        let content = (record["message"] as? [String: Any])?["content"]
        let text: String
        switch content {
        case let plain as String:
            text = plain
        case let blocks as [[String: Any]]:
            text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        default:
            return false
        }
        return text.contains("[Request interrupted by user")
    }

    /// 记录自己声明的写入时刻。两家 CLI 给每条有意义的记录都打戳；没戳的多半是 bookkeeping。
    static func stamp(of record: [String: Any]) -> Date? {
        guard let text = record["timestamp"] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// 文件末尾一段，切成整行。
    static func tail(of url: URL, limit: Int = 128 * 1024) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(limit) ? size - UInt64(limit) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }
        var lines: [Data] = data
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .map { Data($0) }
        // 不从文件头开始时，第一行只是半行。
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    // MARK: - 找文件

    /// 某主体的全部 transcript 及修改时间，新的在前。这里只读元数据。
    private static func transcripts(for subject: Subject) -> [(url: URL, modified: Date)] {
        let root = root(for: subject)
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var found: [(url: URL, modified: Date)] = []
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl",
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { continue }
            found.append((url, modified))
        }
        return found.sorted { $0.modified > $1.modified }
    }
}

/// 自适应时钟监视 CLI 是否正在工作中，驱动 rail 旋转点与主窗口卡片状态点。
/// 活跃时 2 秒一档跟得上几秒钟开始又结束的 turn；长时间无活跃迹象降到 12 秒常驻。
///
/// 刻意与用量刷新分开：用量是别人家服务器上的百分比，这是本地读，必须跟得上
/// 几秒钟开始又结束的 turn，否则它驱动的圆点在两个方向上都是谎话。
@MainActor final class AgentActivityMonitor: ObservableObject {
    @Published private(set) var running: Set<AgentActivity.Subject> = []
    @Published private(set) var lastWrite: Date?
    /// 各主体 turn 最近结束的时刻——与「是否在跑」是两个事实，用于庆祝动画，只庆祝见证过的结束。
    @Published private(set) var finishedAt: [AgentActivity.Subject: Date] = [:]

    /// 快到旋转点随 turn 起停；没有活跃迹象（无进行中的 turn、jsonl 长时间无新写入）
    /// 时降到 12 秒一档，常驻不再每 2 秒枚举进程与文件；重新见到活跃迹象即恢复 2 秒。
    private static let activeInterval: TimeInterval = 2
    private static let idleInterval: TimeInterval = 12
    /// 最后一次 jsonl 写入距现在超过这个窗口就视为无活跃迹象。
    private static let idleAfter: TimeInterval = 10 * 60

    private var timer: Timer?
    private var isScanning = false
    private var currentInterval: TimeInterval = AgentActivityMonitor.activeInterval
    /// stop() 时递增：在途的扫描借此知道自己活得比监视器久，结果丢弃（停止不是 turn 结束）。
    private var generation = 0

    var isRunning: Bool { timer != nil }

    /// UI 可见性输入：浮动条显示中或主窗口可见才扫描——两个圆点都没人看时，2 秒枚举是纯浪费。
    private var panelVisible = true
    private var mainWindowVisible = true
    /// 3.39：UI 重新进入视野时下一拍强制全量枚举（即时发现新 session 文件），
    /// 平时全量按 AgentActivity.fileListTTL（60s）低频走，2 秒档只重 stat 活文件。
    private var forceFullScanOnce = false

    func setPanelVisible(_ visible: Bool) {
        if visible && !panelVisible { forceFullScanOnce = true }
        panelVisible = visible; applyRunState()
    }
    func setMainWindowVisible(_ visible: Bool) {
        if visible && !mainWindowVisible { forceFullScanOnce = true }
        mainWindowVisible = visible; applyRunState()
    }
    private func applyRunState() {
        if panelVisible || mainWindowVisible { start() } else { stop() }
    }

    func start() {
        guard timer == nil else { return }
        scheduleTimer(Self.activeInterval)
        sample()
    }

    private func scheduleTimer(_ interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        currentInterval = interval
    }

    func stop() {
        generation += 1
        timer?.invalidate()
        timer = nil
        running = []
    }

    func isWorking(_ subject: AgentActivity.Subject?) -> Bool {
        subject.map { running.contains($0) } ?? false
    }

    private func sample() {
        guard !isScanning else { return }
        isScanning = true
        let generation = self.generation
        // 3.39：读走并清掉「UI 刚进入视野」的即时全量标记，只影响这一拍。
        let forceFull = forceFullScanOnce
        forceFullScanOnce = false
        Task {
            let states = await Task.detached(priority: .utility) {
                AgentActivity.states(now: Date(), forceFullScan: forceFull)
            }.value
            self.isScanning = false
            // 迟到的结果不许写：停止后到达的扫描会把已停的 turn 标成 running，
            // 下次 start 再把它 diff 成「刚结束」庆祝一次。
            guard generation == self.generation, self.timer != nil else { return }
            let active = Set(states.filter(\.value.isWorking).keys)
            if active != running {
                let now = Date()
                for subject in running.subtracting(active) { finishedAt[subject] = now }
                running = active
            }
            let newest = states.values.compactMap(\.lastWrite).max()
            if newest != lastWrite { lastWrite = newest }
            // 自适应降频：有 turn 在跑或最近 10 分钟内有过写入 → 2 秒；否则 12 秒。
            let fresh = !active.isEmpty || (newest.map { Date().timeIntervalSince($0) < Self.idleAfter } ?? false)
            let desired = fresh ? Self.activeInterval : Self.idleInterval
            if desired != currentInterval { scheduleTimer(desired) }
        }
    }
}
