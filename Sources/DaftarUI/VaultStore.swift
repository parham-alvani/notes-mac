import DaftarCore
import Foundation
import Observation

/// The open vault: its index, kept in step with the files, and the edits and
/// syncs the app makes to it. One per app; each window reads it.
@MainActor @Observable
final class VaultStore {
    private(set) var root: URL?
    private(set) var index = VaultIndex() { didSet { indexGeneration += 1 } }
    /// Grows with every change to the index, so a slow update can tell that
    /// the index moved on while it read the files.
    @ObservationIgnored private var indexGeneration = 0
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
    /// Each window and editor that shows a note, told when a file moves or
    /// goes, so none of them writes the old path again.
    @ObservationIgnored var followers: [ObjectIdentifier: (VaultChange) -> Void] = [:]

    init(settings: AppSettings = .shared, openVault: Bool = true) {
        self.settings = settings
        if openVault, let path = settings.vaultPath { open(URL(filePath: path)) }
    }

    var name: String { root?.lastPathComponent ?? "Daftar" }

    /// Opens the vault at [url]. What the editors hold is saved first, to
    /// the vault it belongs to.
    func open(_ url: URL) {
        guard root != nil, !flushers.isEmpty else { return switchTo(url) }
        Task {
            await flushEditors()
            switchTo(url)
        }
    }

