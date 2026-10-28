import AppKit
import DaftarCore
import SwiftUI

/// ⌘2: the vault's tasks on a board. Columns by status, by day or by file;
/// a card dragged to another status or day column changes its line in the
/// note, as the Tasks plugin would write it.
struct BoardView: View {
    @Bindable var model: WindowModel
    @Environment(VaultStore.self) private var store
    @ViewState private var grouping = TaskBoard.Grouping.status
    @ViewState private var file: String?
    @ViewState private var query = ""
    @ViewState private var allClosed = false
    @ViewState private var target: String?

    var body: some View {
        let tasks = shown
        let statuses = store.index.statuses
        let columns = TaskBoard.columns(tasks, by: grouping, today: .today(), closedWithin: allClosed ? nil : 14, statuses: statuses)
        VStack(spacing: 0) {
            header(count: tasks.filter { $0.task.isOpen(in: statuses) }.count)
            if columns.allSatisfy(\.tasks.isEmpty) {
                ContentUnavailableView {
                    Label(query.isEmpty ? "No tasks" : "No task matches “\(query)”", systemImage: "checklist")
                } description: {
                    Text("A task is a line like `- [ ] Call Sara 📅 2026-11-02` in any note.")
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(columns) { column($0, tasks: tasks) }
                    }
                    .padding(16)
                }
            }
        }
        .background(Palette.background)
    }

    // MARK: Data

    /// The tasks the filters let through.
    private var shown: [VaultTask] {
        let needle = Slugs.fold(query.trimmingCharacters(in: .whitespaces))
        return store.index.tasks.filter { task in
            !store.excluded.contains(task.path) && (file == nil || task.path == file)
                && (needle.isEmpty || Slugs.fold(task.task.text + " " + (task.task.reason ?? "") + " " + task.task.section + " " + task.path).contains(needle))
        }
    }

    /// The notes that hold tasks, for the filter.
    private var files: [String] {
        Set(store.index.tasks.map(\.path)).sorted { Vault.title(of: $0).localizedStandardCompare(Vault.title(of: $1)) == .orderedAscending }
    }

    private func color(_ column: TaskBoard.Column) -> Color {
        switch column.id {
        case "todo", "today": Palette.accent
        case "doing", "week": Palette.blue
        case "done": Palette.green
        case "overdue": Palette.red
        case "tomorrow": Palette.yellow
        case "later": Palette.purple
        case "cancelled", "none": Palette.muted
        default: Palette.named(NSPalette.tagColor(column.title))
        }
    }

    // MARK: Parts

    private func header(count: Int) -> some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.split.3x1.fill")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(LinearGradient(colors: [Palette.purple, Palette.accent], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Board").font(.headline)
                    Text("\(count) open \(count == 1 ? "task" : "tasks")").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Group by", selection: $grouping) {
                    Label("Status", systemImage: "circle.dashed").tag(TaskBoard.Grouping.status)
                    Label("Day", systemImage: "calendar").tag(TaskBoard.Grouping.day)
                    Label("File", systemImage: "doc.text").tag(TaskBoard.Grouping.file)
                }
                .pickerStyle(.segmented).fixedSize().labelsHidden()
                Menu {
                    Button("All Notes") { file = nil }
                    Divider()
                    ForEach(files, id: \.self) { path in
                        Button(Vault.title(of: path)) { file = path }
                    }
                } label: {
                    Label(file.map(Vault.title(of:)) ?? "All Notes", systemImage: "line.3.horizontal.decrease.circle")
                }
                .fixedSize()
                .glassEffect(.regular.interactive(), in: .capsule)
                if grouping == .status {
                    Toggle(isOn: $allClosed) { Label("All closed", systemImage: "archivebox") }
                        .toggleStyle(.button)
                        .help("Show every done and cancelled task, not only the last two weeks'")
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Filter", text: $query).textFieldStyle(.plain).frame(width: 150)
                        .accessibilityLabel("Filter tasks")
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .glassEffect(.regular, in: .capsule)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        // The controls ask for more than a narrow window has: they are cut,
        // and the window's minimum size does not grow, which AppKit refuses
        // in the middle of a layout.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private func column(_ column: TaskBoard.Column, tasks: [VaultTask]) -> some View {
        let color = color(column)
        let lit = target == column.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 9, height: 9).accessibilityHidden(true)
                Text(column.title).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(column.tasks.count)").font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(color.opacity(0.18), in: Capsule())
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(column.title), \(Spoken.count(column.tasks.count, "task"))")
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .glassEffect(.regular.tint(color.opacity(0.22)), in: .rect(cornerRadius: 12))
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(column.tasks) { card($0, color: color) }
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
        }
        .padding(8)
        .frame(width: 300)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(color.opacity(lit ? 0.16 : 0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(color.opacity(lit ? 0.8 : 0), lineWidth: 2))
        .motionAnimation(.snappy, value: lit)
        .dropDestination(for: String.self) { ids, _ in
            guard let drop = column.drop else { return false }
            var moved = false
            for id in ids {
                guard let task = tasks.first(where: { $0.id == id }) else { continue }
                if asksReason(task, drop) {
                    model.taskCancel = TaskCancel(task: task)
                    return true
                }
                withMotion(.snappy) { moved = store.moveTask(task, to: drop) || moved }
            }
            return moved
        } isTargeted: { over in
            if over, column.drop != nil { target = column.id } else if target == column.id { target = nil }
        }
    }

    private func card(_ task: VaultTask, color: Color) -> some View {
        let rtl = TextDirection.startsRtl(task.task.text)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    store.toggleTask(path: task.path, line: task.task.line, status: task.task.status)
                } label: {
                    Image(systemName: symbol(task.task.status)).font(.body.weight(.semibold)).foregroundStyle(color)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help(task.task.isOpen ? "Complete" : "Open again")
                Text(TaskRow.plain(task.task.text))
                    .strikethrough(!task.task.isOpen, color: .secondary)
                    .foregroundStyle(task.task.isOpen ? .primary : .secondary)
                    .lineLimit(4)
                    .multilineTextAlignment(rtl ? .trailing : .leading)
                    .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                TaskStatusBadge(status: task.task.status)
            }
            if let reason = task.task.reason { TaskReasonLabel(reason: reason).padding(.leading, 24) }
            HStack(spacing: 5) {
                Text(Vault.title(of: task.path)).foregroundStyle(Palette.aqua)
                if !task.task.section.isEmpty { Text("› \(task.task.section)").foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                if task.task.recurring != nil { Image(systemName: "repeat").foregroundStyle(.secondary) }
                if let priority = task.task.priority, let mark = TaskRow.priority[priority] {
                    Image(systemName: mark.symbol).foregroundStyle(mark.color)
                }
                if let day = task.task.day {
                    Label(day, systemImage: task.task.due != nil ? "calendar" : "hourglass")
                        .foregroundStyle(dayColor(day, open: task.task.isOpen))
                        .padding(.horizontal, 5)
                        .background(dayColor(day, open: task.task.isOpen).opacity(0.14), in: Capsule())
                }
            }
            .font(.caption).lineLimit(1)
        }
        .padding(10)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 11, bottomLeadingRadius: 11).fill(color).frame(width: 3)
        }
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .onTapGesture { model.open(task.path, line: task.task.line, store: store) }
        // A card is reached with Tab: Return opens its note, Space ticks it.
        .focusable(interactions: .activate)
        .onKeyPress(.return) {
            model.open(task.path, line: task.task.line, store: store)
            return .handled
        }
        .onKeyPress(.space) {
            store.toggleTask(path: task.path, line: task.task.line, status: task.task.status)
            return .handled
        }
        // For VoiceOver the card is one element: the task in words, with
        // what the mouse does as its actions.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Spoken.task(task.task, note: Vault.title(of: task.path), today: .today()))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the note at the task")
        .accessibilityAction(.default) { model.open(task.path, line: task.task.line, store: store) }
        .accessibilityAction(named: task.task.isOpen ? "Complete" : "Open Again") {
            store.toggleTask(path: task.path, line: task.task.line, status: task.task.status)
        }
        .accessibilityAction(named: "Edit Task") { model.taskEdit = TaskRef(path: task.path, line: task.task.line) }
        .accessibilityActions {
            ForEach(TaskBoard.columns([], by: grouping, today: .today()).filter { $0.drop != nil }) { column in
                Button("Move to \(column.title)") { move(task, to: column.drop!) }
            }
        }
        .draggable(task.id) {
            Text(TaskRow.plain(task.task.text)).lineLimit(2).padding(10).frame(width: 260, alignment: .leading)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 11))
        }
        .contextMenu {
            Button("Open Note") { model.open(task.path, line: task.task.line, store: store) }
            Button("Edit Task…") { model.taskEdit = TaskRef(path: task.path, line: task.task.line) }
            StatusMenu(task: task, model: model)
            PostponeMenu(task: task)
            Divider()
            ForEach(TaskBoard.columns([], by: grouping, today: .today()).filter { $0.drop != nil }) { column in
                Button("Move to \(column.title)") { move(task, to: column.drop!) }
            }
        }
        .help(task.path)
    }

    /// A card moved to a column: to Cancelled, the reason is asked first.
    private func move(_ task: VaultTask, to drop: TaskBoard.Drop) {
        if asksReason(task, drop) { model.taskCancel = TaskCancel(task: task) }
        else { withMotion(.snappy) { _ = store.moveTask(task, to: drop) } }
    }

    /// A drop that cancels a task that is not cancelled yet.
    private func asksReason(_ task: VaultTask, _ drop: TaskBoard.Drop) -> Bool {
        guard case .status(let status, _) = drop else { return false }
        let statuses = store.index.statuses
        return statuses.type(status) == .cancelled && statuses.type(task.task.status) != .cancelled
    }

    private func symbol(_ status: Character) -> String {
        switch store.index.statuses.type(status) {
        case .inProgress: "square.inset.filled"
        case .done: "checkmark.square.fill"
        case .cancelled: "xmark.square"
        case .nonTask: "minus.square"
        case .todo: "square"
        }
    }

    private func dayColor(_ text: String, open: Bool) -> Color {
        guard open, let day = Day(text) else { return Palette.muted }
        let today = Day.today()
        return day < today ? Palette.red : day == today ? Palette.accent : Palette.blue
    }
}
