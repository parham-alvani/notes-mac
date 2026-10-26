import Foundation

/// Dates written the way moment.js writes them, which is how Obsidian names
/// a daily note and fills `{{date:…}}` in a template. Ported from the
/// phone's `MomentFormat.kt`: the format is read token by token and each is
/// answered from the date, in moment's English locale.
public enum MomentFormat {
    /// A moment of the day, for the time tokens of a template.
    public struct Clock: Sendable, Hashable {
        public var hour: Int, minute: Int, second: Int
        public init(hour: Int = 0, minute: Int = 0, second: Int = 0) {
            self.hour = hour; self.minute = minute; self.second = second
        }
        public static func now(in zone: TimeZone = .current) -> Clock {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let parts = calendar.dateComponents([.hour, .minute, .second], from: Date())
            return Clock(hour: parts.hour!, minute: parts.minute!, second: parts.second!)
        }
    }

    nonisolated(unsafe) private static let pattern = /\[[^\[]*\]|\\.|Mo|MMMM|MMM|MM|M|Do|DDDD|DDD|DD|D|dddd|ddd|dd|do|d|wo|ww|w|Wo|WW|W|Qo|Q|YYYY|YY|gggg|gg|GGGG|GG|HH|H|hh|h|mm|m|ss|s|A|a|e|E|./.dotMatchesNewlines()

    /// [format] cut into the tokens moment reads it as, literals included.
    static func tokens(_ format: String) -> [String] { format.matches(of: pattern).map { String($0.output) } }

    public static func format(_ format: String, _ day: Day, clock: Clock = Clock()) -> String {
        tokens(format).map { token($0, day, clock) }.joined()
    }

    /// Moment's English week: it starts on Sunday, and week 1 holds the 1st of January.
    static let localeWeeks: Calendar = weeks(firstWeekday: 1, minimumDays: 1)
    static let isoWeeks: Calendar = weeks(firstWeekday: 2, minimumDays: 4)

    private static func weeks(firstWeekday: Int, minimumDays: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = firstWeekday
        calendar.minimumDaysInFirstWeek = minimumDays
        return calendar
    }

    static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    /// Sunday first, as moment numbers them.
    static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    private static func token(_ token: String, _ day: Day, _ clock: Clock) -> String {
        func pad(_ n: Int, _ width: Int = 2) -> String { String(repeating: "0", count: max(0, width - String(n).count)) + String(n) }
        let weekday = day.momentWeekday
        switch token {
        case "YYYY": return pad(day.year, 4)
        case "YY": return pad(((day.year % 100) + 100) % 100)
        case "Q": return String(day.quarter)
        case "Qo": return ordinal(day.quarter)
        case "MMMM": return months[day.month - 1]
        case "MMM": return String(months[day.month - 1].prefix(3))
        case "MM": return pad(day.month)
        case "M": return String(day.month)
        case "Mo": return ordinal(day.month)
        case "DDDD": return pad(day.dayOfYear, 3)
        case "DDD": return String(day.dayOfYear)
        case "DD": return pad(day.day)
        case "D": return String(day.day)
        case "Do": return ordinal(day.day)
        case "dddd": return weekdays[weekday]
        case "ddd": return String(weekdays[weekday].prefix(3))
        case "dd": return String(weekdays[weekday].prefix(2))
        case "d", "e": return String(weekday)
        case "do": return ordinal(weekday)
        case "E": return String(weekday == 0 ? 7 : weekday)
        case "w": return String(day.week(localeWeeks))
        case "ww": return pad(day.week(localeWeeks))
        case "wo": return ordinal(day.week(localeWeeks))
        case "gggg": return pad(day.weekYear(localeWeeks), 4)
        case "gg": return pad(day.weekYear(localeWeeks) % 100)
        case "W": return String(day.week(isoWeeks))
        case "WW": return pad(day.week(isoWeeks))
        case "Wo": return ordinal(day.week(isoWeeks))
        case "GGGG": return pad(day.weekYear(isoWeeks), 4)
        case "GG": return pad(day.weekYear(isoWeeks) % 100)
        case "HH": return pad(clock.hour)
        case "H": return String(clock.hour)
        case "hh": return pad(clock.hour % 12 == 0 ? 12 : clock.hour % 12)
        case "h": return String(clock.hour % 12 == 0 ? 12 : clock.hour % 12)
        case "mm": return pad(clock.minute)
        case "m": return String(clock.minute)
        case "ss": return pad(clock.second)
        case "s": return String(clock.second)
        case "A": return clock.hour < 12 ? "AM" : "PM"
        case "a": return clock.hour < 12 ? "am" : "pm"
        default: return literal(token)
        }
    }

    static func literal(_ token: String) -> String {
        if token.count > 1, token.hasPrefix("[") { return String(token.dropFirst().dropLast()) }
        if token.count == 2, token.hasPrefix("\\") { return String(token.dropFirst()) }
        return token
    }

    /// English ordinals, as moment's default locale writes them.
    static func ordinal(_ n: Int) -> String {
        if (11...13).contains(n % 100) { return "\(n)th" }
        switch n % 10 {
        case 1: return "\(n)st"
        case 2: return "\(n)nd"
        case 3: return "\(n)rd"
        default: return "\(n)th"
        }
    }
}

extension Day {
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 0 for Sunday, as moment counts.
    var momentWeekday: Int { weekday - 1 }
    var dayOfYear: Int { Self.utc.ordinality(of: .day, in: .year, for: date)! }
    var quarter: Int { (month - 1) / 3 + 1 }
    func week(_ calendar: Calendar) -> Int { calendar.component(.weekOfYear, from: date) }
    func weekYear(_ calendar: Calendar) -> Int { calendar.component(.yearForWeekOfYear, from: date) }
    public func adding(years: Int) -> Day { Day(date: Self.utc.date(byAdding: .year, value: years, to: date)!) }
    /// A real day of the calendar, not 30 February.
    static func valid(_ year: Int, _ month: Int, _ day: Int) -> Day? {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        let made = Day(year: year, month: month, day: day)
        return Day(date: made.date) == made ? made : nil
    }
}

/// Where Obsidian's Daily notes plugin keeps a day's note: the two settings
/// of `.obsidian/daily-notes.json` that decide the path, and the template a
/// new note starts from. Blank or missing means the default.
public struct DailyNotes: Sendable, Hashable {
    public static let defaultFormat = "YYYY-MM-DD"
    /// Vault-relative, empty for the root.
    public var folder: String
    /// A moment format, which may itself hold `/` and so subfolders.
    public var format: String
    /// The template's path without `.md`, empty for none.
    public var template: String

