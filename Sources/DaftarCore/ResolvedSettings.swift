import Foundation

/// The app's settings as they hold for one vault on one computer: the
/// vault's committed `.daftar.toml` may hold the same sections and keys as
/// the computer's `config.toml`, so a clone is set up by its first pull.
/// For each key the first of these that has it: the vault's file, when the
/// key is one a vault may set and the computer follows the vault; the
/// computer's file; the default. The rules are `docs/specs/vault-config.md`
/// in notes-linux.
///
/// A repository is text other people and other computers can change, so
/// it never chooses a program to run, a file outside the vault, or what
/// leaves the computer: the keys a vault may set are a list (`allowed`),
/// and a key of the app's that is not on it is refused, by name.
public struct ResolvedSettings: Sendable, Equatable {
    public enum Source: String, Sendable {
        case vault, computer
        case standard = "default"
    }

    /// What a value from the vault must be. A value of another type, or out
    /// of the key's range, is as not there.
    enum Kind: Sendable, Equatable {
        case bool
        /// `appearance.remote_images`: a vault can stop pictures from the
        /// web, never turn them on.
        case onlyFalse
        case int(ClosedRange<Int>)
        /// Any text of one line.
        case text
        /// Text of one line that says something: a font, a name.
        case name
        case choice([String])
        case strings
        /// `HH:MM`.
        case clock
        /// A path in the vault, or empty for none.
        case path
        /// `capture.target`: `daily`, or a path in the vault.
        case target
        /// `calendar.place`: a place the app knows, or empty for none.
        case place
    }

    /// The keys a vault may set. The ranges are those of the app's own controls.
    static let allowed: [String: Kind] = [
        "appearance.theme": .choice(["system", "light", "dark"]),
        "appearance.text_size": .int(10...28),
        "appearance.font": .name,
        "appearance.code_font": .name,
        "appearance.text_width": .int(0...400),
        "appearance.reading_line": .int(0...100),
        "appearance.fold_sections": .choice(["vault", "always", "never"]),
        "appearance.persian_calendar": .bool,
        "appearance.remote_images": .onlyFalse,
        "calendar.place": .place,
        "editor.live_preview": .bool,
        "editor.format_on_save": .bool,
        "git.sync_interval": .int(0...10_080),
        "git.pull_on_launch": .bool,
        "git.name": .name,
        "git.email": .name,
        "notifications.meetings": .bool,
        "notifications.meeting_lead": .int(0...1_440),
        "notifications.digest": .bool,
        "notifications.digest_time": .clock,
        "terminal.font_size": .int(9...24),
        "home.image": .path,
        "export.logo": .path,
        "export.footer": .text,
        "export.contents": .bool,
        "export.landscape": .bool,
        "scratchpad.note": .path,
        "capture.hotkey": .text,
        "capture.target": .target,
        "capture.heading": .text,
        "files.hidden": .strings,
        "files.show_hidden": .bool,
    ]

    /// Sections a vault may set whole (`notifications.*`, `scratchpad.*`,
    /// `capture.*`): a key there the app does not know is left alone.
    static let open: Set<String> = ["notifications", "scratchpad", "capture"]

    /// The sections of the app's own settings. A key in one of them that is
    /// not on the list is refused; every other section (`[check]`,
    /// `[audit]`, `[reader]`, `[agents]`) is not an app setting.
    static let sections: Set<String> = [
        "appearance", "calendar", "editor", "git", "notifications", "terminal", "scratchpad", "capture", "meaning", "home", "files",
        "wakatime", "export",
    ]

    /// The keys at the top of `config.toml`, never the vault's to say.
    static let top: Set<String> = ["vault", "vaults", "vault_settings"]

    static let defaults = ConfigFile(text: ConfigFile.template)

    private var vault: [String: ConfigFile.Value] = [:]
    private var computer = ConfigFile(text: "")
    /// The keys of the vault's file the list refuses, in the file's order.
    public private(set) var refused: [String] = []

    public init() {}

