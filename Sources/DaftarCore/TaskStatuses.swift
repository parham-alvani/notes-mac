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

/// The statuses of a vault, from the Tasks plugin's settings
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
        var all: [TaskStatus] = []
        let object = json.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let settings = object?["statusSettings"] as? [String: Any]
        for list in ["coreStatuses", "customStatuses"] {
            for item in settings?[list] as? [[String: Any]] ?? [] {
                guard let symbol = Self.one(item["symbol"]), let type = (item["type"] as? String).flatMap(TaskState.init(type:)),
                    !all.contains(where: { $0.symbol == symbol })
                else { continue }
                let name = (item["name"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? "[\(symbol)]"
                all.append(TaskStatus(symbol: symbol, name: name, next: Self.one(item["nextStatusSymbol"]) ?? " ", type: type))
            }
        }
        let defaults = [
            TaskStatus(symbol: " ", name: "Todo", next: "x", type: .todo),
            TaskStatus(symbol: "x", name: "Done", next: " ", type: .done),
            TaskStatus(symbol: "/", name: "In Progress", next: "x", type: .inProgress),
            TaskStatus(symbol: "-", name: "Cancelled", next: " ", type: .cancelled),
        ]
        for (at, status) in defaults.enumerated() where !all.contains(where: { $0.symbol == status.symbol }) {
            all.insert(status, at: min(at, all.count))
        }
        self.all = all
    }

    private static func one(_ value: Any?) -> Character? {
        guard let text = value as? String, text.count == 1 else { return nil }
        return text.first
    }

    /// The vault's statuses; the defaults when the file is missing or broken.
    public static func load(_ root: URL) -> TaskStatuses {
        TaskStatuses(json: try? Data(contentsOf: root.appending(path: file)))
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
