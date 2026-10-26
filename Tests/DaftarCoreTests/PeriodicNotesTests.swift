import Foundation
import Testing

@testable import DaftarCore

/// The phone's `PeriodicNotesTest`, ported: expected names are what moment
/// writes (English locale) for the same format and date. Paths are synthetic.
@Suite struct PeriodicNotesTests {
    func notes(_ format: String, folder: String = "") -> PeriodicNotes { PeriodicNotes(DailyNotes(folder: folder, format: format)) }
    var weekly: PeriodicNotes { notes("YYYY-[W]ww") }
    func day(_ y: Int, _ m: Int, _ d: Int) -> Day { Day(year: y, month: m, day: d) }

    @Test func thePeriodFollowsFromTheSmallestThingWritten() {
        #expect(notes("YYYY-MM-DD").period == .day)
        #expect(notes("YYYY/MM/DDDD").period == .day)
        #expect(notes("gggg-[W]ww-ddd").period == .day)
        #expect(notes("dddd, MMMM Do YYYY").period == .day)
        #expect(notes("YYYY-[W]ww").period == .week)
        #expect(notes("GGGG-[W]WW").period == .week)
        #expect(notes("YYYY-MM").period == .month)
        #expect(notes("MMMM YYYY").period == .month)
        #expect(notes("YYYY-[Q]Q").period == .quarter)
        #expect(notes("YYYY").period == .year)
        #expect(notes("[Daily] YYYY-MM").period == .month)
    }

    @Test func aDailyNoteIsTheDayItNames() {
        let daily = notes("YYYY-MM-DD")
        #expect(daily.period(of: "2026-03-04.md") == day(2026, 3, 4))
        #expect(daily.previous("2026-03-01.md") == "2026-02-28.md")
        #expect(daily.next("2026-12-31.md") == "2027-01-01.md")
    }

    @Test func whatMomentWouldNotWriteIsAnOrdinaryNote() {
        let daily = notes("YYYY-MM-DD", folder: "Journal")
        #expect(daily.period(of: "Journal/2026-03-04.md") == day(2026, 3, 4))
        for path in ["2026-03-04.md", "Other/2026-03-04.md", "Journal/2026-02-30.md", "Journal/2026-13-01.md",
            "Journal/2026-3-4.md", "Journal/2026-03-04 notes.md", "Journal/2026-03-04.pdf", "Journal/Plan.md"] {
            #expect(daily.period(of: path) == nil, "\(path)")
        }
        #expect(daily.previous("Journal/Plan.md") == nil)
    }

    @Test func namesWeekdaysAndFoldersAreReadBack() {
        let daily = notes("YYYY/MM-MMMM/YYYY-MM-DD dddd", folder: "Journal/")
        let path = "Journal/2026/03-March/2026-03-04 Wednesday.md"
        #expect(daily.period(of: path) == day(2026, 3, 4))
        #expect(daily.next(path) == "Journal/2026/03-March/2026-03-05 Thursday.md")
        #expect(daily.previous("Journal/2026/03-March/2026-03-01 Sunday.md") == "Journal/2026/02-February/2026-02-28 Saturday.md")
        #expect(daily.period(of: "Journal/2026/03-March/2026-03-04 Friday.md") == nil)
        #expect(notes("dddd, MMMM Do YYYY").period(of: "Wednesday, March 4th 2026.md") == day(2026, 3, 4))
    }

    @Test func aWeeklyNoteStartsOnSunday() {
        #expect(MomentFormat.format("YYYY-[W]ww", day(2026, 9, 24)) == "2026-W39")
        #expect(weekly.period(of: "2026-W39.md") == day(2026, 9, 20))
        #expect(weekly.previous("2026-W39.md") == "2026-W38.md")
        #expect(weekly.next("2026-W39.md") == "2026-W40.md")
        #expect(weekly.period(of: "2026-W60.md") == nil)
        #expect(weekly.period(of: "2026-W00.md") == nil)
    }

    /// See the phone's test: `2026-W01` is both 28 Dec 2025 – 3 Jan 2026
    /// and 27–31 Dec 2026, and is read as the first.
    @Test func theWeekOverNewYearIsNamedAsMomentNamesIt() {
        func name(_ d: Day) -> String { MomentFormat.format("YYYY-[W]ww", d) }
        #expect(name(day(2026, 12, 26)) == "2026-W52")
        #expect(name(day(2026, 12, 27)) == "2026-W01")
        #expect(name(day(2026, 12, 31)) == "2026-W01")
        #expect(name(day(2027, 1, 1)) == "2027-W01")
        #expect(name(day(2026, 1, 1)) == "2026-W01")
        #expect(weekly.period(of: "2026-W01.md") == day(2025, 12, 28))
        #expect(weekly.period(of: "2027-W01.md") == day(2026, 12, 27))
        #expect(weekly.period(of: "2026-W52.md") == day(2026, 12, 20))
        #expect(weekly.next("2026-W52.md") == "2027-W01.md")
        #expect(weekly.previous("2027-W01.md") == "2026-W52.md")
        #expect(weekly.next("2027-W01.md") == "2027-W02.md")
        #expect(weekly.previous("2026-W01.md") == "2025-W52.md")
    }

    @Test func isoWeeksStartOnMonday() {
        let iso = notes("GGGG-[W]WW")
        #expect(iso.period(of: "2026-W53.md") == day(2026, 12, 28))
        #expect(iso.next("2026-W53.md") == "2027-W01.md")
        #expect(iso.period(of: "2027-W01.md") == day(2027, 1, 4))
        #expect(iso.previous("2027-W01.md") == "2026-W53.md")
        #expect(iso.period(of: "2027-W53.md") == nil)
    }

