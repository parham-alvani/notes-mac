import DaftarCore
import Foundation
import Observation

/// The open vault: its index, kept in step with the files, and the edits and
/// syncs the app makes to it. One per app; each window reads it.
@MainActor @Observable
final class VaultStore {
    private(set) var root: URL?
    private(set) var index = VaultIndex()
    private(set) var loading = false
    /// Grows each time the index changes, so a view can follow it cheaply.
    private(set) var revision = 0
    /// Paths that changed in the last update, for a reader showing one of them.
    private(set) var lastChanged: Set<String> = []

    private(set) var syncing = false
    private(set) var lastSync: Date?
    private(set) var syncError: String?
    private(set) var isRepository = false

    /// A message the window shows once, then clears: an edit that failed.
    var notice: String?

    let search = SearchIndex()
    private var watcher: FileWatcher?
    private var pending: Set<String> = []
    private var flush: Task<Void, Never>?
    private var autoSync: Task<Void, Never>?
    private var syncSoon: Task<Void, Never>?

    var settings = AppSettings.shared

    init() {
        if let path = settings.vaultPath { open(URL(filePath: path)) }
    }

    var name: String { root?.lastPathComponent ?? "Daftar" }

    func open(_ url: URL) {
        let url = url.standardizedFileURL
        root = url
        settings.vaultPath = url.path
        loading = true
        watcher = FileWatcher(root: url) { [weak self] paths in
            Task { @MainActor in self?.changed(paths) }
        }
        let search = self.search
        Task.detached(priority: .userInitiated) {
            let index = Vault.index(url, search: search)
            await MainActor.run {
                guard self.root == url else { return }
                self.index = index
                self.loading = false
                self.revision += 1
                self.lastChanged = []
            }
        }
        Task {
            isRepository = await Git(root: url).isRepository()
            scheduleAutoSync()
        }
    }

    /// File events arrive in bursts -- a pull touches many files at once --
    /// so they are gathered for a moment and applied together.
    private func changed(_ paths: Set<String>) {
        pending.formUnion(paths)
        flush?.cancel()
        flush = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let root else { return }
            let changed = pending
            pending = []
            let base = index
            let search = self.search
            let updated = await Task.detached { Vault.update(base, changed: changed, in: root, search: search) }.value
            index = updated
            lastChanged = changed
            revision += 1
        }
    }

    /// The text of a note as it is on disk now.
    func text(of path: String) -> String? {
        guard let root else { return nil }
        return try? String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    func url(of path: String) -> URL? { root?.appending(path: path) }

    // MARK: Edits

    /// Ticks or opens the task on [line] of [path]. The file is read again
    /// first, and the edit is refused when that line is no longer the task
    /// that was clicked.
    func toggleTask(path: String, line: Int, status: Character) {
        guard let root else { return }
        do {
            try VaultEdits.apply(path, in: root) { text in
                try VaultEdits.toggleTask(in: text, line: line, status: status, today: .today())
            }
            changed([path])
            requestSync()
        } catch VaultEdits.Failure.taskMoved {
            notice = "The note changed before the click. Nothing was written; the note is shown again."
            changed([path])
        } catch {
            notice = "The task could not be written: \(error.localizedDescription)"
        }
    }

    // MARK: Git

    /// Commit, pull and push now.
    func sync() async {
        guard let root, isRepository, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            try await Git(root: root).sync(message: Git.message())
            lastSync = Date()
            syncError = nil
        } catch {
            syncError = String(describing: error)
        }
    }

    /// After an edit: a sync a little later, when automatic sync is on, so
    /// that several ticks in a row make one commit.
    private func requestSync() {
        guard settings.syncInterval > 0 else { return }
        syncSoon?.cancel()
        syncSoon = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    func scheduleAutoSync() {
        autoSync?.cancel()
        let minutes = settings.syncInterval
        guard minutes > 0, isRepository else { return }
        autoSync = Task {
            while !Task.isCancelled {
                await sync()
                try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            }
        }
    }

    // MARK: Questions the views ask

    /// Week notes of the calendar, read from the index's copy of the files.
    func calendarDays(from start: Day, count: Int) -> [CalendarDay] {
        var paths: [String] = []
        for offset in stride(from: 0, to: count, by: 1) {
            let path = CalendarWeek.path(for: start.adding(days: offset))
            if !paths.contains(path) { paths.append(path) }
        }
        let end = start.adding(days: count)
        return paths.flatMap { path -> [CalendarDay] in
            guard index.files.contains(path), let text = text(of: path) else { return [] }
            return CalendarWeek.parse(text, path: path)
        }.filter { $0.day >= start && $0.day < end }
    }

    struct TaskGroups {
        var overdue: [VaultTask] = []
        var today: [VaultTask] = []
        var upcoming: [VaultTask] = []
        var inProgress: [VaultTask] = []
    }

    /// Open tasks by the day they belong to: due, else scheduled.
    func taskGroups(today: Day = .today(), days: Int = 7) -> TaskGroups {
        var groups = TaskGroups()
        let horizon = today.adding(days: days)
        for task in index.tasks where task.task.isOpen {
            guard let text = task.task.day, let day = Day(text) else {
                if task.task.status == "/" { groups.inProgress.append(task) }
                continue
            }
            if day < today { groups.overdue.append(task) }
            else if day == today { groups.today.append(task) }
            else if day <= horizon { groups.upcoming.append(task) }
        }
        let order: (VaultTask, VaultTask) -> Bool = {
            ($0.task.day ?? "", $0.path, $0.task.line) < ($1.task.day ?? "", $1.path, $1.task.line)
        }
        groups.overdue.sort(by: order)
        groups.today.sort(by: order)
        groups.upcoming.sort(by: order)
        groups.inProgress.sort(by: order)
        return groups
    }

    /// Notes whose name holds [query], best first: a prefix before a word
    /// start before anywhere, then the shorter path.
    func quickOpen(_ query: String, recent: [String], limit: Int = 50) -> [String] {
        let notes = index.notes.keys
        let needle = Slugs.fold(query.trimmingCharacters(in: .whitespaces))
        if needle.isEmpty {
            let recents = recent.filter { index.notes[$0] != nil }
            return Array(recents.prefix(limit))
        }
        var scored: [(path: String, score: Int)] = []
        for path in notes {
            let title = Slugs.fold(Vault.title(of: path))
            let folded = Slugs.fold(path)
            var score: Int?
            if title == needle { score = 0 }
            else if title.hasPrefix(needle) { score = 1 }
            else if title.contains(" " + needle) || title.contains("-" + needle) { score = 2 }
            else if title.contains(needle) { score = 3 }
            else if folded.contains(needle) { score = 4 }
            else if Self.subsequence(needle, of: title) { score = 5 }
            if var score {
                if recent.contains(path) { score -= 1 }
                scored.append((path, score))
            }
        }
        scored.sort { ($0.score, $0.path.count, $0.path) < ($1.score, $1.path.count, $1.path) }
        return scored.prefix(limit).map(\.path)
    }

    private static func subsequence(_ needle: String, of text: String) -> Bool {
        var rest = needle[...]
        for ch in text where ch == rest.first {
            rest = rest.dropFirst()
            if rest.isEmpty { return true }
        }
        return rest.isEmpty
    }
}