    public init(folder: String = "", format: String = defaultFormat, template: String = "") {
        self.folder = folder.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let format = format.trimmingCharacters(in: .whitespaces)
        self.format = format.isEmpty ? Self.defaultFormat : format
        self.template = template.trimmingCharacters(in: .whitespaces)
    }

    public init(json: Data) {
        let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
        self.init(folder: root["folder"] as? String ?? "", format: root["format"] as? String ?? "", template: root["template"] as? String ?? "")
    }

    /// The settings of the vault at [root].
    public static func read(root: URL) -> DailyNotes {
        (try? Data(contentsOf: root.appending(path: ".obsidian/daily-notes.json"))).map(DailyNotes.init(json:)) ?? DailyNotes()
    }
}

/// How much time one note of a daily-notes format covers.
public enum Period: Sendable, Hashable {
    case day, week, month, quarter, year

    /// The command that opens the current period's note.
    public var current: String {
        switch self {
        case .day: "Today's Note"
        case .week: "This Week's Note"
        case .month: "This Month's Note"
        case .quarter: "This Quarter's Note"
        case .year: "This Year's Note"
        }
    }

    /// The word the app shows: "Today's note" is a week note in a weekly vault.
    public var noun: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        case .quarter: "Quarter"
        case .year: "Year"
        }
    }
}

/// The daily notes read as a series of periods, as the phone's
/// `PeriodicNotes.kt` reads them: a format with no day in it (`YYYY-[W]ww`,
/// `YYYY-MM`) names one note for a whole week or month. A period is known by
/// the day it starts on. A name is read loosely, then accepted only when a
/// day of its period formats to it again, so `2026-02-30` is an ordinary note.
public struct PeriodicNotes: Sendable {
    public let config: DailyNotes
    public let period: Period
    private let tokens: [String]
    private let iso: Bool
    /// The token each capture group stands for, in order.
    private let groups: [String]
    private let pattern: String

    private static let dayTokens: Set = ["D", "DD", "Do", "DDD", "DDDD", "d", "dd", "ddd", "dddd", "do", "e", "E"]
    private static let weekTokens: Set = ["w", "ww", "wo", "W", "WW", "Wo"]
    private static let isoTokens: Set = ["W", "WW", "Wo", "GGGG", "GG"]
    private static let monthTokens: Set = ["M", "MM", "Mo", "MMM", "MMMM"]

