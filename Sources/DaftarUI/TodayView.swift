import AppKit
import DaftarCore
import SwiftUI

/// Today: the meetings from the phone's week note, the free time between
/// them, and the tasks that are due.
struct TodayView: View {
    @Bindable var model: WindowModel
    @Environment(VaultStore.self) private var store

    var body: some View {
        let today = Day.today()
        // The day before too: a meeting late in it can run past midnight.
        let days = store.calendarDays(from: today.adding(days: -1), count: 3)
        let day = days.first { $0.day == today }
        let yesterday = days.first { $0.day == today.adding(days: -1) }
        let tomorrow = days.first { $0.day == today.adding(days: 1) }
        let groups = store.taskGroups(today: today)
        let coming = store.calendarEvents(from: today, to: today.adding(days: Self.holidayDays))
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.largeTitle.bold())
                        .foregroundStyle(LinearGradient(colors: [Palette.accent, Palette.pink, Palette.purple], startPoint: .leading, endPoint: .trailing))
                    if store.settings.persianCalendar {
                        Text(Jalali.long(today)).font(.title3).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        let meetings = day?.meetings.count ?? 0
                        Chip(text: "\(meetings) \(meetings == 1 ? "meeting" : "meetings")", symbol: "calendar", color: Palette.blue)
                        if let free = day?.free { Chip(text: "free \(free)", symbol: "clock", color: Palette.green) }
                        Chip(text: "\(groups.today.count) due", symbol: "sun.max.fill", color: Palette.accent)
                        if !groups.overdue.isEmpty { Chip(text: "\(groups.overdue.count) overdue", symbol: "exclamationmark.circle.fill", color: Palette.red) }
                        if !groups.inProgress.isEmpty { Chip(text: "\(groups.inProgress.count) in progress", symbol: "circle.lefthalf.filled", color: Palette.purple) }
                        if store.drill.counts.due > 0 {
                            Button { model.showsDrill = true } label: {
                                Chip(text: Spoken.count(store.drill.counts.due, "card") + " due", symbol: "rectangle.on.rectangle.angled", color: Palette.green)
                            }
                            .buttonStyle(.plain)
                            .help("Review the cards due (⇧⌘R)")
                            .accessibilityHint("Opens Review Cards")
                        }
                        ForEach(coming.filter { $0.day == today }) { happening in
                            eventChip(happening.event)
                        }
                    }
                }

                if day != nil || groups.today.contains(where: { TaskTime.parse($0.task.text) != nil }) {
                    TimelineCard(
                        model: model, day: today, meetings: (yesterday?.meetings ?? []) + (day?.meetings ?? []),
                        tasks: groups.today)
                }

                Card(title: "Meetings", symbol: "calendar", color: Palette.blue) {
                    if let day {
                        if day.meetings.isEmpty {
                            Text("No meetings today.").foregroundStyle(.secondary)
                        }
                        ForEach(day.meetings) { MeetingRow(meeting: $0) }
                    } else {
                        Text("There is no week note for today in \(CalendarWeek.folder)/. Daftar on the phone writes it.")
                            .foregroundStyle(.secondary)
                    }
                    if let first = tomorrow?.meetings.first(where: { !$0.allDay }) {
                        Divider()
                        Text("Tomorrow starts at \(first.start!.formatted(date: .omitted, time: .shortened)): \(first.title)")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }

                NextJobEventCard(model: model)
                ReviewCard(model: model)

                if !coming.isEmpty {
                    Card(title: "Holidays and feasts", symbol: "star.fill", color: Palette.red) {
                        ForEach(coming) { happening in
                            EventRow(happening: happening, today: today, note: store.note(of: happening.event)) {
                                model.open($0, store: store)
                            }
                        }
                    }
                }

                taskCard("Overdue", "exclamationmark.circle.fill", groups.overdue, Palette.red)
                taskCard("Due today", "sun.max.fill", groups.today, Palette.accent)
                taskCard("In progress", "circle.lefthalf.filled", groups.inProgress, Palette.purple)
                taskCard("Next 7 days", "calendar.badge.clock", groups.upcoming, Palette.aqua)
            }
            .padding(32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// The days of `calendar.place` the card lists, from today on.
    static let holidayDays = 45

    /// A chip for an event of today, red for a holiday; a click opens its
    /// note when the vault has one.
    @ViewBuilder
    private func eventChip(_ event: CalendarEvents.Event) -> some View {
        let chip = Chip(text: event.title, symbol: event.holiday ? "flag.fill" : "sparkles", color: event.holiday ? Palette.red : Palette.aqua)
            .accessibilityLabel(event.holiday ? "\(event.title), a holiday" : event.title)
        if let path = store.note(of: event) {
            Button { model.open(path, store: store) } label: { chip }
                .buttonStyle(.plain)
                .help("Open \(event.title)")
        } else {
            chip.help(event.local)
        }
    }

    @ViewBuilder
    private func taskCard(_ title: String, _ symbol: String, _ tasks: [VaultTask], _ color: Color) -> some View {
        if !tasks.isEmpty {
            Card(title: title, symbol: symbol, color: color, count: tasks.count) {
                // Lazy: only the rows on screen are made. Two hundred overdue
                // tasks made the page 135 MB the first time it showed.
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(tasks) { task in
                        TaskRow(task: task, color: color) { model.open(task.path, line: task.task.line, store: store) }
                            .contextMenu {
                                Button("Edit Task…") { model.taskEdit = TaskRef(path: task.path, line: task.task.line) }
                                StatusMenu(task: task, model: model)
                                Button("Cancel Task…") { model.taskCancel = TaskCancel(task: task) }
                                PostponeMenu(task: task)
                                Button("Open the Note") { model.open(task.path, line: task.task.line, store: store) }
                            }
                    }
                }
            }
        }
    }
}

