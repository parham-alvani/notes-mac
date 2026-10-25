import Foundation

/// The app's settings as a TOML file the person can read, edit and keep in
/// their dotfiles: `$XDG_CONFIG_HOME/daftar/config.toml`, else
/// `~/.config/daftar/config.toml`.
///
/// A small subset of TOML: `[section]` headers and `key = value`, where a
/// value is a quoted string, an integer or a boolean. That is every setting
/// the app has. A change from the app rewrites one value on its own line, so
/// the person's comments and order stay as they wrote them.
public struct ConfigFile: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case string(String)
        case int(Int)
        case bool(Bool)

        var toml: String {
            switch self {
            case .string(let text):
                "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
            case .int(let number): String(number)
            case .bool(let flag): flag ? "true" : "false"
            }
        }
    }

    public private(set) var text: String

    public init(text: String) { self.text = text }

    public static var defaultURL: URL {
        let environment = ProcessInfo.processInfo.environment
        let base = environment["XDG_CONFIG_HOME"].map { URL(filePath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config")
        return base.appending(path: "daftar/config.toml")
    }

    /// `section.key`, or `key` for the top of the file.
    public subscript(path: String) -> Value? {
        let (section, key) = Self.split(path)
        var current = ""
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let header = Self.header(trimmed) {
                current = header
                continue
            }
            guard current == section, let (name, raw) = Self.assignment(trimmed), name == key else { continue }
            return Self.value(raw)
        }
        return nil
    }

    public func string(_ path: String) -> String? {
        if case .string(let text) = self[path] { return text }
        return nil
    }

    public func int(_ path: String) -> Int? {
        if case .int(let number) = self[path] { return number }
        return nil
    }

    public func bool(_ path: String) -> Bool? {
        if case .bool(let flag) = self[path] { return flag }
        return nil
    }

    /// Sets one value: in place when the key is there, else at the end of its
    /// section, else in a new section at the end of the file.
    public mutating func set(_ path: String, _ value: Value) {
        let (section, key) = Self.split(path)
        var lines = text.components(separatedBy: "\n")
        var current = ""
        var lastInSection: Int?
        var sectionSeen = section.isEmpty
        if section.isEmpty { lastInSection = -1 }
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let header = Self.header(trimmed) {
                current = header
                if header == section { sectionSeen = true; lastInSection = index }
                continue
            }
            guard current == section else { continue }
            if !trimmed.isEmpty { lastInSection = index }
            if let (name, _) = Self.assignment(trimmed), name == key {
                let indent = line.prefix { $0 == " " || $0 == "\t" }
                let comment = Self.trailingComment(line)
                lines[index] = "\(indent)\(key) = \(value.toml)" + (comment.map { " " + $0 } ?? "")
                text = lines.joined(separator: "\n")
                return
            }
        }
        let entry = "\(key) = \(value.toml)"
        if sectionSeen, let at = lastInSection {
            lines.insert(entry, at: at + 1)
        } else {
            while lines.last?.isEmpty == true { lines.removeLast() }
            lines += ["", "[\(section)]", entry]
        }
        text = lines.joined(separator: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
    }

    private static func split(_ path: String) -> (String, String) {
        guard let dot = path.lastIndex(of: ".") else { return ("", path) }
        return (String(path[..<dot]), String(path[path.index(after: dot)...]))
    }

    private static func header(_ line: String) -> String? {
        guard line.hasPrefix("["), let end = line.firstIndex(of: "]") else { return nil }
        return line[line.index(after: line.startIndex)..<end].trimmingCharacters(in: .whitespaces)
    }

    private static func assignment(_ line: String) -> (String, String)? {
        guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { return nil }
        let key = line[..<equals].trimmingCharacters(in: .whitespaces)
        let raw = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : (key, raw)
    }

    private static func value(_ raw: String) -> Value? {
        if raw.hasPrefix("\"") {
            var out = ""
            var escaped = false
            for ch in raw.dropFirst() {
                if escaped {
                    out.append(ch == "n" ? "\n" : ch == "t" ? "\t" : ch)
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    return .string(out)
                } else {
                    out.append(ch)
                }
            }
            return nil
        }
        let bare = raw.split(separator: "#", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if bare == "true" { return .bool(true) }
        if bare == "false" { return .bool(false) }
        if let number = Int(bare.replacingOccurrences(of: "_", with: "")) { return .int(number) }
        return nil
    }

    /// A `# comment` after the value, outside any quotes.
    private static func trailingComment(_ line: String) -> String? {
        var quoted = false
        var escaped = false
        guard let equals = line.firstIndex(of: "=") else { return nil }
        for index in line[line.index(after: equals)...].indices {
            let ch = line[index]
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" { quoted.toggle(); continue }
            if ch == "#", !quoted { return String(line[index...]) }
        }
        return nil
    }

    /// The file a new install starts from: every setting, at its default,
    /// with what it does.
    public static let template = """
        # Daftar for macOS. These are all of the app's settings; the app reads
        # this file again whenever it changes, and writes back only the value
        # that a change in its Settings window touches.

        # The folder of the Obsidian vault.
        vault = ""

        [appearance]
        # "system", "light" (Daftar's Daylight palette) or "dark" (naz).
        theme = "system"
        # 14, as the vault's Obsidian snippet sets it.
        text_size = 14
        # The font of notes, in the reader and the editor: a font family, or
        # "SF Pro" (Obsidian's Cupertino theme) and "New York" for Apple's
        # own. Persian always uses Vazirmatn.
        font = "SF Pro"
        # Code and the editor's markup; "SF Mono" is Obsidian's.
        code_font = "SF Mono"
        # Count the tasks due today and overdue on the Dock icon.
        dock_badge = true
        # Show the vault's notes in Spotlight. The index is on this Mac only;
        # excluded files are left out.
        spotlight = true

        [editor]
        # Edit with your own Neovim: it owns the buffer and the file, and the
        # editor shows it. Needs `nvim` (brew install neovim).
        vim_mode = false
        # Empty finds nvim in /opt/homebrew/bin, /usr/local/bin or /usr/bin.
        nvim = ""
        # "user" loads your init.lua (with g:daftar set); "clean" loads none;
        # a path, as "~/.config/daftar/init.lua", loads that file instead.
        nvim_config = "user"

        [git]
        # Minutes between commit-pull-push runs; 0 is off. Keep it off while
        # Obsidian's git plugin syncs the same folder.
        sync_interval = 0
        # Pull when the app starts.
        pull_on_launch = true

        [notifications]
        meetings = true
        # Minutes before a meeting.
        meeting_lead = 5
        digest = true
        # The morning digest of the tasks due, as HH:MM.
        digest_time = "09:00"

        [terminal]
        # Empty is the login shell in $SHELL.
        shell = ""
        font_size = 13

        """
}
