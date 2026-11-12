import DaftarCore
import Foundation
import Observation
import Testing

@testable import DaftarUI

/// What the sidebar and the board work out from every task is worked out
/// when the vault changes, not at each redraw.
@MainActor
@Suite struct MemoTests {
    @Test func aValueIsMadeOnceForAKey() {
        let memo = Memo<Int, [String]>()
        var walks = 0
        let make = { () -> [String] in
            walks += 1
            return ["a"]
        }
        // Ten redraws at one revision walk the tasks once.
        for _ in 0..<10 { #expect(memo.value(for: 1, make) == ["a"]) }
        #expect(walks == 1)
        _ = memo.value(for: 2, make)
        _ = memo.value(for: 2, make)
        #expect(walks == 2)
        #expect(memo.made == 2)
    }

    /// The sidebar's list reads `SidebarFacts`, which change only with what
    /// the list shows: a save of a note's words draws nothing again.
    @Test func theSidebarsFactsChangeOnlyWithWhatItShows() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "daftar-facts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let today = Day.today()
        try "- [ ] Call Sara 📅 \(today)\n".write(to: root.appending(path: "Plan.md"), atomically: true, encoding: .utf8)
        try "Words\n".write(to: root.appending(path: "Words.md"), atomically: true, encoding: .utf8)
        let store = VaultStore(settings: AppSettings(url: root.appending(path: "config/config.toml")), openVault: false)
        store.openSynchronously(root)
        let facts = store.sidebar
        #expect(facts.counts == SidebarFacts.Counts(day: today, due: 1))
        #expect(Set(facts.tree.map(\.path)).isSuperset(of: ["Plan.md", "Words.md"]))
        final class Flag: @unchecked Sendable { var on = false }
        let redrawn = Flag()
        withObservationTracking {
            _ = (facts.tree, facts.files, facts.updated, facts.updatedPaths, facts.tagTree, facts.tagCount, facts.counts)
        } onChange: { redrawn.on = true }
        try store.write("More words\n", to: "Words.md")
        for _ in 0..<100 where store.index.notes["Words.md"]?.parsed.plain.contains("More") != true { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!redrawn.on)
        try store.write("- [ ] Call Sara 📅 \(today)\n- [ ] Pay rent 📅 \(today)\n", to: "Plan.md")
        for _ in 0..<100 where facts.counts.due != 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(redrawn.on)
        #expect(facts.counts.due == 2)
        // Midnight: what is due today is overdue tomorrow.
        #expect(SidebarFacts.counts(store, day: today.adding(days: 1)) == SidebarFacts.Counts(day: today.adding(days: 1), overdue: 2))
    }

    @Test func theBoardsNotesAreSortedByTitlesMadeBeforeTheSort() {
        #expect(BoardView.files(["b/Note 10.md", "a/note 2.md", "a/note 2.md", "c/Alpha.md", "z/Alpha.md"]) == ["c/Alpha.md", "z/Alpha.md", "a/note 2.md", "b/Note 10.md"])
    }

    @Test func theBoardFiltersByNoteQueryAndHiddenFiles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "daftar-memo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Work"), withIntermediateDirectories: true)
        try "- [ ] Call Sara\n- [x] Pay rent\n".write(to: root.appending(path: "Work/Plan.md"), atomically: true, encoding: .utf8)
        try "- [ ] Call the bank\n".write(to: root.appending(path: "Home.md"), atomically: true, encoding: .utf8)
        try "- [ ] hidden call\n".write(to: root.appending(path: "CLAUDE.md"), atomically: true, encoding: .utf8)
        let store = VaultStore(settings: AppSettings(url: root.appending(path: "config/config.toml")), openVault: false)
        store.openSynchronously(root)
        let tasks = store.index.tasks
        let texts = { (found: [VaultTask]) in found.map(\.task.text).sorted() }
        #expect(texts(BoardView.shown(tasks, excluded: store.excluded, file: nil, query: "")) == ["Call Sara", "Call the bank", "Pay rent"])
        #expect(texts(BoardView.shown(tasks, excluded: store.excluded, file: nil, query: " CALL ")) == ["Call Sara", "Call the bank"])
        #expect(texts(BoardView.shown(tasks, excluded: store.excluded, file: "Work/Plan.md", query: "")) == ["Call Sara", "Pay rent"])
        #expect(texts(BoardView.shown(tasks, excluded: ExcludedFiles(), file: nil, query: "hidden")) == ["hidden call"])
    }
}
