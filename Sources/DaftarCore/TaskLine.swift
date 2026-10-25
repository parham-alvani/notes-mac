import Foundation

/// The Tasks plugin's trailing emoji, pulled off a task line.
public enum TaskMetadata {
    public static let symbols: [String: String] = [
        "✅": "done", "➕": "created", "⏳": "scheduled", "❌": "cancelled", "📅": "due",
        "🔁": "recurring", "⛔": "blocked", "🛫": "start", "🆔": "id",
        "🔺": "priority", "⏫": "priority", "🔼": "priority", "🔽": "priority", "⏬": "priority",
        "🏁": "onCompletion",
    ]

    public struct Meta: Sendable, Equatable, Hashable {
        public var emoji: String
        public var value: String
    }

    nonisolated(unsafe) private static let value = /^[0-9A-Za-z\/,:. -]{0,32}$/
    nonisolated(unsafe) private static let dateValue = /^\d{4}-\d{2}-\d{2}$/
    private static let dated: Set<String> = ["done", "created", "scheduled", "cancelled", "due", "start"]

    /// Whether [value] can follow [symbol]: nothing after a priority, only
    /// a date after a date, a rule or an id after the rest.
    private static func takes(_ symbol: String, _ value: String) -> Bool {
        if value.isEmpty { return true }
        let kind = symbols[symbol] ?? ""
        if kind == "priority" { return false }
        return value.wholeMatch(of: dated.contains(kind) ? Self.dateValue : Self.value) != nil
    }

