import Foundation
import Testing

@testable import DaftarCore

// Every fixture here is made up. The repository is public; the vault is not.

@Suite struct HiddenFilesTests {
    static let agents = ["CLAUDE.md", "AGENTS.md", "GEMINI.md", "CLAUDE.local.md"]
    let hidden = ExcludedFiles(filters: ["uploads/", "node_modules/"], names: agents)

    @Test func aFolderFilterHidesTheFolderAndAllInIt() {
        #expect(hidden.contains("uploads/a.png"))
        #expect(hidden.contains("uploads/2026/b.pdf"))
        #expect(hidden.containsFolder("uploads"))
        #expect(hidden.containsFolder("uploads/2026"))
        #expect(hidden.containsFolder("node_modules"))
        #expect(!hidden.containsFolder("Notes"))
        #expect(!hidden.containsFolder("Notes/uploads"))
        #expect(!hidden.contains("Notes/uploads/a.png"))
        #expect(!hidden.contains("uploads.md"))
    }

    @Test func aNameHidesTheFileInAnyFolder() {
        #expect(hidden.contains("CLAUDE.md"))
        #expect(hidden.contains("Work/CLAUDE.md"))
        #expect(hidden.contains("Work/Projects/Alpha/AGENTS.md"))
        #expect(hidden.contains("Calendar/GEMINI.md"))
        #expect(hidden.contains("Notes/CLAUDE.local.md"))
        #expect(hidden.contains("Notes/claude.md"))
        // Only the whole name: a note that has it in its name is a note.
        #expect(!hidden.contains("MyCLAUDE.md"))
        #expect(!hidden.contains("Work/CLAUDE.md.bak"))
        #expect(!hidden.contains("Work/CLAUDE"))
        #expect(!hidden.contains("CLAUDE.md/Plan.md"))
        #expect(!hidden.containsFolder("Work"))
    }

    @Test func noNamesHideNothing() {
        let none = ExcludedFiles(filters: [], names: [" ", ""])
        #expect(none.isEmpty)
        #expect(!none.contains("CLAUDE.md"))
        #expect(!ExcludedFiles(filters: ["uploads/"]).contains("CLAUDE.md"))
    }

    @Test func theTreeLeavesThemOut() {
        let files: Set<String> = [
            "Home.md", "CLAUDE.md", "AGENTS.md", "MyCLAUDE.md",
            "Work/Plan.md", "Work/CLAUDE.md", "Work/CLAUDE.md.bak",
            "Agents/CLAUDE.md",
            "uploads/a.png", "uploads/2026/b.pdf",
        ]
        let tree = hidden.tree(of: files, emptyFolders: ["uploads/empty", "Empty"])
        #expect(tree.map(\.path) == ["Agents", "Empty", "Work", "Home.md", "MyCLAUDE.md"])
        #expect(Vault.folder("Work", in: tree)?.map(\.path) == ["Work/CLAUDE.md.bak", "Work/Plan.md"])
        // A folder with only a hidden file in it is still there, empty.
        #expect(Vault.folder("Agents", in: tree)?.isEmpty == true)
        #expect(Vault.folder("uploads", in: tree) == nil)
        #expect(ExcludedFiles().tree(of: files) == Vault.tree(of: files))
    }

    @Test func linksToHiddenFilesStillResolve() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "daftar-hidden-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (path, text) in [
            "Home.md": "![[diagram.png]] and [[CLAUDE]] and [[Work/CLAUDE.md|rules]]",
            "uploads/diagram.png": "png",
            "Work/CLAUDE.md": "Rules for agents. See [[Home]].",
            ".obsidian/app.json": #"{"userIgnoreFilters":["uploads/","node_modules/"]}"#,
        ] {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let excluded = ExcludedFiles.load(root, names: Self.agents)
        #expect(excluded.contains("uploads/diagram.png"))
        #expect(excluded.contains("Work/CLAUDE.md"))
        let index = Vault.index(root)
        #expect(index.resolve("diagram.png", from: "Home.md") == "uploads/diagram.png")
        #expect(index.resolve("CLAUDE", from: "Home.md") == "Work/CLAUDE.md")
        #expect(index.resolvedLinks(of: "Home.md")["Work/CLAUDE.md"] == "Work/CLAUDE.md")
        // The graph leaves it out, the vault's and the note's own.
        #expect(NoteGraph.vault(index, excluded: excluded).nodes.map(\.path) == ["Home.md"])
        #expect(NoteGraph.local(index, center: "Home.md", excluded: excluded).nodes.map(\.path) == ["Home.md"])
        #expect(NoteGraph.local(index, center: "Home.md").nodes.map(\.path) == ["Home.md", "Work/CLAUDE.md"])
        // Opened by its path, a hidden note is the centre of its own graph.
        #expect(NoteGraph.local(index, center: "Work/CLAUDE.md", excluded: excluded).nodes.map(\.path) == ["Work/CLAUDE.md", "Home.md"])
    }

    @Test func theConfigListsTheNames() {
        let template = ConfigFile(text: ConfigFile.template)
        #expect(template.strings("files.hidden") == Self.agents)
        #expect(template.bool("files.show_hidden") == false)
        var file = ConfigFile(text: "[files]\nhidden = [ \"A.md\" ,\"b \\\"c\\\".md\" ] # mine\n")
        #expect(file.strings("files.hidden") == ["A.md", "b \"c\".md"])
        file.set("files.hidden", .strings(["CLAUDE.md", "x, y.md"]))
        #expect(file.text == "[files]\nhidden = [\"CLAUDE.md\", \"x, y.md\"] # mine\n")
        #expect(file.strings("files.hidden") == ["CLAUDE.md", "x, y.md"])
        file.set("files.hidden", .strings([]))
        #expect(file.strings("files.hidden") == [])
        #expect(ConfigFile(text: "x = [\"a\", 1]").strings("x") == nil)
        #expect(ConfigFile(text: "x = [\"a\"").strings("x") == nil)
        #expect(ConfigFile(text: "x = \"a\"").strings("x") == nil)
    }
}
