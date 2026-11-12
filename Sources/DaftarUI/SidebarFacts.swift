import DaftarCore
import Foundation
import Observation

/// What the sidebar's list shows of the vault, kept apart from the store:
/// the list reads only these, and each is set only when it changed. A save
/// changes the index and marks the note read, which redrew the whole list
/// and every row at each autosave; it changes nothing here, so nothing is
/// drawn again.
@MainActor @Observable
final class SidebarFacts {
    /// The tree, without the excluded files.
    private(set) var tree: [TreeNode] = []
    /// Every file of the vault, for the bookmarks that name one.
    private(set) var files: Set<String> = []
    /// The notes changed on disk since they were read, newest first, with when.
    private(set) var updated: [Updated] = []
    /// The same notes, for a row's dot.
    private(set) var updatedPaths: Set<String> = []
    private(set) var tagTree: [TagNode] = []
    private(set) var tagCount = 0
    /// The first two rows' badges, for [Counts.day].
    private(set) var counts = Counts(day: .today())

    struct Updated: Equatable {
        var path: String
        var modified: Date?
    }

    struct Counts: Equatable {
        var day: Day
        var due = 0
        var overdue = 0
        var inProgress = 0
    }

    @ObservationIgnored private weak var store: VaultStore?

    init(store: VaultStore) {
        self.store = store
        follow()
    }

    /// Reads what the facts are made from, and is told once when any of it changes.
    private func follow() {
        guard let store else { return }
        withObservationTracking {
            _ = (store.index.files, store.excluded, store.places.reads)
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        refresh()
    }

    private func refresh() {
        guard let store else { return }
        let index = store.index
        let tree = store.tree
        if tree != self.tree { self.tree = tree }
        if index.files != files { files = index.files }
        let updated = store.updatedSinceRead.map { Updated(path: $0, modified: index.notes[$0]?.modified) }
        if updated != self.updated {
            self.updated = updated
            updatedPaths = Set(updated.map(\.path))
        }
        if index.tagTree != tagTree { tagTree = index.tagTree }
        if index.tags.count != tagCount { tagCount = index.tags.count }
        // Walking every task takes ~10 ms in a large vault: only when a task,
        // the hidden files, the statuses or the day may have changed.
        let excluded = store.excluded
        let basis = Basis(
            notes: index.notes, statuses: index.statuses, day: .today(),
            excluded: [excluded.prefixes, excluded.patterns.map(\.pattern), excluded.names.sorted()])
        guard self.basis.map({ !$0.sameTasks(as: basis) }) ?? true else { return }
        self.basis = basis
        let counts = Self.counts(store, day: basis.day)
        if counts != self.counts { self.counts = counts }
    }

    /// What the counts were made from.
    private struct Basis {
        var notes: [String: NoteEntry]
        var statuses: TaskStatuses
        var day: Day
        var excluded: [[String]]

        /// The same tasks in the same notes: a note whose date did not change is not read.
        func sameTasks(as other: Basis) -> Bool {
            guard statuses == other.statuses, day == other.day, excluded == other.excluded, notes.count == other.notes.count else { return false }
            for (path, note) in other.notes {
                guard let old = notes[path] else { return false }
                if old.modified != note.modified, old.parsed.tasks != note.parsed.tasks { return false }
            }
            return true
        }
    }

    @ObservationIgnored private var basis: Basis?

    /// The badges for [day], from the store.
    static func counts(_ store: VaultStore, day: Day) -> Counts {
        let groups = store.taskGroups(today: day)
        return Counts(day: day, due: groups.today.count, overdue: groups.overdue.count, inProgress: groups.inProgress.count)
    }
}
