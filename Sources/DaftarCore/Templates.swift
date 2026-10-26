import Foundation

/// Obsidian's core Templates plugin: the folder of `.obsidian/templates.json`
/// and the variables a template is filled with. `{{title}}` is the new
/// note's name, `{{date}}` and `{{time}}` are now in the plugin's formats,
/// and `{{date:FORMAT}}` and `{{time:FORMAT}}` take a moment format of their
/// own. A variable the plugin does not know stays as it is.
public struct Templates: Sendable, Hashable {
    /// Vault-relative, empty when no folder is set.
    public var folder: String
    public var dateFormat: String
    public var timeFormat: String

    public init(folder: String = "", dateFormat: String = "", timeFormat: String = "") {
        self.folder = folder.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.dateFormat = dateFormat.isEmpty ? "YYYY-MM-DD" : dateFormat
        self.timeFormat = timeFormat.isEmpty ? "HH:mm" : timeFormat
    }

    public init(json: Data) {
        let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
        self.init(folder: root["folder"] as? String ?? "", dateFormat: root["dateFormat"] as? String ?? "", timeFormat: root["timeFormat"] as? String ?? "")
    }

    public static func read(root: URL) -> Templates {
        (try? Data(contentsOf: root.appending(path: ".obsidian/templates.json"))).map(Templates.init(json:)) ?? Templates()
    }

    /// The notes of [paths] that are templates: those in the folder, or,
    /// with no folder set, those in a top folder named `Templates`.
    public func templates(in paths: some Collection<String>) -> [String] {
        let prefix = (folder.isEmpty ? "Templates" : folder) + "/"
        return paths.filter { $0.hasPrefix(prefix) && Vault.isNote($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    nonisolated(unsafe) private static let variable = /\{\{\s*(title|date|time)\s*(?::([^}]*))?\}\}/

    /// [template] with its variables filled for a note named [title], made on [day] at [clock].
    public func fill(_ template: String, title: String, day: Day, clock: MomentFormat.Clock) -> String {
        template.replacing(Self.variable) { match in
            let format = match.2.map { String($0).trimmingCharacters(in: .whitespaces) }
            switch match.1 {
            case "title": return title
            case "date": return MomentFormat.format(format ?? dateFormat, day, clock: clock)
            default: return MomentFormat.format(format ?? timeFormat, day, clock: clock)
            }
        }
    }
}
