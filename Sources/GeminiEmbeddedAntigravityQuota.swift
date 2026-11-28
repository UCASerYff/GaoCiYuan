import Foundation

/// The compact English quota text exposed by Gemini's Antigravity model menu.
enum GeminiEmbeddedAntigravityQuota {
    private enum Window: String {
        case weekly, fiveHour = "5h"

        var title: String { self == .weekly ? "每周" : "5 小时" }
        var seconds: TimeInterval { self == .weekly ? 604_800 : 18_000 }
    }

    private enum Group: String, CaseIterable {
        case gemini = "Gemini Models"
        case claudeAndGPT = "Claude and GPT models"
        case argon = "Gemini 4 Argon"

        var quotaID: String { rawValue.lowercased().replacingOccurrences(of: " ", with: "-") }
    }

    private static let windowLabels = #"(?<!\S)(weekly limit|5h limit|5-hour limit|5 hour limit|five hour limit)(?=[: ]|$)"#
    private static let compactLabel = try! NSRegularExpression(pattern: windowLabels + #"(?! (?:remaining|used)(?=[: ]|$))"#)
    private static let rowLabel = try! NSRegularExpression(pattern: windowLabels)
    private static let rowValue = try! NSRegularExpression(pattern: #"^:? ?([0-9]{1,3}(?:\.[0-9]{1,6})?) ?% left(?: resets in (.+))?$"#)
    private static let duration = try! NSRegularExpression(
        pattern: #"^(?:([0-9]{1,3}) ?(?:days?|d) ?)?(?:([0-9]{1,3}) ?(?:hours?|h) ?)?(?:([0-9]{1,3}) ?(?:minutes?|m) ?)?(?:([0-9]{1,3}) ?(?:seconds?|s))?$"#
    )
    private static let continuation = try! NSRegularExpression(
        pattern: #"^(?:[0-9<+-].*%|left(?: |$)|resets?(?: |$)|[0-9]{1,3} ?(?:[dhms]|days?|hours?|minutes?|seconds?)(?: |$))"#
    )

    /// Returns nil when the pane uses the earlier label-and-value format.
    static func parse(lines: [String], observedAt: Date) throws -> [Quota]? {
        let lines = lines.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased() }
        guard lines.contains(where: { firstMatch(compactLabel, in: $0) != nil }) else { return nil }

        var quotas: [Quota] = []
        var seenGroups = Set<Group>()
        var activeGroup: Group?
        var fields: [String] = []

        func finishGroup() throws {
            defer {
                activeGroup = nil
                fields.removeAll()
            }
            guard let group = activeGroup, !fields.isEmpty else { return }
            guard seenGroups.insert(group).inserted else { throw AntigravityDesktopQuota.Failure.paneNotAvailable }
            quotas += try parseRows(fields.joined(separator: " "), group: group, observedAt: observedAt)
        }

        for line in lines where !line.isEmpty {
            if let (group, body) = groupHeader(in: line) {
                try finishGroup()
                activeGroup = group
                if !body.isEmpty { fields.append(body) }
            } else if firstMatch(rowLabel, in: line) != nil || firstMatch(continuation, in: line) != nil {
                guard activeGroup != nil else { throw AntigravityDesktopQuota.Failure.paneNotAvailable }
                fields.append(line)
            } else {
                try finishGroup()
            }
        }
        try finishGroup()
        guard !quotas.isEmpty else { throw AntigravityDesktopQuota.Failure.paneNotAvailable }
        return quotas
    }

    private static func groupHeader(in line: String) -> (Group, String)? {
        for group in Group.allCases {
            let name = group.rawValue.lowercased()
            guard line.hasPrefix(name) else { continue }
            let tail = line.dropFirst(name.count)
            guard tail.isEmpty || tail.first == " " || tail.first == ":" else { continue }
            return (group, tail.trimmingCharacters(in: CharacterSet(charactersIn: " :")))
        }
        return nil
    }

    private static func parseRows(_ text: String, group: Group, observedAt: Date) throws -> [Quota] {
        let rows = rowLabel.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard rows.first?.range.location == 0 else { throw AntigravityDesktopQuota.Failure.paneNotAvailable }
        let source = text as NSString
        var seen = Set<Window>()
        var quotas: [Quota] = []
        for (index, row) in rows.enumerated() {
            let label = source.substring(with: row.range(at: 1))
            let window: Window = label == "weekly limit" ? .weekly : .fiveHour
            let start = NSMaxRange(row.range)
            let end = index + 1 < rows.count ? rows[index + 1].range.location : source.length
            let value = source.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespaces)
            guard seen.insert(window).inserted, let match = firstMatch(rowValue, in: value),
                  let percent = Double((value as NSString).substring(with: match.range(at: 1))),
                  (0...100).contains(percent) else { throw AntigravityDesktopQuota.Failure.paneNotAvailable }

            var resetsAt: Date?
            if match.range(at: 2).location != NSNotFound {
                let countdown = (value as NSString).substring(with: match.range(at: 2))
                guard let seconds = resetInterval(countdown), seconds <= window.seconds else {
                    throw AntigravityDesktopQuota.Failure.paneNotAvailable
                }
                // The displayed duration omits smaller units, so the resulting time is approximate.
                resetsAt = observedAt.addingTimeInterval(seconds)
            }
            quotas.append(Quota(id: "\(group.quotaID)-\(window.rawValue)", title: "\(group.rawValue) · \(window.title)",
                                usedPercent: 100 - percent, resetsAt: resetsAt, windowSeconds: window.seconds))
        }
        return quotas
    }

    private static func resetInterval(_ text: String) -> TimeInterval? {
        guard let match = firstMatch(duration, in: text) else { return nil }
        let source = text as NSString
        let units = [86_400, 3_600, 60, 1]
        let componentLimits = [Int.max, 24, 60, 60]
        var total = 0
        var hasLargerUnit = false
        for (index, unit) in units.enumerated() {
            let range = match.range(at: index + 1)
            guard range.location != NSNotFound else { continue }
            guard let count = Int(source.substring(with: range)), !hasLargerUnit || count < componentLimits[index] else {
                return nil
            }
            total += count * unit
            hasLargerUnit = true
        }
        return hasLargerUnit ? TimeInterval(total) : nil
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
