import Foundation

/// What VoiceOver says for the things the app draws as colour and icons: a
/// task's status, its priority arrow, a red date. Each is words here, so a
/// row reads the same as it looks.
public enum Spoken {
    /// A task's status box in words.
    public static func status(_ status: Character) -> String {
        switch status {
        case " ": "open"
        case "/": "in progress"
        case "x", "X": "done"
        case "-": "cancelled"
        default: "status \(status)"
        }
    }

    /// The Tasks plugin's priority emoji in words, nil for none.
    public static func priority(_ emoji: String?) -> String? {
        switch emoji {
        case "🔺": "highest priority"
        case "⏫": "high priority"
        case "🔼": "medium priority"
        case "🔽": "low priority"
        case "⏬": "lowest priority"
        default: nil
        }
    }

    /// A day next to [today]: "today", "tomorrow", "yesterday", or the date.
    public static func day(_ day: Day, today: Day) -> String {
        switch today.days(to: day) {
        case 0: "today"
        case 1: "tomorrow"
        case -1: "yesterday"
        default: day.description
        }
    }

    /// A task's due or scheduled day, and "overdue" when an open task's due
    /// day is past: what the board says with red.
    public static func when(_ task: ParsedTask, today: Day) -> String? {
        if let text = task.due {
            guard let due = Day(text) else { return "due \(text)" }
            let late = task.isOpen && due < today
            return "due \(day(due, today: today))" + (late ? ", overdue" : "")
        }
        if let text = task.scheduled {
            return "scheduled \(Day(text).map { day($0, today: today) } ?? text)"
        }
        return nil
    }

    /// `[[Target|label]]` as its label, `[[Target]]` as its target.
    public static func plain(_ text: String) -> String {
        text.replacing(/\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/) { String($0.2 ?? $0.1) }
    }

    /// A task row for VoiceOver, in the order the eye reads it: the text,
    /// the status, the day, the priority, the repeat, and where it is.
    /// `Call Sara, open, due today, high priority, repeats every week, in Work › Kit`.
    public static func task(_ task: ParsedTask, note: String? = nil, today: Day) -> String {
        var parts = [plain(task.text).trimmingCharacters(in: .whitespaces), status(task.status)]
        if let when = when(task, today: today) { parts.append(when) }
        if let priority = priority(task.priority) { parts.append(priority) }
        if let rule = task.recurring?.trimmingCharacters(in: .whitespaces), !rule.isEmpty { parts.append("repeats \(rule)") }
        let place = [note, task.section.isEmpty ? nil : task.section].compactMap { $0 }.joined(separator: " › ")
        if !place.isEmpty { parts.append("in \(place)") }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// A heading in an outline: "Heading level 2, Plans".
    public static func heading(level: Int, text: String) -> String {
        "Heading level \(level), \(text)"
    }

    /// A count with its noun: "1 note", "3 notes".
    public static func count(_ count: Int, _ noun: String, plural: String? = nil) -> String {
        "\(count) \(count == 1 ? noun : plural ?? noun + "s")"
    }
}
