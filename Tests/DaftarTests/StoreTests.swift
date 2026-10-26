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

    @Test func tasksAreSortedInTheFile() throws {
        try "# Plan\n- [ ] Open\n- [x] Done\n".write(to: root.appending(path: "Notes/Plan.md"), atomically: true, encoding: .utf8)
        store.openSynchronously(root)
        #expect(store.sortTasks("Notes/Plan.md"))
        #expect(try text("Notes/Plan.md") == "# Plan\n- [x] Done\n- [ ] Open\n")
        #expect(!store.sortTasks("Notes/Plan.md"))
        #expect(!store.sortTasks("Notes/Missing.md"))
    }

    @Test func aTagIsRenamedInEveryNote() throws {
        try "---\ntags: [work/alpha]\n---\n# Plan\n- [ ] Call #Work\n".write(to: root.appending(path: "Notes/Plan.md"), atomically: true, encoding: .utf8)
        try "#work and `#work`".write(to: root.appending(path: "Home.md"), atomically: true, encoding: .utf8)
        try "#workshop".write(to: root.appending(path: "Other.md"), atomically: true, encoding: .utf8)
        store.openSynchronously(root)
        #expect(store.notes(tagged: "#work") == ["Home.md", "Notes/Plan.md"])
        #expect(store.renameTag("work", to: "job") == 2)
        #expect(try text("Notes/Plan.md") == "---\ntags: [job/alpha]\n---\n# Plan\n- [ ] Call #job\n")
        #expect(try text("Home.md") == "#job and `#work`")
        #expect(try text("Other.md") == "#workshop")
        // The app's own edit is not news to the person who made it.
        store.openSynchronously(root)
        #expect(!store.isUpdatedSinceRead("Home.md"))
        #expect(store.renameTag("work", to: "2026") == 0)
    }

    @Test func replaceInVaultWritesTheCheckedMatches() async throws {
        try FileManager.default.createDirectory(at: root.appending(path: ".obsidian"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "Archive"), withIntermediateDirectories: true)
        try #"{"userIgnoreFilters":["Archive/"]}"#.write(to: root.appending(path: ".obsidian/app.json"), atomically: true, encoding: .utf8)
        try "Call Alice. `Alice` stays. Alice again.".write(to: root.appending(path: "Home.md"), atomically: true, encoding: .utf8)
        try "Alice".write(to: root.appending(path: "Notes/Plan.md"), atomically: true, encoding: .utf8)
        try "Alice".write(to: root.appending(path: "Archive/Old.md"), atomically: true, encoding: .utf8)
        try "Alice".write(to: root.appending(path: "Notes/data.txt"), atomically: true, encoding: .utf8)
        store.openSynchronously(root)
        let pattern = try #require(try VaultReplace.Pattern(find: "alice", replace: "Bob", options: .init()))
        let found = await store.replaceMatches(pattern, in: "")
        #expect(found.map(\.path) == ["Home.md", "Notes/Plan.md"])
        #expect(await store.replaceMatches(pattern, in: "Notes").map(\.path) == ["Notes/Plan.md"])
        let home = try #require(found.first)
        // The second Alice of Home is unchecked; Plan changes after the preview.
        var chosen = Set(found.flatMap { note in note.matches.map { MatchKey(path: note.path, id: $0.id) } })
        chosen.remove(MatchKey(path: "Home.md", id: home.matches[1].id))
        try "Alice and Alice".write(to: root.appending(path: "Notes/Plan.md"), atomically: true, encoding: .utf8)
        let summary = store.replace(pattern, shown: found, chosen: chosen)
        #expect(summary == ReplaceSummary(notes: 1, replacements: 1, refused: ["Notes/Plan.md"]))
        #expect(try text("Home.md") == "Call Bob. `Alice` stays. Alice again.")
        #expect(try text("Notes/Plan.md") == "Alice and Alice")
        #expect(try text("Archive/Old.md") == "Alice")
        #expect(store.replace(pattern, shown: found, chosen: []) == ReplaceSummary())
    }

    @Test func thePeriodicNoteIsMadeFromItsTemplate() throws {
        try FileManager.default.createDirectory(at: root.appending(path: ".obsidian"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "Templates"), withIntermediateDirectories: true)
        try #"{"format":"YYYY-[W]ww","folder":"Journal","template":"Templates/Week"}"#.write(to: root.appending(path: ".obsidian/daily-notes.json"), atomically: true, encoding: .utf8)
        try "# {{title}}\nFrom {{date:YYYY-MM-DD}}\n".write(to: root.appending(path: "Templates/Week.md"), atomically: true, encoding: .utf8)
        store.openSynchronously(root)
        #expect(store.periodic.period == .week)
        #expect(store.templateNotes == ["Templates/Week.md"])
        let path = try store.periodicNote(for: Day(year: 2026, month: 9, day: 24))
        #expect(path == "Journal/2026-W39.md")
        #expect(try text(path) == "# 2026-W39\nFrom 2026-09-24\n")
        // Once there, it is opened and not written again.
        try "kept".write(to: root.appending(path: path), atomically: true, encoding: .utf8)
        #expect(try store.periodicNote(for: Day(year: 2026, month: 9, day: 26)) == path)
        #expect(try text(path) == "kept")
        #expect(store.filled(template: "Templates/Week.md", name: "Plan").hasPrefix("# Plan\nFrom "))
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

    @Test func readingPlacesOutliveTheApp() async throws {
        let model = WindowModel()
        model.places = store.places
        model.open("Notes/Plan.md", store: store)
        model.cursorLine = 2
        let moves = try await store.move("Notes/Plan.md", to: "Notes/Roadmap.md")
        #expect(moves == ["Notes/Plan.md": "Notes/Roadmap.md"])
        store.places.write()
        // A new launch: another store, on the same vault and the same state folder.
        let again = VaultStore(settings: AppSettings(url: root.appending(path: "config/config.toml")), openVault: false)
        again.openSynchronously(root)
        #expect(again.places["Notes/Roadmap.md"] == 2)
        #expect(again.places["Notes/Plan.md"] == nil)
        let next = WindowModel()
        next.places = again.places
        next.open("Notes/Roadmap.md", store: again)
        #expect(next.request?.line == 2)
        // Never beside the person's own configuration.
        #expect(store.settings.stateDirectory.path.hasPrefix(root.path))
    }

    @Test func theSwitcherListsANotesHeadings() throws {
        try "# Trip\n## Hotels\ntext\n## Trains\n".write(to: root.appending(path: "Notes/Trip.md"), atomically: true, encoding: .utf8)
        store.openSynchronously(root)
        #expect(store.switcherRows("trip#tra", recent: [], current: nil).rows.map { [$0.path, $0.heading?.text ?? ""] } == [["Notes/Trip.md", "Trains"]])
        #expect(store.switcherRows("trip#", recent: [], current: nil).rows.map(\.heading?.text) == ["Trip", "Hotels", "Trains"])
        // "#" alone: the open note's headings.
        #expect(store.switcherRows("#hot", recent: [], current: "Notes/Trip.md").rows.first?.heading?.text == "Hotels")
        #expect(store.switcherRows("#hot", recent: [], current: nil).rows.isEmpty)
    }

    @Test func findsAndLinksUnlinkedMentions() async throws {
        try "Call the Plan people.\nThe plan is late.\n".write(to: root.appending(path: "Notes/Call.md"), atomically: true, encoding: .utf8)
        store.openSynchronously(root)
        // Home links to Plan already, so it is not listed.
        let found = await store.unlinkedMentions(of: "Notes/Plan.md")
        #expect(found.map(\.source) == ["Notes/Call.md", "Notes/Call.md"])
        store.link(found[1].mention, in: "Notes/Call.md", to: "Notes/Plan.md")
        #expect(try text("Notes/Call.md") == "Call the Plan people.\nThe [[Plan|plan]] is late.\n")
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

    @Test func anEmptyFolderIsInTheTreeAndMoves() async throws {
        let made = try store.createFolder(named: "Ideas", in: "")
        #expect(store.index.tree.contains { $0.isFolder && $0.path == made })
        _ = try store.createFolder(named: "Later", in: "Ideas")
        _ = try await store.move("Ideas", to: "Notes/Ideas")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Notes/Ideas/Later").path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Ideas").path))
        #expect(store.index.emptyFolders == ["Notes/Ideas", "Notes/Ideas/Later"])
        let notes = try #require(store.index.folder("Notes"))
        #expect(notes.contains { $0.path == "Notes/Ideas" })
        // A folder found on disk, as at launch, is listed too.
        #expect(Vault.index(root).emptyFolders == ["Notes/Ideas", "Notes/Ideas/Later"])
    }

    @Test func aCardDroppedOnAColumnChangesOnlyItsLine() throws {
        let task = try #require(store.index.tasks.first { $0.task.text == "Second" })
        #expect(store.moveTask(task, to: .status("/")))
        #expect(try text("Notes/Plan.md") == "# Plan\n- [ ] First 📅 2026-10-30\n- [/] Second\n")
        // The card is old now: its line says something else, and nothing is written.
        #expect(!store.moveTask(task, to: .status("x")))
        #expect(try text("Notes/Plan.md") == "# Plan\n- [ ] First 📅 2026-10-30\n- [/] Second\n")
    }
}
