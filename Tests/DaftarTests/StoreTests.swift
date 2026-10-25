import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// The store's edits on a made-up vault in a temporary folder.
@MainActor
@Suite(.serialized) struct StoreTests {
    let root: URL
    let store: VaultStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Notes"), withIntermediateDirectories: true)
        try "# Plan\n- [ ] First 📅 2026-10-30\n- [ ] Second\n".write(to: root.appending(path: "Notes/Plan.md"), atomically: true, encoding: .utf8)
        try "See [[Plan]].".write(to: root.appending(path: "Home.md"), atomically: true, encoding: .utf8)
        store = VaultStore(settings: AppSettings(url: root.appending(path: "config/config.toml")), openVault: false)
        store.openSynchronously(root)
    }

    func text(_ path: String) throws -> String { try String(contentsOf: root.appending(path: path), encoding: .utf8) }

    @Test func editsATask() throws {
        let before = try #require(TaskLine.fields("- [ ] First 📅 2026-10-30"))
        var after = before
        after.priority = "⏫"
        after.scheduled = "2026-10-28"
        #expect(store.editTask(path: "Notes/Plan.md", line: 1, before: before, fields: after))
        #expect(try text("Notes/Plan.md") == "# Plan\n- [ ] First ⏫ ⏳ 2026-10-28 📅 2026-10-30\n- [ ] Second\n")
        // The form was opened on the old line: a second save is refused.
        #expect(!store.editTask(path: "Notes/Plan.md", line: 1, before: before, fields: after))
    }

    @Test func bookmarksFollowARename() async throws {
        store.toggleBookmark("Notes/Plan.md")
        #expect(store.bookmarks.contains("Notes/Plan.md"))
        let moves = try await store.move("Notes/Plan.md", to: "Notes/Roadmap.md")
        #expect(moves == ["Notes/Plan.md": "Notes/Roadmap.md"])
        #expect(store.bookmarks.contains("Notes/Roadmap.md"))
        #expect(Bookmarks.load(root).contains("Notes/Roadmap.md"))
        #expect(try text("Home.md") == "See [[Roadmap]].")
        try await store.delete("Notes/Roadmap.md")
        #expect(!store.bookmarks.contains("Notes/Roadmap.md"))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Notes/Roadmap.md").path))
    }

    @Test func createsNotesAndFolders() throws {
        let path = try store.createNote(named: "Ideas", in: "Notes")
        #expect(path == "Notes/Ideas.md")
        #expect(throws: VaultMoves.Failure.self) { try store.createNote(named: "ideas", in: "Notes") }
        #expect(throws: VaultMoves.Failure.self) { try store.createNote(named: "a/b", in: "") }
        #expect(try store.createFolder(named: "Archive", in: "") == "Archive")
    }

    @Test func aMissingLinkMakesItsNote() throws {
        #expect(try store.createNote(forLink: "Retro", from: "Notes/Plan.md") == "Notes/Retro.md")
        #expect(try store.createNote(forLink: "Projects/New plan#Goals|the plan", from: "Notes/Plan.md") == "Projects/New plan.md")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Projects/New plan.md").path))
        #expect(try store.createNote(forLink: "Top.md", from: "Home.md") == "Top.md")
        #expect(throws: VaultMoves.Failure.self) { try store.createNote(forLink: "Retro", from: "Notes/Plan.md") }
    }

    @Test func noPathLeavesTheVault() throws {
        let outside = root.deletingLastPathComponent().appending(path: "daftar-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try "secret".write(to: outside.appending(path: "secret.md"), atomically: true, encoding: .utf8)
        // A link inside the vault that points out of it.
        try FileManager.default.createSymbolicLink(at: root.appending(path: "Out"), withDestinationURL: outside)
        for path in ["../\(outside.lastPathComponent)/secret.md", "/etc/hosts", "Notes/../Home.md", "Out/secret.md", "Out", "./Home.md", ""] {
            #expect(store.url(of: path) == nil, "\(path)")
            #expect(store.text(of: path) == nil, "\(path)")
        }
        #expect(store.text(of: "Notes/Plan.md") != nil)
        #expect(store.url(of: "Notes/New/Not yet.md") != nil)
        // A link in a note cannot make a file outside, nor a folder.
        #expect(throws: StoreError.self) { try store.createNote(forLink: "../../escaped", from: "Home.md") }
        #expect(throws: StoreError.self) { try store.createNote(forLink: "Out/made", from: "Home.md") }
        #expect(throws: StoreError.self) { try store.createFolder(named: "x", in: "..") }
        #expect(!FileManager.default.fileExists(atPath: outside.appending(path: "made.md").path))
        // Nor can the reader page tick a task in a file outside.
        store.toggleTask(path: "Out/secret.md", line: 0, status: "x")
        #expect(try String(contentsOf: outside.appending(path: "secret.md"), encoding: .utf8) == "secret")
    }

    @Test func aMovedNoteIsNotWrittenAgainAtItsOldPath() async throws {
        let window = WindowModel()
        window.open("Notes/Plan.md", store: store)
        store.followers[ObjectIdentifier(window)] = { [weak window] in window?.follow($0) }
        let editor = EditorController(store: store)
        editor.load("Notes/Plan.md")
        _ = try await store.move("Notes/Plan.md", to: "Notes/Roadmap.md")
        // The window that did not make the move follows it too.
        #expect(window.path == "Notes/Roadmap.md")
        #expect(editor.path == "Notes/Roadmap.md")
        #expect(throws: StoreError.self) { try store.write("old", to: "Notes/Plan.md") }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Notes/Plan.md").path))
        try await store.delete("Notes")
        #expect(window.path == nil)
        #expect(editor.path == nil)
    }
}