    private func switchTo(_ url: URL) {
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
        let previous = flush
        previous?.cancel()
        flush = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let root else { return }
            // A batch already past its wait finishes first: two at once
            // would each start from the same index and drop the other's work.
            await previous?.value
            guard self.root == root else { return }
            let changed = pending
            pending = []
            let search = self.search
            var updated: VaultIndex
            var start: Int
            repeat {
                // A move or a delete changes the index while the files are
                // read: read them again on top of what it made.
                let base = index
                start = indexGeneration
                updated = await Task.detached { Vault.update(base, changed: changed, in: root, search: search) }.value
            } while start != indexGeneration && self.root == root
            guard self.root == root else { return }
            index = updated
            lastChanged = changed
            revision += 1
            await refreshStatus()
        }
    }

    /// The text of a note as it is on disk now.
    func text(of path: String) -> String? {
        guard let file = url(of: path) else { return nil }
        return try? String(contentsOf: file, encoding: .utf8)
    }

    /// The file a vault path names, or nil when the path leaves the vault.
    /// Paths come from notes, links and the reader page, so each one is checked.
    func url(of path: String) -> URL? { root.flatMap { Self.file(path, in: $0) } }

    /// [path] inside [root], or nil for an absolute path, a `.` or `..`
    /// part, or a symlink that points out of the vault.
    nonisolated static func file(_ path: String, in root: URL) -> URL? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let file = base.appending(path: path)
        // A file that is not there yet: its nearest folder that is.
        var existing = file
        while !FileManager.default.fileExists(atPath: existing.path), existing.path.count > base.path.count {
            existing = existing.deletingLastPathComponent()
        }
        let resolved = existing.resolvingSymlinksInPath().path
        guard resolved == base.path || resolved.hasPrefix(base.path + "/") else { return nil }
        let target = file.resolvingSymlinksInPath().path
        return target.hasPrefix(base.path + "/") ? file : nil
    }

    // MARK: Edits

    /// Writes a note the editor holds, whole. The index and the reader follow
    /// through the file watcher, as they do for any other change.
    func write(_ text: String, to path: String) throws {
        // A note that moved or went is not written again at its old path.
        guard let file = url(of: path), index.files.contains(path) else { throw StoreError.gone(path) }
        try Data(text.utf8).write(to: file, options: .atomic)
        changed([path])
        requestSync()
    }

    /// Ticks or opens the task on [line] of [path]. The file is read again
    /// first, and the edit is refused when that line is no longer the task
    /// that was clicked.
    func toggleTask(path: String, line: Int, status: Character) {
        guard let root, url(of: path) != nil, index.files.contains(path) else { return }
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

    /// Iconic's file in the vault, which Obsidian and the phone read too.
    private func iconicFile(_ root: URL) -> URL { root.appending(path: ".obsidian/plugins/iconic/data.json") }

    /// Gives [path] an icon -- a Lucide name or an emoji -- and a colour, in
    /// Iconic's own file; with both nil, takes them away.
    func setIcon(_ path: String, icon: String?, color: String?) {
        guard let root else { return }
        let file = iconicFile(root)
        do {
            let data = try Iconic.setting(path, icon: icon, color: color, in: try? Data(contentsOf: file))
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            iconic = Iconic.parse(data)
            revision += 1
            requestSync()
        } catch {
            notice = "The icon could not be saved: Iconic's file could not be read."
        }
    }

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

    /// Everything the editors hold is on disk when this returns.
    func flushEditors() async {
        for flush in flushers.values { await flush() }
    }

    private func tell(_ change: VaultChange) {
        for follow in followers.values { follow(change) }
    }

    /// A new, empty note named [name] in [folder]; its vault path.
    func createNote(named name: String, in folder: String, text: String = "") throws -> String {
        guard let root else { throw VaultMoves.Failure.badName(name) }
        guard VaultMoves.isValidName(name) else { throw VaultMoves.Failure.badName(name) }
        let path = (folder.isEmpty ? "" : folder + "/") + VaultMoves.noteName(name)
        guard !index.files.contains(where: { Slugs.fold($0) == Slugs.fold(path) }) else { throw VaultMoves.Failure.exists(path) }
        // `[[../../x]]` in a note names a file outside the vault.
        guard let url = Self.file(path, in: root) else { throw StoreError.outside(path) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        index.files.insert(path)
        changed([path])
        requestSync()
        return path
    }

    /// The note a link to nothing names, made empty: `[[Folder/Name]]` in
    /// that folder, a bare `[[Name]]` next to the note with the link.
    func createNote(forLink target: String, from source: String) throws -> String {
        let clean = Wikilink(target).target.trimmingCharacters(in: .whitespaces)
        let parts = clean.split(separator: "/").map(String.init)
        guard let last = parts.last else { throw VaultMoves.Failure.badName(target) }
        let name = Vault.isNote(last) ? String(last.dropLast(3)) : last
        let folder = parts.count > 1 ? parts.dropLast().joined(separator: "/") : source.split(separator: "/").dropLast().joined(separator: "/")
        return try createNote(named: name, in: folder)
    }

    /// A new folder named [name] in [parent]; its vault path.
    func createFolder(named name: String, in parent: String) throws -> String {
        guard let root, VaultMoves.isValidName(name) else { throw VaultMoves.Failure.badName(name) }
        let path = (parent.isEmpty ? "" : parent + "/") + name.trimmingCharacters(in: .whitespaces)
        guard let url = Self.file(path, in: root) else { throw StoreError.outside(path) }
        if FileManager.default.fileExists(atPath: url.path) { throw VaultMoves.Failure.exists(path) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // It shows in the tree at once, empty as it is.
        index.emptyFolders.insert(path)
        index.derive()
        revision += 1
        return path
    }

    /// Renames or moves a file or a folder, and every link to what moved.
    /// Returns where each file went.
    func move(_ from: String, to: String) async throws -> [String: String] {
        guard let root else { return [:] }
        guard Self.file(from, in: root) != nil, Self.file(to, in: root) != nil else { throw StoreError.outside(to) }
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
        for folder in index.emptyFolders where folder == from || folder.hasPrefix(from + "/") {
            index.emptyFolders.remove(folder)
            index.emptyFolders.insert(to + folder.dropFirst(from.count))
        }
        index.derive()
        revision += 1
        // Every window and editor follows now, before anyone types again.
        tell(.moved(moves, touched: Set(touched)))
        changed(touched)
        requestSync()
        if bookmarks.follow(moves, folder: index.files.contains(to) ? nil : (from, to)) { saveBookmarks(root) }
        // The icons follow too, as Iconic makes them follow in Obsidian.
        if let data = try? Data(contentsOf: iconicFile(root)),
            let moved = try? Iconic.moving(moves, folder: index.files.contains(to) ? nil : (from, to), in: data)
        {
            try? moved.write(to: iconicFile(root), options: .atomic)
            iconic = Iconic.parse(moved)
        }
        let count = moves.count
        notice = count > 1 ? "Moved \(count) files; the links to them follow." : nil
        return moves
    }

    /// Moves a file or a folder to the Trash, where it can be taken back.
    func delete(_ path: String) async throws {
        guard let root, let file = Self.file(path, in: root) else { return }
        await flushEditors()
        try FileManager.default.trashItem(at: file, resultingItemURL: nil)
        let before = bookmarks.entries
        bookmarks.remove(path)
        if bookmarks.entries != before { saveBookmarks(root) }
        let base = path + "/"
        for gone in index.files.filter({ $0 == path || $0.hasPrefix(base) }) {
            search.remove(path: gone)
            index.files.remove(gone)
            index.notes[gone] = nil
        }
        index.emptyFolders = index.emptyFolders.filter { $0 != path && !$0.hasPrefix(base) }
        index.derive()
        revision += 1
        tell(.deleted(path))
        changed([path])
        requestSync()
    }

    /// Moves [task] to a board column. False when its line no longer holds
    /// the task the card showed.
    func moveTask(_ task: VaultTask, to drop: TaskBoard.Drop) -> Bool {
        guard let root, url(of: task.path) != nil, index.files.contains(task.path) else { return false }
        do {
            try VaultEdits.apply(task.path, in: root) { text in
                try VaultEdits.moveTask(in: text, line: task.task.line, task: task.task, to: drop, today: .today())
            }
            changed([task.path])
            requestSync()
            return true
        } catch {
            notice = "\(TaskRow.plain(task.task.text)) changed in its note before the drop. Nothing was written."
            changed([task.path])
            return false
        }
    }

    /// Writes the task on [line] of [path] from [fields]. False when the
    /// line no longer holds the task the form was opened on.
    func editTask(path: String, line: Int, before: TaskFields, fields: TaskFields) -> Bool {
        guard let root, url(of: path) != nil, index.files.contains(path) else { return false }
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

    /// Notes and bases for the switcher, best first (`QuickSwitcher`):
    /// every word, in any order, in the name, an alias or the folders.
    func quickOpen(_ query: String, recent: [String], limit: Int = 50) -> [String] {
        let present = recent.filter { index.files.contains($0) }
        return QuickSwitcher.rank(query, in: quickOpenCandidates(), recent: present, limit: limit)
    }

    /// The notes and bases the switcher can offer, folded once for each
    /// version of the index rather than on every keystroke.
    @ObservationIgnored private var candidates: (revision: Int, files: Int, items: [QuickSwitcher.Candidate])?

    private func quickOpenCandidates() -> [QuickSwitcher.Candidate] {
        if let candidates, candidates.revision == revision, candidates.files == index.files.count { return candidates.items }
        let paths = (Array(index.notes.keys) + index.files.filter(Base.isBase)).filter { !excluded.contains($0) }
        let items = paths.map { path in
            QuickSwitcher.Candidate(path: path, title: Vault.title(of: path), aliases: index.notes[path]?.parsed.aliases ?? [])
        }
        candidates = (revision, index.files.count, items)
        return items
    }

}

/// A file command's effect, for the windows and editors that show the files.
enum VaultChange {
    /// Where each file went, and the notes whose links were rewritten.
    case moved([String: String], touched: Set<String>)
    /// A file or a folder went to the Trash.
    case deleted(String)
}

/// Why the store did not touch a file.
enum StoreError: LocalizedError {
    case gone(String)
    case outside(String)

    var errorDescription: String? {
        switch self {
        case .gone(let path): "“\(path)” is no longer in the vault"
        case .outside(let path): "“\(path)” is outside the vault"
        }
    }
}
