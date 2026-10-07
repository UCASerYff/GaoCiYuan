import Foundation

struct ParsedQuotaResult: Equatable {
    var window: String
    var usedPercent: Double
    var isUsedMetric: Bool
    var rawText: String
    var resetsAt: Date?

    var remainingPercent: Double {
        max(0, min(100, 100.0 - usedPercent))
    }
}

enum QuotaValueParser {
    static func normalizeLessThanPercent(_ text: String) -> String {
        var res = text
        let patterns = [
            #"(?:<|＜|小于)\s*1\s*%"#: "1%",
            #"(?:<|＜|小于)\s*(\d+(?:\.\d+)?)\s*%"#: "$1%"
        ]
        for (pattern, template) in patterns {
            if let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                res = re.stringByReplacingMatches(in: res, range: NSRange(res.startIndex..., in: res), withTemplate: template)
            }
        }
        return res
    }

    static func detectWindow(_ text: String) -> String? {
        let lower = text.lowercased()
        if lower.contains("当前时段") || lower.contains("5h") || lower.contains("5 h") || lower.contains("5-hour") || lower.contains("5 hour") || lower.contains("5小时") || lower.contains("5 小时") || lower.contains("当前会话") || lower.contains("current session") {
            return "5 小时"
        }
        if lower.contains("近 7 天") || lower.contains("近7天") || lower.contains("7天") || lower.contains("7 天") || lower.contains("一周") || lower.contains("1周") || lower.contains("1 周") || lower.contains("每周") || lower.contains("周限额") || lower.contains("周额度") || lower.contains("weekly") || lower.contains("week") {
            return "每周"
        }
        if lower.contains("每月") || lower.contains("月限额") || lower.contains("月额度") || lower.contains("monthly") || lower.contains("month") {
            return "每月"
        }
        return nil
    }

    static func detectResetTime(_ text: String) -> Date? {
        let cal = Calendar.current
        let now = Date()
        if text.contains("后重置") {
            var minutes = 0
            if let hMatch = try? NSRegularExpression(pattern: #"(\d+)\s*小时"#).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let r = Range(hMatch.range(at: 1), in: text), let h = Int(text[r]) {
                minutes += h * 60
            }
            if let mMatch = try? NSRegularExpression(pattern: #"(\d+)\s*分钟"#).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let r = Range(mMatch.range(at: 1), in: text), let m = Int(text[r]) {
                minutes += m
            }
            if minutes > 0 { return cal.date(byAdding: .minute, value: minutes, to: now) }
        }
        if let mMatch = try? NSRegularExpression(pattern: #"(\d+)\s*月\s*(\d+)\s*日\s*(\d+):(\d+)\s*重置"#).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let rM = Range(mMatch.range(at: 1), in: text), let month = Int(text[rM]),
           let rD = Range(mMatch.range(at: 2), in: text), let day = Int(text[rD]),
           let rH = Range(mMatch.range(at: 3), in: text), let hour = Int(text[rH]),
           let rMin = Range(mMatch.range(at: 4), in: text), let min = Int(text[rMin]) {
            let currentYear = cal.component(.year, from: now)
            let comp = DateComponents(year: currentYear, month: month, day: day, hour: hour, minute: min)
            if let date = cal.date(from: comp) {
                return date < now ? cal.date(from: DateComponents(year: currentYear + 1, month: month, day: day, hour: hour, minute: min)) : date
            }
        }
        return nil
    }

    static func isUsedDirection(_ text: String) -> Bool? {
        let lower = text.lowercased()
        let usedKeywords = ["已用", "已使用", "消耗", "used", "consumed", "usage", "用量"]
        let remainingKeywords = ["剩余", "还剩", "可用", "remaining", "available", "left"]

        let hasUsed = usedKeywords.contains { lower.contains($0) }
        let hasRemaining = remainingKeywords.contains { lower.contains($0) }

        if hasUsed && !hasRemaining { return true }
        if hasRemaining && !hasUsed { return false }
        return nil
    }

    static func parseLines(_ rawLines: [String]) -> [ParsedQuotaResult] {
        var cleanLines: [String] = []
        for line in rawLines {
            let trimmed = normalizeLessThanPercent(line.trimmingCharacters(in: .whitespacesAndNewlines))
            if !trimmed.isEmpty {
                cleanLines.append(trimmed)
            }
        }

        var results: [ParsedQuotaResult] = []
        var i = 0
        while i < cleanLines.count {
            let line = cleanLines[i]
            let context = cleanLines[max(0, i - 2)...min(cleanLines.count - 1, i + 2)].joined(separator: " ")
            let window = detectWindow(line) ?? detectWindow(context) ?? "额度"

            let p1 = #"(?i)(已用|已使用|消耗|used|consumed|剩余|还剩|可用|remaining|available)\s*[:：]?\s*(\d+(?:\.\d+)?)\s*%"#
            let p2 = #"(?i)(\d+(?:\.\d+)?)\s*%\s*(已用|已使用|消耗|used|consumed|剩余|还剩|可用|remaining|available)"#

            var matched = false
            for (pattern, valGroup, dirGroup) in [(p1, 2, 1), (p2, 1, 2)] {
                if let re = try? NSRegularExpression(pattern: pattern),
                   let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                   let valRange = Range(m.range(at: valGroup), in: line),
                   let dirRange = Range(m.range(at: dirGroup), in: line),
                   let val = Double(line[valRange]), (0...100).contains(val) {
                    let dirText = String(line[dirRange])
                    let isUsed = (isUsedDirection(dirText) ?? true)
                    let usedVal = isUsed ? val : (100.0 - val)

                    var reset: Date?
                    if i + 1 < cleanLines.count {
                        for lookAhead in (i + 1)...min(cleanLines.count - 1, i + 3) {
                            if let d = detectResetTime(cleanLines[lookAhead]) {
                                reset = d
                                break
                            }
                        }
                    }

                    results.append(ParsedQuotaResult(window: window, usedPercent: usedVal, isUsedMetric: isUsed, rawText: line, resetsAt: reset))
                    matched = true
                    break
                }
            }

            if !matched {
                if let re = try? NSRegularExpression(pattern: #"^(\d+(?:\.\d+)?)\s*%$"#),
                   let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                   let valRange = Range(m.range(at: 1), in: line),
                   let val = Double(line[valRange]), (0...100).contains(val) {
                    let isUsed = isUsedDirection(context) ?? false
                    let usedVal = isUsed ? val : (100.0 - val)
                    results.append(ParsedQuotaResult(window: window, usedPercent: usedVal, isUsedMetric: isUsed, rawText: line, resetsAt: nil))
                }
            }
            i += 1
        }

        var unique: [ParsedQuotaResult] = []
        var seen = Set<String>()
        for r in results {
            if !seen.contains(r.window) {
                seen.insert(r.window)
                unique.append(r)
            }
        }
        return unique
    }
}
