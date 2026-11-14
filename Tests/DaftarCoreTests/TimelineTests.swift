import Foundation
import Testing

@testable import DaftarCore

/// The cases of `today-timeline.md` §6 in notes-linux's `docs/specs`, by
/// the same names in every app. Times are UTC, and so is the viewer's zone
/// unless a test says otherwise.
@Suite struct TimelineTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let day = Day(year: 2026, month: 11, day: 14)

    /// [day] at [hour]:[minute] UTC.
    static func at(_ day: Day, _ hour: Int, _ minute: Int) -> Date {
        day.date.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
    }

    /// A meeting listed on [day] from [from] to [to], `HH:MM` UTC; an end
    /// not after the start is on the next day, as `23:00–Sat 01:00` is.
    static func meeting(_ day: Day, _ from: String, _ to: String, _ title: String = "Meeting", tentative: Bool = false) -> Meeting {
        func minutes(_ text: String) -> Int {
            let parts = text.split(separator: ":").map { Int($0)! }
            return parts[0] * 60 + parts[1]
        }
        let start = at(day, 0, minutes(from))
        var end = at(day, 0, minutes(to))
        if end <= start { end = end.addingTimeInterval(86_400) }
        return Meeting(
            day: day, start: start, end: end, title: title, calendars: [], join: nil,
            tentative: tentative, busyOnly: false, overlaps: nil)
    }

    static func task(_ line: String, at number: Int = 0) -> VaultTask {
        VaultTask(path: "Tasks.md", task: TaskLine.parse(line, line: number, section: "")!)
    }

    static func timeline(
        _ day: Day = TimelineTests.day, meetings: [Meeting] = [], tasks: [VaultTask] = [], zone: TimeZone = TimelineTests.utc, now: Date? = nil
    ) -> Timeline {
        Timeline(day: day, meetings: meetings, tasks: tasks, statuses: .defaults, zone: zone, now: now)
    }

    /// The item titled [title]: its lane and its lanes.
    static func lane(_ timeline: Timeline, _ title: String) -> [Int] {
        guard let item = timeline.items.first(where: { $0.title == title }) else { return [] }
        return [item.lane, item.lanes]
    }

    @Test func aTaskTimeIsReadFromTheStartOfItsText() {
        #expect(TaskTime.parse("09:30 Call Sara") == TaskTime(start: 570, end: 600, text: "Call Sara"))
        #expect(TaskTime.parse("9:30-10:15 Gym") == TaskTime(start: 570, end: 615, text: "Gym"))
        #expect(TaskTime.parse("14:00 – 15:30 Review") == TaskTime(start: 840, end: 930, text: "Review"))
        #expect(TaskTime.parse("7:15–7:45 Run") == TaskTime(start: 435, end: 465, text: "Run"))
        #expect(TaskTime.parse("23:50 Late") == TaskTime(start: 1430, end: 1440, text: "Late"))
        #expect(TaskTime.parse("12:00") == TaskTime(start: 720, end: 750, text: ""))
        #expect(TaskTime.parse("10:00-09:00 Back") == TaskTime(start: 600, end: 630, text: "Back"))
        for text in ["10:00am Coffee", "9:3 x", "24:00 x", "Call at 09:30", "12:60 x", ""] {
            #expect(TaskTime.parse(text) == nil, "\(text)")
        }
    }

    @Test func meetingsAndTasksShareLanesWhenTheyOverlap() {
        let day = Self.day
        let timeline = Self.timeline(
            meetings: [
                Self.meeting(day, "09:00", "10:00", "A"), Self.meeting(day, "09:30", "10:30", "B"),
                Self.meeting(day, "10:00", "11:00", "C"),
            ],
            tasks: [Self.task("- [ ] 11:00 Write 📅 2026-11-14")])
        #expect(Self.lane(timeline, "A") == [0, 2])
        #expect(Self.lane(timeline, "B") == [1, 2])
        #expect(Self.lane(timeline, "C") == [0, 2])
        #expect(Self.lane(timeline, "Write") == [0, 1])

        let same = Self.timeline(
            meetings: [Self.meeting(day, "13:00", "13:30", "Talk")], tasks: [Self.task("- [ ] 13:00 Lunch 📅 2026-11-14")])
        #expect(Self.lane(same, "Talk") == [0, 2])
        #expect(Self.lane(same, "Lunch") == [1, 2])
    }

    @Test func theAxisCoversTheWorkingDayAndEveryItem() {
        let day = Self.day
        func axis(_ timeline: Timeline) -> [Int] { [timeline.start, timeline.end] }
        #expect(axis(Self.timeline()) == [540, 1080])
        #expect(axis(Self.timeline(meetings: [Self.meeting(day, "07:45", "08:20")])) == [420, 1080])
        #expect(axis(Self.timeline(meetings: [Self.meeting(day, "17:30", "19:10")])) == [540, 1200])
        #expect(axis(Self.timeline(now: Self.at(day, 6, 10))) == [360, 1080])
    }

    @Test func freeTimeIsWhatNothingTakes() {
        let day = Self.day
        var meetings = [Self.meeting(day, "09:00", "10:00"), Self.meeting(day, "12:30", "13:00", tentative: true)]
        let tasks = [Self.task("- [ ] 13:00-13:40 Lunch 📅 2026-11-14"), Self.task("- [ ] 17:50 Call 📅 2026-11-14", at: 1)]
        #expect(Self.timeline(meetings: meetings, tasks: tasks).free.map { [$0.start, $0.end] } == [[600, 750], [820, 1070]])
        meetings.append(Self.meeting(day, "10:00", "12:20"))
        #expect(Self.timeline(meetings: meetings, tasks: tasks).free.map { [$0.start, $0.end] } == [[820, 1070]])
    }

    @Test func aMeetingOverMidnightIsCut() {
        let friday = Day(year: 2026, month: 11, day: 13)
        let late = Self.meeting(friday, "23:00", "01:00")
        #expect(Self.timeline(friday, meetings: [late]).items.map { [$0.start, $0.end] } == [[1380, 1440]])
        #expect(Self.timeline(Self.day, meetings: [late]).items.map { [$0.start, $0.end] } == [[0, 60]])

        let earlier = Self.meeting(Day(year: 2026, month: 11, day: 12), "23:00", "01:00")
        #expect(Self.timeline(Self.day, meetings: [earlier]).items.isEmpty)
        #expect(Self.timeline(Self.day.adding(days: 1), meetings: [earlier]).items.isEmpty)
    }

    @Test func theViewersZoneMovesAMeeting() {
        let tehran = TimeZone(identifier: "Asia/Tehran")!
        let timeline = Self.timeline(meetings: [Self.meeting(Self.day, "08:00", "09:00")], zone: tehran)
        #expect(timeline.items.map { [$0.start, $0.end] } == [[690, 750]])
    }

    @Test func nowMarksWhatIsPastAndCurrent() {
        let day = Self.day
        let meetings = [Self.meeting(day, "09:00", "10:00", "First"), Self.meeting(day, "10:00", "11:00", "Second")]
        let today = Self.timeline(meetings: meetings, now: Self.at(day, 10, 0))
        #expect(today.now == 600)
        #expect(today.items.map(\.title) == ["First", "Second"])
        #expect(today.items[0].past && !today.items[0].current)
        #expect(!today.items[1].past && today.items[1].current)

        let later = Self.timeline(meetings: meetings, now: Self.at(day.adding(days: 1), 10, 0))
        #expect(later.now == nil)
        #expect(!later.items.contains { $0.past || $0.current })
    }

    @Test func onlyTheDaysOpenTasksWithATime() {
        let lines = [
            "- [ ] 10:00 A 📅 2026-11-14", "- [x] 11:00 B 📅 2026-11-14", "- [ ] 12:00 C 📅 2026-11-15",
            "- [ ] D 📅 2026-11-14", "- [ ] 13:00 E ⏳ 2026-11-14",
        ]
        let tasks = lines.enumerated().map { Self.task($0.element, at: $0.offset) }
        #expect(Self.timeline(tasks: tasks).items.map(\.title) == ["A", "E"])
        #expect(Self.timeline(tasks: [Self.task("- [ ] 14:00 F ⏳ 2026-11-14 📅 2026-11-15")]).items.isEmpty)
    }

    @Test func aLengthIsWrittenShort() {
        #expect(Timeline.duration(45) == "45m")
        #expect(Timeline.duration(120) == "2h")
        #expect(Timeline.duration(90) == "1h 30m")
        #expect(Timeline.duration(0) == "0m")
    }
}
