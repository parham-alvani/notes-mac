import Foundation

/// The icons and colours the Iconic plugin gives files and folders, read from
/// `.obsidian/plugins/iconic/data.json`, so the tree here looks like the tree
/// in Obsidian and on the phone.
public struct Iconic: Sendable {
    public struct Icon: Sendable, Hashable {
        /// `lucide-book`, or an emoji.
        public var name: String?
        /// One of Iconic's names (`orange`, `cyan`, …) or `#rrggbb`.
        public var color: String?

        public var isEmoji: Bool { name.map { !$0.hasPrefix("lucide-") } ?? false }
    }

    /// A compiled `Regex` is not `Sendable`, but it is only ever read.
    struct Rule: @unchecked Sendable {
        var patterns: [Regex<AnyRegexOutput>]
        var all: Bool
        var icon: Icon
    }

    private var items: [String: Icon] = [:]
    private var folderRules: [Rule] = []
    private var fileRules: [Rule] = []

    public init() {}

    public static func load(_ root: URL) -> Iconic {
        let url = root.appending(path: ".obsidian/plugins/iconic/data.json")
        guard let data = try? Data(contentsOf: url) else { return Iconic() }
        return parse(data)
    }

    public static func parse(_ data: Data) -> Iconic {
        var iconic = Iconic()
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return iconic }
        for key in ["fileIcons", "folderIcons"] {
            for (path, value) in json[key] as? [String: [String: Any]] ?? [:] {
                let icon = Icon(name: value["icon"] as? String, color: value["color"] as? String)
                if icon.name != nil || icon.color != nil { iconic.items[Slugs.normalize(path)] = icon }
            }
        }
        iconic.folderRules = rules(json["folderRules"])
        iconic.fileRules = rules(json["fileRules"])
        return iconic
    }

    /// Only the rule shape this vault uses: conditions that match the path
    /// against a regular expression. A rule with any other condition is
    /// skipped rather than half applied.
    private static func rules(_ value: Any?) -> [Rule] {
        (value as? [[String: Any]] ?? []).compactMap { rule in
            guard rule["enabled"] as? Bool ?? true, let conditions = rule["conditions"] as? [[String: Any]] else { return nil }
            var patterns: [Regex<AnyRegexOutput>] = []
            for condition in conditions {
                guard ["tree", "path"].contains(condition["source"] as? String ?? ""),
                    condition["operator"] as? String == "matches",
                    let text = condition["value"] as? String, let regex = try? Regex(text)
                else { return nil }
                patterns.append(regex)
            }
            let icon = Icon(name: rule["icon"] as? String, color: rule["color"] as? String)
            return Rule(patterns: patterns, all: rule["match"] as? String != "any", icon: icon)
        }
    }

    /// The icon of a vault path: its own, else the first rule that matches.
    public func icon(for path: String, folder: Bool) -> Icon? {
        if let own = items[path] { return own }
        for rule in folder ? folderRules : fileRules {
            let hits = rule.patterns.map { path.firstMatch(of: $0) != nil }
            if rule.all ? hits.allSatisfy({ $0 }) : hits.contains(true) { return rule.icon }
        }
        return nil
    }
}
