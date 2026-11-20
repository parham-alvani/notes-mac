import Foundation

/// The vaults this computer knows, as `config.toml` holds them: `vault`,
/// the one in use, and `vaults`, the list, the one in use among them. One
/// vault is open at a time; the list is what Switch Vault offers. The pure
/// rule over the file's text; the rules are `docs/specs/several-vaults.md`
/// in notes-linux.
///
/// ```toml
/// vault = "~/org"
/// vaults = ["~/org", "~/notes-bundle"]
/// ```
public struct Vaults: Sendable, Equatable {
    public enum Failure: Error, Equatable, LocalizedError {
        /// The vault in use cannot be forgotten.
        case inUse(String)
        /// More than one listed vault has the name: each, as it is shown.
        case ambiguous(String, [String])
        case unknown(String)

        public var errorDescription: String? {
            switch self {
            case .inUse(let name): "\(name) is the vault in use, so it cannot be forgotten. Switch to another vault first."
            case .ambiguous(let name, let shown): "More than one vault is named \(name): \(shown.joined(separator: ", ")). Give its folder."
            case .unknown(let name): "No vault in the list is named \(name)."
            }
        }
    }

    /// Each folder as the person wrote it (`~` kept), in their order, none twice.
    public private(set) var folders: [String]
    /// The vault in use, as written; nil when the file names none.
    public private(set) var inUse: String?
    /// The home folder `~` stands for.
    public let home: String

    /// The list of a `config.toml`'s text. A file with a `vault` and no
    /// `vaults` is a list of that one; the vault in use is always in the list.
    public init(config text: String, home: String = NSHomeDirectory()) {
        self.home = Self.clean(home)
        let file = ConfigFile(text: text)
        folders = []
        for folder in file.strings("vaults") ?? [] where !folder.trimmingCharacters(in: .whitespaces).isEmpty {
            if !folders.contains(where: { same($0, folder) }) { folders.append(folder) }
        }
        if let vault = file.string("vault"), !vault.trimmingCharacters(in: .whitespaces).isEmpty {
            // The list's own spelling of the folder, when it has it already.
            inUse = folders.first { same($0, vault) } ?? vault
            if !folders.contains(where: { same($0, vault) }) { folders.append(vault) }
        }
    }

    /// [folder] as one folder is compared: `~` and `.`/`..` resolved, no
    /// slash at the end, links not followed.
    public func path(of folder: String) -> String { Self.path(of: folder, home: home) }

    public static func path(of folder: String, home: String) -> String {
        var text = folder.trimmingCharacters(in: .whitespaces)
        if text == "~" { text = home } else if text.hasPrefix("~/") { text = home + String(text.dropFirst(1)) }
        return clean(text)
    }

    private static func clean(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        let joined = parts.joined(separator: "/")
        return path.hasPrefix("/") ? "/" + joined : joined
    }

    private func same(_ a: String, _ b: String) -> Bool { path(of: a) == path(of: b) }

    /// [folder] as the file writes a new one: under the home folder with `~`.
    public func written(_ folder: String) -> String {
        let path = path(of: folder)
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    public func contains(_ folder: String) -> Bool { folders.contains { same($0, folder) } }

    public func isInUse(_ folder: String) -> Bool { inUse.map { same($0, folder) } ?? false }

    /// Opens [folder]: it is the vault in use from now on, and is added to
    /// the list, at the end, when it is not there in any spelling. A folder
    /// of the list keeps the text it has, and nothing moves. True when the
    /// list grew.
    @discardableResult
    public mutating func open(_ folder: String) -> Bool {
        if let known = folders.first(where: { same($0, folder) }) {
            inUse = known
            return false
        }
        let text = written(folder)
        folders.append(text)
        inUse = text
        return true
    }

    /// Takes [folder] out of the list; no file is touched. The vault in use is refused.
    public mutating func forget(_ folder: String) throws {
        guard !isInUse(folder) else { throw Failure.inUse(name(of: folder)) }
        let gone = path(of: folder), home = home
        folders.removeAll { Self.path(of: $0, home: home) == gone }
    }

    /// How [folder] is shown: its folder's name, and with its parent folder
    /// (`org — ~/work`) when another vault of the list has the same name.
    public func name(of folder: String) -> String {
        let path = path(of: folder)
        let name = Self.last(path)
        guard folders.contains(where: { !same($0, folder) && Self.last(self.path(of: $0)) == name }) else { return name }
        let parent = (path as NSString).deletingLastPathComponent
        return name + " — " + written(parent)
    }

    private static func last(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? path }

    /// The folder `--vault <name>` means: a listed vault's name, when
    /// exactly one has it. A value with a `/` or a `~` is a folder, as before.
    public func folder(named name: String) throws -> String {
        if name.contains("/") || name.hasPrefix("~") { return name }
        let found = folders.filter { Self.last(path(of: $0)) == name }
        if found.count == 1 { return found[0] }
        if found.isEmpty { throw Failure.unknown(name) }
        throw Failure.ambiguous(name, found.map(self.name(of:)))
    }

    /// [config] with `vault` and `vaults` as they are here. A file whose
    /// lines say the same already is not changed.
    public func applied(to config: ConfigFile) -> ConfigFile {
        var file = config
        if let inUse, file.string("vault").map({ !same($0, inUse) }) ?? true { file.set("vault", .string(inUse)) }
        // The list is written at the first change: a file that names one
        // vault and no list is that list already.
        let before = Vaults(config: config.text, home: home).folders
        if folders != before || (config.strings("vaults").map { $0 != folders } ?? false) { file.set("vaults", .strings(folders)) }
        return file
    }
}
