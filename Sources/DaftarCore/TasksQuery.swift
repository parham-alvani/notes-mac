import Foundation

/// The four states the Tasks plugin knows a task by.
public enum TaskState: Sendable, Equatable {
    case todo, inProgress, done, cancelled

    public init(status: Character) {
        self = switch status {
        case "x", "X": .done
        case "-": .cancelled
        case "/": .inProgress
        // The plugin treats a status it does not know as still to do.
        default: .todo
        }
    }

    /// Ticked or cancelled: no longer to be done.
    public var isFinished: Bool { self == .done || self == .cancelled }

    var type: String {
        switch self {
        case .todo: "TODO"
        case .inProgress: "IN_PROGRESS"
        case .done: "DONE"
        case .cancelled: "CANCELLED"
        }
    }

    var name: String {
        switch self {
        case .todo: "Todo"
        case .inProgress: "In Progress"
        case .done: "Done"
        case .cancelled: "Cancelled"
        }
    }
}

/// One task as a ` ```tasks ` query sees it.
public struct QueryTask: Sendable, Equatable {
    public var text: String
    public var state: TaskState
    /// The note's path inside the vault, `Folder/Note.md`.
    public var path: String
    /// The heading above the task.
    public var section: String
    public var due: String?
    public var scheduled: String?
    public var done: String?
    public var recurring: String?

    public init(_ task: VaultTask) {
        text = task.task.text
        state = TaskState(status: task.task.status)
        path = task.path
        section = task.task.section
        due = task.task.due
        scheduled = task.task.scheduled
        done = task.task.done
        recurring = task.task.recurring
    }

    public init(text: String, state: TaskState, path: String, section: String = "", due: String? = nil,
                scheduled: String? = nil, done: String? = nil, recurring: String? = nil) {
        self.text = text
        self.state = state
        self.path = path
        self.section = section
        self.due = due
        self.scheduled = scheduled
        self.done = done
        self.recurring = recurring
    }

    var folder: String { Self.folder(of: path) }
    var filename: String { path.split(separator: "/").last.map(String.init) ?? path }

    /// A note's folder as the plugin writes it: with its slash, or `/` at the root.
    static func folder(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "/" }
        return String(path[...slash])
    }
}

/// The Obsidian Tasks plugin's query language, the part of it that can be
/// answered from the index: filters on status, dates, path, heading, text and
/// tags, joined with `AND`/`OR`/`NOT`, then `group by`, `sort by` and
/// `limit`. The rules are Daftar's on the phone (`TasksQuery.kt`).
///
/// What it cannot answer is kept in [notUnderstood] and shown. Dropping a
/// filter silently would list tasks the query was written to leave out.
public struct TasksQuery: Sendable {
    typealias Filter = @Sendable (QueryTask, Day) -> Bool
    typealias Comparison = @Sendable (QueryTask, QueryTask) -> ComparisonResult

    private var filters: [Filter] = []
    private var sorts: [Comparison] = []
    private var groupers: [@Sendable (QueryTask) -> String] = []
    public private(set) var limit: Int?
    /// The lines this could not read, as written.
    public private(set) var notUnderstood: [String] = []

    /// The tasks the query selects, in the order it asks for. With no
    /// `sort by`, open tasks come before finished ones and sooner before later;
    /// ties keep the order they were given in.
    public func run<T>(_ tasks: [T], today: Day, view: (T) -> QueryTask) -> [T] {
        // Each task's groups are worked out once, not in every comparison of the sort.
        // The positions are sorted, not the tasks, which are large to move.
        let kept = tasks.indices.filter { at in
            let task = view(tasks[at])
            return filters.allSatisfy { $0(task, today) }
        }
        let views = kept.map { view(tasks[$0]) }
        let groups = views.map { task in groupers.map { group in group(task) } }
        let order: [Comparison] = sorts + [Self.defaultOrder]
        let sorted = kept.indices.sorted { a, b in
            for (x, y) in zip(groups[a], groups[b]) {
                let result = Self.compare(x, y)
                if result != .orderedSame { return result == .orderedAscending }
            }
            for compare in order {
                let result = compare(views[a], views[b])
                if result != .orderedSame { return result == .orderedAscending }
            }
            return kept[a] < kept[b]
        }.map { tasks[kept[$0]] }
        return limit.map { Array(sorted.prefix($0)) } ?? sorted
    }

    /// The groups a task is listed under, outermost first. A group may be
    /// named "" -- no heading, grouped by heading -- and has no title.
    public func groups(of task: QueryTask) -> [String] { groupers.map { $0(task) } }

