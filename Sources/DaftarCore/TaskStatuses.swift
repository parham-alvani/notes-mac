import Foundation

/// One status a task can have, as the Tasks plugin's settings name it.
public struct TaskStatus: Sendable, Hashable {
    public var symbol: Character
    public var name: String
    /// The status a click in Obsidian moves it to.
    public var next: Character
    public var type: TaskState

    public init(symbol: Character, name: String, next: Character, type: TaskState) {
        self.symbol = symbol
        self.name = name
        self.next = next
        self.type = type
    }

    /// Done, cancelled, or not a task at all: nothing left to do.
    public var isClosed: Bool { type.isFinished }

    /// One of the four every vault has, which the app draws with its own
    /// square; any other shows its name.
    public var isDefault: Bool { [" ", "x", "/", "-"].contains(symbol) }
}

/// The statuses of a vault, from its `[tasks.statuses.<id>]` sections, else
/// the Tasks plugin's settings
/// (`.obsidian/plugins/obsidian-tasks-plugin/data.json`): the core ones,
/// then the custom ones, such as `[r]` "In Review". The rules are Daftar's
/// on Linux (`task_status.rs`) and Android (`TaskStatuses.kt`).
public struct TaskStatuses: Sendable, Equatable {
    public static let file = ".obsidian/plugins/obsidian-tasks-plugin/data.json"

    /// In the settings' order, with the four defaults wherever the settings
    /// leave one out.
    public private(set) var all: [TaskStatus]

    public static let defaults = TaskStatuses(json: nil)

    /// The statuses in [json]. A symbol listed twice is the first one, one
    /// that is not a single character is left out, and a file that cannot
    /// be read is the four defaults.
    public init(json: Data?) {
        let object = json.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let settings = object?["statusSettings"] as? [String: Any]
        let items = ["coreStatuses", "customStatuses"].flatMap { settings?[$0] as? [[String: Any]] ?? [] }
        self.init(items: items.map { ($0["symbol"], $0["name"], $0["nextStatusSymbol"], $0["type"]) })
    }

    /// The statuses of a vault's `[tasks.statuses.<id>]` sections
    /// (`docs/specs/no-obsidian-folder.md`), in the file's order; nil when
    /// it has none. A section with one of the four defaults' symbols may
    /// leave its type out, and changes that status's name or next symbol.
    public init?(settings: ConfigFile) {
        var ids: [String] = []
        for key in settings.keys where key.hasPrefix("tasks.statuses.") {
            let rest = key.dropFirst("tasks.statuses.".count)
            guard let dot = rest.lastIndex(of: ".") else { continue }
            let id = String(rest[..<dot])
            if !ids.contains(id) { ids.append(id) }
        }
        guard !ids.isEmpty else { return nil }
        self.init(
            items: ids.filter { $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" } }.map { id in
                let value = { (name: String) in settings.string("tasks.statuses.\(id).\(name)") }
                return (value("symbol"), value("name"), value("next"), value("type"))
            })
    }

    /// The statuses of [items], each its symbol, name, next symbol and type as
    /// the settings write them. A symbol listed twice is the first one, one that
    /// is not a single character is left out, and the four defaults are put
    /// in wherever the items leave one out.
    init(items: [(symbol: Any?, name: Any?, next: Any?, type: Any?)]) {
        var all: [TaskStatus] = []
        let defaults = Self.four
        for item in items {
            guard let symbol = Self.one(item.symbol), !all.contains(where: { $0.symbol == symbol }) else { continue }
            let standard = defaults.first { $0.symbol == symbol }
            guard let type = (item.type as? String).flatMap(TaskState.init(type:)) ?? standard?.type else { continue }
            let name = (item.name as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? standard?.name ?? "[\(symbol)]"
            all.append(TaskStatus(symbol: symbol, name: name, next: Self.one(item.next) ?? standard?.next ?? " ", type: type))
        }
        for (at, status) in defaults.enumerated() where !all.contains(where: { $0.symbol == status.symbol }) {
            all.insert(status, at: min(at, all.count))
        }
        self.all = all
    }

    /// The four statuses every vault has.
    static let four = [
            TaskStatus(symbol: " ", name: "Todo", next: "x", type: .todo),
            TaskStatus(symbol: "x", name: "Done", next: " ", type: .done),
            TaskStatus(symbol: "/", name: "In Progress", next: "x", type: .inProgress),
            TaskStatus(symbol: "-", name: "Cancelled", next: " ", type: .cancelled),
        ]

    private static func one(_ value: Any?) -> Character? {
        guard let text = value as? String, text.count == 1 else { return nil }
        return text.first
    }

    /// The vault's statuses: its `[tasks.statuses.*]` sections, else the
    /// Tasks plugin's file, which is then not read; the defaults when the
    /// file is missing or broken.
    public static func load(_ root: URL) -> TaskStatuses {
        TaskStatuses(settings: DaftarFolder.settings(root)) ?? TaskStatuses(json: try? Data(contentsOf: root.appending(path: file)))
    }

    /// The status [symbol] stands for. `X` is done unless the settings say
    /// otherwise; a symbol they do not name is still to do, named by itself.
    public func status(_ symbol: Character) -> TaskStatus {
        if let found = all.first(where: { $0.symbol == symbol }) { return found }
        if symbol == "X" { return TaskStatus(symbol: "X", name: "Done", next: " ", type: .done) }
        return TaskStatus(symbol: symbol, name: "[\(symbol)]", next: "x", type: .todo)
    }

    public func type(_ symbol: Character) -> TaskState { status(symbol).type }
    public func isClosed(_ symbol: Character) -> Bool { type(symbol).isFinished }

    /// The statuses of the vault open now, for the rules that are given only
    /// a symbol: the defaults until a vault sets its own.
    public static var current: TaskStatuses {
        get { lock.withLock { shared } }
        set { lock.withLock { shared = newValue } }
    }

    nonisolated(unsafe) private static let lock = NSLock()
    nonisolated(unsafe) private static var shared = TaskStatuses.defaults
}
