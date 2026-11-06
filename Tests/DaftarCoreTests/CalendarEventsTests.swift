import Foundation
import Testing

@testable import DaftarCore

// The holidays of a place and the month of the day picker
// (`docs/specs/calendar-events.md` in notes-linux): the tests of
// `calendar_events.rs` and `month_grid.rs` in Daftar for Linux, by the same
// names, so every app keeps the same days.

private func day(_ text: String) -> Day { Day(text)! }

private func titles(_ place: CalendarEvents.Place, _ from: String, _ to: String) -> [String] {
    CalendarEvents.between(place, from: day(from), to: day(to)).map { "\($0.day) \($0.event.title)" }
}

@Suite struct CalendarEventsTests {
    @Test func easterFallsWhereTheChurchPutsIt() {
        for (year, easter) in [
            (2000, "2000-04-23"), (2024, "2024-03-31"), (2025, "2025-04-20"), (2026, "2026-04-05"),
            (2027, "2027-03-28"), (2038, "2038-04-25"), (2285, "2285-03-22"),
        ] {
            #expect(CalendarEvents.easter(year) == day(easter), "\(year)")
        }
    }

    @Test func aPlaceIsReadFromTheConfig() {
        #expect(CalendarEvents.Place("barcelona") == .barcelona)
        #expect(CalendarEvents.Place(" Catalonia ") == .catalonia)
        #expect(CalendarEvents.Place("es") == .spain)
        #expect(CalendarEvents.Place("") == nil)
        #expect(CalendarEvents.Place("madrid") == nil)
    }

    @Test func barcelona2027HasTheOfficialHolidays() {
        let holidays = CalendarEvents.between(.barcelona, from: day("2027-01-01"), to: day("2027-12-31"))
            .filter(\.event.holiday).map(\.day.description)
        #expect(holidays == [
            "2027-01-01", "2027-01-06", "2027-03-26", "2027-03-29", "2027-05-01", "2027-05-17", "2027-06-24", "2027-08-15",
            "2027-09-11", "2027-09-24", "2027-10-12", "2027-11-01", "2027-12-06", "2027-12-08", "2027-12-25", "2027-12-26",
        ])
    }

    @Test func aPlaceKeepsTheDaysOfThePlacesAroundIt() {
        #expect(titles(.spain, "2027-03-26", "2027-03-29") == ["2027-03-26 Good Friday"])
        #expect(titles(.catalonia, "2027-03-26", "2027-03-29") == ["2027-03-26 Good Friday", "2027-03-29 Easter Monday"])
        #expect(titles(.catalonia, "2027-05-17", "2027-05-17").isEmpty)
        #expect(titles(.barcelona, "2027-05-17", "2027-05-17") == ["2027-05-17 Whit Monday"])
    }

    @Test func daysFromEasterAndWeekdaysMoveWithTheYear() {
        #expect(titles(.catalonia, "2027-02-01", "2027-02-28") == ["2027-02-04 Dijous Gras"])
        #expect(titles(.spain, "2026-05-01", "2026-05-31") == ["2026-05-01 Labour Day", "2026-05-03 Mother's Day"])
        #expect(titles(.spain, "2027-05-01", "2027-05-31") == ["2027-05-01 Labour Day", "2027-05-02 Mother's Day"])
    }

    @Test func aSpanRunsOverTheNewYearInOrder() {
        #expect(titles(.barcelona, "2026-12-24", "2027-01-06") == [
            "2026-12-24 Christmas Eve",
            "2026-12-25 Christmas Day",
            "2026-12-26 Sant Esteve",
            "2026-12-31 New Year's Eve",
            "2027-01-01 New Year's Day",
            "2027-01-05 Three Kings' Parade",
            "2027-01-06 Three Kings' Day",
        ])
    }

    @Test func aDatedEventIsOnlyInItsYears() {
        #expect(titles(.barcelona, "2026-07-18", "2026-07-18") == ["2026-07-18 Pride Barcelona"])
        #expect(titles(.barcelona, "2027-06-01", "2027-07-31").allSatisfy { !$0.contains("Pride") })
        #expect(titles(.catalonia, "2026-07-18", "2026-07-18").isEmpty)
    }

    @Test func oneDayListsItsEvents() {
        let on = CalendarEvents.on(.barcelona, day("2027-06-24"))
        #expect(on.map(\.title) == ["Sant Joan"])
        #expect(on.map(\.holiday) == [true])
        #expect(CalendarEvents.on(.barcelona, day("2027-06-25")).isEmpty)
    }

    @Test func titlesAreUnique() {
        #expect(Set(CalendarEvents.events.map(\.title)).count == CalendarEvents.events.count)
    }
}

@Suite struct MonthGridTests {
    @Test func aGregorianMonthStartsItsWeeksOnMonday() {
        let month = Month.of(.gregorian, day("2026-11-03"))
        #expect(month.title == "November 2026")
        let cells = month.cells
        // 1 November 2026 is a Sunday: six days before it.
        #expect(cells.prefix { $0 == nil }.count == 6)
        #expect(cells[6] == day("2026-11-01"))
        #expect(cells.compactMap { $0 }.count == 30)
        #expect(cells.count == 42)
        #expect(month.weekdays[0] == "Mo")
    }

    @Test func aJalaliMonthStartsItsWeeksOnSaturday() {
        let month = Month.of(.jalali, day("2026-11-03"))
        #expect(month.year == 1405 && month.month == 8)
        #expect(month.title == "آبان ۱۴۰۵")
        let cells = month.cells
        // 1 Aban 1405 is 2026-10-23, a Friday: six days after Saturday.
        #expect(cells.prefix { $0 == nil }.count == 6)
        #expect(cells[6] == day("2026-10-23"))
        #expect(cells.compactMap { $0 }.count == 30)
        #expect(month.number(day("2026-11-03")) == "۱۲")
        #expect(month.weekdays[0] == "ش")
    }

    @Test func monthsStepOverTheYear() {
        let esfand = Month(kind: .jalali, year: 1403, month: 12)
        #expect(esfand.cells.compactMap { $0 }.count == 30)
        #expect(esfand.adding(1) == Month(kind: .jalali, year: 1404, month: 1))
        #expect(esfand.adding(12).cells.compactMap { $0 }.count == 29)
        let january = Month(kind: .gregorian, year: 2027, month: 1)
        #expect(january.adding(-1) == Month(kind: .gregorian, year: 2026, month: 12))
        #expect(Month(kind: .gregorian, year: 2028, month: 2).cells.compactMap { $0 }.count == 29)
    }

    @Test func aMonthOffTheCalendarHasNoDays() {
        #expect(Month(kind: .jalali, year: 4000, month: 1).cells.isEmpty)
    }
}
