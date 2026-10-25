import DaftarCore
import Foundation
import Observation

/// The open vault: its index, kept in step with the files, and the edits and
/// syncs the app makes to it. One per app; each window reads it.
@MainActor @Observable
final class VaultStore {
    private(set) var root: URL?
    private(set) var index = VaultIndex()
    /// The Iconic plugin's icons and colours for the tree.
    private(set) var iconic = Iconic()
    /// Obsidian's excluded files, kept out of search and the switcher.
    private(set) var excluded = ExcludedFiles()
    /// Obsidian's bookmarks, the same file both apps read and write.
    private(set) var bookmarks = Bookmarks()
    private(set) var loading = false
    /// Grows each time the index changes, so a view can follow it cheaply.
    private(set) var revision = 0
    /// Paths that changed in the last update, for a reader showing one of them.
    private(set) var lastChanged: Set<String> = []

    private(set) var syncing = false
    private(set) var lastSync: Date?
    private(set) var syncError: String?
    private(set) var isRepository = false
    /// The branch and how it stands, refreshed after each sync and file change.
    private(set) var gitStatus: Git.Status?

    /// A message the window shows once, then clears: an edit that failed.
    var notice: String?

    let search = SearchIndex()
    private var watcher: FileWatcher?
    private var pending: Set<String> = []
    private var flush: Task<Void, Never>?
    private var autoSync: Task<Void, Never>?
    private var syncSoon: Task<Void, Never>?

    let settings: AppSettings
    /// Each open editor's save, which a rename, a move or a delete waits for,
    /// so no editor writes the old file again after it is gone.
    @ObservationIgnored var flushers: [ObjectIdentifier: () async -> Void] = [:]

    init(settings: AppSettings = .shared, openVault: Bool = true) {
        self.settings = settings
        if openVault, let path = settings.vaultPath { open(URL(filePath: path)) }
    }

    var name: String { root?.lastPathComponent ?? "Daftar" }