    @Test func monthsQuartersAndYearsStepByTheirLength() {
        let monthly = notes("YYYY-MM", folder: "Months")
        #expect(monthly.period(of: "Months/2026-12.md") == day(2026, 12, 1))
        #expect(monthly.next("Months/2026-12.md") == "Months/2027-01.md")
        #expect(monthly.previous("Months/2026-01.md") == "Months/2025-12.md")
        #expect(notes("MMMM YYYY").next("December 2026.md") == "January 2027.md")
        let quarterly = notes("YYYY-[Q]Q")
        #expect(quarterly.period(of: "2026-Q3.md") == day(2026, 7, 1))
        #expect(quarterly.next("2026-Q4.md") == "2027-Q1.md")
        #expect(quarterly.period(of: "2026-Q5.md") == nil)
        #expect(notes("YYYY").previous("2026.md") == "2025.md")
        #expect(notes("YYYY").period(of: "Plan.md") == nil)
    }

    @Test func thePeriodADayFallsIn() {
        let thursday = day(2026, 9, 24)
        #expect(weekly.start(of: thursday) == day(2026, 9, 20))
        #expect(notes("GGGG-[W]WW").start(of: thursday) == day(2026, 9, 21))
        #expect(notes("YYYY-MM").start(of: thursday) == day(2026, 9, 1))
        #expect(notes("YYYY-[Q]Q").start(of: thursday) == day(2026, 7, 1))
        #expect(notes("YYYY").start(of: thursday) == day(2026, 1, 1))
        #expect(weekly.path(for: thursday) == "2026-W39.md")
    }

    @Test func theNearestNoteSkipsTheGaps() {
        let paths = ["2026-W30.md", "2026-W35.md", "2026-W39.md", "2026-W44.md", "Plan.md", "2026-W99.md"]
        #expect(weekly.nearest(paths, from: "2026-W39.md", step: -1) == "2026-W35.md")
        #expect(weekly.nearest(paths, from: "2026-W39.md", step: 1) == "2026-W44.md")
        #expect(weekly.nearest(paths, from: "2026-W30.md", step: -1) == nil)
        #expect(weekly.nearest(paths, from: "2026-W44.md", step: 1) == nil)
        let boundary = ["2026-W01.md", "2026-W52.md", "2027-W01.md", "2027-W02.md"]
        #expect(weekly.nearest(boundary, from: "2026-W52.md", step: 1) == "2027-W01.md")
        #expect(weekly.nearest(boundary, from: "2027-W01.md", step: -1) == "2026-W52.md")
        #expect(weekly.nearest(paths, from: "Plan.md", step: 1) == nil)
    }

    @Test func theSameWeekInEarlierYears() {
        let paths = ["2026-W39.md", "2025-W38.md", "2025-W39.md", "2024-W38.md", "2022-W39.md", "Plan.md"]
        let found = weekly.yearsAgo(paths, from: "2026-W39.md")
        #expect(found.map(\.years) == [1, 2, 4])
        #expect(found.map(\.path) == ["2025-W38.md", "2024-W38.md", "2022-W39.md"])
        #expect(weekly.yearsAgo(paths, from: "Plan.md").isEmpty)
        let daily = notes("YYYY-MM-DD", folder: "Journal")
        #expect(daily.yearsAgo(["Journal/2026-09-27.md", "Journal/2025-09-27.md", "Journal/2025-09-26.md"], from: "Journal/2026-09-27.md").map(\.path) == ["Journal/2025-09-27.md"])
        #expect(notes("YYYY").yearsAgo(["2025.md", "2026.md"], from: "2026.md").isEmpty)
    }

    @Test func theSettingsFileIsRead() {
        let config = DailyNotes(json: Data(#"{"format":"YYYY-[W]ww","folder":"/Journal/","template":"Templates/Week"}"#.utf8))
        #expect(config.format == "YYYY-[W]ww")
        #expect(config.folder == "Journal")
        #expect(config.template == "Templates/Week")
        #expect(DailyNotes(json: Data(#"{"format":""}"#.utf8)).format == "YYYY-MM-DD")
        #expect(DailyNotes(json: Data("nonsense".utf8)) == DailyNotes())
    }

    @Test func timeTokensForTemplates() {
        let clock = MomentFormat.Clock(hour: 14, minute: 5, second: 9)
        #expect(MomentFormat.format("YYYY-MM-DD HH:mm:ss", day(2026, 10, 26), clock: clock) == "2026-10-26 14:05:09")
        #expect(MomentFormat.format("h:mm A, dddd Do MMMM", day(2026, 10, 26), clock: clock) == "2:05 PM, Monday 26th October")
    }
}

@Suite struct TemplatesTests {
    @Test func variablesAreFilled() {
        let templates = Templates(json: Data(#"{"folder":"Meta/Templates","dateFormat":"DD.MM.YYYY"}"#.utf8))
        let filled = templates.fill("# {{title}}\nMade {{date}} at {{ time }}, week {{date:ww}}, {{time:h A}}. {{other}}",
            title: "Plan", day: Day(year: 2026, month: 10, day: 26), clock: .init(hour: 9, minute: 30))
        #expect(filled == "# Plan\nMade 26.10.2026 at 09:30, week 44, 9 AM. {{other}}")
    }

    @Test func theTemplatesAreTheNotesOfTheFolder() {
        let paths = ["Meta/Templates/Week.md", "Meta/Templates/b.png", "Meta/Templates/Day.md", "Templates/Other.md", "Plan.md"]
        #expect(Templates(folder: "Meta/Templates/").templates(in: paths) == ["Meta/Templates/Day.md", "Meta/Templates/Week.md"])
        #expect(Templates().templates(in: paths) == ["Templates/Other.md"])
    }
}
