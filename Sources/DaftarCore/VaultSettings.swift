import Foundation

/// What a vault says about itself to Daftar on every device, in the
/// `.daftar.toml` at its root, beside `daftar-cli`'s own sections:
///
/// ```toml
/// [reader]
/// folded = true
/// ```
///
/// `reader.folded`: a note opens with its sections folded, each heading
/// saying what is under it (`docs/specs/folded-sections.md` in notes-linux).
/// A file that is not there, or a key that is not, is the default.
///
/// ```toml
/// [agents]
/// read_only_clones = false
/// ```
///
/// `agents.read_only_clones`: with `false`, a read-only clone is not served
/// to an agent, and nothing there sends a note's text to a model
/// (`docs/specs/read-only-vault.md`). Not set is `true`, and a clone that is
/// not read-only is never touched by the key.
///
/// The file may also hold the app's own settings, which `ResolvedSettings`
/// reads: these sections are what the vault says about itself, and are
/// read whatever the computer's `vault_settings` says.
public struct VaultSettings: Sendable, Equatable {
    public static let file = ".daftar.toml"

    public var folded = false
    /// A read-only clone of this vault may be read by an agent.
    public var agentsInReadOnlyClones = true
    /// The file's text, for the app's own settings in it (`ResolvedSettings`).
    public var text = ""

    public init() {}

    public init(text: String) {
        let file = ConfigFile(text: text)
        folded = file.bool("reader.folded") ?? false
        agentsInReadOnlyClones = file.bool("agents.read_only_clones") ?? true
        self.text = text
    }

    public static func read(root: URL) -> VaultSettings {
        (try? String(contentsOf: root.appending(path: file), encoding: .utf8)).map(VaultSettings.init(text:)) ?? VaultSettings()
    }

    /// Whether an agent, or anything that sends a note's text to a model,
    /// is refused in a clone that is [readOnly].
    public func refusesAgents(readOnly: Bool) -> Bool { readOnly && !agentsInReadOnlyClones }
}
