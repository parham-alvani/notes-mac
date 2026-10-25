import Foundation

/// A `.base` file: an Obsidian Bases query over the vault's files. Filters
/// pick the files, formulas add columns, and each view sorts, groups and
/// shows them.
public struct Base: Sendable {
    public struct View: Sendable {
        public var type = "table"
        public var name = "Table"
        public var filter: BaseFilter?
        public var order: [String] = []
        public var sort: [(property: String, ascending: Bool)] = []
        public var groupBy: (property: String, ascending: Bool)?
        public var limit: Int?
    }

    public var filter: BaseFilter?
    public var formulas: [(name: String, source: String)] = []
    public var displayNames: [String: String] = [:]
    public var views: [View] = []

    public static func parse(_ source: String) -> Base {
        let root = YAML.parse(source)
        var base = Base()
        base.filter = root["filters"].flatMap(BaseFilter.init)
        base.formulas = (root["formulas"]?.entries ?? []).compactMap { entry in entry.value.string.map { (entry.key, $0) } }
        for entry in root["properties"]?.entries ?? [] {
            if let name = entry.value["displayName"]?.string { base.displayNames[entry.key] = name }
        }
        for node in root["views"]?.items ?? [] {
            var view = View()
            view.type = node["type"]?.string ?? "table"
            view.name = node["name"]?.string ?? "View \(base.views.count + 1)"
            view.filter = node["filters"].flatMap(BaseFilter.init)
            view.order = (node["order"]?.items ?? []).compactMap(\.string)
            view.sort = (node["sort"]?.items ?? []).compactMap { item in
                item["property"]?.string.map { ($0, item["direction"]?.string?.uppercased() != "DESC") }
            }
            if let group = node["groupBy"], let property = group["property"]?.string ?? group.string {
                view.groupBy = (property, group["direction"]?.string?.uppercased() != "DESC")
            }
            view.limit = node["limit"]?.string.flatMap { Int($0) }
            base.views.append(view)
        }
        if base.views.isEmpty { base.views = [View()] }
        return base
    }

    /// The YAML of a ` ```base ` block is the same as a file's.
    public static func isBase(_ path: String) -> Bool { path.lowercased().hasSuffix(".base") }
}

/// `filters:` -- one statement, or `and`, `or` and `not` over a list of them.
public indirect enum BaseFilter: Sendable {
    case statement(String)
    case all([BaseFilter])
    case any([BaseFilter])
    case none([BaseFilter])

    init?(_ node: YAMLNode) {
        switch node {
        case .scalar(let text): self = .statement(text)
        case .list(let items): self = .all(items.compactMap(BaseFilter.init))
        case .map(let entries):
            let parts: [BaseFilter] = entries.compactMap { entry in
                let items = entry.value.items.compactMap(BaseFilter.init)
                switch entry.key {
                case "and": return .all(items)
                case "or": return .any(items)
                case "not": return .none(items)
                default: return nil
                }
            }
            if parts.isEmpty { return nil }
            self = parts.count == 1 ? parts[0] : .all(parts)
        case .null: return nil
        }
    }
}

/// What a view shows: the columns, then the rows in their groups.
public struct BaseTable: Sendable, Equatable {
    public struct Group: Sendable, Equatable {
        /// Nil when the view has no `groupBy`.
        public var name: String?
        public var rows: [Row]
    }

    public struct Row: Sendable, Equatable {
        public var path: String
        public var cells: [BaseCell]
    }

    public var name: String
    public var type: String
    public var columns: [String]
    public var groups: [Group]
    public var count: Int
}

/// One cell as the page draws it: text runs, some of them links.
public struct BaseCell: Sendable, Equatable {
    public struct Part: Sendable, Equatable {
        public var text: String
        public var path: String?
    }

    public var parts: [Part] = []
    /// A checkbox property.
    public var check: Bool?
    public var numeric = false

    public var text: String { parts.map(\.text).joined() }
}

/// Runs a base over a vault index. One engine is for one run: it keeps what
/// it has worked out for each file, so the views share it.
public final class BaseEngine {
    public struct Stat: Sendable {
        public var created: Date
        public var modified: Date
        public var size: Int

        public init(created: Date, modified: Date, size: Int) {
            self.created = created
            self.modified = modified
            self.size = size
        }
    }

    let index: VaultIndex
    let now: Date
    /// `.obsidian/types.json`: a property's type, which says whether `2026`
    /// is a number or text and whether one value is still a list.
    let types: [String: String]
    let stat: (String) -> Stat?
    private var stats: [String: Stat?] = [:]
    private var formulas: [String: BaseExpr] = [:]
    private var rows: [String: Row] = [:]
    private var parsed: [String: Result<BaseExpr, BaseParseError>] = [:]
    /// The file `this` is: the base, or the note that embeds it.
    private var context = ""
    /// What could not be read or worked out, once each, for the page to list.
    public private(set) var problems: [String] = []

    final class Row {
        let path: String
        var formulas: [String: BaseValue] = [:]
        var working: Set<String> = []
        init(path: String) { self.path = path }
    }

    public init(index: VaultIndex, now: Date = Date(), types: [String: String] = [:], stat: @escaping (String) -> Stat? = { _ in nil }) {
        self.index = index
        self.now = now
        self.types = types
        self.stat = stat
    }

