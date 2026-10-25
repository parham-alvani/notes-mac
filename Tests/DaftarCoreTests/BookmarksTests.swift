import Foundation
import Testing

@testable import DaftarCore

// Every fixture here is made up. The repository is public; the vault is not.

@Suite struct BookmarksTests {
    let json = """
        {
          "items": [
            {"type": "file", "ctime": 1, "path": "Home.md"},
            {"type": "group", "ctime": 2, "title": "Work", "items": [
              {"type": "file", "ctime": 3, "path": "Projects/Alpha/Plan.md", "title": "The plan"},
              {"type": "folder", "ctime": 4, "path": "Projects/Alpha"}
            ]},
            {"type": "search", "ctime": 5, "query": "tag:#work"}
          ]
        }
        """

    func makeVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "daftar-bookmarks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: ".obsidian"), withIntermediateDirectories: true)
        try json.write(to: root.appending(path: ".obsidian/bookmarks.json"), atomically: true, encoding: .utf8)
        return root
    }

    @Test func readsFilesFoldersAndGroups() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let bookmarks = Bookmarks.load(root)
        #expect(bookmarks.entries == [
            .init(path: "Home.md", title: nil, group: nil, folder: false),
            .init(path: "Projects/Alpha/Plan.md", title: "The plan", group: "Work", folder: false),
            .init(path: "Projects/Alpha", title: nil, group: "Work", folder: true),
        ])
        #expect(bookmarks.contains("Projects/Alpha/Plan.md"))
        #expect(!bookmarks.contains("Projects/Alpha"))
    }

    @Test func togglesAndKeepsWhatItDoesNotShow() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        var bookmarks = Bookmarks.load(root)
        bookmarks.toggle("Other.md", now: Date(timeIntervalSince1970: 10))
        bookmarks.toggle("Projects/Alpha/Plan.md")
        try bookmarks.save(root)
        let again = Bookmarks.load(root)
        #expect(again.entries.map(\.path) == ["Home.md", "Projects/Alpha", "Other.md"])
        #expect(again.items.contains { $0["type"] as? String == "search" && $0["query"] as? String == "tag:#work" })
        #expect(again.items.last?["ctime"] as? Int == 10_000)
    }

    @Test func followsMovesAndDeletes() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        var bookmarks = Bookmarks.load(root)
        let changed = bookmarks.follow(
            ["Projects/Alpha/Plan.md": "Projects/Gamma/Plan.md"], folder: ("Projects/Alpha", "Projects/Gamma"))
        #expect(changed)
        #expect(bookmarks.entries.map(\.path) == ["Home.md", "Projects/Gamma/Plan.md", "Projects/Gamma"])
        bookmarks.remove("Projects/Gamma")
        #expect(bookmarks.entries.map(\.path) == ["Home.md"])
        // The group stays, empty, as Obsidian keeps it.
        #expect(bookmarks.items.contains { $0["type"] as? String == "group" })
    }
}
