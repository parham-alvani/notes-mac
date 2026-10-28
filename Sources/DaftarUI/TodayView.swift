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
        let days = store.calendarDays(from: today, count: 2)
        let day = days.first { $0.day == today }
        let tomorrow = days.first { $0.day == today.adding(days: 1) }
        let groups = store.taskGroups(today: today)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.largeTitle.bold())
                        .foregroundStyle(LinearGradient(colors: [Palette.accent, Palette.pink, Palette.purple], startPoint: .leading, endPoint: .trailing))
                    HStack(spacing: 8) {
                        let meetings = day?.meetings.count ?? 0
                        Chip(text: "\(meetings) \(meetings == 1 ? "meeting" : "meetings")", symbol: "calendar", color: Palette.blue)
                        if let free = day?.free { Chip(text: "free \(free)", symbol: "clock", color: Palette.green) }
                        Chip(text: "\(groups.today.count) due", symbol: "sun.max.fill", color: Palette.accent)
                        if !groups.overdue.isEmpty { Chip(text: "\(groups.overdue.count) overdue", symbol: "exclamationmark.circle.fill", color: Palette.red) }
                        if !groups.inProgress.isEmpty { Chip(text: "\(groups.inProgress.count) in progress", symbol: "circle.lefthalf.filled", color: Palette.purple) }
                    }
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

    @ViewBuilder
    private func taskCard(_ title: String, _ symbol: String, _ tasks: [VaultTask], _ color: Color) -> some View {
        if !tasks.isEmpty {
            Card(title: title, symbol: symbol, color: color, count: tasks.count) {
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
            if let join = meeting.join, !past {
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