/// A rounded group in its own colour: a tinted icon, a count, and a soft
/// wash of the colour behind it.
struct Card<Content: View>: View {
    var title: String
    var symbol: String
    var color: Color = Palette.accent
    var count: Int?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .accessibilityHidden(true)
                Text(title).font(.headline).foregroundStyle(color)
                if let count {
                    Text("\(count)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(color)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(color.opacity(0.16), in: Capsule())
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [color.opacity(0.10), color.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(color.opacity(0.25)))
    }
}

/// A small coloured pill with an icon: the summary under the date.
struct Chip: View {
    var text: String
    var symbol: String
    var color: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.3)))
            .accessibilityElement(children: .combine)
    }
}

/// The day's meetings and timed tasks on one axis of hours, with the free
/// time between them and a line at now: `today-timeline.md` §5 in
/// notes-linux's `docs/specs`. A minute is a point.
struct TimelineCard: View {
    @Bindable var model: WindowModel
    var day: Day
    var meetings: [Meeting]
    var tasks: [VaultTask]
    @Environment(VaultStore.self) private var store

    /// The height of one line of a box's text: the shortest box.
    static let line: CGFloat = 18
    static let hoursWidth: CGFloat = 42

    var body: some View {
        TimelineView(.everyMinute) { context in
            let timeline = DaftarCore.Timeline(
                day: day, meetings: meetings, tasks: tasks, statuses: store.index.statuses, zone: .current, now: context.date)
            Card(title: "Timeline", symbol: "clock", color: Palette.blue) {
                if !timeline.allDay.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(timeline.allDay.enumerated()), id: \.offset) { _, meeting in
                            Chip(text: meeting.title, symbol: "calendar", color: meeting.busyOnly ? Palette.muted : Palette.blue)
                                .opacity(meeting.tentative ? 0.6 : 1)
                                .help(Self.details(meeting))
                                .accessibilityLabel("All day, \(meeting.title)")
                        }
                    }
                }
                axis(timeline)
                    .padding(.vertical, 8)
            }
        }
    }

    private func axis(_ timeline: DaftarCore.Timeline) -> some View {
        let height = CGFloat(timeline.end - timeline.start)
        let hours = Array(stride(from: timeline.start, through: timeline.end, by: 60))
        return HStack(alignment: .top, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                ForEach(hours, id: \.self) { minute in
                    Text(Self.clock(minute))
                        .font(.caption2.monospacedDigit())
                        .faint()
                        .offset(y: CGFloat(minute - timeline.start) - 7)
                }
            }
            .frame(width: Self.hoursWidth, height: height, alignment: .topTrailing)
            .accessibilityHidden(true)
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .topLeading) {
                    ForEach(hours, id: \.self) { minute in
                        Rectangle()
                            .fill(Color.secondary.opacity(0.2))
                            .frame(width: width, height: 1)
                            .offset(y: CGFloat(minute - timeline.start))
                    }
                    .accessibilityHidden(true)
                    ForEach(timeline.free, id: \.self) { free in
                        freeBand(free, width: width)
                            .offset(y: CGFloat(free.start - timeline.start))
                    }
                    // In order of start: a later box is drawn over an earlier one.
                    ForEach(timeline.items) { item in
                        let lane = width / CGFloat(max(item.lanes, 1))
                        box(item, height: max(CGFloat(item.end - item.start), Self.line))
                            .frame(width: max(lane - 3, 1), height: max(CGFloat(item.end - item.start), Self.line))
                            .opacity(item.past ? 0.5 : 1)
                            .offset(x: lane * CGFloat(item.lane), y: CGFloat(item.start - timeline.start))
                    }
                    if let now = timeline.now {
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Palette.red).frame(width: width, height: 1.5)
                            Circle().fill(Palette.red).frame(width: 8, height: 8).offset(x: -4)
                        }
                        .frame(width: width, height: 8)
                        .offset(y: CGFloat(now - timeline.start) - 4)
                        .allowsHitTesting(false)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Now, \(Self.clock(now))")
                    }
                }
            }
            .frame(height: height)
        }
    }

    private func freeBand(_ free: DaftarCore.Timeline.Free, width: CGFloat) -> some View {
        let height = CGFloat(free.minutes)
        let label = "free \(DaftarCore.Timeline.duration(free.minutes))"
        return Rectangle()
            .fill(Palette.green.opacity(0.08))
            .frame(width: width, height: height)
            .overlay(alignment: .topLeading) {
                if height >= Self.line {
                    Text(label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Palette.green)
                        .padding(.horizontal, 6).padding(.top, 2)
                }
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(Self.clock(free.start))–\(Self.clock(free.end)), \(label)")
    }

    @ViewBuilder
    private func box(_ item: DaftarCore.Timeline.Item, height: CGFloat) -> some View {
        if let meeting = item.meeting {
            meetingBox(item, meeting, height: height)
        } else if let task = item.task {
            taskBox(item, task, height: height)
        }
    }

    /// Lines of text a box [height] tall holds, at least one.
    private static func lines(_ height: CGFloat) -> Int { max(1, Int((height - 4) / 15)) }

    @ViewBuilder
    private func meetingBox(_ item: DaftarCore.Timeline.Item, _ meeting: Meeting, height: CGFloat) -> some View {
        let color = meeting.busyOnly ? Palette.muted : Palette.blue
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        let label = HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(Self.clock(item.start))–\(Self.clock(item.end))")
                .monospacedDigit()
                .foregroundStyle(color)
                .fixedSize()
            Text(item.title)
                .foregroundStyle(meeting.busyOnly ? .secondary : .primary)
                .lineLimit(Self.lines(height))
        }
        .font(.caption.weight(item.current ? .semibold : .regular))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color.opacity(meeting.tentative ? 0.07 : 0.18), in: shape)
        .overlay(
            shape.strokeBorder(
                color.opacity(meeting.tentative ? 0.45 : 0.7), style: StrokeStyle(lineWidth: 1, dash: meeting.tentative ? [4, 3] : []))
        )
        .clipShape(shape)
        .contentShape(shape)
        let spoken = "\(Self.clock(item.start)) to \(Self.clock(item.end)), \(meeting.title)"
        if let join = meeting.join, Vault.leavesTheApp(join) {
            Button { NSWorkspace.shared.open(join) } label: { label }
                .buttonStyle(.plain)
                .help(Self.details(meeting, joins: true))
                .accessibilityLabel(spoken)
                .accessibilityValue(Self.state(item, meeting))
                .accessibilityHint("Joins the meeting")
        } else {
            label
                .help(Self.details(meeting))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
                .accessibilityValue(Self.state(item, meeting))
        }
    }

    private func taskBox(_ item: DaftarCore.Timeline.Item, _ task: VaultTask, height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button {
                store.toggleTask(path: task.path, line: task.task.line, status: task.task.status)
            } label: {
                Image(systemName: store.index.statuses.type(task.task.status) == .inProgress ? "square.inset.filled" : "square")
                    .fontWeight(.semibold)
                    .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
            .help("Complete")
            .accessibilityLabel(TaskRow.plain(item.title))
            .accessibilityValue(Spoken.status(task.task.status))
            .accessibilityAddTraits(.isToggle)
            .accessibilityHint("Completes the task")
            Button { model.open(task.path, line: task.task.line, store: store) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Self.clock(item.start))–\(Self.clock(item.end))")
                        .monospacedDigit()
                        .foregroundStyle(Palette.accent)
                        .fixedSize()
                    Text(TaskRow.plain(item.title))
                        .lineLimit(Self.lines(height))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(Vault.title(of: task.path)) at the task")
            .accessibilityLabel("\(Self.clock(item.start)) to \(Self.clock(item.end)), \(TaskRow.plain(item.title))")
            .accessibilityHint("Opens the note at the task")
        }
        .font(.caption.weight(item.current ? .semibold : .regular))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.accent.opacity(0.18), in: shape)
        .overlay(shape.strokeBorder(Palette.accent.opacity(0.7)))
        .clipShape(shape)
    }

    /// `09:30`; 1440 is `24:00`.
    static func clock(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }

    /// The tooltip of a meeting: its calendars and what it overlaps.
    static func details(_ meeting: Meeting, joins: Bool = false) -> String {
        var lines: [String] = []
        if !meeting.calendars.isEmpty { lines.append(meeting.calendars.joined(separator: ", ")) }
        if meeting.tentative { lines.append("Maybe") }
        if meeting.busyOnly { lines.append("Busy only") }
        if let overlaps = meeting.overlaps { lines.append("Overlaps \(overlaps)") }
        if joins { lines.append("Click to join") }
        return lines.isEmpty ? meeting.title : lines.joined(separator: "\n")
    }

    private static func state(_ item: DaftarCore.Timeline.Item, _ meeting: Meeting) -> String {
        var parts = [item.current ? "now" : item.past ? "finished" : "", meeting.tentative ? "maybe" : "", meeting.busyOnly ? "busy only" : ""]
        if let overlaps = meeting.overlaps { parts.append("overlaps \(overlaps)") }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

struct MeetingRow: View {
    var meeting: Meeting

    var body: some View {
        let now = Date()
        let past = (meeting.end ?? .distantFuture) < now
        let live = !past && (meeting.start ?? .distantFuture) <= now
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // A bar in the meeting's state: now, next, or done.
            RoundedRectangle(cornerRadius: 2)
                .fill(live ? Palette.accent : past ? Palette.muted.opacity(0.5) : Palette.blue)
                .frame(width: 4, height: 18)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
                .accessibilityHidden(true)
            Text(time)
                .font(.callout.monospacedDigit().weight(live ? .semibold : .regular))
                .foregroundStyle(live ? Palette.accent : past ? .secondary : Palette.blue)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(meeting.title).fontWeight(live ? .semibold : .regular)
                    if live {
                    Text("now").font(.caption.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Palette.accent, in: Capsule())
                }
                if meeting.tentative {
                    Text("maybe").font(.caption).foregroundStyle(Palette.purple)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Palette.purple.opacity(0.15), in: Capsule())
                }
                }
                .foregroundStyle(meeting.busyOnly || past ? .secondary : .primary)
                if let overlaps = meeting.overlaps {
                    Label("Overlaps \(overlaps)", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Palette.red)
                }
            }
            // The bar's colour and the dimming say now, next or done: in words here.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(time), \(meeting.title)")
            .accessibilityValue(state(live: live, past: past))
            Spacer()
            if let join = meeting.join, !past, Vault.leavesTheApp(join) {
                Button { NSWorkspace.shared.open(join) } label: { Label("Join", systemImage: "video.fill") }
                    .buttonStyle(.glassProminent)
                    .tint(live ? Palette.accent : Palette.blue)
                    .controlSize(.small)
            }
        }
        .opacity(past ? 0.6 : 1)
    }

    private func state(live: Bool, past: Bool) -> String {
        var parts = [live ? "now" : past ? "finished" : "", meeting.tentative ? "maybe" : ""]
        if let overlaps = meeting.overlaps { parts.append("overlaps \(overlaps)") }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var time: String {
        guard let start = meeting.start, let end = meeting.end else { return "All day" }
        return "\(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
    }
}

