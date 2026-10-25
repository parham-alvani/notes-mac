import Foundation
import Testing

@testable import DaftarCore

// Every fixture here is made up. The repository is public; the vault is not.

@Suite struct VaultMovesTests {
    let files: [String: String] = [
        "Home.md": """
            [[Alpha]], [[Alpha#Plan|the plan]], ![[Alpha]], [[Projects/Alpha]] and [[Alpha.md]].
            A [markdown link](Projects/Alpha/Alpha.md) and `[[Alpha]]` in code.
            ```
            [[Alpha]]
            ```
            ![[diagram.png|300]] and [[Other]].
            """,
        "Projects/Alpha/Alpha.md": "The folder note. See [[Plan]].",
        "Projects/Alpha/Plan.md": "Plan for [[Alpha]], from [[Home]].",
        "Work/Beta.md": "Beta, see [[Plan]].",
        "Other.md": "Nothing to change.",
        "uploads/diagram.png": "png",
    ]

    func makeVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "daftar-moves-\(UUID().uuidString)")
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test func names() {
        #expect(VaultMoves.isValidName("Meeting notes"))
        #expect(!VaultMoves.isValidName("a/b"))
        #expect(!VaultMoves.isValidName("x#y"))
        #expect(!VaultMoves.isValidName("  "))
        #expect(!VaultMoves.isValidName(".hidden"))
        #expect(VaultMoves.noteName("Plan") == "Plan.md")
        #expect(VaultMoves.noteName("Shops.base") == "Shops.base")
        let taken: Set<String> = ["Notes/Untitled.md", "Notes/Untitled 1.md", "Notes/New/x.md"]
        #expect(VaultMoves.freeName("Untitled", in: "Notes", files: taken) == "Notes/Untitled 2.md")
        #expect(VaultMoves.freeName("New", ext: "", in: "Notes", files: taken) == "Notes/New 1")
        #expect(VaultMoves.freeName("Untitled", in: "", files: taken) == "Untitled.md")
    }

    @Test func plans() throws {
        let paths = Set(files.keys)
        #expect(try VaultMoves.plan("Other.md", to: "Archive/Other.md", files: paths) == ["Other.md": "Archive/Other.md"])
        // The folder note takes the folder's new name.
        #expect(try VaultMoves.plan("Projects/Alpha", to: "Projects/Gamma", files: paths) == [
            "Projects/Alpha/Alpha.md": "Projects/Gamma/Gamma.md",
            "Projects/Alpha/Plan.md": "Projects/Gamma/Plan.md",
        ])
        #expect(throws: VaultMoves.Failure.exists("Home.md")) { try VaultMoves.plan("Other.md", to: "Home.md", files: paths) }
        #expect(throws: VaultMoves.Failure.intoItself) { try VaultMoves.plan("Projects", to: "Projects/Alpha/Projects", files: paths) }
        // Only the case changes: not a clash with itself.
        #expect(try VaultMoves.plan("Other.md", to: "other.md", files: paths) == ["Other.md": "other.md"])
    }

    @Test func renamingANoteRewritesEveryLinkInItsStyle() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = Vault.index(root)
        let changed = try VaultMoves.perform("Projects/Alpha", to: "Projects/Gamma", index: index, root: root)
        #expect(changed.contains("Projects/Gamma/Gamma.md"))
        let home = try String(contentsOf: root.appending(path: "Home.md"), encoding: .utf8)
        #expect(home == """
            [[Gamma]], [[Gamma#Plan|the plan]], ![[Gamma]], [[Projects/Gamma/Gamma]] and [[Gamma.md]].
            A [markdown link](Projects/Gamma/Gamma.md) and `[[Alpha]]` in code.
            ```
            [[Alpha]]
            ```
            ![[diagram.png|300]] and [[Other]].
            """)
        let plan = try String(contentsOf: root.appending(path: "Projects/Gamma/Plan.md"), encoding: .utf8)
        #expect(plan == "Plan for [[Gamma]], from [[Home]].")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Projects/Gamma/Gamma.md").path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Projects/Alpha").path))
        // Untouched notes stay as they were.
        #expect(try String(contentsOf: root.appending(path: "Other.md"), encoding: .utf8) == "Nothing to change.")
    }

    @Test func aNameThatIsNoLongerUniqueBecomesAPath() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = Vault.index(root)
        try VaultMoves.perform("Other.md", to: "Work/Plan.md", index: index, root: root)
        let home = try String(contentsOf: root.appending(path: "Home.md"), encoding: .utf8)
        #expect(home.hasSuffix("![[diagram.png|300]] and [[Work/Plan]]."))
    }

    @Test func movingAnAttachmentFollowsItsEmbeds() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = Vault.index(root)
        try VaultMoves.perform("uploads/diagram.png", to: "uploads/flow.png", index: index, root: root)
        let home = try String(contentsOf: root.appending(path: "Home.md"), encoding: .utf8)
        #expect(home.contains("![[flow.png|300]]"))
    }

    @Test func changingOnlyTheCaseWorks() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = Vault.index(root)
        try VaultMoves.perform("Other.md", to: "other.md", index: index, root: root)
        #expect(Vault.scan(root).contains("other.md"))
        #expect(try String(contentsOf: root.appending(path: "Home.md"), encoding: .utf8).hasSuffix("[[other]]."))
    }

    @Test func excludedFiles() {
        let excluded = ExcludedFiles(filters: ["uploads/", "node_modules/", "/\\.excalidraw\\.md$/"])
        #expect(excluded.contains("uploads/a.png"))
        #expect(excluded.contains("Uploads/b.md"))
        #expect(excluded.contains("Drawings/x.excalidraw.md"))
        #expect(!excluded.contains("Notes/uploads.md"))
        #expect(!excluded.contains("Home.md"))
    }
}
