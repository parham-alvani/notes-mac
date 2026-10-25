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
                VStack(alignment: .leading, spacing: 4) {
                    Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.largeTitle.bold())
                    Text(summary(day: day, groups: groups)).foregroundStyle(.secondary)
                }

                Card(title: "Meetings", symbol: "calendar") {
                    if let day {
                        if let free = day.free {
                            Label("Free \(free)", systemImage: "clock")
                                .font(.callout).foregroundStyle(.secondary)
                        }
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

                taskCard("Overdue", "exclamationmark.circle", groups.overdue, Palette.red)
                taskCard("Due today", "sun.max", groups.today, Palette.accent)
                taskCard("In progress", "circle.lefthalf.filled", groups.inProgress, Palette.blue)
                taskCard("Next 7 days", "calendar.badge.clock", groups.upcoming, Palette.muted)
            }
            .padding(32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func summary(day: CalendarDay?, groups: VaultStore.TaskGroups) -> String {
        let meetings = day?.meetings.count ?? 0
        var parts = ["\(meetings) \(meetings == 1 ? "meeting" : "meetings")", "\(groups.today.count) due"]
        if !groups.overdue.isEmpty { parts.append("\(groups.overdue.count) overdue") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func taskCard(_ title: String, _ symbol: String, _ tasks: [VaultTask], _ color: Color) -> some View {
        if !tasks.isEmpty {
            Card(title: "\(title) · \(tasks.count)", symbol: symbol, color: color) {
                ForEach(tasks) { task in
                    TaskRow(task: task) { model.open(task.path, line: task.task.line, store: store) }
                }
            }
        }
    }
}

/// A rounded group, as System Settings draws them.
struct Card<Content: View>: View {
    var title: String
    var symbol: String
    var color: Color = Palette.accent
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline).foregroundStyle(color)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}

struct MeetingRow: View {
    var meeting: Meeting

    var body: some View {
        let now = Date()
        let past = (meeting.end ?? .distantFuture) < now
        let live = !past && (meeting.start ?? .distantFuture) <= now
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(time)
                .font(.callout.monospacedDigit())
                .foregroundStyle(live ? Palette.accent : .secondary)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(meeting.title).fontWeight(live ? .semibold : .regular)
                    if meeting.tentative { Text("maybe").font(.caption).foregroundStyle(.secondary) }
                }
                .foregroundStyle(meeting.busyOnly || past ? .secondary : .primary)
                if let overlaps = meeting.overlaps {
                    Label("Overlaps \(overlaps)", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Palette.red)
                }
            }
            Spacer()
            if let join = meeting.join, !past {
                Button("Join") { NSWorkspace.shared.open(join) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .opacity(past ? 0.6 : 1)
    }

    private var time: String {
        guard let start = meeting.start, let end = meeting.end else { return "All day" }
        return "\(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
    }
}

struct TaskRow: View {
    var task: VaultTask
    var open: () -> Void
    @Environment(VaultStore.self) private var store

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                store.toggleTask(path: task.path, line: task.task.line, status: task.task.status)
            } label: {
                // The phone's squares: open, and in progress with a dot.
                Image(systemName: task.task.status == "/" ? "square.inset.filled" : "square")
                    .font(.body)
                    .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
            .help("Complete")
            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.plain(task.task.text))
                        .lineLimit(2)
                        .multilineTextAlignment(TextDirection.startsRtl(task.task.text) ? .trailing : .leading)
                        .frame(maxWidth: .infinity, alignment: TextDirection.startsRtl(task.task.text) ? .trailing : .leading)
                    HStack(spacing: 4) {
                        Text(Vault.title(of: task.path))
                        if !task.task.section.isEmpty { Text("› \(task.task.section)") }
                        if let day = task.task.day { Text("· \(day)") }
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// `[[Target|label]]` as its label, for a one-line list.
    static func plain(_ text: String) -> String {
        text.replacing(/\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/) { String($0.2 ?? $0.1) }
    }
}
