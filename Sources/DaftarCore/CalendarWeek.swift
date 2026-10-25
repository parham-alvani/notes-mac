import Foundation

/// One meeting, as Daftar on the phone wrote it into a week note.
public struct Meeting: Sendable, Hashable, Identifiable {
    public var day: Day
    /// Nil for an all-day event.
    public var start: Date?
    public var end: Date?
    public var title: String
    public var calendars: [String]
    public var join: URL?
    public var tentative: Bool
    /// The calendar is set to busy only: the time is real, the rest is not here.
    public var busyOnly: Bool
    public var overlaps: String?

    public var id: String { "\(day) \(start?.timeIntervalSince1970 ?? 0) \(title)" }
    public var allDay: Bool { start == nil }
}

/// One `## Monday 26 October` section of a week note.
public struct CalendarDay: Sendable, Hashable {
    public var day: Day
    public var free: String?
    public var meetings: [Meeting]
}

/// Reads the week notes in `Calendar/` (`2026-W44.md`). They are written by
/// Daftar on the phone, and their format is `Calendar/CLAUDE.md` in the vault.
/// The notes are only read here: they are written over at every change.
public enum CalendarWeek {
    public static let folder = "Calendar"

    public static func isWeekNote(_ path: String) -> Bool {
        path.wholeMatch(of: /Calendar\/\d{4}-W\d{2}\.md/) != nil
    }

    nonisolated(unsafe) private static let zoneLine = /Times are ([A-Za-z_]+\/[A-Za-z_\/+-]+|UTC)/
    nonisolated(unsafe) private static let dayHeading = /^## \w+ (\d{1,2}) (\w+)\s*$/
    nonisolated(unsafe) private static let event = /^- (All day|(\d{2}):(\d{2})–(?:\w{3} )?(\d{2}):(\d{2})) (.*)$/
    nonisolated(unsafe) private static let calendarsSuffix = /\s*\(((?:<[^>]+>(?:, )?)+)\)$/
    nonisolated(unsafe) private static let detail = /^\s{2,}- (\w+): (.*)$/
    private static let months = ["january", "february", "march", "april", "may", "june", "july", "august",
                                 "september", "october", "november", "december"]

    /// The days of one week note. [path] gives the year, which the headings leave out.
    public static func parse(_ text: String, path: String) -> [CalendarDay] {
        guard let match = path.firstMatch(of: /(\d{4})-W(\d{2})\.md$/), let isoYear = Int(match.1),
            let isoWeek = Int(match.2)
        else { return [] }
        let monday = mondayOf(isoYear: isoYear, week: isoWeek)
        let zone = text.firstMatch(of: zoneLine).flatMap { TimeZone(identifier: String($0.1)) } ?? .current

        var days: [CalendarDay] = []
        for line in text.components(separatedBy: "\n") {
            if let heading = line.wholeMatch(of: dayHeading), let date = Int(heading.1),
                let month = months.firstIndex(of: heading.2.lowercased())
            {
                // The week's Monday fixes the year: a week can start in December
                // and end in January.
                let candidates = [monday.year, monday.year + 1].map { Day(year: $0, month: month + 1, day: date) }
                let day = candidates.min { abs(monday.days(to: $0)) < abs(monday.days(to: $1)) }!
                days.append(CalendarDay(day: day, free: nil, meetings: []))
                continue
            }
            guard !days.isEmpty else { continue }
            if line.hasPrefix("Free: ") {
                days[days.count - 1].free = String(line.dropFirst(6)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                continue
            }
            if let found = line.wholeMatch(of: event) {
                let day = days[days.count - 1].day
                var rest = String(found.6)
                var calendars: [String] = []
                if let suffix = rest.firstMatch(of: calendarsSuffix) {
                    calendars = suffix.1.split(separator: ",").map {
                        $0.trimmingCharacters(in: CharacterSet(charactersIn: " <>"))
                    }
                    rest = String(rest[..<suffix.range.lowerBound])
                }
                let tentative = rest.hasSuffix(" (maybe)")
                if tentative { rest = String(rest.dropLast(" (maybe)".count)) }
                var meeting = Meeting(
                    day: day, start: nil, end: nil, title: unescape(rest), calendars: calendars, join: nil,
                    tentative: tentative, busyOnly: rest == "Busy", overlaps: nil)
                if let h1 = found.2, let m1 = found.3, let h2 = found.4, let m2 = found.5,
                    let start = time(day, Int(h1)!, Int(m1)!, zone), var end = time(day, Int(h2)!, Int(m2)!, zone)
                {
                    // `23:00–Sat 01:00` ends on a later day.
                    while end <= start { end = end.addingTimeInterval(86_400) }
                    meeting.start = start
                    meeting.end = end
                }
                days[days.count - 1].meetings.append(meeting)
                continue
            }
            if let found = line.wholeMatch(of: detail), var meeting = days[days.count - 1].meetings.popLast() {
                let value = String(found.2)
                switch found.1 {
                case "Join": meeting.join = URL(string: value.trimmingCharacters(in: CharacterSet(charactersIn: "<>")))
                case "Overlaps": meeting.overlaps = value
                default: break
                }
                days[days.count - 1].meetings.append(meeting)
            }
        }
        return days
    }

    /// The path of the week note that holds [day].
    public static func path(for day: Day) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: day.date)
        return String(format: "\(folder)/%04d-W%02d.md", parts.yearForWeekOfYear!, parts.weekOfYear!)
    }

    static func mondayOf(isoYear: Int, week: Int) -> Day {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(weekday: 2, weekOfYear: week, yearForWeekOfYear: isoYear))!
        return Day(date: date)
    }

    private static func time(_ day: Day, _ hour: Int, _ minute: Int, _ zone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: hour, minute: minute))
    }

    /// The week notes escape markdown in titles so the vault's lint passes.
    private static func unescape(_ text: String) -> String {
        text.replacing(/\\([\\`*_{}\[\]()#+\-.!|<>~=])/) { String($0.1) }
    }
}
