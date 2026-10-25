import Foundation

/// The vault's tasks as a board: columns by status, by day or by file. A card
/// dropped on a status or a day column changes that task's line, and only it:
/// to done the task is ticked as a click ticks it, with its `✅` date and,
/// for a recurring one, the next occurrence.
public enum TaskBoard {
    public enum Grouping: String, CaseIterable, Sendable {
        case status, day, file
    }

    /// What a column writes on a task dropped on it.
    public enum Drop: Sendable, Hashable {
        case status(Character)
        /// The due date; nil takes it away.
        case due(String?)
    }

    public struct Column: Sendable, Identifiable, Equatable {
        public var id: String
        public var title: String
        public var tasks: [VaultTask]
        /// Nil for a column nothing can be dropped on, as Overdue.
        public var drop: Drop?
    }

    /// The board of [tasks]. Done and cancelled tasks show when they closed
    /// within [closedWithin] days, or all of them when it is nil.
    public static func columns(_ tasks: [VaultTask], by grouping: Grouping, today: Day, closedWithin: Int? = 14) -> [Column] {
        switch grouping {
        case .status:
            let since = closedWithin.map { today.adding(days: -$0) }
            let recent = { (date: String?) in
                guard let since else { return true }
                return date.flatMap(Day.init).map { $0 >= since } ?? false
            }
            var todo: [VaultTask] = [], doing: [VaultTask] = [], done: [VaultTask] = [], cancelled: [VaultTask] = []
            for task in tasks {
                switch task.task.status {
                case "/": doing.append(task)
                case "x", "X": if recent(task.task.done) { done.append(task) }
                case "-": if recent(task.task.cancelled) { cancelled.append(task) }
                default: todo.append(task)
                }
            }
            return [
                Column(id: "todo", title: "To Do", tasks: todo.sorted(by: open), drop: .status(" ")),
                Column(id: "doing", title: "In Progress", tasks: doing.sorted(by: open), drop: .status("/")),
                Column(id: "done", title: "Done", tasks: done.sorted { closed($0.task.done, $1.task.done, $0, $1) }, drop: .status("x")),
                Column(id: "cancelled", title: "Cancelled", tasks: cancelled.sorted { closed($0.task.cancelled, $1.task.cancelled, $0, $1) }, drop: .status("-")),
            ]
        case .day:
            let tomorrow = today.adding(days: 1), week = today.adding(days: 7)
            var columns: [String: [VaultTask]] = [:]
            for task in tasks where task.task.isOpen {
                let key: String
                if let text = task.task.day, let day = Day(text) {
                    key = day < today ? "overdue" : day == today ? "today" : day == tomorrow ? "tomorrow" : day <= week ? "week" : "later"
                } else {
                    key = "none"
                }
                columns[key, default: []].append(task)
            }
            let all: [(String, String, Drop?)] = [
                ("overdue", "Overdue", nil),
                ("today", "Today", .due(today.description)),
                ("tomorrow", "Tomorrow", .due(tomorrow.description)),
                ("week", "Next 7 Days", .due(week.description)),
                ("later", "Later", nil),
                ("none", "No Date", .due(nil)),
            ]
            return all.map { Column(id: $0.0, title: $0.1, tasks: (columns[$0.0] ?? []).sorted(by: open), drop: $0.2) }
        case .file:
            let byFile = Dictionary(grouping: tasks.filter(\.task.isOpen), by: \.path)
            return byFile.keys.sorted { Vault.title(of: $0).localizedStandardCompare(Vault.title(of: $1)) == .orderedAscending }.map {
                Column(id: $0, title: Vault.title(of: $0), tasks: byFile[$0]!.sorted(by: open), drop: nil)
            }
        }
    }

    /// The order of open tasks: by day, the ones with none last, then by
    /// priority, then where they are.
    static func open(_ a: VaultTask, _ b: VaultTask) -> Bool {
        let da = a.task.day ?? "9999", db = b.task.day ?? "9999"
        if da != db { return da < db }
        let pa = rank(a.task.priority), pb = rank(b.task.priority)
        if pa != pb { return pa < pb }
        return (a.path, a.task.line) < (b.path, b.task.line)
    }

    /// The last one closed first.
    static func closed(_ a: String?, _ b: String?, _ x: VaultTask, _ y: VaultTask) -> Bool {
        if (a ?? "") != (b ?? "") { return (a ?? "") > (b ?? "") }
        return (x.path, x.task.line) < (y.path, y.task.line)
    }

    static func rank(_ priority: String?) -> Int {
        switch priority {
        case "🔺": 0
        case "⏫": 1
        case "🔼": 2
        case "🔽": 4
        case "⏬": 5
        default: 3
        }
    }

    /// The lines a task line becomes when it is dropped on [drop]; nil when
    /// it is not a task, or nothing changes.
    public static func moved(_ raw: String, to drop: Drop, today: Day) -> [String]? {
        guard var fields = TaskLine.fields(raw) else { return nil }
        switch drop {
        case .status(let status):
            let wasClosed = TaskLine.closed.contains(fields.status)
            if status == fields.status || (status == "x" && fields.status == "X") { return nil }
            // Done from open: the tick a click makes, recurrence and all.
            if status == "x", !wasClosed { return TaskLine.toggled(raw, today: today.description) }
            fields.status = status
            fields.done = status == "x" ? today.description : nil
            fields.cancelled = status == "-" ? today.description : nil
        case .due(let day):
            guard fields.due != day else { return nil }
            fields.due = day
        }
        return TaskLine.edited(raw, fields).map { [$0] }
    }
}

extension VaultEdits {
    /// The task on [line] of [text] dropped on a board column. [task] is
    /// what the card showed, whose status and words the line must still hold.
    public static func moveTask(in text: String, line: Int, task: ParsedTask, to drop: TaskBoard.Drop, today: Day) throws -> String {
        var lines = text.components(separatedBy: "\n")
        guard line >= 0, line < lines.count else { throw Failure.taskMoved }
        let raw = lines[line]
        let crlf = raw.hasSuffix("\r")
        let clean = crlf ? String(raw.dropLast()) : raw
        guard let now = TaskLine.parse(clean, line: line, section: ""), now.status == task.status, now.text == task.text else {
            throw Failure.taskMoved
        }
        guard let replacement = TaskBoard.moved(clean, to: drop, today: today) else { return text }
        lines.replaceSubrange(line...line, with: replacement.map { crlf ? $0 + "\r" : $0 })
        return lines.joined(separator: "\n")
    }
}
