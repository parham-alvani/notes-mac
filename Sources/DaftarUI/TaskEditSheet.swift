import DaftarCore
import SwiftUI

/// A task to edit: the note and the line it is on.
struct TaskRef: Identifiable, Equatable {
    var path: String
    var line: Int
    var id: String { "\(path):\(line)" }
}

/// The Tasks plugin's "edit task", as a sheet: the text, the status, the
/// priority, the dates and the repeat rule, each in its colour. The line is
/// read again before it is written, and the edit is refused when it changed.
struct TaskEditSheet: View {
    var task: TaskRef
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @ViewState private var before: TaskFields?
    @ViewState private var fields = TaskFields()
    @ViewState private var error: String?
    @FocusState private var focused: Bool

    private static let statuses: [(Character, String, String, Color)] = [
        (" ", "To do", "square", Palette.accent), ("/", "In progress", "square.inset.filled", Palette.purple),
        ("x", "Done", "checkmark.square.fill", Palette.green), ("-", "Cancelled", "xmark.square.fill", Palette.red),
    ]
    private static let priorities: [(String?, String, String, Color)] = [
        (nil, "None", "minus", Palette.muted), ("⏬", "Lowest", "chevron.down.2", Palette.blue), ("🔽", "Low", "chevron.down", Palette.blue),
        ("🔼", "Medium", "chevron.up", Palette.accent), ("⏫", "High", "chevron.up.2", Palette.red), ("🔺", "Highest", "exclamationmark.2", Palette.red),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "checklist")
                    .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(LinearGradient(colors: [Palette.accent, Palette.purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: Palette.accent.opacity(0.4), radius: 8, y: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Edit Task").font(.title2.weight(.semibold))
                    Text("\(Vault.title(of: task.path)), line \(task.line + 1)").font(.callout).foregroundStyle(.secondary)
                }
            }
            if before == nil {
                Text(error ?? "Reading the task…").foregroundStyle(error == nil ? Color.secondary : Palette.red)
            } else {
                form
            }
            if let error, before != nil {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.glass)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.glassProminent).tint(Palette.accent)
                    .disabled(before == nil || fields.text.trimmingCharacters(in: .whitespaces).isEmpty || fields == before)
            }
        }
        .padding(24)
        .frame(width: 680)
        .onAppear(perform: load)
    }

    @ViewBuilder private var form: some View {
        TextField("What to do", text: $fields.text, axis: .vertical)
            .textFieldStyle(.roundedBorder).font(.title3).lineLimit(1...3)
            .focused($focused)
        row("Status") {
            HStack(spacing: 6) {
                ForEach(Self.statuses, id: \.0) { status, name, symbol, color in
                    pill(name, symbol, color, on: fields.status == status) { fields.status = status }
                }
            }
        }
        row("Priority") {
            HStack(spacing: 6) {
                ForEach(Self.priorities, id: \.1) { emoji, name, symbol, color in
                    pill(name, symbol, color, on: fields.priority == emoji) { fields.priority = emoji }
                }
            }
        }
        row("Dates") {
            VStack(alignment: .leading, spacing: 6) {
                DateField(title: "Due", symbol: "calendar", color: Palette.accent, value: $fields.due)
                DateField(title: "Scheduled", symbol: "hourglass", color: Palette.blue, value: $fields.scheduled)
                DateField(title: "Start", symbol: "airplane.departure", color: Palette.purple, value: $fields.start)
            }
        }
        row("Repeat") {
            HStack {
                TextField("every week", text: Binding { fields.recurring ?? "" } set: { fields.recurring = $0.isEmpty ? nil : $0 })
                    .textFieldStyle(.roundedBorder)
                Menu {
                    ForEach(["every day", "every week", "every 2 weeks", "every month", "every year", "every week when done"], id: \.self) { rule in
                        Button(rule) { fields.recurring = rule }
                    }
                    Divider()
                    Button("Never") { fields.recurring = nil }
                } label: { Image(systemName: "repeat") }
                .fixedSize()
                .tint(Palette.pink)
                if let rule = fields.recurring, Recurrence(rule) == nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.yellow)
                        .help("Daftar repeats only plain intervals, such as every 2 weeks; Obsidian reads the rest.")
                }
            }
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(.callout.weight(.semibold)).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            content()
        }
    }

    private func pill(_ name: String, _ symbol: String, _ color: Color, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(name, systemImage: symbol)
                .font(.callout.weight(on ? .semibold : .regular))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(on ? .white : color)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(on ? AnyShapeStyle(color.gradient) : AnyShapeStyle(color.opacity(0.12)), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func load() {
        guard let text = store.text(of: task.path) else {
            error = "The note could not be read."
            return
        }
        let lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(task.line), let found = TaskLine.fields(lines[task.line].trimmingCharacters(in: CharacterSet(charactersIn: "\r"))) else {
            error = "That line is no longer a task. The note changed; open it again."
            return
        }
        before = found
        fields = found
        focused = true
    }

    private func save() {
        guard let before else { return }
        if store.editTask(path: task.path, line: task.line, before: before, fields: fields) { dismiss() }
        else { error = "The note changed before the save. Nothing was written." }
    }
}

/// A date that can be there or not: a switch, then the date.
struct DateField: View {
    var title: String
    var symbol: String
    var color: Color
    @Binding var value: String?

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding { value != nil } set: { value = $0 ? (value ?? Day.today().description) : nil }) {
                Label(title, systemImage: symbol).foregroundStyle(value == nil ? Color.secondary : color).frame(width: 110, alignment: .leading)
            }
            .toggleStyle(.switch).controlSize(.small).tint(color)
            if let current = value, let day = Day(current) {
                DatePicker("", selection: Binding {
                    Calendar.current.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) ?? Date()
                } set: { date in
                    value = Day(date: date, in: .current).description
                }, displayedComponents: .date)
                .labelsHidden().datePickerStyle(.field)
                Text(Self.relative(day)).font(.caption).foregroundStyle(color)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(color.opacity(0.12), in: Capsule())
            }
        }
    }

    static func relative(_ day: Day) -> String {
        let days = Day.today().days(to: day)
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case 2...: return "in \(days) days"
        default: return "\(-days) days ago"
        }
    }
}

/// "Postpone": the Tasks plugin's menu, for an open task with a date.
struct PostponeMenu: View {
    var task: VaultTask
    @Environment(VaultStore.self) private var store

    var body: some View {
        if task.task.isOpen, task.task.due ?? task.task.scheduled ?? task.task.start != nil {
            Menu("Postpone") {
                ForEach(TaskLine.Postpone.allCases, id: \.self) { amount in
                    Button("By \(amount.title)") { withMotion(.snappy) { _ = store.moveTask(task, to: .postpone(amount)) } }
                }
            }
        }
    }
}
