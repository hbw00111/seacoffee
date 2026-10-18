import Foundation

/// Reads the plan usage that Claude Code's own `/usage` screen prints. Used when the
/// OAuth token has expired: the CLI fetches the numbers (and renews its own login),
/// Sea Coffee only scrapes the terminal output.
public enum ClaudeUsageScreen {
    /// Turns raw PTY output into plain lines: cursor moves become spaces or line breaks,
    /// every other escape sequence is dropped.
    public static func plainText(_ raw: String) -> String {
        var text = raw
        let rules: [(String, String)] = [
            (#"\x{1B}\[[0-9;]*[CG]"#, " "),
            (#"\x{1B}\[[0-9;]*[ABEFHf]"#, "\n"),
            (#"\x{1B}\][^\x{07}\x{1B}]*(\x{07}|\x{1B}\\)"#, ""),
            (#"\x{1B}\[[0-9;?<>=]*[ -/]*[@-~]"#, ""),
            (#"\x{1B}[=>()78][0-9A-B]?"#, ""),
            ("\r", "\n"),
        ]
        for (pattern, replacement) in rules {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return text
    }

    /// The latest value of each window on the screen, mapped to the same quota ids as the
    /// OAuth usage API. Returns nil when no window with a percentage is visible.
    public static func usage(_ screen: String, now: Date = Date(), timeZone: TimeZone = .current) -> UsageSnapshot? {
        let lines = plainText(screen).components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var found: [String: Quota] = [:]
        for (index, line) in lines.enumerated() {
            guard let (key, label) = window(line) else { continue }
            let following = lines[(index + 1)..<min(lines.count, index + 4)]
            guard let used = following.lazy.compactMap(percentUsed).first else { continue }
            let reset = following.first { $0.lowercased().hasPrefix("resets") }
                .flatMap { resetDate($0, now: now, timeZone: timeZone) }
            // The screen redraws while loading; later frames win.
            found[key] = Quota(id: "claude-\(key)", label: label, remaining: 100 - used, limit: 100,
                               monetary: false, resetsAt: reset)
        }
        let order = ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus"]
        let quotas = order.compactMap { found[$0] }
        return quotas.isEmpty ? nil : UsageSnapshot(quotas: quotas, source: "Claude", fetchedAt: now)
    }

    static func window(_ line: String) -> (String, String)? {
        let lower = line.lowercased()
        if lower.hasPrefix("current session") { return ("five_hour", "5 小时") }
        guard lower.hasPrefix("current week") else { return nil }
        if lower.contains("sonnet") { return ("seven_day_sonnet", "Sonnet 每周") }
        if lower.contains("opus") { return ("seven_day_opus", "Opus 每周") }
        return ("seven_day", "每周")
    }

    static func percentUsed(_ line: String) -> Double? {
        guard let match = line.range(of: #"(\d{1,3}(\.\d+)?)\s*%\s*(used|left)"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let part = line[match]
        guard let number = Double(part.prefix { $0.isNumber || $0 == "." }), number <= 100 else { return nil }
        return part.lowercased().hasSuffix("left") ? 100 - number : number
    }

    /// "Resets 3pm (Asia/Shanghai)", "Resets 2:59pm", "Resets Oct 21, 11am (Asia/Shanghai)",
    /// "Resets Oct 21 at 11am". Anything else is an unknown reset time.
    static func resetDate(_ line: String, now: Date, timeZone: TimeZone) -> Date? {
        var text = String(line.dropFirst("resets".count)).trimmingCharacters(in: .whitespaces)
        var zone = timeZone
        if let open = text.lastIndex(of: "("), text.hasSuffix(")") {
            if let named = TimeZone(identifier: String(text[text.index(after: open)..<text.index(before: text.endIndex)])) { zone = named }
            text = text[..<open].trimmingCharacters(in: .whitespaces)
        }
        let pattern = #"^(?:([A-Za-z]{3,9})\.?\s+(\d{1,2})(?:,|\s+at)?\s*)?(?:(\d{1,2})(?::(\d{2}))?\s*([ap]m))?$"#
        guard !text.isEmpty, let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ i: Int) -> String? { Range(match.range(at: i), in: text).map { String(text[$0]) } }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        var hasTime = false
        if let hour = group(3).flatMap(Int.init), let meridiem = group(5)?.lowercased(), (1...12).contains(hour) {
            parts.hour = hour % 12 + (meridiem == "pm" ? 12 : 0)
            parts.minute = group(4).flatMap(Int.init) ?? 0
            hasTime = true
        } else {
            parts.hour = 0; parts.minute = 0
        }
        if let monthName = group(1), let day = group(2).flatMap(Int.init) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let names = formatter.shortMonthSymbols.map { $0.lowercased() }
            guard let month = names.firstIndex(of: String(monthName.lowercased().prefix(3))) else { return nil }
            parts.month = month + 1; parts.day = day
            guard var date = calendar.date(from: parts) else { return nil }
            // No year on screen: a date well in the past means next year.
            if date < now.addingTimeInterval(-86_400) { date = calendar.date(byAdding: .year, value: 1, to: date) ?? date }
            return date
        }
        guard hasTime, var date = calendar.date(from: parts) else { return nil }
        if date < now.addingTimeInterval(-60) { date = calendar.date(byAdding: .day, value: 1, to: date) ?? date }
        return date
    }
}
