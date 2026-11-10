import CoreServices
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

    @Test func searchForgetsTheVaultOpenedBefore() throws {
        #expect(store.search.search("Plan").map(\.path).contains("Notes/Plan.md"))
        let other = FileManager.default.temporaryDirectory.appending(path: "daftar-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        try "# Garden\nTomatoes.".write(to: other.appending(path: "Garden.md"), atomically: true, encoding: .utf8)
        store.openSynchronously(other)
        #expect(store.search.search("Plan").isEmpty)
        #expect(store.search.search("Tomatoes").map(\.path) == ["Garden.md"])
    }

    /// An editor that holds typing not saved yet, as the store sees one:
    /// its save, which the store asks for before an edit of its own.
    final class Typing {
        let file: URL
        var unsaved: String?
        var saves = 0
        init(_ file: URL, unsaved: String) {
            self.file = file
            self.unsaved = unsaved
        }
        func save() {
            saves += 1
            guard let text = unsaved else { return }
            try? text.write(to: file, atomically: true, encoding: .utf8)
            unsaved = nil
        }
    }

    func typing(_ path: String, _ unsaved: String) -> Typing {
        let typing = Typing(root.appending(path: path), unsaved: unsaved)
        store.flushers[ObjectIdentifier(typing)] = { typing.save() }
        return typing
    }

    func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// A tick, a status, a task form, a sort, a tag rename and a restore
    /// each wait for the editors' save, and so read what was typed: before
    /// this the edit read the older file, and the editor's save wrote it away.
    @Test func anEditOfTheStoresWaitsForTheEditorsSave() async throws {
        let typed = "# Plan\n- [ ] First 📅 2026-10-30\n- [ ] Second\n- [ ] Typed #work\n"
        var editor = typing("Notes/Plan.md", typed)
        store.toggleTask(path: "Notes/Plan.md", line: 2, status: " ")
        #expect(await eventually { (try? text("Notes/Plan.md"))?.contains("- [x] Second") == true })
        #expect(try text("Notes/Plan.md").hasSuffix("- [ ] Typed #work\n"))

        store.openSynchronously(root)
        editor = typing("Notes/Plan.md", try text("Notes/Plan.md") + "- [x] Later\n")
        #expect(store.sortTasks("Notes/Plan.md"))
        #expect(await eventually { editor.saves == 1 && (try? text("Notes/Plan.md"))?.hasSuffix("- [ ] Typed #work\n") == true })
        #expect(try text("Notes/Plan.md").contains("- [x] Later\n"))

        try "#work at home".write(to: root.appending(path: "Home.md"), atomically: true, encoding: .utf8)
        store.openSynchronously(root)
        editor = typing("Home.md", "Typed #work at home")
        #expect(await store.renameTag("work", to: "job") == 2)
        #expect(try text("Home.md") == "Typed #job at home")

        editor = typing("Home.md", "typed after")
        try await store.restore("the older text", to: "Home.md")
        #expect(editor.saves == 1)
        #expect(try text("Home.md") == "the older text")

        editor = typing("Home.md", "typed before the sync")
        await store.sync()
        await store.pull()
        #expect(editor.saves == 2)
        #expect(try text("Home.md") == "typed before the sync")
    }

    /// A note in another encoding reads as nothing: it gets no editor, and
    /// no save goes over it.
    @Test func aFileThatIsNotUTF8IsNeverWrittenOver() throws {
        let bytes = Data([0x23, 0x20, 0xE4, 0xF6, 0xFC, 0x0A, 0xFF, 0xFE])
        try bytes.write(to: root.appending(path: "Notes/Old.md"))
        store.openSynchronously(root)
        #expect(store.text(of: "Notes/Old.md") == nil)
        #expect(!store.isText("Notes/Old.md"))
        #expect(store.isText("Notes/Plan.md"))
        #expect(store.isText("Notes/Not there yet.md"))
        #expect(throws: StoreError.self) { try store.write("typed into an empty editor", to: "Notes/Old.md") }
        #expect(try Data(contentsOf: root.appending(path: "Notes/Old.md")) == bytes)
        // Made text by another program, it is a note like any other.
        try "# Old\n".write(to: root.appending(path: "Notes/Old.md"), atomically: true, encoding: .utf8)
        #expect(store.isText("Notes/Old.md"))
        try store.write("# Old\nmore\n", to: "Notes/Old.md")
        #expect(try text("Notes/Old.md") == "# Old\nmore\n")
    }

    /// A pull, or Obsidian, writes a file of `.obsidian` the store keeps a
    /// copy of: the store reads it again, without the app being opened anew.
    @Test func theSettingsOfTheVaultAreReadAgainWhenTheyChange() throws {
        let obsidian = root.appending(path: ".obsidian/plugins/iconic")
        try FileManager.default.createDirectory(at: obsidian, withIntermediateDirectories: true)
        #expect(store.periodic.path(for: Day(year: 2026, month: 3, day: 4)) == "2026-03-04.md")
        try #"{"folder": "Journal", "format": "YYYY-MM-DD"}"#.write(to: root.appending(path: FileWatcher.dailyNotes), atomically: true, encoding: .utf8)
        try #"{"folder": "Models", "dateFormat": "DD.MM.YYYY"}"#.write(to: root.appending(path: FileWatcher.templates), atomically: true, encoding: .utf8)
        try #"{"items": [{"type": "file", "ctime": 1, "path": "Home.md"}]}"#.write(to: root.appending(path: FileWatcher.bookmarks), atomically: true, encoding: .utf8)
        try #"{"fileIcons": {"Notes": {"icon": "lucide-book", "color": "cyan"}}}"#.write(to: root.appending(path: FileWatcher.iconic), atomically: true, encoding: .utf8)
        let before = store.revision
        store.changed(FileWatcher.settings)
        #expect(store.periodic.path(for: Day(year: 2026, month: 3, day: 4)) == "Journal/2026-03-04.md")
        #expect(store.templates.folder == "Models" && store.templates.dateFormat == "DD.MM.YYYY")
        #expect(store.bookmarks.contains("Home.md"))
        #expect(store.iconic.icon(for: "Notes", folder: true) == Iconic.Icon(name: "lucide-book", color: "cyan"))
        #expect(store.revision > before)
    }

    /// The watcher reports those files, and asks for a rescan when the
    /// system says events were lost.
    @Test func theWatcherReportsSettingsAndLostEvents() {
        #expect(FileWatcher.reports("Notes/Plan.md"))
        #expect(FileWatcher.reports(".obsidian/bookmarks.json") && FileWatcher.reports(".obsidian/plugins/iconic/data.json"))
        #expect(FileWatcher.reports(".obsidian/daily-notes.json") && FileWatcher.reports(".obsidian/templates.json"))
        #expect(!FileWatcher.reports(".obsidian/workspace.json") && !FileWatcher.reports(".git/index") && !FileWatcher.reports(""))
        #expect(FileWatcher.lostEvents(FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)))
        #expect(FileWatcher.lostEvents(FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagItemIsDir)))
        #expect(FileWatcher.lostEvents(FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)))
        #expect(!FileWatcher.lostEvents(FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)))
    }

    /// Events lost: nothing says which files changed, so all are read again.
    @Test func aRescanFindsWhatNoEventNamed() async throws {
        try "# New\n- [ ] Found\n".write(to: root.appending(path: "Notes/New.md"), atomically: true, encoding: .utf8)
        try "Now see [[New]].".write(to: root.appending(path: "Home.md"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appending(path: "Notes/Plan.md"))
        #expect(!store.index.files.contains("Notes/New.md"))
        store.rescan()
        store.rescan()
        #expect(await eventually { !store.rescanning && store.index.files.contains("Notes/New.md") })
        #expect(await eventually { !store.rescanning })
        #expect(!store.index.files.contains("Notes/Plan.md"))
        #expect(store.index.backlinks["Notes/New.md"]?.map(\.source) == ["Home.md"])
        #expect(store.search.search("Found").map(\.path) == ["Notes/New.md"])
        #expect(store.lastChanged.contains("Home.md"))
    }

    @Test func tasksAreSortedInTheFile() throws {
        try "# Plan\n- [ ] Open\n- [x] Done\n".write(to: root.appending(path: "Notes/Plan.md"), atomically: true, encoding: .utf8)
        store.openSynchronously(root)
        #expect(store.sortTasks("Notes/Plan.md"))
        #expect(try text("Notes/Plan.md") == "# Plan\n- [x] Done\n- [ ] Open\n")
        #expect(!store.sortTasks("Notes/Plan.md"))
        #expect(!store.sortTasks("Notes/Missing.md"))
    }

    @Test func aTagIsRenamedInEveryNote() async throws {
        try "---\ntags: [work/alpha]\n---\n# Plan\n- [ ] Call #Work\n".write(to: root.appending(path: "Notes/Plan.md"), atomically: true, encoding: .utf8)
        try "#work and `#work`".write(to: root.appending(path: "Home.md"), atomically: true, encoding: .utf8)
        try "#workshop".write(to: root.appending(path: "Other.md"), atomically: true, encoding: .utf8)
        store.openSynchronously(root)
        #expect(store.notes(tagged: "#work") == ["Home.md", "Notes/Plan.md"])
        #expect(await store.renameTag("work", to: "job") == 2)
        #expect(try text("Notes/Plan.md") == "---\ntags: [job/alpha]\n---\n# Plan\n- [ ] Call #job\n")
        #expect(try text("Home.md") == "#job and `#work`")
        #expect(try text("Other.md") == "#workshop")
        // The app's own edit is not news to the person who made it.
        store.openSynchronously(root)
        #expect(!store.isUpdatedSinceRead("Home.md"))
        #expect(await store.renameTag("work", to: "2026") == 0)
    }

    @Test func hiddenFilesAreOnlyLeftOutOfTheLists() throws {
        try FileManager.default.createDirectory(at: root.appending(path: ".obsidian"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "uploads"), withIntermediateDirectories: true)
        try #"{"userIgnoreFilters":["uploads/"]}"#.write(to: root.appending(path: ".obsidian/app.json"), atomically: true, encoding: .utf8)
        try "Rules. - [ ] Example 📅 2026-10-30".write(to: root.appending(path: "Notes/CLAUDE.md"), atomically: true, encoding: .utf8)
        try "png".write(to: root.appending(path: "uploads/plan.png"), atomically: true, encoding: .utf8)
        try "Mine".write(to: root.appending(path: "Notes/MyCLAUDE.md"), atomically: true, encoding: .utf8)
        store.openSynchronously(root)
        let shown = { (folder: String) in store.folder(folder)?.map(\.path) }
        #expect(shown("Notes") == ["Notes/MyCLAUDE.md", "Notes/Plan.md"])
        #expect(shown("uploads") == nil)
        #expect(store.quickOpen("claude", recent: []) == ["Notes/MyCLAUDE.md"])
        #expect(store.quickOpen("", recent: ["Notes/CLAUDE.md", "Home.md"]) == ["Home.md"])
        #expect(store.quickOpen("plan", recent: []).contains("uploads/plan.png") == false)
        // Still a file of the vault: a link resolves and its path opens.
        #expect(store.index.resolve("plan.png", from: "Home.md") == "uploads/plan.png")
        #expect(store.index.notes["Notes/CLAUDE.md"] != nil)
        #expect(store.hidden.contains("Notes/CLAUDE.md"))

        store.settings.showHidden = true
        store.refreshHidden()
        #expect(shown("Notes") == ["Notes/CLAUDE.md", "Notes/MyCLAUDE.md", "Notes/Plan.md"])
        #expect(shown("uploads") == ["uploads/plan.png"])
        #expect(Set(store.quickOpen("claude", recent: [])) == ["Notes/CLAUDE.md", "Notes/MyCLAUDE.md"])
        #expect(store.hidden.contains("Notes/CLAUDE.md"))

        store.settings.showHidden = false
        store.settings.hiddenNames = ["MyCLAUDE.md"]
        store.refreshHidden()
        #expect(shown("Notes") == ["Notes/CLAUDE.md", "Notes/Plan.md"])
        let config = ConfigFile(text: try String(contentsOf: store.settings.url, encoding: .utf8))
        #expect(config.strings("files.hidden") == ["MyCLAUDE.md"])
        #expect(config.bool("files.show_hidden") == false)
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

    /// A bookmark the phone made, pulled while the app runs, is still
    /// there after a bookmark made here: the file is read before it is written.
    @Test func aBookmarkIsAddedToTheFileAsItIsNow() throws {
        store.toggleBookmark("Notes/Plan.md")
        let file = root.appending(path: ".obsidian/bookmarks.json")
        let pulled = """
            {
              "items": [
                {
                  "type": "file",
                  "ctime": 7,
                  "path": "Home.md",
                  "title": "From the phone"
                }
              ]
            }
            """
        try pulled.write(to: file, atomically: true, encoding: .utf8)
        store.toggleBookmark("Notes/Plan.md")
        #expect(Bookmarks.load(root).entries.map(\.path) == ["Home.md", "Notes/Plan.md"])
        #expect(try String(contentsOf: file, encoding: .utf8).hasPrefix(String(pulled.dropLast(8))))
        store.toggleBookmark("Notes/Plan.md")
        #expect(try String(contentsOf: file, encoding: .utf8) == pulled)
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