    public init(_ config: DailyNotes) {
        self.config = config
        let tokens = MomentFormat.tokens(config.format)
        self.tokens = tokens
        let has = { (set: Set<String>) in tokens.contains(where: set.contains) }
        period = has(Self.dayTokens) ? .day : has(Self.weekTokens) ? .week : has(Self.monthTokens) ? .month
            : has(["Q", "Qo"]) ? .quarter : .year
        iso = has(Self.isoTokens)
        var groups: [String] = []
        pattern = "^" + tokens.map { token in
            if let regex = Self.regex(for: token) { groups.append(token); return regex }
            return NSRegularExpression.escapedPattern(for: MomentFormat.literal(token))
        }.joined() + "$"
        self.groups = groups
    }

    private var weeks: Calendar { iso ? MomentFormat.isoWeeks : MomentFormat.localeWeeks }

    /// The first day of the period [day] falls in.
    public func start(of day: Day) -> Day {
        switch period {
        case .day: return day
        case .week:
            let first = weeks.firstWeekday - 1
            return day.adding(days: -((day.momentWeekday - first + 7) % 7))
        case .month: return Day(year: day.year, month: day.month, day: 1)
        case .quarter: return Day(year: day.year, month: (day.month - 1) / 3 * 3 + 1, day: 1)
        case .year: return Day(year: day.year, month: 1, day: 1)
        }
    }

    /// The start of the period [by] periods after the one starting on [start].
    public func shift(_ start: Day, by: Int) -> Day {
        switch period {
        case .day: start.adding(days: by)
        case .week: start.adding(days: 7 * by)
        case .month: start.adding(months: by)
        case .quarter: start.adding(months: 3 * by)
        case .year: start.adding(years: by)
        }
    }

