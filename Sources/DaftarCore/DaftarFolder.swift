import Foundation

/// Daftar's own homes for the settings Obsidian kept in `.obsidian/`
/// (`docs/specs/no-obsidian-folder.md` in notes-linux): a section of the
/// vault's `.daftar.toml`, or a file in `.daftar/` for data too long for a
/// settings file. Each setting is read from its new place first; only when
/// that is not there at all (the key is not set, the file does not exist)
/// is the old file of `.obsidian/` read, and the two are never merged.
public enum DaftarFolder {
    public static let name = ".daftar"
    /// Iconic's JSON, as it is.
    public static let icons = ".daftar/icons.json"
    /// The home page's quotes: `[{"text": "…", "author": "…"}]`.
    public static let quotes = ".daftar/quotes.json"
    /// Obsidian's `bookmarks.json`, as it is.
    public static let bookmarks = ".daftar/bookmarks.json"

    /// The vault's `.daftar.toml`, empty when it has none.
    public static func settings(_ root: URL) -> ConfigFile { ConfigFile(text: VaultSettings.read(root: root).text) }

    /// Whether [path] (one of `icons`, `quotes`, `bookmarks`) is in the vault at [root].
    public static func has(_ path: String, in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: path).path)
    }

    /// Where a file that has a new place in `.daftar/` and an old one in
    /// `.obsidian/` is written: the new place when it is there, else the
    /// old one in a vault that has `.obsidian/`, as before, else the new
    /// place: nothing is made in `.obsidian/` in a vault that has none.
    public static func written(_ path: String, old: String, in root: URL) -> URL {
        if has(path, in: root) { return root.appending(path: path) }
        var isFolder: ObjCBool = false
        let obsidian = FileManager.default.fileExists(atPath: root.appending(path: ".obsidian").path, isDirectory: &isFolder) && isFolder.boolValue
        return root.appending(path: obsidian ? old : path)
    }

    /// The JSON of `.obsidian/app.json`, or nil.
    static func obsidianApp(_ root: URL) -> [String: Any]? {
        (try? Data(contentsOf: root.appending(path: ".obsidian/app.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// The folder pasted and dropped files go to, relative to the vault, or
    /// empty for its root: `files.attachments`, else Obsidian's
    /// `attachmentFolderPath`. A path that leaves the vault is as not set.
    public static func attachments(_ root: URL) -> String {
        if let folder = settings(root).string("files.attachments"), folder.isEmpty || Vault.holds(folder, in: root) {
            return folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        guard let folder = obsidianApp(root)?["attachmentFolderPath"] as? String, !folder.isEmpty, folder != "/" else { return "" }
        return folder.hasPrefix("./") ? "" : folder
    }

    /// The excluded files' filters: `files.ignore`, else Obsidian's `userIgnoreFilters`.
    public static func ignoreFilters(_ root: URL) -> [String] {
        settings(root).strings("files.ignore") ?? obsidianApp(root)?["userIgnoreFilters"] as? [String] ?? []
    }

    /// The keys of [file] under the section [prefix] (`properties.types`),
    /// one level down, with the quotes of a quoted key taken off, in the
    /// file's order.
    static func keys(_ file: ConfigFile, under prefix: String) -> [(name: String, key: String)] {
        file.keys.compactMap { key in
            guard key.hasPrefix(prefix + ".") else { return nil }
            let name = String(key.dropFirst(prefix.count + 1))
            return name.contains(".") && !name.hasPrefix("\"") ? nil : (unquoted(name), key)
        }
    }

    /// `"a b"` as `a b`; a bare name as it is.
    static func unquoted(_ name: String) -> String {
        name.count >= 2 && name.hasPrefix("\"") && name.hasSuffix("\"") ? String(name.dropFirst().dropLast()) : name
    }
}
