import Foundation
import Testing

@testable import DaftarCore

// The Jalali calendar of `jalali.rs` in Daftar for Linux, with its tests by
// the same names: the apps must agree day for day.

@Suite struct JalaliTests {
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Day { Day(year: y, month: m, day: d) }

    @Test func nowruzAndTheMonthsFallWhereTheCalendarPutsThem() {
        #expect(Jalali(day(2026, 3, 21)) == Jalali(year: 1405, month: 1, day: 1))
        #expect(Jalali(day(2024, 3, 20)) == Jalali(year: 1403, month: 1, day: 1))
        #expect(Jalali(day(2026, 10, 27)) == Jalali(year: 1405, month: 8, day: 5))
        #expect(Jalali(day(2025, 3, 20)) == Jalali(year: 1403, month: 12, day: 30))
        #expect(Jalali(day(1979, 2, 11)) == Jalali(year: 1357, month: 11, day: 22))
    }

    @Test func aDayGoesThereAndBack() {
        var at = day(1990, 1, 1)
        var wrong: [Day] = []
        for _ in 0..<20_000 {
            if Jalali(at).gregorian != at { wrong.append(at) }
            at = at.adding(days: 3)
        }
        #expect(wrong.isEmpty, "\(wrong.prefix(5))")
        #expect(Jalali(year: 1404, month: 12, day: 30).gregorian == nil)
        #expect(Jalali(year: 1403, month: 12, day: 30).gregorian == day(2025, 3, 20))
    }

    @Test func aMonthOnKeepsTheDayOrTheLastOne() {
        // Dey 10 to Bahman 10, a day before the Gregorian month would go.
        #expect(Jalali.adding(months: 1, to: day(2026, 12, 31)) == day(2027, 1, 30))
        // Shahrivar 31 to Mehr 30.
        #expect(Jalali.adding(months: 1, to: day(2026, 9, 22)) == day(2026, 10, 22))
        // 1403-12-30, a leap Esfand, to 1404-12-29.
        #expect(Jalali.adding(months: 12, to: day(2025, 3, 20)) == day(2026, 3, 20))
        // Dey 10 1405 to Farvardin 10 1406, over the year's end.
        #expect(Jalali.adding(months: 3, to: day(2026, 12, 31)) == day(2027, 3, 30))
        #expect(Jalali.adding(months: -1, to: day(2026, 12, 31)) == day(2026, 12, 1))
        #expect(Jalali.adding(months: 12 * 5000, to: day(2026, 12, 31)) == nil)
        #expect(Jalali.adding(months: .max, to: day(2026, 12, 31)) == nil)
        #expect(Jalali.monthLength(year: 1403, month: 12) == 30)
        #expect(Jalali.monthLength(year: 1404, month: 12) == 29)
        #expect(Jalali.monthLength(year: 1404, month: 13) == nil)
    }

    @Test func itReadsAsPersian() {
        #expect(Jalali.long(day(2026, 10, 27)) == "سه‌شنبه ۵ آبان ۱۴۰۵")
        #expect(Jalali.persianDigits("2026-10") == "۲۰۲۶-۱۰")
        #expect(Jalali.latinDigits("۱۴۰۵/۰۸/۰۵") == "1405/08/05")
    }

    @Test func aJalaliDayTypedIsItsGregorianDay() {
        #expect(Jalali.parse("1405-08-05") == day(2026, 10, 27))
        #expect(Jalali.parse("۱۴۰۵/۸/۵") == day(2026, 10, 27))
        #expect(Jalali.parse("2026-10-27") == nil)
        #expect(Jalali.parse("1405-13-01") == nil)
        #expect(Jalali(day(2026, 10, 27)).iso == "1405-08-05")
    }
}
