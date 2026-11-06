import Foundation

/// A month as the day picker draws it, in the Gregorian calendar or in the
/// Jalali one (`docs/specs/calendar-events.md` in notes-linux): its title,
/// the names of its weekdays, and its days in weeks. A Gregorian week starts
/// on Monday, as Spain's does; a Jalali one on Saturday, as Iran's does. It
/// is `month_grid.rs` of Daftar for Linux, with its tests by the same names.
public struct Month: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case gregorian, jalali
    }

    public var kind: Kind
    public var year: Int
    public var month: Int

    public init(kind: Kind, year: Int, month: Int) {
        self.kind = kind
        self.year = year
        self.month = month
    }

    private static let gregorianWeekdays = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
    private static let jalaliWeekdays = ["ش", "ی", "د", "س", "چ", "پ", "ج"]
    public static let gregorianMonths = [
        "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December",
    ]

    /// The month [day] is in.
    public static func of(_ kind: Kind, _ day: Day) -> Month {
        switch kind {
        case .gregorian:
            return Month(kind: kind, year: day.year, month: day.month)
        case .jalali:
            let jalali = Jalali(day)
            return Month(kind: kind, year: jalali.year, month: jalali.month)
        }
    }

    /// [count] months on, or back when negative.
    public func adding(_ count: Int) -> Month {
        let index = year * 12 + month - 1 + count
        let year = index >= 0 ? index / 12 : (index + 1) / 12 - 1
        return Month(kind: kind, year: year, month: index - year * 12 + 1)
    }

    /// `November 2026`, or `آبان ۱۴۰۵`.
    public var title: String {
        let index = ((month - 1) % 12 + 12) % 12
        switch kind {
        case .gregorian: return "\(Self.gregorianMonths[index]) \(year)"
        case .jalali: return Jalali.persianDigits("\(Jalali.months[index]) \(year)")
        }
    }

    /// The weekdays' short names, from the first of the week.
    public var weekdays: [String] { kind == .gregorian ? Self.gregorianWeekdays : Self.jalaliWeekdays }

    /// Read from the right: the Jalali month.
    public var rightToLeft: Bool { kind == .jalali }

    /// The day of the month as the calendar writes it: `5`, or `۵`.
    public func number(_ day: Day) -> String {
        switch kind {
        case .gregorian: return "\(day.day)"
        case .jalali: return Jalali.persianDigits("\(Jalali(day).day)")
        }
    }

    /// A day of the weekend, drawn muted: Saturday and Sunday in the
    /// Gregorian month, Friday in the Jalali one.
    public func isWeekend(_ day: Day) -> Bool {
        let weekday = day.weekdayFromMonday
        return kind == .gregorian ? weekday >= 5 : weekday == 4
    }

    private var first: Day? {
        switch kind {
        case .gregorian: return Day.of(year: year, month: month, day: 1)
        case .jalali: return Jalali(year: year, month: month, day: 1).gregorian
        }
    }

    private var length: Int? {
        switch kind {
        case .gregorian:
            guard let first, let next = Day.of(year: adding(1).year, month: adding(1).month, day: 1) else { return nil }
            return first.days(to: next)
        case .jalali:
            return Jalali.monthLength(year: year, month: month)
        }
    }

    /// The month's days in weeks of seven: nil before the first and after
    /// the last, to fill its first and last weeks. Empty for a month the
    /// calendar does not have.
    public var cells: [Day?] {
        guard let first, let length else { return [] }
        let fromMonday = first.weekdayFromMonday
        // Saturday is 5 days from Monday.
        let lead = kind == .gregorian ? fromMonday : (fromMonday + 2) % 7
        var cells: [Day?] = Array(repeating: nil, count: lead)
        cells += (0..<length).map { Optional(first.adding(days: $0)) }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }
}