    /// Reads the body of the fence. [file] is the path of the note the query
    /// is written in, which `{{query.file.*}}` stands for.
    public static func parse(_ source: String, file: String? = nil) -> TasksQuery {
        var query = TasksQuery()
        for raw in source.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            // A blank line and a comment say nothing; a layout line says how
            // to draw the list, not which tasks are in it.
            if line.isEmpty || line.hasPrefix("#") || layout.contains(where: { lower.hasPrefix($0) }) { continue }
            guard let expanded = placeholders(line, file: file) else {
                query.notUnderstood.append(line)
                continue
            }
            let low = expanded.lowercased()
            if low.hasPrefix("group by ") {
                if let group = group(String(expanded.dropFirst("group by ".count))) { query.groupers.append(group) }
                else { query.notUnderstood.append(line) }
            } else if low.hasPrefix("filter by function ") {
                if let expression = TaskExpression.parse(String(expanded.dropFirst("filter by function ".count))) {
                    query.filters.append { task, _ in expression.test(task) }
                } else {
                    query.notUnderstood.append(line)
                }
            } else if let match = low.wholeMatch(of: /limit (?:to )?(\d+)(?: tasks?)?/) {
                query.limit = Int(match.1)
            } else if low.hasPrefix("sort by ") {
                if let sort = sort(String(low.dropFirst("sort by ".count))) { query.sorts.append(sort) }
                else { query.notUnderstood.append(line) }
            } else if let filter = expression(expanded) {
                query.filters.append(filter)
            } else {
                query.notUnderstood.append(line)
            }
        }
        return query
    }

    private static let layout = ["hide ", "show ", "short mode", "full mode", "explain", "ignore global query"]

    private static let namedGroups: [String: String] = [
        "filename": "task.file.filenameWithoutExtension", "path": "task.file.path", "folder": "task.file.folder",
        "heading": "task.heading", "status": "task.status.name", "status.name": "task.status.name",
        "status.type": "task.status.type",
    ]

    private static func group(_ spec: String) -> (@Sendable (QueryTask) -> String)? {
        let source: String
        if spec.lowercased().hasPrefix("function ") {
            source = String(spec.dropFirst("function ".count))
        } else {
            guard let named = namedGroups[spec.trimmingCharacters(in: .whitespaces).lowercased()] else { return nil }
            source = named
        }
        guard let expression = TaskExpression.parse(source) else { return nil }
        return { task in
            switch expression.evaluate(task) {
            case .null: ""
            case .list(let items): items.map(\.display).joined(separator: ", ")
            case let value: value.display
            }
        }
    }

    private static func placeholders(_ line: String, file: String?) -> String? {
        guard line.contains("{{") else { return line }
        guard let file else { return nil }
        let name = file.split(separator: "/").last.map(String.init) ?? file
        let values = [
            "query.file.path": file, "query.file.folder": QueryTask.folder(of: file), "query.file.filename": name,
            "query.file.filenameWithoutExtension": name.removingSuffix(".md"),
        ]
        var unknown = false
        let out = line.replacing(/\{\{([^}]*)\}\}/) { match in
            if let value = values[match.1.trimmingCharacters(in: .whitespaces)] { return value }
            unknown = true
            return String(match.0)
        }
        return unknown ? nil : out
    }

    // MARK: Filters

    /// A filter line, which may be a boolean combination:
    /// `(due today) OR (scheduled today)`, `NOT (done)`.
    static func expression(_ line: String) -> Filter? {
        let text = line.trimmingCharacters(in: .whitespaces)
        if !text.hasPrefix("("), text.prefixMatch(of: negation) == nil { return filter(text) }
        var combination = Combination(text: Array(text))
        return combination.parse()
    }

    nonisolated(unsafe) static let negation = /(?i)NOT\s*\(/

    static func filter(_ line: String) -> Filter? {
        let text = line.trimmingCharacters(in: .whitespaces)
        switch text.lowercased() {
        case "done": return { task, _ in task.state.isFinished }
        case "not done": return { task, _ in !task.state.isFinished }
        case "is recurring": return { task, _ in task.recurring != nil }
        case "is not recurring": return { task, _ in task.recurring == nil }
        default: break
        }
        if let match = text.wholeMatch(of: /(?i)status\.type is( not)? (todo|in[_ ]progress|done|cancelled)/) {
            let wanted: TaskState = switch match.2.lowercased().replacingOccurrences(of: " ", with: "_") {
            case "todo": .todo
            case "in_progress": .inProgress
            case "done": .done
            default: .cancelled
            }
            let negate = match.1 != nil
            return { task, _ in (task.state == wanted) != negate }
        }
        if let match = text.wholeMatch(of: /(?i)(has|no) (due|scheduled|done|happens) date/), let field = dateField(String(match.2)) {
            let wantsOne = match.1.lowercased() == "has"
            return { task, _ in (field(task) != nil) == wantsOne }
        }
        if let match = text.wholeMatch(of: /(?i)(due|scheduled|done|happens)( on or before| on or after| before| after| on| in)?\s+(.+)/),
            let field = dateField(String(match.1))
        {
            let relation = match.2.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "on"
            let phrase = String(match.3).trimmingCharacters(in: .whitespaces)
            guard DateRange(phrase, today: Day(year: 2000, month: 1, day: 1)) != nil else { return nil }
            let ranges = DateRange.Cache(phrase)
            return { task, today in
                guard let range = ranges.range(today: today), let value = field(task), let day = Day(value) else { return false }
                return range.relation(relation, day) ?? false
            }
        }
        if let match = text.wholeMatch(of: /(?i)(description|path|heading|filename|folder) (includes|does not include)\s+(.+)/) {
            let field: @Sendable (QueryTask) -> String = switch match.1.lowercased() {
            case "description": { $0.text }
            case "path": { $0.path }
            case "heading": { $0.section }
            case "filename": { $0.filename }
            default: { $0.folder }
            }
            let negate = match.2.lowercased().hasPrefix("does not")
            let value = String(match.3).trimmingCharacters(in: .whitespaces)
            return { task, _ in field(task).localizedCaseInsensitiveContains(value) != negate }
        }
        if let match = text.wholeMatch(of: /(?i)(tag|tags) (include|includes|do not include|does not include)\s+(.+)/) {
            let negate = match.2.lowercased().contains("not")
            var wanted = String(match.3).trimmingCharacters(in: .whitespaces)
            if wanted.hasPrefix("#") { wanted.removeFirst() }
            let tag = wanted
            return { task, _ in
                let has = tags(in: task.text).contains { $0.localizedCaseInsensitiveContains(tag) }
                return has != negate
            }
        }
        return nil
    }

    private static func dateField(_ name: String) -> (@Sendable (QueryTask) -> String?)? {
        switch name.lowercased() {
        case "due": { $0.due }
        case "scheduled": { $0.scheduled }
        case "done": { $0.done }
        // The plugin counts the start date too; the index does not keep it.
        case "happens": { [$0.scheduled, $0.due].compactMap { $0 }.min() }
        default: nil
        }
    }

    private static func tags(in text: String) -> [String] {
        text.matches(of: /(?:^|[^\p{L}\p{N}_])#([\p{L}\p{N}_\/-]*[\p{L}_\/-][\p{L}\p{N}_\/-]*)/).map { String($0.1) }
    }

    // MARK: Sorting

    private static func sort(_ spec: String) -> Comparison? {
        let parts = spec.split(whereSeparator: \.isWhitespace).map(String.init)
        let reverse = parts.count == 2 && parts[1] == "reverse"
        guard parts.count == 1 || reverse else { return nil }
        let key: Comparison
        switch parts[0] {
        case "due": key = dates { $0.due }
        case "scheduled": key = dates { $0.scheduled }
        case "done": key = dates { $0.done }
        case "happens": key = dates { [$0.scheduled, $0.due].compactMap { $0 }.min() }
        case "status": key = { a, b in compare(a.state.isFinished ? 1 : 0, b.state.isFinished ? 1 : 0) }
        case "path": key = { a, b in compare(a.path.lowercased(), b.path.lowercased()) }
        case "filename": key = { a, b in compare(a.filename.lowercased(), b.filename.lowercased()) }
        case "heading": key = { a, b in compare(a.section.lowercased(), b.section.lowercased()) }
        case "description": key = { a, b in compare(a.text.lowercased(), b.text.lowercased()) }
        default: return nil
        }
        return reverse ? { a, b in key(b, a) } : key
    }

    /// Dated first, soonest first, as the plugin sorts a date.
    private static func dates(_ of: @escaping @Sendable (QueryTask) -> String?) -> Comparison {
        { a, b in
            switch (of(a), of(b)) {
            case (nil, nil): .orderedSame
            case (nil, _): .orderedDescending
            case (_, nil): .orderedAscending
            case let (x?, y?): compare(x, y)
            }
        }
    }

    private static let defaultOrder: Comparison = { a, b in
        let finished = compare(a.state.isFinished ? 1 : 0, b.state.isFinished ? 1 : 0)
        if finished != .orderedSame { return finished }
        return dates { $0.due ?? $0.scheduled }(a, b)
    }

    static func compare<V: Comparable>(_ a: V, _ b: V) -> ComparisonResult {
        a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }

    /// `(a) AND (b)`, `(a) OR NOT (b)`, nested to any depth, left to right.
    private struct Combination {
        var text: [Character]
        var at = 0

        mutating func parse() -> Filter? {
            guard let result = sequence() else { return nil }
            skipSpace()
            return at == text.count ? result : nil
        }

        private mutating func sequence() -> Filter? {
            guard var left = operand() else { return nil }
            while true {
                skipSpace()
                guard let op = ["AND NOT ", "AND ", "OR ", "XOR "].first(where: { starts(with: $0) }) else { return left }
                at += op.count
                guard let right = operand() else { return nil }
                let l = left
                switch op.trimmingCharacters(in: .whitespaces) {
                case "AND": left = { t, d in l(t, d) && right(t, d) }
                case "OR": left = { t, d in l(t, d) || right(t, d) }
                case "XOR": left = { t, d in l(t, d) != right(t, d) }
                default: left = { t, d in l(t, d) && !right(t, d) }
                }
            }
        }

        private func starts(with word: String) -> Bool {
            let end = at + word.count
            guard end <= text.count else { return false }
            return String(text[at..<end]).uppercased() == word
        }

        private mutating func operand() -> Filter? {
            skipSpace()
            if let match = String(text[at...]).prefixMatch(of: TasksQuery.negation) {
                at += match.0.count - 1
                guard let inner = operand() else { return nil }
                return { t, d in !inner(t, d) }
            }
            guard at < text.count, text[at] == "(", let close = closing(at) else { return nil }
            let inside = String(text[(at + 1)..<close]).trimmingCharacters(in: .whitespaces)
            at = close + 1
            if inside.hasPrefix("(") || inside.prefixMatch(of: TasksQuery.negation) != nil {
                var nested = Combination(text: Array(inside))
                return nested.parse()
            }
            return TasksQuery.filter(inside)
        }

        private func closing(_ open: Int) -> Int? {
            var depth = 0
            for index in open..<text.count {
                if text[index] == "(" { depth += 1 }
                if text[index] == ")" {
                    depth -= 1
                    if depth == 0 { return index }
                }
            }
            return nil
        }

        private mutating func skipSpace() {
            while at < text.count, text[at].isWhitespace { at += 1 }
        }
    }
}

/// The days a date phrase in a query means: `today`, `2026-10-09`, `this week`,
/// `next month`, `in 3 days`, or two dates for a range.
struct DateRange: Equatable {
    var start: Day
    var end: Day

    init(start: Day, end: Day) {
        self.start = start
        self.end = end
    }

    init?(_ phrase: String, today: Day) {
        let text = phrase.trimmingCharacters(in: .whitespaces).lowercased()
        let monday = today.adding(days: -((today.weekday + 5) % 7))
        let first = Day(year: today.year, month: today.month, day: 1)
        func month(_ start: Day) -> DateRange { DateRange(start: start, end: start.adding(months: 1).adding(days: -1)) }
        switch text {
        case "today": self.init(start: today, end: today)
        case "tomorrow": self.init(start: today.adding(days: 1), end: today.adding(days: 1))
        case "yesterday": self.init(start: today.adding(days: -1), end: today.adding(days: -1))
        case "this week": self.init(start: monday, end: monday.adding(days: 6))
        case "next week": self.init(start: monday.adding(days: 7), end: monday.adding(days: 13))
        case "last week": self.init(start: monday.adding(days: -7), end: monday.adding(days: -1))
        case "this month": self = month(first)
        case "next month": self = month(first.adding(months: 1))
        case "last month": self = month(first.adding(months: -1))
        default:
            if let match = text.wholeMatch(of: /in (\d+) days?/), let n = Int(match.1) {
                self.init(start: today.adding(days: n), end: today.adding(days: n))
            } else if let match = text.wholeMatch(of: /(\d+) days? ago/), let n = Int(match.1) {
                self.init(start: today.adding(days: -n), end: today.adding(days: -n))
            } else if let match = text.wholeMatch(of: /(\d{4}-\d{2}-\d{2})\s+(\d{4}-\d{2}-\d{2})/) {
                guard let a = Day(String(match.1)), let b = Day(String(match.2)), a <= b else { return nil }
                self.init(start: a, end: b)
            } else if let day = Day(text) {
                self.init(start: day, end: day)
            } else {
                return nil
            }
        }
    }

    /// The range of one phrase, made once for each day the query runs on
    /// rather than once for each task it tests.
    final class Cache: @unchecked Sendable {
        let phrase: String
        private let lock = NSLock()
        private var last: (today: Day, range: DateRange?)?

        init(_ phrase: String) { self.phrase = phrase }

        func range(today: Day) -> DateRange? {
            lock.withLock {
                if let last, last.today == today { return last.range }
                let range = DateRange(phrase, today: today)
                last = (today, range)
                return range
            }
        }
    }

    func relation(_ relation: String, _ date: Day) -> Bool? {
        switch relation {
        case "before": date < start
        case "after": date > end
        case "on", "in": date >= start && date <= end
        case "on or before": date <= end
        case "on or after": date >= start
        default: nil
        }
    }
}

extension Day {
    /// 1 is Sunday, as `Calendar` counts.
    var weekday: Int {
        Self.utc.component(.weekday, from: date)
    }
}
