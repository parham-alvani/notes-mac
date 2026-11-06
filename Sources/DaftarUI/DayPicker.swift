import DaftarCore
import SwiftUI

/// The day picker of a task's dates and a date property
/// (`docs/specs/calendar-events.md` in notes-linux): a month of days in the
/// Gregorian calendar, or in the Jalali one, read from the right, when
/// `appearance.persian_calendar` is on, with today, the picked day, the
/// weekend and the holidays and feasts of `calendar.place` marked. It stands
/// in for AppKit's calendar, which knows one calendar and no holidays. A
/// day picked is its Gregorian day, in either calendar.
struct DayPicker: View {
    var selected: Day?
    var pick: (Day) -> Void
    @Environment(VaultStore.self) private var store
    /// The month shown, once an arrow moved it; else the selected day's.
    @ViewState private var month: Month?

    static let weekdayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    /// `Tuesday, 3 November 2026`.
    static func long(_ day: Day) -> String {
        "\(weekdayNames[day.weekdayFromMonday]), \(day.day) \(Month.gregorianMonths[day.month - 1]) \(day.year)"
    }

    var body: some View {
        let kind: Month.Kind = store.settings.persianCalendar ? .jalali : .gregorian
        let today = Day.today()
        let shown = month.flatMap { $0.kind == kind ? $0 : nil } ?? Month.of(kind, selected ?? today)
        let cells = shown.cells
        let days = cells.compactMap { $0 }
        let events = Self.events(store.settings.place, days)
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Button { month = shown.adding(-1) } label: { Image(systemName: "chevron.backward") }
                    .help("Month before").accessibilityLabel("Month before")
                Text(shown.title)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)
                Button("Today") { month = Month.of(kind, today) }
                    .font(.caption)
                    .help("Today's month")
                Button { month = shown.adding(1) } label: { Image(systemName: "chevron.forward") }
                    .help("Month after").accessibilityLabel("Month after")
            }
            .buttonStyle(.borderless)
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    ForEach(Array(shown.weekdays.enumerated()), id: \.offset) { _, name in
                        Text(name).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(width: 34)
                            .accessibilityHidden(true)
                    }
                }
                ForEach(0..<(cells.count / 7), id: \.self) { week in
                    GridRow {
                        ForEach(0..<7, id: \.self) { column in
                            if let day = cells[week * 7 + column] {
                                cell(day, in: shown, today: today, events: events[day] ?? [])
                            } else {
                                Color.clear.frame(width: 34, height: 34).accessibilityHidden(true)
                            }
                        }
                    }
                }
            }
        }
        // The Jalali month reads from the right: its first weekday, its
        // arrows and its days.
        .environment(\.layoutDirection, shown.rightToLeft ? .rightToLeft : .leftToRight)
        .frame(width: 260)
    }

    /// The events of [days] by day, for the place in the settings.
    static func events(_ place: CalendarEvents.Place?, _ days: [Day]) -> [Day: [CalendarEvents.Event]] {
        guard let place, let first = days.first, let last = days.last else { return [:] }
        return Dictionary(grouping: CalendarEvents.between(place, from: first, to: last), by: \.day).mapValues { $0.map(\.event) }
    }

    /// What a day's tooltip and VoiceOver say: its full date, the Jalali
    /// one too in the Jalali month, and its events, a holiday marked.
    static func describe(_ day: Day, in month: Month, events: [CalendarEvents.Event]) -> String {
        var lines = [long(day)]
        if month.kind == .jalali { lines.append(Jalali.long(day)) }
        lines += events.map { $0.holiday ? "\($0.title) (holiday)" : $0.title }
        return lines.joined(separator: "\n")
    }

    private func cell(_ day: Day, in month: Month, today: Day, events: [CalendarEvents.Event]) -> some View {
        let picked = day == selected
        let holiday = events.contains { $0.holiday }
        let color: Color = picked ? .white : holiday ? Palette.red : month.isWeekend(day) ? .secondary : .primary
        return Button { pick(day) } label: {
            VStack(spacing: 0) {
                Text(month.number(day))
                    .font(.callout.weight(picked || day == today ? .semibold : .regular).monospacedDigit())
                if month.kind == .jalali {
                    Text("\(day.day)").font(.system(size: 8).monospacedDigit()).opacity(0.7)
                }
                Circle()
                    .fill(events.isEmpty ? Color.clear : picked ? Color.white : holiday ? Palette.red : Palette.accent)
                    .frame(width: 4, height: 4)
            }
            .foregroundStyle(color)
            .frame(width: 34, height: 34)
            .background(picked ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                if day == today, !picked {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Palette.accent, lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Self.describe(day, in: month, events: events))
        .accessibilityLabel(Self.describe(day, in: month, events: events).replacingOccurrences(of: "\n", with: ", "))
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// A calendar button beside a date field, which opens the day picker on the
/// field's day, or today's month when the field has none.
struct DayPickerButton: View {
    var selected: Day?
    var name: String
    var pick: (Day) -> Void
    @Environment(VaultStore.self) private var store
    @ViewState private var open = false

    var body: some View {
        Button { open.toggle() } label: { Image(systemName: "calendar") }
            .buttonStyle(.borderless)
            .help("Pick a day")
            .accessibilityLabel("Pick a day for \(name)")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                DayPicker(selected: selected) { day in
                    open = false
                    pick(day)
                }
                .padding(12)
                .environment(store)
            }
    }
}
