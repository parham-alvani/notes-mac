import Foundation

/// A day of the Solar Hijri (Jalali) calendar, Iran's own: a day of it from
/// a Gregorian day and back, its month and weekday names, and Persian digits.
/// The arithmetic is jalaali-js's (Borkowski's leap years, as Iran's
/// calendar sets them), good from 1 to 3177 of the Jalali years. It is
/// `jalali.rs` of Daftar for Linux, ported, so the apps agree day for day;
/// never Foundation's `.persian` calendar, whose leap years can differ.
public struct Jalali: Sendable, Hashable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public static let months = ["فروردین", "اردیبهشت", "خرداد", "تیر", "مرداد", "شهریور", "مهر", "آبان", "آذر", "دی", "بهمن", "اسفند"]

    /// From Monday.
    public static let weekdays = ["دوشنبه", "سه‌شنبه", "چهارشنبه", "پنجشنبه", "جمعه", "شنبه", "یکشنبه"]

    private static let breaks = [-61, 9, 38, 199, 426, 686, 756, 818, 1111, 1181, 1210, 1635, 2060, 2097, 2192, 2262, 2324, 2394, 2456, 3178]

    /// Whether [year] is leap, the Gregorian year it starts in, and the day
    /// of March of that year its first day falls on.
    static func yearOf(_ year: Int) -> (leap: Bool, gregorian: Int, march: Int)? {
        guard year >= breaks[0], year < breaks[breaks.count - 1] else { return nil }
        let gregorian = year + 621
        var leapJ = -14
        var previous = breaks[0]
        var jump = 0
        for next in breaks.dropFirst() {
            jump = next - previous
            if year < next { break }
            leapJ += jump / 33 * 8 + jump % 33 / 4
            previous = next
        }
        var n = year - previous
        leapJ += n / 33 * 8 + (n % 33 + 3) / 4
        if jump % 33 == 4, jump - n == 4 { leapJ += 1 }
        let leapG = gregorian / 4 - (gregorian / 100 + 1) * 3 / 4 - 150
        let march = 20 + leapJ - leapG
        if jump - n < 6 { n = n - jump + (jump + 4) / 33 * 33 }
        var leap = ((n + 1) % 33 - 1) % 4
        if leap == -1 { leap = 4 }
        return (leap == 0, gregorian, march)
    }

    /// The Julian day number of a Gregorian day.
    static func julian(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let d = (year + (month - 8) / 6 + 100100) * 1461 / 4 + (153 * ((month + 9) % 12) + 2) / 5 + day - 34840408
        return d - (year + 100100 + (month - 8) / 6) / 100 * 3 / 4 + 752
    }

    /// The Gregorian day of a Julian day number (proleptic, as chrono's).
    static func fromJulian(_ jdn: Int) -> Day {
        var j = 4 * jdn + 139361631
        j += (4 * jdn + 183187720) / 146097 * 3 / 4 * 4 - 3908
        let i = j % 1461 / 4 * 5 + 308
        let day = i % 153 / 5 + 1
        let month = i / 153 % 12 + 1
        let year = j / 1461 - 100100 + (8 - month) / 6
        return Day(year: year, month: month, day: day)
    }

    public init(_ gregorian: Day) {
        let jdn = Self.julian(gregorian.year, gregorian.month, gregorian.day)
        let gregorianYear = Self.fromJulian(jdn).year
        var year = gregorianYear - 621
        let march = Self.yearOf(year)?.march ?? 20
        var k = jdn - Self.julian(gregorianYear, 3, march)
        if k >= 0 {
            if k <= 185 {
                self.init(year: year, month: 1 + k / 31, day: k % 31 + 1)
                return
            }
            k -= 186
        } else {
            year -= 1
            k += 179
            if Self.yearOf(year)?.leap == true { k += 1 }
        }
        self.init(year: year, month: 7 + k / 30, day: k % 30 + 1)
    }

    /// The days of [month] in [year]: 31 in the first six months, 30 in the
    /// next five, and Esfand's 30 in a leap year or 29. Nil for a month or a
    /// year the calendar does not have.
    public static func monthLength(year: Int, month: Int) -> Int? {
        guard let info = yearOf(year) else { return nil }
        switch month {
        case 1...6: return 31
        case 7...11: return 30
        case 12: return info.leap ? 30 : 29
        default: return nil
        }
    }

    /// [months] Jalali months after [day], on the same day of the month or
    /// the last day of a shorter one (Shahrivar 31 and a month is Mehr 30):
    /// the step of `🔁 every jalali month` (`docs/specs/jalali-recurrence.md`
    /// in notes-linux). Nil past the calendar's range.
    public static func adding(months: Int, to day: Day) -> Day? {
        let from = Jalali(day)
        let (index, overflow) = (from.year * 12 + from.month - 1).addingReportingOverflow(months)
        guard !overflow else { return nil }
        let year = index >= 0 ? index / 12 : (index + 1) / 12 - 1
        let month = index - year * 12 + 1
        guard let length = monthLength(year: year, month: month) else { return nil }
        return Jalali(year: year, month: month, day: min(from.day, length)).gregorian
    }

    /// The Gregorian day, or nil for a day the calendar does not have.
    public var gregorian: Day? {
        guard let info = Self.yearOf(year),
            let length = Self.monthLength(year: year, month: month),
            day >= 1, day <= length
        else { return nil }
        let first = Self.julian(info.gregorian, 3, info.march)
        return Self.fromJulian(first + (month - 1) * 31 - month / 7 * (month - 7) + day - 1)
    }

    public var monthName: String { Self.months[min(max(month, 1), 12) - 1] }

    /// `سه‌شنبه ۵ آبان ۱۴۰۵`: the day as it is said in Persian.
    public static func long(_ day: Day) -> String {
        let jalali = Jalali(day)
        let jdn = julian(day.year, day.month, day.day)
        let weekday = weekdays[((jdn % 7) + 7) % 7]
        return persianDigits("\(weekday) \(jalali.day) \(jalali.monthName) \(jalali.year)")
    }

    /// A day typed as `1405-08-05`, in Latin or Persian digits, as the
    /// Gregorian day it is; a year before 1700 is a Jalali year.
    public static func parse(_ text: String) -> Day? {
        let latin = latinDigits(text.trimmingCharacters(in: .whitespacesAndNewlines))
        let parts = latin.split(omittingEmptySubsequences: false) { $0 == "-" || $0 == "/" }
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
            month >= 0, day >= 0, year < 1700
        else { return nil }
        return Jalali(year: year, month: month, day: day).gregorian
    }

    /// `1405-08-05`.
    public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public var description: String { iso }

    /// The digits 0-9 as Persian ones.
    public static func persianDigits(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { (scalar: Unicode.Scalar) -> Unicode.Scalar in
            guard scalar.value >= 0x30, scalar.value <= 0x39 else { return scalar }
            return Unicode.Scalar(0x06F0 + scalar.value - 0x30)!
        }))
    }

    /// Persian and Arabic digits as ASCII ones.
    public static func latinDigits(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { (scalar: Unicode.Scalar) -> Unicode.Scalar in
            switch scalar.value {
            case 0x06F0...0x06F9: return Unicode.Scalar(0x30 + scalar.value - 0x06F0)!
            case 0x0660...0x0669: return Unicode.Scalar(0x30 + scalar.value - 0x0660)!
            default: return scalar
            }
        }))
    }
}