    func open(_ url: URL) {
        let url = url.standardizedFileURL
        root = url
        // Only a new vault is written: the file may say `~/org` for this one.
        if settings.vaultPath.map({ URL(filePath: $0).standardizedFileURL.path }) != url.path { settings.vaultPath = url.path }
        iconic = Iconic.load(url)
        excluded = ExcludedFiles.load(url)
        bookmarks = Bookmarks.load(url)
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
            guard isRepository else { return }
            if settings.pullOnLaunch {
                await run { try await Git(root: url).pull() }
            }
            await refreshStatus()
            scheduleAutoSync()
        }
    }

    /// For tests: the vault indexed before this returns, with no watcher and no git.
    func openSynchronously(_ url: URL) {
        root = url.standardizedFileURL
        excluded = ExcludedFiles.load(url)
        bookmarks = Bookmarks.load(url)
        index = Vault.index(url, search: search)
        revision += 1
    }

    /// For tests: what the file watcher reports, without waiting for it.
    func noteChanged(_ path: String) {
        lastChanged = [path]
        revision += 1
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
            await refreshStatus()
        }
    }

    /// The text of a note as it is on disk now.
    func text(of path: String) -> String? {
        guard let root else { return nil }
        return try? String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    func url(of path: String) -> URL? { root?.appending(path: path) }

    // MARK: Edits

    /// Writes a note the editor holds, whole. The index and the reader follow
    /// through the file watcher, as they do for any other change.
    func write(_ text: String, to path: String) throws {
        guard let root else { return }
        try Data(text.utf8).write(to: root.appending(path: path), options: .atomic)
        changed([path])
        requestSync()
    }

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

    // MARK: Files

    /// Bookmarks the file, or takes the bookmark away.
    func toggleBookmark(_ path: String) {
        guard let root else { return }
        bookmarks.toggle(path)
        saveBookmarks(root)
    }

    private func saveBookmarks(_ root: URL) {
        do {
            try bookmarks.save(root)
        } catch {
            notice = "The bookmarks could not be saved: \(error.localizedDescription)"
        }
    }

    private func flushEditors() async {
        for flush in flushers.values { await flush() }
    }

    /// A new, empty note named [name] in [folder]; its vault path.
    func createNote(named name: String, in folder: String, text: String = "") throws -> String {
        guard let root else { throw VaultMoves.Failure.badName(name) }
        guard VaultMoves.isValidName(name) else { throw VaultMoves.Failure.badName(name) }
        let path = (folder.isEmpty ? "" : folder + "/") + VaultMoves.noteName(name)
        guard !index.files.contains(where: { Slugs.fold($0) == Slugs.fold(path) }) else { throw VaultMoves.Failure.exists(path) }
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        index.files.insert(path)
        changed([path])
        requestSync()
        return path
    }

    /// A new folder named [name] in [parent]; its vault path.
    func createFolder(named name: String, in parent: String) throws -> String {
        guard let root, VaultMoves.isValidName(name) else { throw VaultMoves.Failure.badName(name) }
        let path = (parent.isEmpty ? "" : parent + "/") + name.trimmingCharacters(in: .whitespaces)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: root.appending(path: path).path, isDirectory: &isDirectory) {
            throw VaultMoves.Failure.exists(path)
        }
        try FileManager.default.createDirectory(at: root.appending(path: path), withIntermediateDirectories: true)
        return path
    }

    /// Renames or moves a file or a folder, and every link to what moved.
    /// Returns where each file went.
    func move(_ from: String, to: String) async throws -> [String: String] {
        guard let root else { return [:] }
        await flushEditors()
        let moves = try VaultMoves.plan(from, to: to, files: index.files)
        let touched = try VaultMoves.perform(from, to: to, index: index, root: root)
        // The tree follows at once; the file watcher reads the notes again.
        for (old, new) in moves {
            search.remove(path: old)
            index.files.remove(old)
            index.files.insert(new)
            if var note = index.notes.removeValue(forKey: old) {
                note.path = new
                index.notes[new] = note
            }
        }
        index.derive()
        revision += 1
        changed(touched)
        requestSync()
        if bookmarks.follow(moves, folder: index.files.contains(to) ? nil : (from, to)) { saveBookmarks(root) }
        let count = moves.count
        notice = count > 1 ? "Moved \(count) files; the links to them follow." : nil
        return moves
    }

    /// Moves a file or a folder to the Trash, where it can be taken back.
    func delete(_ path: String) async throws {
        guard let root else { return }
        await flushEditors()
        try FileManager.default.trashItem(at: root.appending(path: path), resultingItemURL: nil)
        let before = bookmarks.entries
        bookmarks.remove(path)
        if bookmarks.entries != before { saveBookmarks(root) }
        let base = path + "/"
        for gone in index.files.filter({ $0 == path || $0.hasPrefix(base) }) {
            search.remove(path: gone)
            index.files.remove(gone)
            index.notes[gone] = nil
        }
        index.derive()
        revision += 1
        changed([path])
        requestSync()
    }

    /// Writes the task on [line] of [path] from [fields]. False when the
    /// line no longer holds the task the form was opened on.
    func editTask(path: String, line: Int, before: TaskFields, fields: TaskFields) -> Bool {
        guard let root else { return false }
        do {
            try VaultEdits.apply(path, in: root) { text in
                try VaultEdits.editTask(in: text, line: line, before: before, fields: fields)
            }
            changed([path])
            requestSync()
            return true
        } catch {
            changed([path])
            return false
        }
    }

    // MARK: Git

    /// Commit, pull and push now.
    func sync() async {
        guard let root else { return }
        await run { try await Git(root: root).sync(message: Git.message()) }
    }

    /// Pull only: nothing is committed or pushed.
    func pull() async {
        guard let root else { return }
        await run { try await Git(root: root).pull() }
    }

    private func run(_ work: () async throws -> Void) async {
        guard isRepository, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            try await work()
            lastSync = Date()
            syncError = nil
        } catch {
            syncError = String(describing: error)
        }
        await refreshStatus()
    }

    func refreshStatus() async {
        guard let root, isRepository else { return }
        gitStatus = try? await Git(root: root).status()
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

    /// Notes and bases whose name holds [query], best first: a prefix before
    /// a word start before anywhere, then the shorter path.
    func quickOpen(_ query: String, recent: [String], limit: Int = 50) -> [String] {
        let notes = (Array(index.notes.keys) + index.files.filter(Base.isBase)).filter { !excluded.contains($0) }
        let needle = Slugs.fold(query.trimmingCharacters(in: .whitespaces))
        if needle.isEmpty {
            let recents = recent.filter { index.files.contains($0) }
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