    /// The period [path] is the note of, by its start; nil when it is not a daily note.
    public func period(of path: String) -> Day? {
        guard let name = name(of: path),
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name))
        else { return nil }
        var fields: [String: String] = [:]
        for (index, token) in groups.enumerated() {
            if let range = Range(match.range(at: index + 1), in: name) { fields[token] = String(name[range]) }
        }
        guard let candidate = candidate(fields) else { return nil }
        let start = start(of: candidate)
        return days(from: start).contains { format($0) == name } ? start : nil
    }

    /// The note of the period starting on [start]. Where its days disagree
    /// (the week over New Year under `YYYY-[W]ww`), the name that reads back
    /// as this period.
    public func path(of start: Day) -> String {
        var names: [String] = []
        for day in days(from: start) where !names.contains(format(day)) { names.append(format(day)) }
        let own = names.first { period(of: path(named: $0)) == start } ?? names[0]
        return path(named: own)
    }

    /// The note of the period [day] falls in.
    public func path(for day: Day) -> String { path(of: start(of: day)) }

    public func previous(_ path: String) -> String? { period(of: path).map { self.path(of: shift($0, by: -1)) } }
    public func next(_ path: String) -> String? { period(of: path).map { self.path(of: shift($0, by: 1)) } }

    /// Of [paths], the daily note nearest to [from] in the direction of
    /// [step]: a journal kept in fits and starts has gaps.
    public func nearest(_ paths: some Collection<String>, from: String, step: Int) -> String? {
        guard let here = period(of: from) else { return nil }
        let periods = paths.compactMap { path in period(of: path).map { ($0, path) } }
        if step < 0 { return periods.filter { $0.0 < here }.max { ($0.0, $0.1) < ($1.0, $1.1) }?.1 }
        return periods.filter { $0.0 > here }.min { ($0.0, $0.1) < ($1.0, $1.1) }?.1
    }

    /// The notes of [paths] for the same time of year as [from] in earlier
    /// years, as years back and path, nearest first. Found by the calendar
    /// day, not by the number in the name. Nothing for a yearly note.
    public func yearsAgo(_ paths: some Collection<String>, from: String) -> [(years: Int, path: String)] {
        guard period != .year, let here = period(of: from),
            let earliest = paths.compactMap({ period(of: $0) }).min(), earliest.year < here.year
        else { return [] }
        let existing = Set(paths)
        return (1...(here.year - earliest.year)).compactMap { years in
            let path = path(of: start(of: here.adding(years: -years)))
            return existing.contains(path) && path != from ? (years, path) : nil
        }
    }

    private func days(from start: Day) -> [Day] {
        let end = shift(start, by: 1)
        return (0..<start.days(to: end)).map { start.adding(days: $0) }
    }

    private func format(_ day: Day) -> String {
        MomentFormat.format(config.format, day).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func path(named name: String) -> String { (config.folder.isEmpty ? name : "\(config.folder)/\(name)") + ".md" }

    private func name(of path: String) -> String? {
        guard path.hasSuffix(".md") else { return nil }
        var inside = Substring(path)
        if !config.folder.isEmpty {
            guard inside.hasPrefix(config.folder + "/") else { return nil }
            inside = inside.dropFirst(config.folder.count + 1)
        }
        return String(inside.dropLast(3))
    }

    /// A day inside the period the fields describe, when they describe one.
    private func candidate(_ fields: [String: String]) -> Day? {
        func int(_ keys: String...) -> Int? { keys.lazy.compactMap { fields[$0] }.first.flatMap(number) }
        func century(_ yy: Int) -> Int { yy + (yy > 68 ? 1900 : 2000) }
        let year = int("YYYY") ?? int("YY").map(century)
        let weekYear = (iso ? int("GGGG") ?? int("GG").map(century) : int("gggg") ?? int("gg").map(century)) ?? year
        let month = int("MMMM", "MMM", "MM", "M", "Mo")
        let dayOfMonth = int("DD", "D", "Do")
        let dayOfYear = int("DDDD", "DDD")
        let week = int("ww", "w", "wo", "WW", "W", "Wo")
        // Sunday first (0) as moment numbers a weekday, ISO's 7 for Sunday from E.
        let weekday = int("dddd", "ddd", "dd", "d", "do", "e") ?? int("E").map { $0 % 7 }
        let quarter = int("Q", "Qo")
        if let year, let month, let dayOfMonth { return Day.valid(year, month, dayOfMonth) }
        if let year, let dayOfYear {
            guard (1...366).contains(dayOfYear) else { return nil }
            let day = Day(year: year, month: 1, day: 1).adding(days: dayOfYear - 1)
            return day.year == year ? day : nil
        }
        if let weekYear, let week {
            var parts = DateComponents()
            parts.yearForWeekOfYear = weekYear
            parts.weekOfYear = week
            parts.weekday = weeks.firstWeekday
            guard (1...53).contains(week), let date = weeks.date(from: parts) else { return nil }
            let start = Day(date: date)
            if let weekday { return start.adding(days: (weekday - start.momentWeekday + 7) % 7) }
            return period == .day ? nil : start
        }
        if period == .day { return nil }
        if let year, let month { return Day.valid(year, month, 1) }
        if let year, let quarter { return (1...4).contains(quarter) ? Day(year: year, month: (quarter - 1) * 3 + 1, day: 1) : nil }
        if let year, period == .year { return Day(year: year, month: 1, day: 1) }
        return nil
    }

    /// Numbers as written, and names as the number they stand for.
    private func number(_ text: String) -> Int? {
        if let n = Int(text) { return n }
        if let n = Int(text.trimmingCharacters(in: .letters)) { return n }
        if let month = MomentFormat.months.firstIndex(where: { $0 == text || $0.prefix(3) == text }) { return month + 1 }
        return MomentFormat.weekdays.firstIndex { $0 == text || $0.prefix(3) == text || $0.prefix(2) == text }
    }

    private static func names(_ values: [String]) -> String {
        "(" + values.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")"
    }

    private static func regex(for token: String) -> String? {
        switch token {
        case "YYYY", "gggg", "GGGG": #"(\d{4})"#
        case "YY", "gg", "GG", "MM", "DD", "ww", "WW": #"(\d{2})"#
        case "M", "D", "w", "W": #"(\d{1,2})"#
        case "Mo", "Do", "wo", "Wo": #"(\d{1,2}(?:st|nd|rd|th))"#
        case "Q", "d", "e", "E": #"(\d)"#
        case "Qo", "do": #"(\d(?:st|nd|rd|th))"#
        case "DDDD": #"(\d{3})"#
        case "DDD": #"(\d{1,3})"#
        case "MMMM": names(MomentFormat.months)
        case "MMM": names(MomentFormat.months.map { String($0.prefix(3)) })
        case "dddd": names(MomentFormat.weekdays)
        case "ddd": names(MomentFormat.weekdays.map { String($0.prefix(3)) })
        case "dd": names(MomentFormat.weekdays.map { String($0.prefix(2)) })
        default: nil
        }
    }
}
