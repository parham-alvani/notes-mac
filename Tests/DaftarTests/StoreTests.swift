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
}