struct TaskRow: View {
    var task: VaultTask
    var color: Color = Palette.accent
    var open: () -> Void
    @Environment(VaultStore.self) private var store

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                store.toggleTask(path: task.path, line: task.task.line, status: task.task.status)
            } label: {
                // The phone's squares: open, and in progress with a dot.
                Image(systemName: store.index.statuses.type(task.task.status) == .inProgress ? "square.inset.filled" : "square")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(color)
            }
            .buttonStyle(.plain)
            .help("Complete")
            // A checkbox drawn as a square: VoiceOver hears a toggle with its task.
            .accessibilityLabel(Self.plain(task.task.text))
            .accessibilityValue(Spoken.status(task.task.status))
            .accessibilityAddTraits(.isToggle)
            .accessibilityHint("Completes the task")
            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Self.plain(task.task.text))
                            .lineLimit(2)
                            .multilineTextAlignment(TextDirection.startsRtl(task.task.text) ? .trailing : .leading)
                            .frame(maxWidth: .infinity, alignment: TextDirection.startsRtl(task.task.text) ? .trailing : .leading)
                        TaskStatusBadge(status: task.task.status)
                    }
                    if let reason = task.task.reason { TaskReasonLabel(reason: reason) }
                    HStack(spacing: 4) {
                        Text(Vault.title(of: task.path)).foregroundStyle(Palette.aqua)
                        if !task.task.section.isEmpty { Text("› \(task.task.section)").foregroundStyle(.secondary) }
                        if let day = task.task.day {
                            Label(day, systemImage: task.task.due != nil ? "calendar" : "hourglass")
                                .foregroundStyle(color)
                                .padding(.horizontal, 5)
                                .background(color.opacity(0.12), in: Capsule())
                        }
                        if let priority = task.task.priority, let mark = Self.priority[priority] {
                            Image(systemName: mark.symbol).foregroundStyle(mark.color)
                        }
                    }
                    .font(.caption).lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Spoken.task(task.task, note: Vault.title(of: task.path), today: .today()))
            .accessibilityHint("Opens the note at the task")
        }
    }

    /// The Tasks plugin's priority emoji, as a coloured mark.
    static let priority: [String: (symbol: String, color: Color)] = [
        "🔺": ("chevron.up.2", Palette.red), "⏫": ("chevron.up.2", Palette.red), "🔼": ("chevron.up", Palette.accent),
        "🔽": ("chevron.down", Palette.blue), "⏬": ("chevron.down.2", Palette.blue),
    ]

    /// `[[Target|label]]` as its label, for a one-line list.
    static func plain(_ text: String) -> String { Spoken.plain(text) }
}

