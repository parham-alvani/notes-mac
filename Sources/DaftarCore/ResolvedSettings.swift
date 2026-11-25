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
        "appearance.dark_palette": .choice(["naz", "naz-soft"]),
        "appearance.text_size": .int(10...28),
        "appearance.font": .name,
        "appearance.code_font": .name,
        "appearance.text_width": .int(0...400),
        "appearance.block_width": .int(0...400),
        "appearance.reading_line": .int(0...100),
        "appearance.fold_sections": .choice(["vault", "always", "never"]),
        "appearance.link_preview": .bool,
        "appearance.section_bar": .bool,
        "appearance.persian_calendar": .bool,
        "appearance.remote_images": .onlyFalse,
        "calendar.place": .place,
        "editor.live_preview": .bool,
        "editor.format_bar": .bool,
        "editor.slash_menu": .bool,
        "editor.focus": .bool,
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
        // What `.obsidian/` held (`docs/specs/no-obsidian-folder.md`).
        "files.attachments": .path,
        "files.ignore": .strings,
        "daily.format": .text,
        "daily.folder": .path,
        "daily.template": .path,
        "templates.folder": .path,
        "templates.date_format": .text,
        "templates.time_format": .text,
        "home.greeting": .text,
        "home.clock": .choice(["12-hour", "24-hour", "system"]),
        "home.show_time": .bool,
        "home.show_greeting": .bool,
        "home.show_search": .bool,
        "home.show_recent": .bool,
        "home.show_bookmarks": .bool,
        "home.show_quote": .bool,
        // `docs/specs/more-vault-settings.md`.
        "calendar.working_day": .text,
        "tasks.default_scheduled": .int(0...365),
        "notifications.digest_filter": .strings,
        "jobs.waiting": .strings,
        "jobs.closed": .strings,
    ]

    /// The kind of [key] when a vault may set it on every platform: a key
    /// on `allowed`, or a key of a notification rule
    /// (`notifications.rules.<id>.note` and the others,
    /// `NotificationRule.kinds`), whose ids no list can name ahead.
    static func shared(_ key: String) -> Kind? {
        if let kind = allowed[key] { return kind }
        if let (_, name) = NotificationRule.split(key) { return NotificationRule.kinds[name] }
        // A status's section, `[tasks.statuses.<id>]`.
        if key.hasPrefix("tasks.statuses."), let dot = key.lastIndex(of: "."), ["symbol", "name", "next", "type"].contains(String(key[key.index(after: dot)...])) {
            let id = key[key.index(key.startIndex, offsetBy: "tasks.statuses.".count)..<dot]
            return !id.isEmpty && id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) ? .text : nil
        }
        // A property's type, `[properties.types]`.
        if key.hasPrefix("properties.types."), !key.dropFirst("properties.types.".count).isEmpty { return .text }
        // A folder's rules, `[folders."<folder>"]`.
        if let (_, name) = FolderRules.split(key) {
            switch name {
            case "direction": return .choice(["rtl", "ltr", "auto"])
            case "folded": return .bool
            case "template": return .path
            default: return nil
            }
        }
        return nil
    }

    /// The settings only the Mac has, which a vault holds in its `[macos]`
    /// table and nowhere else: none names a program, a path outside the
    /// vault, or what leaves the Mac.
    static let platformOnly: [String: Kind] = [
        "appearance.dock_badge": .bool,
        "appearance.spotlight": .bool,
        "appearance.hide_menu_bar": .bool,
        "editor.properties_form": .bool,
        "editor.typewriter": .bool,
        "editor.spell_check": .bool,
        "editor.animate_cursor": .bool,
        "editor.cursor_trail": .bool,
        "editor.cursor_effect": .choice(["none", "railgun", "torpedo", "pixiedust", "sonicboom", "ripple"]),
        "editor.option_as_meta": .choice(["none", "left", "right", "both"]),
        "editor.blur_panels": .bool,
        "meaning.search": .bool,
        "meaning.refresh_minutes": .int(0...1_440),
        "home.new_tab": .choice(["home", "note"]),
    ]

    /// The keys that differ by platform by nature: a change of one is
    /// written to the platform's table, never to the shared section.
    /// `capture.hotkey` is on the shared list and is the Mac's own: a global shortcut of this platform.
    static let byPlatform: Set<String> = ["appearance.font", "appearance.code_font", "terminal.font_size", "capture.hotkey"]

    /// This app's table in a vault's file, and the other apps' tables, which it never reads.
    public static let platform = "macos"
    static let platforms = ["linux", "macos", "android"]

    /// Sections a vault may set whole (`notifications.*`, `scratchpad.*`,
    /// `capture.*`): a key there the app does not know is left alone.
    static let open: Set<String> = ["notifications", "scratchpad", "capture"]

    /// The sections of the app's own settings. A key in one of them that is
    /// not on the list is refused; every other section (`[check]`,
    /// `[audit]`, `[reader]`, `[agents]`) is not an app setting.
    static let sections: Set<String> = [
        "appearance", "calendar", "editor", "git", "notifications", "terminal", "scratchpad", "capture", "meaning", "home", "files",
        "wakatime", "export", "daily", "templates", "jobs",
    ]

    /// The keys at the top of `config.toml`, never the vault's to say.
    static let top: Set<String> = ["vault", "vaults", "vault_settings"]

    static let defaults = ConfigFile(text: ConfigFile.template)

    private var vault: [String: ConfigFile.Value] = [:]
    /// The keys the vault's file has in this platform's table, whatever their value.
    public private(set) var inPlatformTable: Set<String> = []
    /// The keys this computer declines, and whether it declines every one.
    private var declined: Set<String> = []
    private var follows = true
    private var computer = ConfigFile(text: "")
    /// The keys of the vault's file the list refuses, in the file's order.
    public private(set) var refused: [String] = []
    /// The keys the vault sets here, in the order its file writes them.
    private var vaultOrder: [String] = []

    public init() {}

    /// The settings of [vault] (the text of its `.daftar.toml`) on a
    /// computer whose `config.toml` is [computer]. [root] is the vault's
    /// folder, for the rule that a path from the vault stays in it once
    /// its links are resolved; with none, only the path's text is judged.
    public static func resolved(vault: String, computer: String, root: URL? = nil, platform: String = ResolvedSettings.platform) -> ResolvedSettings {
        var resolved = ResolvedSettings()
        resolved.computer = ConfigFile(text: computer)
        let file = ConfigFile(text: vault)
        switch resolved.computer["vault_settings"] {
        case .bool(false): resolved.follows = false
        case .strings(let keys): resolved.declined = Set(keys)
        default: break
        }
        // The shared sections first, then the platform's own table over them.
        var shared: [String: ConfigFile.Value] = [:], own: [String: ConfigFile.Value] = [:]
        var seen: Set<String> = []
        for key in file.keys where seen.insert(key).inserted {
            var name = key
            var table = false
            if key.hasPrefix(platform + ".") {
                name = String(key.dropFirst(platform.count + 1))
                table = true
            } else if platforms.contains(where: { key.hasPrefix($0 + ".") }) {
                // Another platform's table: never read here.
                continue
            }
            // What only this platform has is the platform table's to hold.
            guard let kind = Self.shared(name) ?? (table && platform == Self.platform ? platformOnly[name] : nil) else {
                let section = name.lastIndex(of: ".").map { String(name[..<$0]) } ?? ""
                if section.isEmpty ? (!table && top.contains(name)) : (sections.contains(section) && !open.contains(section)) { resolved.refused.append(key) }
                continue
            }
            if table { resolved.inPlatformTable.insert(name) }
            guard resolved.follows, !resolved.declined.contains(name), let value = file[key], accepts(value, as: kind, root: root) else { continue }
            if table { own[name] = value } else { shared[name] = value }
            if !resolved.vaultOrder.contains(name) { resolved.vaultOrder.append(name) }
        }
        resolved.vault = shared.merging(own) { $1 }
        return resolved
    }

    /// Where a change made in the app is written.
    public enum Destination: Sendable, Equatable {
        /// The computer's `config.toml`.
        case device
        /// The platform's table in the vault's `.daftar.toml` (`[macos.…]`).
        case platform
        /// The vault's shared section.
        case shared
    }

    /// Where the change of [key] to [value] is written, the first that
    /// applies. The device: a key a vault may never hold, a key this
    /// computer declines, a vault that cannot be written ([writable] false:
    /// a read-only clone, a folder that is no repository and has no
    /// `.daftar.toml`), or a value a vault may not hold. The platform's
    /// table: a key that is there already, one that differs by platform by
    /// nature, and a setting only this platform has. Else the shared section.
    public func destination(of key: String, value: ConfigFile.Value, root: URL? = nil, writable: Bool) -> Destination {
        let only = Self.platformOnly[key]
        guard writable, follows, !declined.contains(key), let kind = Self.shared(key) ?? only,
            Self.accepts(value, as: kind, root: root)
        else { return .device }
        // The author is the vault's own to write by hand, not a setting of the app.
        if only != nil || Self.byPlatform.contains(key) || inPlatformTable.contains(key) { return .platform }
        return .shared
    }

    /// [key] as the vault's file names it at [destination]: under the platform's table, or as it is.
    public static func written(_ key: String, at destination: Destination) -> String {
        destination == .platform ? platform + "." + key : key
    }

    /// A key a vault may hold on this platform: it has Keep on This Device and Follow the Vault.
    public static func mayBeInVault(_ key: String) -> Bool { shared(key) != nil || platformOnly[key] != nil }

    /// This computer declines [key] (`vault_settings` as a list), or every key.
    public func declines(_ key: String) -> Bool { !follows || declined.contains(key) }

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

    /// Every key set here, the vault's first in its file's order, then the
    /// computer's in its file's order: the order of the notification rules.
    public var orderedKeys: [String] {
        var seen = Set(vaultOrder)
        return vaultOrder + computer.keys.filter { seen.insert($0).inserted }
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