    /// The sentence and its metadata, in the order written. From the right:
    /// the metadata is always a suffix, and an emoji with prose after it is
    /// part of the sentence, as is a second field of a kind already found.
    public static func split(_ line: String) -> (text: String, meta: [Meta]) {
        var remaining = line
        var found: [Meta] = []
        // Tags after the signifiers (`📅 2026-10-20 ⏫ #kit`) stay part of
        // the text, as the Tasks plugin keeps them.
        var tags: [String] = []
        var kinds = Set<String>()
        while true {
            var last: (String, Range<String.Index>)?
            for symbol in symbols.keys {
                if let range = remaining.range(of: symbol, options: .backwards),
                    last == nil || range.lowerBound > last!.1.lowerBound
                {
                    last = (symbol, range)
                }
            }
            guard let (symbol, range) = last, !kinds.contains(symbols[symbol]!) else { break }
            var value = remaining[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !takes(symbol, value) {
                guard let match = value.wholeMatch(of: /(.*?)((?:\s*#[\p{L}\p{N}_\/-]+)+)/),
                    takes(symbol, String(match.1))
                else { break }
                tags.insert(String(match.2).trimmingCharacters(in: .whitespaces), at: 0)
                value = String(match.1)
            }
            found.append(Meta(emoji: symbol, value: value))
            kinds.insert(symbols[symbol]!)
            remaining = String(remaining[..<range.lowerBound])
            while remaining.last?.isWhitespace ?? false { remaining.removeLast() }
        }
        if !tags.isEmpty { remaining += " " + tags.joined(separator: " ") }
        return (remaining, found.reversed())
    }
}

/// One task as it is written in the file, and the edits the app makes to it.
///
/// The rules are Daftar's on Android (`TaskLine.kt`): the done date goes on
/// the end, a repeating task leaves its next occurrence above the one just
/// done, and every edit is a function of the line as it is now.
public enum TaskLine {
    /// `- [ ] `, `* [x] `, `1. [/] `, and the same inside a quote or callout.
    nonisolated(unsafe) private static let pattern = /^(\s*(?:>\s?)*\s*(?:[-*+]|\d+[.)])\s+)\[([^\]\n])\]\s*(.*)$/

    public static let closed: Set<Character> = ["x", "X", "-"]

    private static let done = "✅"
    private static let cancelledMark = "❌"
    private static let recur = "🔁"
    private static let moved = ["📅", "⏳", "🛫"]

    public static func isTask(_ raw: String) -> Bool {
        raw.wholeMatch(of: pattern) != nil
    }

    static func parse(_ raw: String, line: Int, section: String) -> ParsedTask? {
        guard let match = raw.wholeMatch(of: pattern), let status = match.2.first else { return nil }
        let body = String(match.3).replacing(/\s+\^[A-Za-z0-9-]+\s*$/, with: "")
        let split = TaskMetadata.split(body)
        func date(_ emoji: String) -> String? {
            split.meta.first { $0.emoji == emoji }?.value.nilIfEmpty
        }
        let prefix = match.1
        let indent = prefix.prefix { $0 == " " || $0 == "\t" || $0 == ">" }
        return ParsedTask(
            line: line, status: status, text: split.text, section: section,
            created: date("➕"), scheduled: date("⏳"), due: date("📅"), start: date("🛫"),
            done: date(done), cancelled: date(cancelledMark), recurring: date(recur),
            priority: split.meta.first { TaskMetadata.symbols[$0.emoji] == "priority" }?.emoji,
            nested: indent.contains(where: { $0 == " " || $0 == "\t" }))
    }

    /// The line after a click on its checkbox: an open task is completed, and
    /// a closed one is opened again without its done or cancelled date. More
    /// than one line when a repeating task leaves its next occurrence.
    public static func toggled(_ raw: String, today: String) -> [String]? {
        guard let match = raw.wholeMatch(of: pattern), let status = match.2.first else { return nil }
        let prefix = String(match.1)
        // The block id `^abc` stays the line's last word, on the line it named.
        var body = String(match.3)
        var id = ""
        if let found = body.firstMatch(of: blockId) {
            id = " " + found.1
            body = String(body[..<found.range.lowerBound])
        }
        if closed.contains(status) {
            let text = body.replacing(/[ \t]*(?:✅|❌)[ \t]*\d{4}-\d{2}-\d{2}/, with: "")
            return [prefix + "[ ] " + text + id]
        }
        if var lines = completeRecurring(prefix: prefix, body: body, today: today) {
            lines[lines.count - 1] += id
            return lines
        }
        return [prefix + "[x] " + trimmedEnd(body) + " \(done) \(today)" + id]
    }

    nonisolated(unsafe) private static let blockId = /\s+(\^[A-Za-z0-9-]+)\s*$/

    /// The next occurrence above the one just done, every date moved by the
    /// same number of days. Nil when the rule is not a plain interval or the
    /// task has no date to move.
    static func completeRecurring(prefix: String, body: String, today: String) -> [String]? {
        let split = TaskMetadata.split(body)
        guard let rule = split.meta.first(where: { $0.emoji == recur })?.value,
            let recurrence = Recurrence(rule),
            let now = Day(today)
        else { return nil }
        let dates = Dictionary(split.meta.compactMap { meta in Day(meta.value).map { (meta.emoji, $0) } }) { a, _ in a }
        guard let leading = moved.lazy.compactMap({ dates[$0] }).first else { return nil }
        let from = recurrence.whenDone ? now : leading
        let shift = leading.days(to: recurrence.next(after: from, notBefore: now))
        let next = split.meta.map { meta in
            if moved.contains(meta.emoji), let date = dates[meta.emoji] {
                return TaskMetadata.Meta(emoji: meta.emoji, value: date.adding(days: shift).description)
            }
            return meta
        }
        let rebuilt = ([trimmedEnd(split.text)] + next.map { trimmedEnd("\($0.emoji) \($0.value)") })
            .filter { !$0.isEmpty }.joined(separator: " ")
        return [prefix + "[ ] " + rebuilt, prefix + "[x] " + trimmedEnd(body) + " \(done) \(today)"]
    }

    private static func trimmedEnd(_ text: String) -> String {
        var text = text
        while text.last?.isWhitespace ?? false { text.removeLast() }
        return text
    }

    /// The line a task is on now: the recorded line when it still holds the
    /// same task, else the first line that does.
    public static func locate(_ lines: [String], line: Int, text: String) -> Int? {
        if line < lines.count, let task = parse(lines[line], line: line, section: ""), task.text == text {
            return line
        }
        return lines.indices.first { parse(lines[$0], line: $0, section: "")?.text == text }
    }
}

/// How often a task comes back: the plain intervals only. A rule with
/// weekdays or ordinals is refused rather than guessed at, because a wrong
/// guess writes a wrong date into the vault.
public struct Recurrence: Sendable, Equatable {
    public enum Unit: Sendable { case day, week, month, year }
    public var amount: Int
    public var unit: Unit
    public var whenDone: Bool

    public init?(_ rule: String) {
        var text = rule.trimmingCharacters(in: .whitespaces).lowercased()
        whenDone = text.hasSuffix("when done")
        if whenDone { text = String(text.dropLast("when done".count)).trimmingCharacters(in: .whitespaces) }
        guard let match = text.wholeMatch(of: /every(?:\s+(\d+))?\s+(day|week|month|year)s?/) else { return nil }
        amount = match.1.flatMap { Int($0) } ?? 1
        guard amount > 0 else { return nil }
        unit = switch match.2 {
        case "day": .day
        case "week": .week
        case "month": .month
        default: .year
        }
    }

    /// Stepped until it lands after [notBefore], so a daily task ticked ten
    /// days late does not come back already overdue.
    func next(after from: Day, notBefore: Day) -> Day {
        var date = step(from)
        var guardSteps = 0
        while date <= notBefore, guardSteps < 4000 {
            date = step(date)
            guardSteps += 1
        }
        return date
    }

    private func step(_ day: Day) -> Day {
        switch unit {
        case .day: day.adding(days: amount)
        case .week: day.adding(days: 7 * amount)
        case .month: day.adding(months: amount)
        case .year: day.adding(months: 12 * amount)
        }
    }
}

/// A calendar day with no time and no zone, as the vault writes it:
/// `2026-10-25`.
public struct Day: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init?(_ text: String) {
        guard let match = text.trimmingCharacters(in: .whitespaces).wholeMatch(of: /(\d{4})-(\d{2})-(\d{2})/),
            let y = Int(match.1), let m = Int(match.2), let d = Int(match.3),
            (1...12).contains(m), (1...31).contains(d)
        else { return nil }
        self.init(year: y, month: m, day: d)
        guard description == "\(match.1)-\(match.2)-\(match.3)", Day(date: date) == self else { return nil }
    }

    /// The day [date] falls on in [zone].
    public init(date: Date, in zone: TimeZone = TimeZone(identifier: "UTC")!) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    public static func today(in zone: TimeZone = .current) -> Day { Day(date: Date(), in: zone) }

    /// Midnight UTC, for arithmetic only.
    var date: Date { Self.utc.date(from: DateComponents(year: year, month: month, day: day))! }

    public func adding(days: Int) -> Day { Day(date: Self.utc.date(byAdding: .day, value: days, to: date)!) }
    public func adding(months: Int) -> Day { Day(date: Self.utc.date(byAdding: .month, value: months, to: date)!) }
    public func days(to other: Day) -> Int { Self.utc.dateComponents([.day], from: date, to: other.date).day! }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public static func < (a: Day, b: Day) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// A task's parts, as the edit form shows them.
public struct TaskFields: Sendable, Equatable {
    public var status: Character = " "
    public var text = ""
    /// The priority's emoji, 🔺 ⏫ 🔼 🔽 or ⏬; nil for none.
    public var priority: String?
    public var recurring: String?
    public var created: String?
    public var start: String?
    public var scheduled: String?
    public var due: String?
    public var cancelled: String?
    public var done: String?
    /// Signifiers the form does not show (🏁, ⛔, 🆔), kept as they are.
    public var other: [TaskMetadata.Meta] = []

    public init() {}
}

extension TaskLine {
    nonisolated(unsafe) private static let line = /^(\s*(?:>\s?)*\s*(?:[-*+]|\d+[.)])\s+)\[([^\]\n])\]\s*(.*?)(\s+\^[A-Za-z0-9-]+)?\s*$/