    /// The settings of [vault] (the text of its `.daftar.toml`) on a
    /// computer whose `config.toml` is [computer]. [root] is the vault's
    /// folder, for the rule that a path from the vault stays in it once
    /// its links are resolved; with none, only the path's text is judged.
    public static func resolved(vault: String, computer: String, root: URL? = nil) -> ResolvedSettings {
        var resolved = ResolvedSettings()
        resolved.computer = ConfigFile(text: computer)
        let file = ConfigFile(text: vault)
        var declined: Set<String> = []
        var follows = true
        switch resolved.computer["vault_settings"] {
        case .bool(false): follows = false
        case .strings(let keys): declined = Set(keys)
        default: break
        }
        var seen: Set<String> = []
        for key in file.keys where seen.insert(key).inserted {
            guard let kind = allowed[key] else {
                let section = key.lastIndex(of: ".").map { String(key[..<$0]) } ?? ""
                if section.isEmpty ? top.contains(key) : (sections.contains(section) && !open.contains(section)) { resolved.refused.append(key) }
                continue
            }
            guard follows, !declined.contains(key), let value = file[key], accepts(value, as: kind, root: root) else { continue }
            resolved.vault[key] = value
        }
        return resolved
    }

    static func accepts(_ value: ConfigFile.Value, as kind: Kind, root: URL?) -> Bool {
        func line(_ text: String) -> Bool { !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
        switch (kind, value) {
        case (.bool, .bool): return true
        case (.onlyFalse, .bool(let flag)): return !flag
        case (.int(let range), .int(let number)): return range.contains(number)
        case (.text, .string(let text)): return line(text)
        case (.name, .string(let text)): return line(text) && !text.trimmingCharacters(in: .whitespaces).isEmpty
        case (.choice(let choices), .string(let text)): return choices.contains(text)
        case (.strings, .strings(let list)): return list.allSatisfy(line)
        case (.clock, .string(let text)):
            let parts = text.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
            guard parts.count == 2, let hour = parts[0], let minute = parts[1] else { return false }
            return (0..<24).contains(hour) && (0..<60).contains(minute)
        case (.path, .string(let text)): return text.isEmpty || Vault.holds(text, in: root)
        case (.target, .string(let text)): return text == "daily" || Vault.holds(text, in: root)
        case (.place, .string(let text)): return text.isEmpty || CalendarEvents.Place(text) != nil
        default: return false
        }
    }

    /// Where [key]'s value comes from.
    public func source(of key: String) -> Source {
        if vault[key] != nil { return .vault }
        return computer[key] != nil ? .computer : .standard
    }

    /// The keys the vault sets here, each shown in Settings as "From the vault".
    public var fromVault: Set<String> { Set(vault.keys) }

    /// The vault's value, else the computer's, else the default.
    public subscript(key: String) -> ConfigFile.Value? {
        vault[key] ?? computer[key] ?? Self.defaults[key]
    }

    public func string(_ key: String) -> String? {
        for case .string(let text)? in [vault[key], computer[key], Self.defaults[key]] { return text }
        return nil
    }

    public func int(_ key: String) -> Int? {
        for case .int(let number)? in [vault[key], computer[key], Self.defaults[key]] { return number }
        return nil
    }

    public func bool(_ key: String) -> Bool? {
        // A vault can only turn pictures from the web off.
        for case .bool(let flag)? in [vault[key], computer[key], Self.defaults[key]] { return flag }
        return nil
    }

    public func strings(_ key: String) -> [String]? {
        for case .strings(let list)? in [vault[key], computer[key], Self.defaults[key]] { return list }
        return nil
    }

    /// The vault's own author, for a commit in a clone that names none
    /// (`git.name` and `git.email`, which only a vault sets).
    public var author: Git.Author {
        func said(_ key: String) -> String? {
            if case .string(let text)? = vault[key] { return text.trimmingCharacters(in: .whitespaces) }
            return nil
        }
        return Git.Author(name: said("git.name"), email: said("git.email"))
    }
}

extension Vault {
    /// Whether [path], as a vault's own file may write it, names a file in
    /// the vault at [root]: relative, with no `.` or `..` part, not a `~`
    /// path, and not a link that leaves the vault once resolved. With no
    /// [root] only the text is judged.
    public static func holds(_ path: String, in root: URL?) -> Bool {
        guard !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\") else { return false }
        guard let root else {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            return !parts.isEmpty && !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
        }
        return file(path, in: root) != nil
    }

    /// [path] inside [root], or nil for an absolute path, a `.` or `..`
    /// part, or a symlink that points out of the vault.
    public static func file(_ path: String, in root: URL) -> URL? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let file = base.appending(path: path)
        // A file that is not there yet: its nearest folder that is.
        var existing = file
        while !FileManager.default.fileExists(atPath: existing.path), existing.path.count > base.path.count {
            existing = existing.deletingLastPathComponent()
        }
        let resolved = existing.resolvingSymlinksInPath().path
        guard resolved == base.path || resolved.hasPrefix(base.path + "/") else { return nil }
        let target = file.resolvingSymlinksInPath().path
        return target.hasPrefix(base.path + "/") ? file : nil
    }
}
