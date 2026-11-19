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
public struct VaultSettings: Sendable, Equatable {
    public static let file = ".daftar.toml"

    public var folded = false

    public init() {}

    public init(text: String) {
        folded = ConfigFile(text: text).bool("reader.folded") ?? false
    }

    public static func read(root: URL) -> VaultSettings {
        (try? String(contentsOf: root.appending(path: file), encoding: .utf8)).map(VaultSettings.init(text:)) ?? VaultSettings()
    }
}
