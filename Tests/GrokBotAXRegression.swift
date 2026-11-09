import AppKit
import ApplicationServices
import Foundation

// Pure fixtures only: no Grok Bot process, chat text, credentials or private data.
@main struct GrokBotAXRegression {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }

    static func main() throws {
        let observed = GrokBotAX.parse(lines: ["账户", "Premium 96% 已用", "设置"])
        require(observed == GrokBotAX.Observation(plan: "Premium", weeklyPercentUsed: 96), "real avatar row")
        require(GrokBotAX.parse(lines: ["SuperGrok 19.25% 已用"])?.weeklyPercentUsed == 19.25, "decimal")
        require(GrokBotAX.parse(lines: ["Premium 96% 已用", "Premium 96% 已用"]) == observed, "duplicate identical rows")
        require(GrokBotAX.parse(lines: ["Premium 0% 已用"])?.weeklyPercentUsed == 0, "zero used")
        require(GrokBotAX.parse(lines: ["Premium 100% 已用"])?.weeklyPercentUsed == 100, "full used")
        for invalid in [
            "Premium 96% 剩余", "Premium 100.1% 已用", "Premium -0.1% 已用",
            "聊天提到 Premium 96% 已用", "Premium NaN% 已用", "Premium Infinity% 已用",
            "Premium 96 已用", "Premium % 已用", "Premium\nPlus 96% 已用",
        ] {
            require(GrokBotAX.parse(lines: [invalid]) == nil, "accepted \(invalid)")
        }
        require(GrokBotAX.parse(lines: ["Premium 96% 已用", "SuperGrok 1% 已用"]) == nil, "conflicting rows")
        require(GrokBotAX.parse(lines: [String(repeating: "A", count: 65) + " 96% 已用"]) == nil, "unbounded plan")

        let avatar = GrokBotAX.AvatarCandidate(title: "nickname", x: 16, y: 832, windowHeight: 884)
        let input = GrokBotAX.AvatarCandidate(title: "输入框操作", x: 351, y: 832, windowHeight: 884)
        let share = GrokBotAX.AvatarCandidate(title: "分享", x: 10, y: 22, windowHeight: 884)
        let empty = GrokBotAX.AvatarCandidate(title: " ", x: 1, y: 850, windowHeight: 884)
        require(GrokBotAX.chooseAvatar([input, avatar, share, empty]) == avatar, "bottom-left avatar selection")
        require(GrokBotAX.chooseAvatar([share, empty]) == nil, "top or empty popup selected")
        require(!GrokBotAX.shouldReadWithoutNavigation(isActive: true, userInitiated: false), "automatic foreground read must skip")
        require(GrokBotAX.shouldReadWithoutNavigation(isActive: false, userInitiated: false), "automatic background read blocked")
        require(GrokBotAX.shouldReadWithoutNavigation(isActive: true, userInitiated: true), "manual open menu cannot be read")

        let first = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let second = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        GrokBotAX.resetNavigationForTesting(first)
        GrokBotAX.resetNavigationForTesting(second)
        defer {
            GrokBotAX.resetNavigationForTesting(first)
            GrokBotAX.resetNavigationForTesting(second)
        }
        require(!GrokBotAX.navigationThrottled(first, now: now), "never navigated was throttled")
        GrokBotAX.markNavigated(first, now: now)
        require(GrokBotAX.navigationThrottled(first, now: now.addingTimeInterval(299)), "299 seconds escaped throttle")
        require(!GrokBotAX.navigationThrottled(first, now: now.addingTimeInterval(300)), "300 seconds still throttled")
        require(!GrokBotAX.navigationThrottled(second, now: now), "account throttle leaked")

        let zone = TimeZone(identifier: "Asia/Shanghai")!
        let reading = GrokBotUsageReport.avatarManualReading(plan: "Premium", weeklyPercentUsed: 96, capturedAt: now)
        require(reading.resetsAt == nil && !reading.sharedWithOtherApps, "avatar invented reset or sharing")
        require(reading.plan == "Premium" && reading.source == .avatarMenu, "avatar source or plan")
        let text = GrokBotUsageReport.statusLine(reading, now: now, timeZone: zone)
        require(text.contains("头像栏目") && text.contains("额度剩余 4%（已用 96%）"), text)
        require(text.contains("Premium") && !text.contains("本周") && !text.contains("平台未提供重置"), text)
        let ring = GrokBotUsageReport.dedicatedRingFace(isGrokBotRoute: true, reading: reading, now: now, timeZone: zone)
        require(ring?.label == "4%" && ring?.fill == 0.04 && ring?.stale == false, "avatar ring")
        require(ring?.label.contains("旧") == false, "stale text leaked into number")

        let legacyData = try JSONEncoder().encode(GrokBotUsageReport.ManualReading(weeklyPercentUsed: 84.8, capturedAt: now, resetsAt: nil, sharedWithOtherApps: true))
        let legacy = try JSONDecoder().decode(GrokBotUsageReport.ManualReading.self, from: legacyData)
        require(legacy.plan == nil && legacy.source == nil, "legacy manual archive no longer decodes")
        require(GrokBotUsageReport.statusLine(legacy, now: now, timeZone: zone).contains("读取最近一次快照"), "legacy presentation changed")
        print("{\"passed\":true,\"used\":96,\"remaining\":4,\"avatarNavigationThrottled\":true}")
    }
}