/// A holiday or a feast on the Today page: how far it is, its title and
/// local name, and its date; a click opens its note when the vault has one.
struct EventRow: View {
    var happening: CalendarEvents.Happening
    var today: Day
    var note: String?
    var open: (String) -> Void

    var body: some View {
        let event = happening.event
        let color = event.holiday ? Palette.red : Palette.aqua
        let row = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(DateField.relative(happening.day))
                .font(.caption.weight(.semibold)).foregroundStyle(color)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(color.opacity(0.14), in: Capsule())
            Text(event.title).foregroundStyle(note == nil ? Color.primary : Palette.link)
            if event.local != event.title {
                Text(event.local).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Self.short(happening.day)).font(.caption).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(event.title), \(event.local), \(DayPicker.long(happening.day)), \(DateField.relative(happening.day))\(event.holiday ? ", a holiday" : "")")
        if let note {
            Button { open(note) } label: { row }
                .buttonStyle(.plain)
                .help(note)
                .accessibilityHint("Opens its note")
        } else {
            row
        }
    }

    /// `Tue 3 Nov`.
    static func short(_ day: Day) -> String {
        "\(DayPicker.weekdayNames[day.weekdayFromMonday].prefix(3)) \(day.day) \(Month.gregorianMonths[day.month - 1].prefix(3))"
    }
}

extension VaultStore {
    /// The holidays and feasts of `calendar.place` from [from] to [to]; none
    /// when no place is set.
    func calendarEvents(from: Day, to: Day) -> [CalendarEvents.Happening] {
        guard let place = settings.place else { return [] }
        return CalendarEvents.between(place, from: from, to: to)
    }

    /// An event's note: the vault's note named by its title, found as a
    /// `[[Title]]` link from the vault's top finds it. The app never makes it.
    func note(of event: CalendarEvents.Event) -> String? {
        index.resolve(event.title, from: "").flatMap { Vault.isNote($0) ? $0 : nil }
    }
}
