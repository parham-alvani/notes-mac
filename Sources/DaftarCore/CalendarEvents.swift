import Foundation

/// The days a place keeps: its public holidays and the feasts and festivals
/// around them, for Spain, Catalonia and Barcelona
/// (`docs/specs/calendar-events.md` in notes-linux). The rules are written
/// here, not in the vault; each event names a note, by its title, that says
/// what the day is. It is `calendar_events.rs` of Daftar for Linux, with its
/// tests by the same names.
public enum CalendarEvents {
    /// Where the person lives. Each place keeps the days of the ones before
    /// it: Barcelona keeps Catalonia's, and Catalonia keeps Spain's.
    public enum Place: Int, Sendable, Hashable, Comparable, CaseIterable {
        case spain, catalonia, barcelona

        /// `calendar.place` in the config file; empty or anything else is none.
        public init?(_ text: String) {
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "spain", "es": self = .spain
            case "catalonia", "es-ct": self = .catalonia
            case "barcelona", "es-ct-barcelona": self = .barcelona
            default: return nil
            }
        }

        /// As the config file writes it.
        public var key: String {
            switch self {
            case .spain: "spain"
            case .catalonia: "catalonia"
            case .barcelona: "barcelona"
            }
        }

        public var name: String { key.capitalized }

        public static func < (a: Place, b: Place) -> Bool { a.rawValue < b.rawValue }
    }

    /// When an event falls in a year.
    public enum When: Sendable, Hashable {
        /// The same month and day every year.
        case fixed(month: Int, day: Int)
        /// Days from Easter Sunday: Good Friday is -2.
        case easter(Int)
        /// The first (1) to fourth weekday of a month; the weekday counts
        /// from Monday, 0, to Sunday, 6.
        case nth(month: Int, weekday: Int, nth: Int)
        /// Days set each year, `YYYY-MM-DD`: a year with none has no event.
        case dates([String])
    }

    /// A day of the calendar.
    public struct Event: Sendable, Hashable {
        /// In English, and the title of its note.
        public var title: String
        /// As the place calls it.
        public var local: String
        public var place: Place
        /// A public holiday: offices, schools and most shops close.
        public var holiday: Bool
        public var when: When
    }

    /// An event on its day.
    public struct Happening: Sendable, Hashable, Identifiable {
        public var day: Day
        public var event: Event
        public var id: String { "\(day) \(event.title)" }
    }

    private static func event(_ title: String, _ local: String, _ place: Place, _ holiday: Bool, _ when: When) -> Event {
        Event(title: title, local: local, place: place, holiday: holiday, when: when)
    }

    /// Every event, in the order a day lists them. Catalonia keeps every one
    /// of Spain's holidays and adds four; Barcelona adds two local ones. A
    /// holiday on a Sunday is not moved in Catalonia.
    public static let events: [Event] = [
        event("New Year's Day", "Año Nuevo", .spain, true, .fixed(month: 1, day: 1)),
        event("Three Kings' Parade", "Cabalgata de Reyes", .spain, false, .fixed(month: 1, day: 5)),
        event("Three Kings' Day", "Día de Reyes", .spain, true, .fixed(month: 1, day: 6)),
        event("Santa Eulàlia", "Festes de Santa Eulàlia", .barcelona, false, .fixed(month: 2, day: 12)),
        event("Dijous Gras", "Dijous Gras", .catalonia, false, .easter(-52)),
        event("Father's Day", "Día del Padre", .spain, false, .fixed(month: 3, day: 19)),
        event("Good Friday", "Viernes Santo", .spain, true, .easter(-2)),
        event("Easter Monday", "Dilluns de Pasqua", .catalonia, true, .easter(1)),
        event("Sant Jordi", "Diada de Sant Jordi", .catalonia, false, .fixed(month: 4, day: 23)),
        event("Labour Day", "Día del Trabajador", .spain, true, .fixed(month: 5, day: 1)),
        event("Mother's Day", "Día de la Madre", .spain, false, .nth(month: 5, weekday: 6, nth: 1)),
        event("Whit Monday", "Dilluns de Pasqua Granada", .barcelona, true, .easter(50)),
        event("Sant Joan's Eve", "Revetlla de Sant Joan", .catalonia, false, .fixed(month: 6, day: 23)),
        event("Sant Joan", "Sant Joan", .catalonia, true, .fixed(month: 6, day: 24)),
        event("Pride Barcelona", "Pride Barcelona", .barcelona, false, .dates(["2026-07-18"])),
        event("Assumption Day", "Asunción de la Virgen", .spain, true, .fixed(month: 8, day: 15)),
        event("La Diada", "Diada Nacional de Catalunya", .catalonia, true, .fixed(month: 9, day: 11)),
        event("La Mercè", "Festes de la Mercè", .barcelona, true, .fixed(month: 9, day: 24)),
        event("Spain's National Day", "Fiesta Nacional de España", .spain, true, .fixed(month: 10, day: 12)),
        event("La Castanyada", "La Castanyada", .catalonia, false, .fixed(month: 10, day: 31)),
        event("All Saints' Day", "Todos los Santos", .spain, true, .fixed(month: 11, day: 1)),
        event("Constitution Day", "Día de la Constitución", .spain, true, .fixed(month: 12, day: 6)),
        event("Immaculate Conception", "Inmaculada Concepción", .spain, true, .fixed(month: 12, day: 8)),
        event("Christmas Eve", "Nochebuena", .spain, false, .fixed(month: 12, day: 24)),
        event("Christmas Day", "Navidad", .spain, true, .fixed(month: 12, day: 25)),
        event("Sant Esteve", "Sant Esteve", .catalonia, true, .fixed(month: 12, day: 26)),
        event("New Year's Eve", "Nochevieja", .spain, false, .fixed(month: 12, day: 31)),
    ]

    /// Easter Sunday of [year] in the Gregorian calendar (the anonymous
    /// Gregorian algorithm, Meeus/Jones/Butcher).
    public static func easter(_ year: Int) -> Day {
        let a = year % 19
        let b = year / 100
        let c = year % 100
        let d = b / 4
        let e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4
        let k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = (h + l - 7 * m + 114) % 31 + 1
        return Day(year: year, month: month, day: day)
    }

    /// The day [event] falls on in [year], if it does that year.
    public static func day(of event: Event, in year: Int) -> Day? {
        switch event.when {
        case .fixed(let month, let day):
            return Day.of(year: year, month: month, day: day)
        case .easter(let offset):
            return easter(year).adding(days: offset)
        case .nth(let month, let weekday, let nth):
            guard let first = Day.of(year: year, month: month, day: 1) else { return nil }
            let ahead = (7 + weekday - first.weekdayFromMonday) % 7
            let day = first.adding(days: ahead + 7 * (nth - 1))
            return day.month == month ? day : nil
        case .dates(let dates):
            return dates.lazy.compactMap { Day($0) }.first { $0.year == year }
        }
    }

    /// The events [place] keeps from [from] to [to], both kept, by day and
    /// then in the table's order.
    public static func between(_ place: Place, from: Day, to: Day) -> [Happening] {
        guard from <= to else { return [] }
        var found: [(happening: Happening, order: Int)] = []
        for year in from.year...to.year {
            for (order, event) in events.enumerated() where event.place <= place {
                if let on = day(of: event, in: year), from <= on, on <= to {
                    found.append((Happening(day: on, event: event), order))
                }
            }
        }
        found.sort { ($0.happening.day, $0.order) < ($1.happening.day, $1.order) }
        return found.map(\.happening)
    }

    /// The events of one day.
    public static func on(_ place: Place, _ day: Day) -> [Event] {
        between(place, from: day, to: day).map(\.event)
    }
}

extension Day {
    /// The day, or nil when its month has no such day.
    static func of(year: Int, month: Int, day: Int) -> Day? {
        guard (1...12).contains(month), day >= 1 else { return nil }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let length = month == 2 ? (leap ? 29 : 28) : [4, 6, 9, 11].contains(month) ? 30 : 31
        return day <= length ? Day(year: year, month: month, day: day) : nil
    }

    /// The day of the week, from Monday (0) to Sunday (6).
    public var weekdayFromMonday: Int { ((Jalali.julian(year, month, day) % 7) + 7) % 7 }
}
