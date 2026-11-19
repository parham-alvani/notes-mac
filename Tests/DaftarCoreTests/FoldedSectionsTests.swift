import Foundation
import Testing

@testable import DaftarCore

/// Notes that open folded: what the vault says, and what is kept of a note
/// the person folded or opened themselves (`docs/specs/folded-sections.md`
/// in notes-linux).
@Suite struct FoldedSectionsTests {
    @Test func theVaultSaysWhetherNotesOpenFolded() {
        #expect(!VaultSettings().folded)
        #expect(!VaultSettings(text: "").folded)
        #expect(VaultSettings(text: "[reader]\nfolded = true\n").folded)
        #expect(!VaultSettings(text: "[reader]\nfolded = false\n").folded)
        // Beside daftar-cli's own keys and sections, which are left alone.
        let text = """
            memory = true

            [audit]
            active = ["applied", "screening"]
            quiet_days = 30

            [reader]
            # Notes open as their own table of contents.
            folded = true
            """
        #expect(VaultSettings(text: text).folded)
        // The key of another section is not this one.
        #expect(!VaultSettings(text: "[audit]\nfolded = true\n").folded)
    }

    @Test func aVaultWithNoFileHasTheDefault() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "daftar-vault-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(VaultSettings.read(root: root) == VaultSettings())
        try "[reader]\nfolded = true\n".write(to: root.appending(path: ".daftar.toml"), atomically: true, encoding: .utf8)
        #expect(VaultSettings.read(root: root).folded)
    }

    /// No folds kept is "as the setting says"; none shut, kept on purpose, is the person's choice.
    @Test func noneShutIsKeptOnlyWhenItIsAChoice() {
        var places = ReadingPlaces()
        #expect(places.keptFolds("A.md") == nil)
        places.setFolds("A.md", ["2:Plan"])
        #expect(places.keptFolds("A.md") == ["2:Plan"])
        // Where notes open unfolded, none shut is the default again.
        places.setFolds("A.md", [])
        #expect(places.keptFolds("A.md") == nil)
        #expect(places.folds("A.md").isEmpty)
        // Where notes open folded, a note opened whole stays open.
        places.setFolds("A.md", [], explicit: true)
        #expect(places.keptFolds("A.md") == [])
        // And it is still so after the file is written and read.
        let again = ReadingPlaces(data: places.data)
        #expect(again.keptFolds("A.md") == [])
        #expect(again.keptFolds("B.md") == nil)
    }
}
