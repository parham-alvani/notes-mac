import DaftarCore
import Foundation
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

    @Test func theSidebarsCountsAreKeptForARevisionAndADay() {
        let memo = Memo<FilesList.GroupsKey, Int>()
        let monday = Day(year: 2026, month: 10, day: 26), tuesday = Day(year: 2026, month: 10, day: 27)
        _ = memo.value(for: .init(revision: 4, today: monday)) { 1 }
        _ = memo.value(for: .init(revision: 4, today: monday)) { 1 }
        #expect(memo.made == 1)
        // Midnight: yesterday's "due today" is overdue now.
        _ = memo.value(for: .init(revision: 4, today: tuesday)) { 1 }
        _ = memo.value(for: .init(revision: 5, today: tuesday)) { 1 }
        #expect(memo.made == 3)
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
