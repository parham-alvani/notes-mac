import Foundation

/// A notification the person defines: at a time of the day, a note that has
/// no heading for today rings (`docs/specs/notification-rules.md` in
/// notes-linux). A rule is a `[notifications.rules.<id>]` section of the
/// settings, so a vault's `.daftar.toml` can carry it to every device:
///
/// ```toml
/// [notifications.rules.diary]
/// note = "Diet/Diary.md"
/// heading = "D MMM YYYY · dddd"
/// at = "21:00"
/// ```
public struct NotificationRule: Sendable, Equatable {
    /// The section every rule is under, with its id after the dot.
    static let section = "notifications.rules"

    /// The keys of a rule, and what a vault's value of each must be.
    static let kinds: [String: ResolvedSettings.Kind] = [
        "note": .path, "heading": .text, "at": .clock, "title": .text, "message": .text,
    ]

    public var id: String
    /// The note's path in the vault.
    public var note: String
    /// A moment.js format of the day's heading.
    public var heading: String
    /// The time of the check on the wall clock, in minutes after midnight.
    public var at: Int
    public var title: String?
    public var message: String?

    public init(id: String, note: String, heading: String, at: Int, title: String? = nil, message: String? = nil) {
        self.id = id
        self.note = note
        self.heading = heading
        self.at = at
        self.title = title
        self.message = message
    }

    /// The rules [settings] set, the vault's first, each in the order its
    /// file writes them. A rule that lacks a key it needs, or has one that
    /// does not fit, is left out; [root] is the vault, whose `note` must stay in it.
    public static func all(_ settings: ResolvedSettings, root: URL? = nil) -> [NotificationRule] {
        var ids: [String] = []
        for key in settings.orderedKeys {
            if let (id, _) = split(key), !ids.contains(id) { ids.append(id) }
        }
        return ids.compactMap { read(settings, id: $0, root: root) }
    }

    private static func read(_ settings: ResolvedSettings, id: String, root: URL?) -> NotificationRule? {
        func key(_ name: String) -> String? { settings.string("\(section).\(id).\(name)") }
        func oneLine(_ text: String) -> Bool { !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
        func said(_ name: String) -> String? { key(name).flatMap { !$0.trimmingCharacters(in: .whitespaces).isEmpty && oneLine($0) ? $0 : nil } }
        guard let note = said("note")?.trimmingCharacters(in: .whitespaces), Vault.holds(note, in: root),
            let heading = said("heading"), let at = key("at").flatMap(minutes)
        else { return nil }
        return NotificationRule(id: id, note: note, heading: heading, at: at, title: said("title"), message: said("message"))
    }

    /// The rule's id and the key's name in [key], `notifications.rules.<id>.<name>`;
    /// nil for any other key and for an id with a character other than a
    /// letter, a digit, `_` or `-`.
    static func split(_ key: String) -> (id: String, name: String)? {
        guard key.hasPrefix(section + ".") else { return nil }
        let rest = key.dropFirst(section.count + 1)
        guard let dot = rest.lastIndex(of: ".") else { return nil }
        let id = rest[..<dot]
        guard !id.isEmpty, id.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") })
        else { return nil }
        return (String(id), String(rest[rest.index(after: dot)...]))
    }

    /// `HH:MM` in minutes after midnight, or nil.
    static func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isASCII) }),
            let hour = Int(parts[0]), let minute = Int(parts[1]), (0..<24).contains(hour), (0..<60).contains(minute)
        else { return nil }
        return hour * 60 + minute
    }

    /// The heading [day] should have: the format with the time at 00:00.
    public func expected(_ day: Day) -> String {
        MomentFormat.format(heading, day)
    }

    /// Whether [text], the note's, has no heading for [day]: none whose
    /// text, trimmed, starts with the expected one. A note that is not
    /// there is nil, and has none.
    public func isMissing(text: String?, day: Day) -> Bool {
        guard let text else { return true }
        let expected = expected(day)
        return !NoteParser.parse(text).headings.contains { $0.text.trimmingCharacters(in: .whitespaces).hasPrefix(expected) }
    }

    /// The alert's title: the rule's, else the note's name.
    public var alertTitle: String {
        if let title { return title }
        let name = note.split(separator: "/").last.map(String.init) ?? note
        return name.hasSuffix(".md") ? String(name.dropLast(3)) : name
    }

    /// The alert's body on [day]: the rule's message, else what is missing.
    public func body(_ day: Day) -> String {
        message ?? "No heading for today yet: \(expected(day))"
    }

    /// The alert's identifier, the same every day, so a day's alert replaces the day before's.
    public var alertId: String { "rule.\(id)" }

    /// When the alert next rings after [now] in [calendar], and the day it
    /// is about: today at `at` while that is ahead and the note lacks
    /// today's heading, else tomorrow at `at`; nil when that day's heading
    /// is there already. [text] reads the note.
    public func next(now: Date, calendar: Calendar = .current, text: String?) -> (at: Date, day: Day)? {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        for date in [now, tomorrow].compactMap({ calendar.date(bySettingHour: at / 60, minute: at % 60, second: 0, of: $0) }) where date > now {
            let day = Day(date: date, in: calendar.timeZone)
            // A day whose heading is there needs no alert; tomorrow's is asked only when today's is past or written.
            if isMissing(text: text, day: day) { return (date, day) }
        }
        return nil
    }
}
