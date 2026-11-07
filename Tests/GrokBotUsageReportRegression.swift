import Foundation

// Compile: swiftc -parse-as-library Sources/GrokBotUsageReport.swift Tests/GrokBotUsageReportRegression.swift -o /tmp/grokbot-usage-report
// The file provider is exercised against a temporary directory. No Grok Bot
// process, credential, private database, or network call is used.
@main struct GrokBotUsageReportRegression {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }

    static func rejected(_ data: Data, now: Date, zone: TimeZone, _ reason: String) {
        switch GrokBotUsageReport.ingest(data, now: now, timeZone: zone) {
        case .failure(.invalid(let got)):
            require(got == reason, "expected \(reason), got \(got)")
        default:
            fatalError("\(reason) was accepted")
        }
    }

    static func payload(set: [String: Any] = [:], nulls: Set<String> = [], drop: Set<String> = []) throws -> Data {
        var object: [String: Any] = [
            "schema": 1,
            "source": GrokBotUsageReport.sourceIdentifier,
            "capturedAt": "2026-11-07T01:12:00Z",
            "plan": "Premium",
            "weeklyPercentUsed": 19.3,
            "resetsAt": "2026-11-09T01:00:00Z",
            "sharedWithOtherApps": true,
        ]
        for key in drop { object.removeValue(forKey: key) }
        for (key, value) in set { object[key] = value }
        for key in nulls { object[key] = NSNull() }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func main() throws {
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        let captured = parser.date(from: "2026-11-07T01:12:00Z")!
        let reset = parser.date(from: "2026-11-09T01:00:00Z")!
        let now = parser.date(from: "2026-11-07T02:00:00Z")!
        let contract = """
        {"schema":1,"source":"grok-bot-usage-report","capturedAt":"2026-11-07T01:12:00Z","plan":"Premium","weeklyPercentUsed":19.3,"resetsAt":"2026-11-09T01:00:00Z","sharedWithOtherApps":true}
        """
        guard case .success(let reading) = GrokBotUsageReport.ingest(Data(contract.utf8), now: now, timeZone: zone) else {
            fatalError("contract example rejected")
        }
        require(reading.freshness == .current, "fresh report")
        require(reading.snapshot.plan == "Premium", "plan")
        require(reading.snapshot.weeklyPercentUsed == 19.3, "percent")
        require(reading.snapshot.sharedWithOtherApps, "shared")
        require(reading.snapshot.capturedAt == captured && reading.snapshot.resetsAt == reset, "instants")
        let expected = "本周已用 19.3%（与套餐内其他应用共享） · 重置 周一 11月9日 09:00 · 数据 周六 11月7日 09:12"
        require(reading.line == expected, reading.line)
        require(GrokBotUsageReport.presentation(reading) == expected, "current presentation")
        require(GrokBotUsageReport.connectorStatus(.success(reading), installed: false, running: false) == expected, "a valid report does not wait for process detection")
        require(!expected.contains("实时") && !expected.contains("剩余") && !expected.contains("Premium"), "display added a claim")
        require(!expected.contains("0%"), "fresh 19.3 rendered as zero")

        let offset = contract.replacingOccurrences(of: "2026-11-07T01:12:00Z", with: "2026-11-07T09:12:00+08:00")
        guard case .success(let offsetReading) = GrokBotUsageReport.ingest(Data(offset.utf8), now: now, timeZone: zone) else {
            fatalError("offset timestamp rejected")
        }
        require(offsetReading.line == expected, "local reset and capture")

        let whole = try payload(set: ["weeklyPercentUsed": 19, "sharedWithOtherApps": false])
        guard case .success(let plain) = GrokBotUsageReport.ingest(whole, now: now, timeZone: zone) else { fatalError("integer percent rejected") }
        require(plain.line.hasPrefix("本周已用 19% · 重置 "), plain.line)
        require(!plain.line.contains("共享"), "unshared report claimed sharing")

        guard case .success(let precise) = GrokBotUsageReport.ingest(try payload(set: ["weeklyPercentUsed": 19.25]), now: now, timeZone: zone) else {
            fatalError("19.25 rejected")
        }
        require(precise.line.hasPrefix("本周已用 19.25%"), precise.line)
        guard case .success(let full) = GrokBotUsageReport.ingest(try payload(set: ["weeklyPercentUsed": 100]), now: now, timeZone: zone) else {
            fatalError("100 rejected")
        }
        require(full.line.hasPrefix("本周已用 100%"), full.line)
        guard case .success(let explicitZero) = GrokBotUsageReport.ingest(try payload(set: ["weeklyPercentUsed": 0]), now: now, timeZone: zone) else {
            fatalError("explicit zero rejected")
        }
        require(explicitZero.line.hasPrefix("本周已用 0%"), "explicit zero is a recorded value")

        guard case .success(let openReset) = GrokBotUsageReport.ingest(try payload(nulls: ["resetsAt"]), now: now, timeZone: zone) else {
            fatalError("null reset rejected")
        }
        require(openReset.freshness == .current && openReset.line.contains("平台未提供重置时间"), openReset.line)
        guard case .success(let trimmed) = GrokBotUsageReport.ingest(try payload(set: ["plan": "  Premium  "]), now: now, timeZone: zone) else {
            fatalError("trimmed plan rejected")
        }
        require(trimmed.snapshot.plan == "Premium" && !trimmed.line.contains("Premium"), "plan stays off the display line")
        guard case .success(let named) = GrokBotUsageReport.ingest(try payload(set: ["plan": "see \"schema\": 1.0"]), now: now, timeZone: zone) else {
            fatalError("plan text was read as the schema token")
        }
        require(named.snapshot.plan == "see \"schema\": 1.0" && named.freshness == .current, "schema scan entered a string")

        let exactly = now.addingTimeInterval(-GrokBotUsageReport.staleAfter)
        guard case .success(let boundary) = GrokBotUsageReport.ingest(try payload(set: ["capturedAt": parser.string(from: exactly)]), now: now, timeZone: zone) else {
            fatalError("six-hour boundary rejected")
        }
        require(boundary.freshness == .current, "exactly six hours is still current")
        let olderInstant = exactly.addingTimeInterval(-1)
        guard case .success(let older) = GrokBotUsageReport.ingest(try payload(set: ["capturedAt": parser.string(from: olderInstant)]), now: now, timeZone: zone) else {
            fatalError("old report rejected")
        }
        require(older.freshness == .olderThanLimit, "older than six hours")
        let olderText = GrokBotUsageReport.presentation(older)
        require(olderText.hasPrefix("用量报告已超过 6 小时，不作为当前读数。记录：本周已用 19.3%"), olderText)
        require(!olderText.contains("实时"), "stale report claimed to be live")

        guard case .success(let elapsed) = GrokBotUsageReport.ingest(try payload(set: [
            "capturedAt": parser.string(from: now),
            "resetsAt": parser.string(from: now),
        ]), now: now, timeZone: zone) else { fatalError("reset boundary rejected") }
        require(elapsed.freshness == .resetElapsed, "reset at now has elapsed")
        let elapsedText = GrokBotUsageReport.connectorStatus(.success(elapsed), installed: true, running: true)
        require(elapsedText == "用量报告的重置时间已过，不作为本周读数。数据 \(elapsed.capturedText)", elapsedText)
        require(!elapsedText.contains("%"), "elapsed window still showed a percent")

        guard case .success(let both) = GrokBotUsageReport.ingest(try payload(set: [
            "capturedAt": parser.string(from: olderInstant),
            "resetsAt": parser.string(from: olderInstant),
        ]), now: now, timeZone: zone) else { fatalError("old elapsed report rejected") }
        require(both.freshness == .resetElapsed, "a passed reset wins over age")
        require(!GrokBotUsageReport.presentation(both).contains("%"), "old elapsed percent leaked")

        let ahead = now.addingTimeInterval(GrokBotUsageReport.futureSkew)
        guard case .success(let skewed) = GrokBotUsageReport.ingest(try payload(set: ["capturedAt": parser.string(from: ahead), "resetsAt": parser.string(from: now.addingTimeInterval(3600))]), now: now, timeZone: zone) else {
            fatalError("clock skew rejected")
        }
        require(skewed.freshness == .current, "skew within one minute")
        rejected(try payload(set: ["capturedAt": parser.string(from: ahead.addingTimeInterval(1))]), now: now, zone: zone, "capturedAt 晚于当前时间")

        rejected(Data(), now: now, zone: zone, "文件为空")
        rejected(Data("[]".utf8), now: now, zone: zone, "不是 JSON 对象")
        rejected(Data("\"grok-bot-usage-report\"".utf8), now: now, zone: zone, "不是 JSON 对象")
        rejected(Data((contract + " {}").utf8), now: now, zone: zone, "不是 JSON 对象")
        rejected(try payload(drop: ["resetsAt"]), now: now, zone: zone, "缺少约定字段")
        rejected(try payload(set: ["onDemandCents": 0]), now: now, zone: zone, "含有未约定的字段")
        rejected(try payload(set: ["source": "Grok 账号官方接口"]), now: now, zone: zone, "source 必须为 grok-bot-usage-report")
        rejected(try payload(set: ["schema": 2]), now: now, zone: zone, "schema 必须为整数 1")
        rejected(try payload(set: ["schema": true]), now: now, zone: zone, "schema 必须为整数 1")
        rejected(Data(contract.replacingOccurrences(of: "\"schema\":1", with: "\"schema\":1.0").utf8), now: now, zone: zone, "schema 必须为整数 1")
        rejected(Data(contract.replacingOccurrences(of: "\"schema\":1", with: "\"schema\":1e0").utf8), now: now, zone: zone, "schema 必须为整数 1")
        rejected(try payload(set: ["weeklyPercentUsed": true]), now: now, zone: zone, "weeklyPercentUsed 必须为 0 到 100 的数字")
        rejected(try payload(set: ["weeklyPercentUsed": "19.3"]), now: now, zone: zone, "weeklyPercentUsed 必须为 0 到 100 的数字")
        rejected(try payload(set: ["weeklyPercentUsed": 100.1]), now: now, zone: zone, "weeklyPercentUsed 必须为 0 到 100 的数字")
        rejected(try payload(set: ["weeklyPercentUsed": -0.1]), now: now, zone: zone, "weeklyPercentUsed 必须为 0 到 100 的数字")
        rejected(try payload(set: ["resetsAt": ""]), now: now, zone: zone, "resetsAt 必须为 ISO 8601 时间或 null")
        rejected(try payload(set: ["resetsAt": 1_762_473_600]), now: now, zone: zone, "resetsAt 必须为 ISO 8601 时间或 null")
        rejected(try payload(set: ["capturedAt": "2026-11-07T09:12:00"]), now: now, zone: zone, "capturedAt 必须为 ISO 8601 时间")
        rejected(try payload(set: ["plan": " "]), now: now, zone: zone, "plan 为空或含控制字符")
        rejected(try payload(set: ["plan": "Premium\nPlus"]), now: now, zone: zone, "plan 为空或含控制字符")
        rejected(try payload(set: ["plan": String(repeating: "A", count: GrokBotUsageReport.maximumPlanLength + 1)]), now: now, zone: zone, "plan 为空或含控制字符")
        rejected(try payload(set: ["sharedWithOtherApps": 1]), now: now, zone: zone, "sharedWithOtherApps 必须为布尔值")
        rejected(try payload(set: ["sharedWithOtherApps": "true"]), now: now, zone: zone, "sharedWithOtherApps 必须为布尔值")
        let sand = try JSONSerialization.data(withJSONObject: ["usagePercent": 19.3, "source": "sand"])
        rejected(sand, now: now, zone: zone, "缺少约定字段")

        let missingRunning = GrokBotUsageReport.connectorStatus(.failure(.missing), installed: true, running: true)
        let missingInstalled = GrokBotUsageReport.connectorStatus(.failure(.missing), installed: true, running: false)
        let missingAbsent = GrokBotUsageReport.connectorStatus(.failure(.missing), installed: false, running: false)
        require(missingRunning == "已检测到 Grok Bot（运行中）。尚无可读取用量，等待记录。", missingRunning)
        require(missingInstalled == "已检测到 Grok Bot（未启动）。尚无可读取用量，等待记录。", missingInstalled)
        require(missingAbsent == "尚未检测到 Grok Bot。安装或启动后会自动重新检测；等待可读取的用量记录。", missingAbsent)
        for status in [missingRunning, missingInstalled, missingAbsent] {
            require(!status.contains("%") && !status.contains("0"), status)
        }
        let leaked = try payload(set: ["plan": "LEAKED-PLAN", "weeklyPercentUsed": "nope"])
        let invalidStatus = GrokBotUsageReport.connectorStatus(.failure(GrokBotUsageReport.ingest(leaked, now: now, timeZone: zone).failureValue), installed: true, running: true)
        require(invalidStatus == "已检测到 Grok Bot（运行中）。用量记录不符合 grokbot-usage.json 约定，未显示百分比。", invalidStatus)
        require(!invalidStatus.contains("%") && !invalidStatus.contains("LEAKED-PLAN") && !invalidStatus.contains("0"), invalidStatus)
        require(GrokBotUsageReport.connectorStatus(.failure(.unreadable), installed: false, running: false) == "尚未检测到 Grok Bot。用量记录无法读取，未显示百分比。", "unreadable")
        require(GrokBotUsageReport.connectorStatus(.failure(.tooLarge), installed: true, running: false) == "已检测到 Grok Bot（未启动）。用量记录超出大小限制，未显示百分比。", "too large")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("grokbot-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = GrokBotUsageReport.contractFileURL(home: home)
        require(url.path == home.path + "/Library/Application Support/GaoSeries/Token/grokbot-usage.json", url.path)
        let provider = GrokBotUsageFileProvider(fileURL: url, timeZone: zone)
        guard case .failure(.missing) = provider.load(now: now) else { fatalError("absent file produced a reading") }
        require(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Library").path), "reader created a directory")

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contract.utf8).write(to: url)
        guard case .success(let loaded) = provider.load(now: now) else { fatalError("written contract not read") }
        require(loaded.line == expected && loaded.freshness == .current, "file provider display")
        let before = try Data(contentsOf: url)
        _ = provider.load(now: now)
        let after = try Data(contentsOf: url)
        require(after == before, "reader rewrote the file")

        try Data(Data(count: 32)).write(to: url)
        let blocked = GrokBotUsageFileProvider(fileURL: url, timeZone: zone, read: { _ in throw CocoaError(.fileReadNoPermission) })
        guard case .failure(.unreadable) = blocked.load(now: now) else { fatalError("unreadable file produced a reading") }
        try Data(count: GrokBotUsageReport.maximumBytes + 1).write(to: url)
        guard case .failure(.tooLarge) = provider.load(now: now) else { fatalError("oversized file produced a reading") }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard case .failure(.invalid("路径是目录")) = provider.load(now: now) else { fatalError("directory produced a reading") }

        let fixedHome = GrokBotUsageReport.defaultFileURL(homePath: "/Users/example")
        require(fixedHome.path == "/Users/example/Library/Application Support/GaoSeries/Token/grokbot-usage.json", fixedHome.path)
        print("{\"passed\":true,\"cases\":\"parse-staleness-validation-file\"}")
    }
}

private extension Result where Failure == GrokBotUsageReport.Rejection {
    var failureValue: Failure {
        guard case .failure(let failure) = self else { fatalError("expected failure") }
        return failure
    }
}