    /// The property types in a vault's `.obsidian/types.json`.
    public static func types(in root: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: root.appending(path: ".obsidian/types.json")),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let types = object["types"] as? [String: String]
        else { return [:] }
        return types
    }

    /// Every view of [base]; [context] is the file `this` names.
    public func run(_ base: Base, context: String) -> [BaseTable] {
        self.context = context
        for (name, source) in base.formulas {
            if let expression = expression(source, what: "Formula \(name)") { formulas[name] = expression }
        }
        let candidates = index.files.sorted().filter { passes(base.filter, $0) ?? true }
        return base.views.map { table($0, of: base, from: candidates) }
    }

    private func table(_ view: View, of base: Base, from candidates: [String]) -> BaseTable {
        var paths = candidates.filter { passes(view.filter, $0) ?? true }
        if !view.sort.isEmpty {
            let keys = view.sort.map { sort in (column(sort.property), sort.ascending) }
            let values = Dictionary(uniqueKeysWithValues: paths.map { path in (path, keys.map { value(of: $0.0, path) }) })
            paths.sort { a, b in
                for (offset, key) in keys.enumerated() {
                    let order = Self.order(values[a]![offset], values[b]![offset], ascending: key.1)
                    if order != 0 { return order < 0 }
                }
                return a < b
            }
        }
        if let limit = view.limit, limit >= 0 { paths = Array(paths.prefix(limit)) }
        let order = view.order.isEmpty ? ["file.name"] : view.order
        let columns = order.map(column)
        let rows = paths.map { path in
            BaseTable.Row(path: path, cells: zip(order, columns).map { id, expression in cell(id, expression, path) })
        }
        var groups: [BaseTable.Group] = []
        if let groupBy = view.groupBy {
            let key = column(groupBy.property)
            var byName: [String: (value: BaseValue, rows: [BaseTable.Row])] = [:]
            var names: [String] = []
            for row in rows {
                let value = value(of: key, row.path)
                let name = Self.isEmpty(value) ? "" : display(value)
                if byName[name] == nil {
                    names.append(name)
                    byName[name] = (value, [])
                }
                byName[name]!.rows.append(row)
            }
            names.sort { a, b in
                let order = Self.order(byName[a]!.value, byName[b]!.value, ascending: groupBy.ascending)
                return order != 0 ? order < 0 : a < b
            }
            groups = names.map { BaseTable.Group(name: $0.isEmpty ? "None" : $0, rows: byName[$0]!.rows) }
        } else {
            groups = [BaseTable.Group(name: nil, rows: rows)]
        }
        return BaseTable(
            name: view.name, type: view.type, columns: order.map { base.displayNames[$0] ?? Self.label($0) }, groups: groups,
            count: rows.count)
    }

    public typealias View = Base.View

    /// A column's heading when the base gives it no `displayName`.
    static func label(_ id: String) -> String {
        if id.hasPrefix("file.") { return "file " + id.dropFirst(5) }
        if id.hasPrefix("formula.") { return String(id.dropFirst(8)) }
        if id.hasPrefix("note.") { return String(id.dropFirst(5)) }
        return id
    }

    // MARK: Filters and columns

    /// Nil when nothing in [filter] could be applied.
    func passes(_ filter: BaseFilter?, _ path: String) -> Bool? {
        guard let filter else { return nil }
        switch filter {
        case .statement(let source):
            guard let expression = expression(source, what: "Filter") else { return nil }
            return Self.truthy(evaluate(expression, row(path), [:]))
        case .all(let items):
            let results = items.compactMap { passes($0, path) }
            return results.isEmpty ? nil : !results.contains(false)
        case .any(let items):
            let results = items.compactMap { passes($0, path) }
            return results.isEmpty ? nil : results.contains(true)
        case .none(let items):
            let results = items.compactMap { passes($0, path) }
            return results.isEmpty ? nil : !results.contains(true)
        }
    }

    /// A property id from `order`, `sort` or `groupBy` -- `file.name`,
    /// `formula.x`, `note.x` or a bare name -- as an expression.
    private func column(_ id: String) -> BaseExpr {
        if let expression = try? BaseParser.parse(id) { return expression }
        // A key no expression can spell, such as `my-key` or `due date`.
        return .index(.name("note"), .value(.string(id.hasPrefix("note.") ? String(id.dropFirst(5)) : id)))
    }

    private func value(of expression: BaseExpr, _ path: String) -> BaseValue {
        evaluate(expression, row(path), [:])
    }

    private func cell(_ id: String, _ expression: BaseExpr, _ path: String) -> BaseCell {
        // The name column is the file, as a link to it.
        if id == "file.name" || id == "file.basename" || id == "file" {
            return BaseCell(parts: [.init(text: title(path), path: path)])
        }
        return cell(for: value(of: expression, path))
    }

    func cell(for value: BaseValue) -> BaseCell {
        switch value {
        case .null: return BaseCell()
        case .bool(let flag): return BaseCell(check: flag)
        case .number: return BaseCell(parts: [.init(text: display(value))], numeric: true)
        case .list(let items):
            var cell = BaseCell()
            for (offset, item) in items.enumerated() {
                if offset > 0 { cell.parts.append(.init(text: ", ")) }
                cell.parts += self.cell(for: item).parts
            }
            return cell
        case .link(let target, let path, let shown): return BaseCell(parts: [.init(text: shown ?? path.map(title) ?? target, path: path)])
        case .file(let path): return BaseCell(parts: [.init(text: title(path), path: path)])
        default: return BaseCell(parts: [.init(text: display(value))])
        }
    }

    private func title(_ path: String) -> String {
        Vault.isNote(path) ? Vault.title(of: path) : String(path.split(separator: "/").last ?? "")
    }

    private func expression(_ source: String, what: String) -> BaseExpr? {
        if parsed[source] == nil {
            parsed[source] = Result { try BaseParser.parse(source) }.mapError { $0 as? BaseParseError ?? BaseParseError(message: "\($0)") }
        }
        switch parsed[source]! {
        case .success(let expression): return expression
        case .failure(let error):
            note("\(what) not understood, so not applied: \(source) (\(error.message))")
            return nil
        }
    }

    private func note(_ problem: String) {
        if !problems.contains(problem) { problems.append(problem) }
    }

    private func row(_ path: String) -> Row {
        if let row = rows[path] { return row }
        let row = Row(path: path)
        rows[path] = row
        return row
    }

    private func fileStat(_ path: String) -> Stat? {
        if let known = stats[path] { return known }
        let found = stat(path)
        stats[path] = found
        return found
    }

    // MARK: Evaluation

    func evaluate(_ expression: BaseExpr, _ row: Row, _ locals: [String: BaseValue]) -> BaseValue {
        switch expression {
        case .value(let value): return value
        case .list(let items): return .list(items.map { evaluate($0, row, locals) })
        case .name(let name):
            if let local = locals[name] { return local }
            switch name {
            case "file": return .file(row.path)
            case "this": return .file(context)
            case "note": return .object(properties(of: row.path))
            case "formula": return .object(formulas.keys.sorted().map { ($0, formula($0, row)) })
            default: return property(name, of: row.path)
            }
        case .member(let receiver, let name):
            if case .name(let space) = receiver, locals[space] == nil {
                if space == "formula" { return formula(name, row) }
                if space == "note" { return property(name, of: row.path) }
            }
            return member(evaluate(receiver, row, locals), name)
        case .index(let receiver, let key):
            if case .name("note") = receiver, locals["note"] == nil, case .string(let name) = evaluate(key, row, locals) {
                return property(name, of: row.path)
            }
            return subscriptValue(evaluate(receiver, row, locals), evaluate(key, row, locals))
        case .call(let name, let arguments):
            return call(name, arguments, row, locals)
        case .method(let receiver, let name, let arguments):
            return method(evaluate(receiver, row, locals), name, arguments, row, locals)
        case .unary(let symbol, let operand):
            let value = evaluate(operand, row, locals)
            if symbol == "!" { return .bool(!Self.truthy(value)) }
            switch value {
            case .number(let number): return .number(-number)
            case .duration(let span): return .duration(-span)
            default: return .null
            }
        case .binary(let symbol, let left, let right):
            if symbol == "&&" { return .bool(Self.truthy(evaluate(left, row, locals)) && Self.truthy(evaluate(right, row, locals))) }
            if symbol == "||" { return .bool(Self.truthy(evaluate(left, row, locals)) || Self.truthy(evaluate(right, row, locals))) }
            return binary(symbol, evaluate(left, row, locals), evaluate(right, row, locals))
        }
    }

    private func formula(_ name: String, _ row: Row) -> BaseValue {
        if let known = row.formulas[name] { return known }
        guard let expression = formulas[name] else { return .null }
        guard row.working.insert(name).inserted else {
            note("Formula \(name) uses itself")
            return .null
        }
        let value = evaluate(expression, row, [:])
        row.working.remove(name)
        row.formulas[name] = value
        return value
    }

    // MARK: Properties

    private func properties(of path: String) -> [(key: String, value: BaseValue)] {
        (index.notes[path]?.parsed.properties ?? []).map { ($0.key, convert($0.key, $0.values, from: path)) }
    }

    func property(_ key: String, of path: String) -> BaseValue {
        guard let properties = index.notes[path]?.parsed.properties else { return .null }
        let lowered = key.lowercased()
        guard let found = properties.first(where: { $0.key == key }) ?? properties.first(where: { $0.key.lowercased() == lowered }) else {
            return .null
        }
        return convert(found.key, found.values, from: path)
    }

    /// Front matter is read as text; the type in `types.json`, or the shape
    /// of the text, makes it a number, a date, a checkbox, a link or a list.
    private func convert(_ key: String, _ values: [String], from path: String) -> BaseValue {
        let type = types[key]
        if values.isEmpty { return ["multitext", "tags", "aliases"].contains(type) ? .list([]) : .null }
        if values.count > 1 || ["multitext", "tags", "aliases"].contains(type) {
            return .list(values.map { scalar($0, type: "text", from: path) })
        }
        return scalar(values[0], type: type, from: path)
    }

    private func scalar(_ text: String, type: String?, from path: String) -> BaseValue {
        if text.hasPrefix("[["), text.hasSuffix("]]") {
            let link = Wikilink(String(text.dropFirst(2).dropLast(2)))
            return .link(target: link.target, path: index.resolve(link.target, from: path), display: link.alias)
        }
        switch type {
        case "number": return Double(text).map(BaseValue.number) ?? .string(text)
        case "checkbox": return .bool(text.lowercased() == "true")
        case "date", "datetime": return Self.parseDate(text).map { .date($0.0, time: $0.1) } ?? .string(text)
        case "text": return .string(text)
        default:
            if text == "true" || text == "false" { return .bool(text == "true") }
            if let number = Double(text), text.first?.isNumber ?? false || text.hasPrefix("-") { return .number(number) }
            if let date = Self.parseDate(text) { return .date(date.0, time: date.1) }
            return .string(text)
        }
    }

    nonisolated(unsafe) private static let datePattern = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?)?(Z)?$/

    /// `2026-10-25`, `2026-10-25T09:30`, `2026-10-25 09:30:00`, in the local
    /// time zone unless it ends in `Z`.
    static func parseDate(_ text: String) -> (Date, Bool)? {
        guard let match = text.trimmingCharacters(in: .whitespaces).wholeMatch(of: datePattern) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        if match.7 != nil { calendar.timeZone = TimeZone(identifier: "UTC")! }
        var parts = DateComponents(year: Int(match.1), month: Int(match.2), day: Int(match.3))
        if let hour = match.4, let minute = match.5 {
            parts.hour = Int(hour)
            parts.minute = Int(minute)
            parts.second = match.6.flatMap { Int($0) } ?? 0
        }
        guard let date = calendar.date(from: parts) else { return nil }
        return (date, match.4 != nil)
    }

    // MARK: Members

    private func member(_ value: BaseValue, _ name: String) -> BaseValue {
        switch value {
        case .file(let path): return fileMember(path, name)
        case .link(_, let path?, _) where name != "length": return fileMember(path, name)
        case .string(let text): return name == "length" ? .number(Double(text.count)) : .null
        case .list(let items): return name == "length" ? .number(Double(items.count)) : .null
        case .date(let date, _):
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
            switch name {
            case "year": return .number(Double(parts.year ?? 0))
            case "month": return .number(Double(parts.month ?? 0))
            case "day": return .number(Double(parts.day ?? 0))
            case "hour": return .number(Double(parts.hour ?? 0))
            case "minute": return .number(Double(parts.minute ?? 0))
            case "second": return .number(Double(parts.second ?? 0))
            case "millisecond": return .number(Double((parts.nanosecond ?? 0) / 1_000_000))
            default: return .null
            }
        case .duration(let span):
            let ms = span.approximateMilliseconds
            switch name {
            case "days": return .number(ms / 86_400_000)
            case "hours": return .number(ms / 3_600_000)
            case "minutes": return .number(ms / 60_000)
            case "seconds": return .number(ms / 1000)
            case "milliseconds": return .number(ms)
            default: return .null
            }
        case .object(let entries): return entries.first { $0.key == name }?.value ?? .null
        default: return .null
        }
    }

    private func fileMember(_ path: String, _ name: String) -> BaseValue {
        let parts = path.split(separator: "/")
        let fileName = String(parts.last ?? "")
        let dot = fileName.lastIndex(of: ".")
        switch name {
        case "name": return .string(fileName)
        case "basename": return .string(dot.map { String(fileName[..<$0]) } ?? fileName)
        case "ext": return .string(dot.map { String(fileName[fileName.index(after: $0)...]) } ?? "")
        case "path": return .string(path)
        case "folder": return .string(parts.count > 1 ? parts.dropLast().joined(separator: "/") : "/")
        case "file": return .file(path)
        case "mtime":
            if let note = index.notes[path] { return .date(note.modified, time: true) }
            return fileStat(path).map { .date($0.modified, time: true) } ?? .null
        case "ctime": return fileStat(path).map { .date($0.created, time: true) } ?? .null
        case "size": return fileStat(path).map { .number(Double($0.size)) } ?? .null
        case "properties": return .object(properties(of: path))
        case "tags": return .list((index.notes[path]?.parsed.tags ?? []).map(BaseValue.string))
        case "links", "embeds":
            var seen = Set<String>()
            let links = (index.notes[path]?.parsed.links ?? []).filter { (name == "embeds") == $0.embed && seen.insert($0.target).inserted }
            return .list(links.map { .link(target: $0.target, path: index.resolve($0.target, from: path), display: nil) })
        case "backlinks":
            var seen = Set<String>()
            return .list((index.backlinks[path] ?? []).filter { seen.insert($0.source).inserted }.map { .file($0.source) })
        default: return .null
        }
    }

    private func subscriptValue(_ value: BaseValue, _ key: BaseValue) -> BaseValue {
        switch (value, key) {
        case (.list(let items), .number(let number)):
            let at = Int(number) < 0 ? items.count + Int(number) : Int(number)
            return items.indices.contains(at) ? items[at] : .null
        case (.string(let text), .number(let number)):
            let characters = Array(text)
            let at = Int(number)
            return characters.indices.contains(at) ? .string(String(characters[at])) : .null
        case (_, .string(let name)): return member(value, name)
        default: return .null
        }
    }

    // MARK: Functions

    private func call(_ name: String, _ arguments: [BaseExpr], _ row: Row, _ locals: [String: BaseValue]) -> BaseValue {
        if name == "if" {
            guard let condition = arguments.first else { return .null }
            if Self.truthy(evaluate(condition, row, locals)) {
                return arguments.count > 1 ? evaluate(arguments[1], row, locals) : .null
            }
            return arguments.count > 2 ? evaluate(arguments[2], row, locals) : .null
        }
        let values = arguments.map { evaluate($0, row, locals) }
        let first = values.first ?? .null
        switch name {
        case "now": return .date(now, time: true)
        case "today": return .date(Calendar.current.startOfDay(for: now), time: false)
        case "date":
            switch first {
            case .date: return first
            case .string(let text): return Self.parseDate(text).map { .date($0.0, time: $0.1) } ?? .null
            default: return .null
            }
        case "duration":
            if case .string(let text) = first { return BaseSpan.parse(text).map(BaseValue.duration) ?? .null }
            return first
        case "number": return number(first).map(BaseValue.number) ?? .null
        case "list":
            if case .list = first { return first }
            return Self.isEmpty(first) && values.isEmpty ? .list([]) : .list([first])
        case "link":
            let shown = values.count > 1 ? display(values[1]) : nil
            switch first {
            case .string(let target): return .link(target: target, path: resolve(target), display: shown)
            case .file(let path): return .link(target: path, path: path, display: shown)
            case .link(let target, let path, _): return .link(target: target, path: path, display: shown)
            default: return .null
            }
        case "file":
            switch first {
            case .string(let target): return resolve(target).map(BaseValue.file) ?? .null
            case .link(_, let path?, _): return .file(path)
            case .file: return first
            default: return .null
            }
        case "max", "min":
            let numbers = values.compactMap(number)
            guard !numbers.isEmpty else { return .null }
            return .number(name == "max" ? numbers.max()! : numbers.min()!)
        case "escapeHTML", "html", "icon", "image": return .string(display(first))
        case "random": return .number(Double.random(in: 0..<1))
        default:
            note("Unknown function \(name)()")
            return .null
        }
    }

    private func resolve(_ target: String) -> String? {
        if index.files.contains(target) { return target }
        return index.resolve(target, from: context)
    }

    private func method(_ receiver: BaseValue, _ name: String, _ arguments: [BaseExpr], _ row: Row, _ locals: [String: BaseValue]) -> BaseValue {
        // These run their argument once per item, with `value` and `index` set.
        if case .list(let items) = receiver, ["filter", "map", "reduce"].contains(name), let body = arguments.first {
            switch name {
            case "filter":
                return .list(items.enumerated().filter { offset, item in
                    var scope = locals
                    scope["value"] = item
                    scope["index"] = .number(Double(offset))
                    return Self.truthy(evaluate(body, row, scope))
                }.map(\.element))
            case "map":
                return .list(items.enumerated().map { offset, item in
                    var scope = locals
                    scope["value"] = item
                    scope["index"] = .number(Double(offset))
                    return evaluate(body, row, scope)
                })
            default:
                var accumulator = arguments.count > 1 ? evaluate(arguments[1], row, locals) : .null
                for (offset, item) in items.enumerated() {
                    var scope = locals
                    scope["value"] = item
                    scope["index"] = .number(Double(offset))
                    scope["acc"] = accumulator
                    accumulator = evaluate(body, row, scope)
                }
                return accumulator
            }
        }
        let values = arguments.map { evaluate($0, row, locals) }
        let first = values.first ?? .null
        // Methods every value has.
        switch name {
        case "isEmpty": return .bool(Self.isEmpty(receiver))
        case "isTruthy": return .bool(Self.truthy(receiver))
        case "toString": return .string(display(receiver))
        case "isType": return .bool(Self.typeName(receiver) == display(first).lowercased())
        default: break
        }
        switch receiver {
        case .null:
            return .null
        case .string(let text):
            return stringMethod(text, name, values)
        case .number(let number):
            switch name {
            case "abs": return .number(abs(number))
            case "ceil": return .number(number.rounded(.up))
            case "floor": return .number(number.rounded(.down))
            case "round":
                let digits = self.number(first).map(Int.init) ?? 0
                let scale = pow(10, Double(digits))
                return .number((number * scale).rounded() / scale)
            case "toFixed": return .string(String(format: "%.\(max(0, self.number(first).map(Int.init) ?? 0))f", number))
            default: break
            }
        case .date(let date, let time):
            switch name {
            case "format": return .string(Self.format(date, display(first)))
            case "relative": return .string(Self.relative(date, now: now))
            case "date": return .date(Calendar.current.startOfDay(for: date), time: false)
            case "time": return .string(time ? Self.format(date, "HH:mm:ss") : "00:00:00")
            default: break
            }
        case .list(let items):
            switch name {
            case "contains": return .bool(items.contains { Self.equal($0, first) })
            case "containsAll": return .bool(values.allSatisfy { value in items.contains { Self.equal($0, value) } })
            case "containsAny": return .bool(values.contains { value in items.contains { Self.equal($0, value) } })
            case "join": return .string(items.map(display).joined(separator: values.isEmpty ? "," : display(first)))
            case "reverse": return .list(items.reversed())
            case "flat": return .list(items.flatMap { if case .list(let inner) = $0 { inner } else { [$0] } })
            case "sort": return .list(items.sorted { Self.order($0, $1, ascending: true) < 0 })
            case "unique":
                var seen = Set<String>()
                return .list(items.filter { seen.insert(Self.typeName($0) + display($0)).inserted })
            case "slice":
                let range = Self.slice(items.count, values.compactMap(number))
                return .list(Array(items[range]))
            default: break
            }
        case .file(let path), .link(_, let path?, _):
            if let value = fileMethod(path, name, values, receiver) { return value }
            if case .link(_, _, let shown) = receiver, let shown { return stringMethod(shown, name, values) }
        case .link(let target, nil, _):
            return stringMethod(target, name, values)
        case .object(let entries):
            switch name {
            case "keys": return .list(entries.map { .string($0.key) })
            case "values": return .list(entries.map(\.value))
            default: break
            }
        case .regex(let regex, _):
            if name == "matches" {
                let text = display(first)
                return .bool(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil)
            }
        default:
            break
        }
        note("Unknown method .\(name)() on \(Self.typeName(receiver))")
        return .null
    }

    private func stringMethod(_ text: String, _ name: String, _ values: [BaseValue]) -> BaseValue {
        let first = values.first ?? .null
        let strings = values.map(display)
        switch name {
        case "contains": return .bool(text.contains(display(first)))
        case "containsAll": return .bool(strings.allSatisfy(text.contains))
        case "containsAny": return .bool(strings.contains(where: text.contains))
        case "startsWith": return .bool(text.hasPrefix(display(first)))
        case "endsWith": return .bool(text.hasSuffix(display(first)))
        case "lower": return .string(text.lowercased())
        case "upper": return .string(text.uppercased())
        case "trim": return .string(text.trimmingCharacters(in: .whitespacesAndNewlines))
        case "reverse": return .string(String(text.reversed()))
        case "repeat": return .string(String(repeating: text, count: max(0, number(first).map(Int.init) ?? 0)))
        case "title":
            var out = ""
            var start = true
            for character in text {
                out += start ? character.uppercased() : String(character)
                start = character.isWhitespace
            }
            return .string(out)
        case "slice":
            let characters = Array(text)
            return .string(String(characters[Self.slice(characters.count, values.compactMap(number))]))
        case "split":
            var parts: [String]
            if case .regex(let regex, _) = first {
                parts = []
                var start = text.startIndex
                for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let range = Range(match.range, in: text) else { continue }
                    parts.append(String(text[start..<range.lowerBound]))
                    start = range.upperBound
                }
                parts.append(String(text[start...]))
            } else {
                let separator = display(first)
                parts = separator.isEmpty ? text.map(String.init) : text.components(separatedBy: separator)
            }
            if values.count > 1, let limit = number(values[1]) { parts = Array(parts.prefix(Int(limit))) }
            return .list(parts.map(BaseValue.string))
        case "replace":
            let replacement = values.count > 1 ? display(values[1]) : ""
            if case .regex(let regex, let global) = first {
                let range = NSRange(text.startIndex..., in: text)
                if global { return .string(regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)) }
                guard let match = regex.firstMatch(in: text, range: range) else { return .string(text) }
                let replaced = regex.replacementString(for: match, in: text, offset: 0, template: replacement)
                return .string((text as NSString).replacingCharacters(in: match.range, with: replaced))
            }
            return .string(text.replacingOccurrences(of: display(first), with: replacement))
        default:
            note("Unknown method .\(name)() on string")
            return .null
        }
    }

    private func fileMethod(_ path: String, _ name: String, _ values: [BaseValue], _ receiver: BaseValue) -> BaseValue? {
        let first = values.first ?? .null
        switch name {
        case "inFolder":
            let folder = display(first).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return .bool(folder.isEmpty || path.hasPrefix(folder + "/"))
        case "hasProperty":
            let key = display(first)
            return .bool(index.notes[path]?.parsed.properties.contains { $0.key == key } ?? false)
        case "hasTag":
            let tags = (index.notes[path]?.parsed.tags ?? []).map { $0.lowercased() }
            return .bool(values.map { display($0).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "#")) }.contains { wanted in
                tags.contains { $0 == wanted || $0.hasPrefix(wanted + "/") }
            })
        case "hasLink", "linksTo":
            guard let target = target(of: first) else { return .bool(false) }
            return .bool((index.notes[path]?.parsed.links ?? []).contains { index.resolve($0.target, from: path) == target })
        case "asLink":
            return .link(target: path, path: path, display: values.isEmpty ? nil : display(first))
        case "asFile":
            return .file(path)
        default:
            return nil
        }
    }

    /// The vault path a file, a link or a name stands for.
    private func target(of value: BaseValue) -> String? {
        switch value {
        case .file(let path): path
        case .link(_, let path, _): path
        case .string(let text): resolve(text)
        default: nil
        }
    }

    // MARK: Operators

    private func binary(_ symbol: String, _ left: BaseValue, _ right: BaseValue) -> BaseValue {
        switch symbol {
        case "==": return .bool(Self.equal(left, right))
        case "!=": return .bool(!Self.equal(left, right))
        case "<", ">", "<=", ">=":
            guard let order = Self.compare(left, right) else { return .bool(false) }
            switch symbol {
            case "<": return .bool(order < 0)
            case ">": return .bool(order > 0)
            case "<=": return .bool(order <= 0)
            default: return .bool(order >= 0)
            }
        default:
            return arithmetic(symbol, left, right)
        }
    }

    private func arithmetic(_ symbol: String, _ left: BaseValue, _ right: BaseValue) -> BaseValue {
        switch (left, right, symbol) {
        case (.date(let date, let time), _, "+"), (.date(let date, let time), _, "-"):
            if case .date(let other, _) = right, symbol == "-" {
                return .duration(BaseSpan(milliseconds: date.timeIntervalSince(other) * 1000))
            }
            guard var span = Self.span(right) else { return symbol == "+" ? .string(display(left) + display(right)) : .null }
            if symbol == "-" { span = -span }
            return .date(Self.add(span, to: date), time: time || span.milliseconds.truncatingRemainder(dividingBy: 86_400_000) != 0)
        case (.duration(let a), .duration(let b), "+"): return .duration(a + b)
        case (.duration(let a), .duration(let b), "-"): return .duration(a + -b)
        case (.duration(let span), .number(let number), "*"):
            return .duration(BaseSpan(months: Int(Double(span.months) * number), milliseconds: span.milliseconds * number))
        case (.duration(let span), .number(let number), "/"):
            return .number(span.approximateMilliseconds / number)
        case (.string, _, "+"), (_, .string, "+"):
            return .string(display(left) + display(right))
        default:
            guard let a = number(left), let b = number(right) else { return .null }
            switch symbol {
            case "+": return .number(a + b)
            case "-": return .number(a - b)
            case "*": return .number(a * b)
            case "/": return b == 0 ? .null : .number(a / b)
            case "%": return b == 0 ? .null : .number(a.truncatingRemainder(dividingBy: b))
            default: return .null
            }
        }
    }

    private static func span(_ value: BaseValue) -> BaseSpan? {
        switch value {
        case .duration(let span): span
        case .string(let text): BaseSpan.parse(text)
        case .number(let ms): BaseSpan(milliseconds: ms)
        default: nil
        }
    }

    private static func add(_ span: BaseSpan, to date: Date) -> Date {
        let shifted = span.months == 0 ? date : Calendar.current.date(byAdding: .month, value: span.months, to: date) ?? date
        return shifted.addingTimeInterval(span.milliseconds / 1000)
    }

    private func number(_ value: BaseValue) -> Double? {
        switch value {
        case .number(let number): number
        case .bool(let flag): flag ? 1 : 0
        case .string(let text): Double(text.trimmingCharacters(in: .whitespaces))
        case .date(let date, _): date.timeIntervalSince1970 * 1000
        case .duration(let span): span.approximateMilliseconds
        default: nil
        }
    }

    static func truthy(_ value: BaseValue) -> Bool {
        switch value {
        case .null: false
        case .bool(let flag): flag
        case .number(let number): number != 0 && !number.isNaN
        case .string(let text): !text.isEmpty
        case .list(let items): !items.isEmpty
        default: true
        }
    }

    static func isEmpty(_ value: BaseValue) -> Bool {
        switch value {
        case .null: true
        case .string(let text): text.isEmpty
        case .list(let items): items.isEmpty
        case .object(let entries): entries.isEmpty
        default: false
        }
    }

    static func typeName(_ value: BaseValue) -> String {
        switch value {
        case .null: "null"
        case .bool: "boolean"
        case .number: "number"
        case .string: "string"
        case .date: "date"
        case .duration: "duration"
        case .list: "list"
        case .link: "link"
        case .file: "file"
        case .object: "object"
        case .regex: "regexp"
        }
    }

    static func equal(_ a: BaseValue, _ b: BaseValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.number(let x), .number(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.date, .date), (.date, .string), (.string, .date), (.duration, .duration): return compare(a, b) == 0
        case (.list(let x), .list(let y)): return x.count == y.count && zip(x, y).allSatisfy { equal($0, $1) }
        case (.file(let x), .file(let y)): return x == y
        case (.link(_, let x?, _), .file(let y)), (.file(let y), .link(_, let x?, _)): return x == y
        case (.link(let t, let x, _), .link(let u, let y, _)): return x != nil ? x == y : t == u
        case (.link(let target, let path, _), .string(let text)), (.string(let text), .link(let target, let path, _)):
            return text == target || text == path || path.map { Vault.title(of: $0) == text } ?? false
        case (.file(let path), .string(let text)), (.string(let text), .file(let path)):
            return text == path || Vault.title(of: path) == text
        default: return false
        }
    }

    /// Negative, zero or positive; nil when the two cannot be ordered.
    static func compare(_ a: BaseValue, _ b: BaseValue) -> Int? {
        func sign(_ x: Double, _ y: Double) -> Int { x < y ? -1 : x > y ? 1 : 0 }
        switch (a, b) {
        case (.number(let x), .number(let y)): return sign(x, y)
        case (.date(let x, _), .date(let y, _)): return sign(x.timeIntervalSince1970, y.timeIntervalSince1970)
        case (.date, .string(let text)): return parseDate(text).flatMap { compare(a, .date($0.0, time: $0.1)) }
        case (.string(let text), .date): return parseDate(text).flatMap { compare(.date($0.0, time: $0.1), b) }
        case (.duration(let x), .duration(let y)): return sign(x.approximateMilliseconds, y.approximateMilliseconds)
        case (.duration(let x), .number(let y)): return sign(x.approximateMilliseconds, y)
        case (.number(let x), .duration(let y)): return sign(x, y.approximateMilliseconds)
        case (.string(let x), .string(let y)):
            switch x.localizedStandardCompare(y) {
            case .orderedAscending: return -1
            case .orderedDescending: return 1
            case .orderedSame: return 0
            }
        case (.bool(let x), .bool(let y)): return x == y ? 0 : (x ? 1 : -1)
        case (.file(let x), .file(let y)): return compare(.string(Vault.title(of: x)), .string(Vault.title(of: y)))
        case (.link(let t, _, let s), .link(let u, _, let r)): return compare(.string(s ?? t), .string(r ?? u))
        case (.list(let x), .list(let y)):
            for (p, q) in zip(x, y) { if let order = compare(p, q), order != 0 { return order } }
            return sign(Double(x.count), Double(y.count))
        default: return nil
        }
    }

    /// The order of two rows for a sort key: empty values last both ways,
    /// and values of different kinds by their text.
    static func order(_ a: BaseValue, _ b: BaseValue, ascending: Bool) -> Int {
        let emptyA = isEmpty(a), emptyB = isEmpty(b)
        if emptyA || emptyB { return emptyA == emptyB ? 0 : (emptyA ? 1 : -1) }
        let order = compare(a, b) ?? (compare(.string(plain(a)), .string(plain(b))) ?? 0)
        return ascending ? order : -order
    }

    private static func plain(_ value: BaseValue) -> String {
        switch value {
        case .string(let text): text
        case .number(let number): "\(number)"
        default: typeName(value)
        }
    }

    private static func slice(_ count: Int, _ bounds: [Double]) -> Range<Int> {
        func clamp(_ value: Double) -> Int {
            let at = Int(value)
            return min(count, max(0, at < 0 ? count + at : at))
        }
        let start = bounds.first.map(clamp) ?? 0
        let end = bounds.count > 1 ? clamp(bounds[1]) : count
        return start..<max(start, end)
    }

    // MARK: Text

    /// A value as text: in a cell, in `+` with a string, in `join`.
    public func display(_ value: BaseValue) -> String {
        switch value {
        case .null: return ""
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let number):
            if number == number.rounded(), abs(number) < 1e15 { return String(Int64(number)) }
            var text = String(format: "%.4f", number)
            while text.hasSuffix("0") { text.removeLast() }
            return text
        case .string(let text): return text
        case .date(let date, let time): return Self.format(date, time ? "YYYY-MM-DD HH:mm" : "YYYY-MM-DD")
        case .duration(let span): return Self.humanize(span.approximateMilliseconds / 1000)
        case .list(let items): return items.map(display).joined(separator: ", ")
        case .link(let target, let path, let shown): return shown ?? path.map(title) ?? target
        case .file(let path): return title(path)
        case .object(let entries): return entries.map { "\($0.key): \(display($0.value))" }.joined(separator: ", ")
        case .regex(let regex, _): return "/\(regex.pattern)/"
        }
    }

    /// moment's `fromNow`: "3 days ago", "in an hour".
    public static func relative(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        let text = humanize(abs(seconds))
        return seconds > 0 ? "in " + text : text + " ago"
    }

    /// moment's thresholds for a length of time in words.
    static func humanize(_ seconds: Double) -> String {
        let s = abs(seconds), minutes = s / 60, hours = minutes / 60, days = hours / 24
        func count(_ value: Double, _ unit: String) -> String { "\(Int(value.rounded())) \(unit)" }
        if s < 45 { return "a few seconds" }
        if s < 90 { return "a minute" }
        if minutes < 45 { return count(minutes, "minutes") }
        if minutes < 90 { return "an hour" }
        if hours < 22 { return count(hours, "hours") }
        if hours < 36 { return "a day" }
        if days < 26 { return count(days, "days") }
        if days < 45 { return "a month" }
        if days < 320 { return count(days / 30.4375, "months") }
        if days < 548 { return "a year" }
        return count(days / 365.25, "years")
    }

    nonisolated(unsafe) private static let formatToken =
        /\[[^\]]*\]|YYYY|YY|Q|MMMM|MMM|MM|M|Do|DD|D|dddd|ddd|dd|d|HH|H|hh|h|mm|m|ss|s|SSS|A|a|ZZ|Z|X|x/

    private static let months = [
        "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December",
    ]
    private static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// A date in a moment.js format, such as `ddd D MMM, HH:mm`.
    public static func format(_ date: Date, _ pattern: String) -> String {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond, .weekday], from: date)
        let year = parts.year ?? 0, month = parts.month ?? 1, day = parts.day ?? 1
        let hour = parts.hour ?? 0, minute = parts.minute ?? 0, second = parts.second ?? 0
        let weekday = (parts.weekday ?? 1) - 1
        func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
        func ordinal(_ value: Int) -> String {
            let suffix = (11...13).contains(value % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][value % 10] ?? "th"
            return "\(value)\(suffix)"
        }
        let offset = TimeZone.current.secondsFromGMT(for: date) / 60
        let zone = (offset < 0 ? "-" : "+") + two(abs(offset) / 60)
        return pattern.replacing(formatToken) { match -> String in
            let token = String(match.output)
            switch token {
            case "YYYY": return String(year)
            case "YY": return two(year % 100)
            case "Q": return String((month - 1) / 3 + 1)
            case "MMMM": return months[month - 1]
            case "MMM": return String(months[month - 1].prefix(3))
            case "MM": return two(month)
            case "M": return String(month)
            case "Do": return ordinal(day)
            case "DD": return two(day)
            case "D": return String(day)
            case "dddd": return weekdays[weekday]
            case "ddd": return String(weekdays[weekday].prefix(3))
            case "dd": return String(weekdays[weekday].prefix(2))
            case "d": return String(weekday)
            case "HH": return two(hour)
            case "H": return String(hour)
            case "hh": return two(hour % 12 == 0 ? 12 : hour % 12)
            case "h": return String(hour % 12 == 0 ? 12 : hour % 12)
            case "mm": return two(minute)
            case "m": return String(minute)
            case "ss": return two(second)
            case "s": return String(second)
            case "SSS": return String(format: "%03d", (parts.nanosecond ?? 0) / 1_000_000)
            case "A": return hour < 12 ? "AM" : "PM"
            case "a": return hour < 12 ? "am" : "pm"
            case "ZZ": return zone + two(abs(offset) % 60)
            case "Z": return zone + ":" + two(abs(offset) % 60)
            case "X": return String(Int(date.timeIntervalSince1970))
            case "x": return String(Int64(date.timeIntervalSince1970 * 1000))
            default: return String(token.dropFirst().dropLast())
            }
        }
    }
}
