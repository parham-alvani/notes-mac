import Foundation

/// What a vault's `[folders."<folder>"]` sections say for the notes under
/// each folder (`docs/specs/more-vault-settings.md`, section 6): their base
/// direction, whether they open folded, and the template a new note there
/// starts from. The most specific folder wins, key by key.
public struct FolderRules: Sendable, Equatable {
    /// A note's base direction.
    public enum Direction: String, Sendable {
        case rtl, ltr, auto
    }

    /// What one folder's section sets; nil for a key it leaves out.
    public struct Rule: Sendable, Equatable {
        public var direction: Direction?
        public var folded: Bool?
        public var template: String?

        public init(direction: Direction? = nil, folded: Bool? = nil, template: String? = nil) {
            self.direction = direction
            self.folded = folded
            self.template = template
        }
    }

    /// Each folder's own section, by its path with no `/` at either end.
    public private(set) var folders: [String: Rule] = [:]

    public init() {}

    /// The sections of [settings]. A value that does not fit is as not there.
    public init(_ settings: ResolvedSettings) {
        for key in settings.orderedKeys {
            guard let (folder, name) = Self.split(key) else { continue }
            var rule = folders[folder] ?? Rule()
            switch name {
            case "direction": rule.direction = settings.string(key).flatMap(Direction.init(rawValue:))
            case "folded": rule.folded = settings.bool(key)
            case "template": rule.template = settings.string(key).flatMap { $0.isEmpty ? nil : $0 }
            default: continue
            }
            folders[folder] = rule
        }
    }

    /// The folder and the key's name of `folders."<folder>".<name>`; nil for
    /// any other key, or a folder that is no path in a vault.
    static func split(_ key: String) -> (folder: String, name: String)? {
        guard key.hasPrefix("folders."), let dot = key.lastIndex(of: ".") else { return nil }
        let name = String(key[key.index(after: dot)...])
        let quoted = key[key.index(key.startIndex, offsetBy: "folders.".count)..<dot]
        let folder = DaftarFolder.unquoted(String(quoted)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !folder.isEmpty, Vault.holds(folder, in: nil) else { return nil }
        return (folder, name)
    }

    /// The rule for the note at [path]: each key from the nearest folder above it that sets it.
    public func rule(for path: String) -> Rule {
        var rule = Rule()
        var parts = path.split(separator: "/").dropLast().map(String.init)
        while !parts.isEmpty {
            if let own = folders[parts.joined(separator: "/")] {
                rule.direction = rule.direction ?? own.direction
                rule.folded = rule.folded ?? own.folded
                rule.template = rule.template ?? own.template
            }
            parts.removeLast()
        }
        return rule
    }
}