    /// The task on [raw], in parts; nil when the line is not a task.
    public static func fields(_ raw: String) -> TaskFields? {
        guard let match = raw.wholeMatch(of: line), let status = match.2.first else { return nil }
        let split = TaskMetadata.split(String(match.3))
        var fields = TaskFields()
        fields.status = status
        fields.text = split.text
        for meta in split.meta {
            let value = meta.value.isEmpty ? nil : meta.value
            switch meta.emoji {
            case "➕": fields.created = value
            case "🛫": fields.start = value
            case "⏳": fields.scheduled = value
            case "📅": fields.due = value
            case "❌": fields.cancelled = value
            case "✅": fields.done = value
            case "🔁": fields.recurring = value
            case "🔺", "⏫", "🔼", "🔽", "⏬": fields.priority = meta.emoji
            default: fields.other.append(meta)
            }
        }
        return fields
    }

    /// [raw] with its task written from [fields]: the same indent, bullet
    /// and block id, the signifiers in the Tasks plugin's order.
    public static func edited(_ raw: String, _ fields: TaskFields) -> String? {
        guard let match = raw.wholeMatch(of: line) else { return nil }
        var parts = [fields.text.trimmingCharacters(in: .whitespaces)]
        if let priority = fields.priority { parts.append(priority) }
        if let rule = fields.recurring?.trimmingCharacters(in: .whitespaces), !rule.isEmpty { parts.append("🔁 " + rule) }
        let afterRule = ["🏁", "⛔", "🆔"]
        for emoji in afterRule {
            for meta in fields.other where meta.emoji == emoji { parts.append("\(meta.emoji) \(meta.value)") }
        }
        for (emoji, value) in [("➕", fields.created), ("🛫", fields.start), ("⏳", fields.scheduled), ("📅", fields.due), ("❌", fields.cancelled), ("✅", fields.done)] {
            if let value, !value.isEmpty { parts.append("\(emoji) \(value)") }
        }
        for meta in fields.other where !afterRule.contains(meta.emoji) { parts.append("\(meta.emoji) \(meta.value)") }
        return String(match.1) + "[\(fields.status)] " + parts.filter { !$0.isEmpty }.joined(separator: " ") + (match.4.map(String.init) ?? "")
    }
}
