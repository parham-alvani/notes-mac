import Foundation

/// A time at the start of a task's text, as the Obsidian Day Planner plugin
/// writes it: `09:30 Call Sara`, `14:00-15:30 Review`, `7:15 – 7:45 Run`.
/// The rules are `today-timeline.md` §1 in notes-linux's `docs/specs`; the
/// time is the viewer's wall clock, with no zone.
public struct TaskTime: Sendable, Hashable {
    /// Minutes from midnight.
    public var start: Int
    /// Minutes from midnight, after [start] and at most 1440.
    public var end: Int
    /// The text after the time, trimmed: what the timeline shows.
    public var text: String

    public init(start: Int, end: Int, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    /// How long a task with no end, or an end not after its start, lasts.
    public static let length = 30

    /// The time [text] starts with, or nil. A time is `H:MM` or `HH:MM` in
    /// ASCII digits, maybe followed by `-` or `–` (a space on each side or
    /// not) and an end, and then by a space or the end of the text.
    public static func parse(_ text: String) -> TaskTime? {
        let bytes = Array(text.utf8)
        guard let start = clock(bytes, at: 0) else { return nil }
        if let end = range(bytes, at: start.next), ends(bytes, at: end.next) {
            return made(start: start.minutes, end: end.minutes, bytes, from: end.next)
        }
        guard ends(bytes, at: start.next) else { return nil }
        return made(start: start.minutes, end: nil, bytes, from: start.next)
    }

    private static func made(start: Int, end: Int?, _ bytes: [UInt8], from index: Int) -> TaskTime {
        let finish = end.flatMap { $0 > start ? $0 : nil } ?? min(start + length, 1440)
        let rest = String(decoding: bytes[index...], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return TaskTime(start: start, end: finish, text: rest)
    }

    /// `H:MM` or `HH:MM` at [index]: its minutes and the index after it.
    private static func clock(_ bytes: [UInt8], at index: Int) -> (minutes: Int, next: Int)? {
        var at = index
        var hours = 0
        var digits = 0
        while at < bytes.count, digits < 2, let value = digit(bytes[at]) {
            hours = hours * 10 + value
            at += 1
            digits += 1
        }
        guard digits > 0, at < bytes.count, bytes[at] == 0x3A else { return nil }
        at += 1
        guard at + 1 < bytes.count, let tens = digit(bytes[at]), let ones = digit(bytes[at + 1]) else { return nil }
        let minutes = tens * 10 + ones
        guard hours < 24, minutes < 60 else { return nil }
        return (hours * 60 + minutes, at + 2)
    }

    /// ` - 15:30`, `–15:30` and the like at [index]: the end's minutes and the index after it.
    private static func range(_ bytes: [UInt8], at index: Int) -> (minutes: Int, next: Int)? {
        var at = index
        if at < bytes.count, bytes[at] == 0x20 { at += 1 }
        if at < bytes.count, bytes[at] == 0x2D {
            at += 1
        } else if at + 2 < bytes.count, bytes[at] == 0xE2, bytes[at + 1] == 0x80, bytes[at + 2] == 0x93 {
            at += 3
        } else {
            return nil
        }
        if at < bytes.count, bytes[at] == 0x20 { at += 1 }
        return clock(bytes, at: at)
    }

    /// A time is followed by a space or by the end of the text.
    private static func ends(_ bytes: [UInt8], at index: Int) -> Bool {
        index == bytes.count || bytes[index] == 0x20
    }

    private static func digit(_ byte: UInt8) -> Int? {
        byte >= 0x30 && byte <= 0x39 ? Int(byte - 0x30) : nil
    }
}

/// One day's meetings and timed tasks on one axis of hours, with the free
/// time of the working day between them and the minute of now: the rules of
/// `today-timeline.md` §2–§4 in notes-linux's `docs/specs`. Every time is
/// in minutes from the day's midnight on the viewer's wall clock.
public struct Timeline: Sendable {
    /// What an item on the axis stands for.
    public enum Source: Sendable, Hashable {
        case meeting(Meeting)
        case task(VaultTask)
    }

    /// A meeting or a task on the axis, in its lane.
    public struct Item: Sendable, Hashable, Identifiable {
        public var source: Source
        public var start: Int
        public var end: Int
        /// The meeting's title, or the task's text after its time.
        public var title: String
        /// Its column, from 0, of [lanes] equal ones.
        public var lane = 0
        /// The lanes its cluster of overlapping items uses.
        public var lanes = 1
        /// Ended by now.
        public var past = false
        /// Started by now and not ended.
        public var current = false
        public var id: String

        public var meeting: Meeting? {
            switch source {
            case .meeting(let meeting): return meeting
            case .task: return nil
            }
        }

        public var task: VaultTask? {
            switch source {
            case .meeting: return nil
            case .task(let task): return task
            }
        }

        var isMeeting: Bool { meeting != nil }
    }

    /// A stretch of the working day that nothing takes.
    public struct Free: Sendable, Hashable {
        public var start: Int
        public var end: Int
        public var minutes: Int { end - start }
    }

    /// 09:00 to 18:00, as the week notes count free time.
    public static let workingDay = 540..<1080

    /// `calendar.working_day`, `HH:MM-HH:MM` with the start before the end,
    /// in minutes after midnight; the default for a value that does not fit
    /// (`docs/specs/more-vault-settings.md`, section 1).
    public static func workingDay(_ text: String?) -> Range<Int> {
        let parts = text?.split(separator: "-", omittingEmptySubsequences: false).map { NotificationRule.minutes(String($0).trimmingCharacters(in: .whitespaces)) }
        guard let parts, parts.count == 2, let start = parts[0], let end = parts[1], start < end else { return workingDay }
        return start..<end
    }
    /// Free time shorter than this is not free time.
    public static let shortestFree = 15

    public var day: Day
    /// The meetings and tasks, by start, the longer first, meetings before tasks.
    public var items: [Item]
    /// The day's all-day events, in their order in the note.
    public var allDay: [Meeting]
    public var free: [Free]
    /// Where the axis starts and ends, on the hour.
    public var start: Int
    public var end: Int
    /// The minute of now, when [day] is today in [zone].
    public var now: Int?

    /// - Parameters:
    ///   - meetings: the meetings of the day's week note and the day before;
    ///     others are left out.
    ///   - tasks: the vault's tasks; the day's open ones with a time are taken.
    public init(
        day: Day, meetings: [Meeting], tasks: [VaultTask], statuses: TaskStatuses = .current,
        zone: TimeZone = .current, now: Date? = nil, workingDay: Range<Int> = Timeline.workingDay
    ) {
        self.day = day
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let next = day.adding(days: 1)
        let midnight = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) ?? day.date
        let nextMidnight = calendar.date(from: DateComponents(year: next.year, month: next.month, day: next.day)) ?? next.date
        func minute(_ date: Date) -> Int {
            if date <= midnight { return 0 }
            if date >= nextMidnight { return 1440 }
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }

        var found: [Item] = []
        let before = day.adding(days: -1)
        for (offset, meeting) in meetings.enumerated() where meeting.day == day || meeting.day == before {
            guard let from = meeting.start, let to = meeting.end, to > midnight, from < nextMidnight else { continue }
            let start = minute(from)
            let end = minute(to)
            guard end > start else { continue }
            found.append(Item(source: .meeting(meeting), start: start, end: end, title: meeting.title, id: "meeting \(offset) \(meeting.id)"))
        }
        allDay = meetings.filter { $0.allDay && $0.day == day }
        for task in tasks where !statuses.isClosed(task.task.status) {
            guard let text = task.task.day, Day(text) == day, let time = TaskTime.parse(task.task.text) else { continue }
            found.append(Item(source: .task(task), start: time.start, end: time.end, title: time.text, id: "task \(task.id)"))
        }

        // By start, the longer first, meetings before tasks, then as they came.
        let order = found.indices.sorted { a, b in
            let x = found[a]
            let y = found[b]
            if x.start != y.start { return x.start < y.start }
            if x.end - x.start != y.end - y.start { return x.end - x.start > y.end - y.start }
            if x.isMeeting != y.isMeeting { return x.isMeeting }
            return a < b
        }
        var items = order.map { found[$0] }

        // A cluster runs while each item starts before the latest end so far;
        // each item takes the first lane free by its start.
        var first = 0
        var laneEnds: [Int] = []
        var latest = Int.min
        for at in items.indices {
            if at > 0, items[at].start >= latest {
                for done in first..<at { items[done].lanes = laneEnds.count }
                first = at
                laneEnds = []
            }
            if let lane = laneEnds.firstIndex(where: { $0 <= items[at].start }) {
                items[at].lane = lane
                laneEnds[lane] = items[at].end
            } else {
                items[at].lane = laneEnds.count
                laneEnds.append(items[at].end)
            }
            latest = at == first ? items[at].end : max(latest, items[at].end)
        }
        for done in first..<items.count { items[done].lanes = laneEnds.count }

        var nowMinute: Int?
        if let now, Day(date: now, in: zone) == day { nowMinute = minute(now) }
        if let nowMinute {
            for at in items.indices {
                items[at].past = items[at].end <= nowMinute
                items[at].current = items[at].start <= nowMinute && items[at].end > nowMinute
            }
        }
        self.now = nowMinute
        self.items = items

        var low = workingDay.lowerBound
        var high = workingDay.upperBound
        for item in items {
            low = min(low, item.start)
            high = max(high, item.end)
        }
        if let nowMinute {
            low = min(low, nowMinute)
            high = max(high, nowMinute)
        }
        start = max(0, low / 60 * 60)
        end = min(1440, (high + 59) / 60 * 60)

        // Free time: the working day less every item, tentative meetings too.
        var free: [Free] = []
        var cursor = workingDay.lowerBound
        func gap(_ from: Int, _ to: Int) {
            if to - from >= Self.shortestFree { free.append(Free(start: from, end: to)) }
        }
        for item in items {
            if item.start > cursor { gap(cursor, min(item.start, workingDay.upperBound)) }
            cursor = max(cursor, item.end)
        }
        gap(cursor, workingDay.upperBound)
        self.free = free
    }

    /// A length as free time is labelled: `45m`, `2h`, `1h 30m`.
    public static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        if rest == 0 { return "\(hours)h" }
        return "\(hours)h \(rest)m"
    }
}
