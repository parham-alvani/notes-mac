import DaftarCore
import Foundation
import Observation

/// The open vault: its index, kept in step with the files, and the edits and
/// syncs the app makes to it. One per app; each window reads it.
@MainActor @Observable
final class VaultStore {
    private(set) var root: URL?
    private(set) var index = VaultIndex() {
        didSet {
            indexGeneration += 1
            // The rules given only a symbol (a tick, `isOpen`) follow the open vault's statuses.
            if index.statuses != oldValue.statuses { TaskStatuses.current = index.statuses }
        }
    }
    /// Grows with every change to the index, so a slow update can tell that
    /// the index moved on while it read the files.
    @ObservationIgnored private var indexGeneration = 0
    /// The Iconic plugin's icons and colours for the tree.
    private(set) var iconic = Iconic()
    /// Obsidian's excluded files and the files for AI agents (`files.hidden`):
    /// what the lists leave out, always, as Spotlight does.
    private(set) var hidden = ExcludedFiles()
    /// What the tree, search, the switcher and the graph leave out now:
    /// [hidden], or nothing while Show Hidden Files is on.
    private(set) var excluded = ExcludedFiles()
    /// Obsidian's bookmarks, the same file both apps read and write.
    private(set) var bookmarks = Bookmarks()
    /// The Daily notes plugin's series, which may be of weeks or months.
    private(set) var periodic = PeriodicNotes(DailyNotes())
    /// The Templates plugin's folder and formats.
    private(set) var templates = Templates()
    /// The Beautitab plugin's settings, for the home page.
    private(set) var beautitab = Beautitab()
    /// The drill cards and their reviews, read off the main thread (`DrillDeck`).
    let drill = DrillDeck()
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
    /// A pull's rebase stopped on a conflict and is still open, or the
    /// changes a pull kept aside did not fit ([unstashing]). No sync runs
    /// until the person resolves it or aborts it.
    private(set) var rebasing = false
    /// The stop is not a rebase: the pull is done, and the changes not yet
    /// committed left conflict marks. There is nothing to abort.
    private(set) var unstashing = false
    /// The files the open rebase stopped on.
    private(set) var conflicts: [Git.Conflicted] = []
    /// Grows each time a sync finds the rebase open, so the window in front
    /// shows the conflicts.
    private(set) var conflictStops = 0

    /// A message the window shows once, then clears: an edit that failed.
    var notice: String?

    /// The open vault's full-text search, made anew for each vault opened:
    /// an index still being built for the one before fills its own, which
    /// nothing reads.
    @ObservationIgnored private(set) var search = SearchIndex()
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
    /// Where each note was being read, for every window.
    @ObservationIgnored let places = PlaceBook()
    /// The audit's findings, its fixes, and format on save (`daftar-cli`).
    let checks = VaultChecks()
    /// What the sidebar's list shows, set only when it changes.
    @ObservationIgnored private(set) lazy var sidebar = SidebarFacts(store: self)

    init(settings: AppSettings = .shared, openVault: Bool = true) {
        self.settings = settings
        checks.store = self
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
        loadHidden(url)
        bookmarks = Bookmarks.load(url)
        periodic = PeriodicNotes(DailyNotes.read(root: url))
        templates = Templates.read(root: url)
        beautitab = Beautitab.read(root: url)
        places.load(root: url, directory: settings.stateDirectory)
        loading = true
        watcher = FileWatcher(root: url) { [weak self] paths in
            Task { @MainActor in self?.changed(paths) }
        } rescan: { [weak self] in
            Task { @MainActor in self?.rescan() }
        }
        search = SearchIndex()
        let search = self.search
        Task.detached(priority: .userInitiated) {
            let index = Vault.index(url, search: search)
            await MainActor.run {
                guard self.root == url else { return }
                self.index = index
                self.loading = false
                self.revision += 1
                self.lastChanged = []
                self.prewarmCandidates()
                self.checks.opened(url)
            }
        }
        Task {
            isRepository = await Git(root: url).isRepository()
            guard isRepository else { return }
            // A rebase left open, by Daftar or in a terminal, is shown, not pulled over.
            if (try? await Git(root: url).openStop()) != nil {
                await refreshConflicts(show: true)
            } else if settings.pullOnLaunch {
                await run { try await Git(root: url).pull() }
            }
            await refreshStatus()
            scheduleAutoSync()
        }
    }

    private func loadHidden(_ url: URL) {
        hiddenRevision += 1
        hidden = ExcludedFiles.load(url, names: settings.hiddenNames)
        excluded = settings.showHidden ? ExcludedFiles() : hidden
    }

    /// Reads the excluded and hidden files again, after `files.hidden` or
    /// `files.show_hidden` changed; every list follows the new revision.
    func refreshHidden() {
        guard let root else { return }
        loadHidden(root)
        revision += 1
    }

    /// The file tree, without the excluded files, made again only when the
    /// files or what is excluded changed.
    var tree: [TreeNode] {
        if excluded.isEmpty { return index.tree }
        if let treed, treed.files == index.files, treed.empty == index.emptyFolders, treed.revision == hiddenRevision { return treed.tree }
        let tree = excluded.tree(of: index.files, emptyFolders: index.emptyFolders)
        treed = (index.files, index.emptyFolders, hiddenRevision, tree)
        return tree
    }

    @ObservationIgnored private var treed: (files: Set<String>, empty: Set<String>, revision: Int, tree: [TreeNode])?
    @ObservationIgnored private var hiddenRevision = 0

    /// The logo of the folder at [path] (`Vault.logo`), kept until the files
    /// change: each look reads every file's name, and the breadcrumb asks
    /// for each of its folders at every drawing.
    func logo(of folder: String) -> String? {
        if logos.files != index.files { logos = (index.files, [:]) }
        if let known = logos.found[folder] { return known }
        let found = Vault.logo(of: folder, in: index.files)
        logos.found[folder] = .some(found)
        return found
    }

    @ObservationIgnored private var logos: (files: Set<String>, found: [String: String?]) = ([], [:])

    /// The folder at [path] in the shown tree; "" is the vault itself.
    func folder(_ path: String) -> [TreeNode]? { Vault.folder(path, in: tree) }

    /// For tests: the vault indexed before this returns, with no watcher and no git.
    func openSynchronously(_ url: URL) {
        root = url.standardizedFileURL
        loadHidden(url)
        bookmarks = Bookmarks.load(url)
        periodic = PeriodicNotes(DailyNotes.read(root: url))
        templates = Templates.read(root: url)
        beautitab = Beautitab.read(root: url)
        places.load(root: url, directory: settings.stateDirectory)
        search = SearchIndex()
        index = Vault.index(url, search: search)
        isRepository = FileManager.default.fileExists(atPath: url.appending(path: ".git").path)
        revision += 1
    }

    /// Reads the Beautitab settings again: the home page asks each time it
    /// shows, so an edit in Obsidian shows without a restart.
    func refreshBeautitab() {
        guard let root else { return }
        let read = Beautitab.read(root: root)
        if read != beautitab { beautitab = read }
    }

    /// For tests: what the file watcher reports, without waiting for it.
    func noteChanged(_ path: String) {
        lastChanged = [path]
        revision += 1
    }

    /// The files of `.obsidian` the store keeps a copy of, read again when
    /// one of [paths] is theirs: a pull or Obsidian wrote it. Without this
    /// a new daily-notes folder, an icon or a bookmark from the phone
    /// showed only after the app was opened again.
    private func readSettings(_ paths: Set<String>, in root: URL) {
        if paths.contains(FileWatcher.iconic) { iconic = Iconic.load(root) }
        if paths.contains(FileWatcher.bookmarks) { readBookmarks(root) }
        if paths.contains(FileWatcher.dailyNotes) { periodic = PeriodicNotes(DailyNotes.read(root: root)) }
        if paths.contains(FileWatcher.templates) { templates = Templates.read(root: root) }
        if paths.contains(FileWatcher.app) { loadHidden(root) }
        revision += 1
    }

    /// The whole vault read again, as at launch: the system lost file
    /// events (a very large pull, a queue that overflowed), so which files
    /// changed is not known. One at a time; a second request while one
    /// runs makes it run once more.
    func rescan() {
        guard let root, !loading else { return }
        if rescanning { return rescanAgain = true }
        rescanning = true
        readSettings(FileWatcher.settings, in: root)
        let search = SearchIndex()
        Task {
            let index = await Task.detached(priority: .utility) { Vault.index(root, search: search) }.value
            rescanning = false
            guard self.root == root else { return }
            self.search = search
            self.index = index
            // Every editor and reader looks at its file again.
            lastChanged = index.files
            Logo.shared.forget(index.files)
            revision += 1
            prewarmCandidates()
            checks.changed()
            await refreshStatus()
            if rescanAgain {
                rescanAgain = false
                rescan()
            }
        }
    }

    @ObservationIgnored private(set) var rescanning = false
    @ObservationIgnored private var rescanAgain = false

    /// File events arrive in bursts -- a pull touches many files at once --
    /// so they are gathered for a moment and applied together.
    func changed(_ paths: Set<String>) {
        if let root, !paths.isDisjoint(with: FileWatcher.settings) {
            readSettings(paths, in: root)
            if paths.isSubset(of: FileWatcher.settings) { return }
        }
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
            Logo.shared.forget(changed)
            revision += 1
            prewarmCandidates()
            checks.changed()
            await refreshStatus()
        }
    }

    /// The text of a note as it is on disk now.
    func text(of path: String) -> String? {
        guard let file = url(of: path) else { return nil }
        return try? String(contentsOf: file, encoding: .utf8)
    }

    /// Whether [path] can be read as UTF-8 text; a file that is not there
    /// yet can. An editor opens only such a file, and `write` writes over
    /// only such a file: a note in another encoding read as "" would open
    /// empty and be replaced by the first key typed. Asked at each drawing
    /// of a pane, so the answer is kept until the file's date or size changes.
    func isText(_ path: String) -> Bool {
        guard let file = url(of: path) else { return false }
        guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return true }
        let date = values.contentModificationDate, size = values.fileSize
        if let known = textual[path], known.date == date, known.size == size { return known.text }
        guard let data = try? Data(contentsOf: file) else { return true }
        let text = String(data: data, encoding: .utf8) != nil
        textual[path] = (date, size, text)
        return text
    }

    @ObservationIgnored private var textual: [String: (date: Date?, size: Int?, text: Bool)] = [:]

    /// The file a vault path names, or nil when the path leaves the vault.
    /// Paths come from notes, links and the reader page, so each one is checked.
    func url(of path: String) -> URL? { root.flatMap { Self.file(path, in: $0) } }

    /// The vault path of a file URL inside the vault, or nil.
    func vaultPath(of url: URL) -> String? {
        guard let root else { return nil }
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(base) else { return nil }
        return Slugs.normalize(String(path.dropFirst(base.count)))
    }

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
        // A file the app could not read was never shown: what would be
        // written is not an edit of it.
        guard isText(path) else { throw StoreError.notText(path) }
        try Data(text.utf8).write(to: file, options: .atomic)
        textual[path] = nil
        places.markRead(path)
        WakaTime.shared.heartbeat(path, store: self, write: true)
        changed([path])
        requestSync()
    }

    /// The gate of every edit the app makes to a note outside an editor:
    /// [work] runs once all that the editors hold is on disk, so it reads
    /// what the person typed, and no editor saves its older text over the
    /// edit afterwards. With no editor open it runs at once and its answer
    /// is returned. With one open, saving waits for Neovim, so the work
    /// runs after it and the answer here is true; [otherwise] then says
    /// what a false answer would have said.
    @discardableResult
    private func afterEditors(_ work: @escaping () -> Bool, otherwise: (() -> Void)? = nil) -> Bool {
        guard !flushers.isEmpty else { return work() }
        Task {
            await flushEditors()
            if !work() { otherwise?() }
        }
        return true
    }

    /// An edit of the app's own, read from the file and written back. The
    /// app's own change does not make the note "updated since you read".
    private func ownEdit(_ path: String, in root: URL, _ change: (String) throws -> String) throws {
        try VaultEdits.apply(path, in: root, change)
        places.markRead(path)
    }

    /// The notes read before that changed on disk since, by a pull or
    /// another app: newest first.
    var updatedSinceRead: [String] {
        index.notes.values
            .filter { note in places.lastRead(note.path).map { note.modified.timeIntervalSince($0) > 2 } ?? false }
            .filter { !excluded.contains($0.path) }
            .sorted { $0.modified > $1.modified }
            .map(\.path)
    }

    func isUpdatedSinceRead(_ path: String) -> Bool {
        guard let read = places.lastRead(path), let note = index.notes[path] else { return false }
        return note.modified.timeIntervalSince(read) > 2
    }

    /// Ticks or opens the task on [line] of [path]. The file is read again
    /// first, and the edit is refused when that line is no longer the task
    /// that was clicked: its status, and the text the index read, which the
    /// view was drawn from.
    func toggleTask(path: String, line: Int, status: Character) {
        // What the view showed, read before the editors save.
        let expected = index.notes[path]?.parsed.tasks.first { $0.line == line }?.text
        afterEditors { self.toggleTaskNow(path: path, line: line, status: status, expected: expected) }
    }

    private func toggleTaskNow(path: String, line: Int, status: Character, expected: String?) -> Bool {
        guard let root, url(of: path) != nil, index.files.contains(path) else { return false }
        let statuses = index.statuses
        do {
            try ownEdit(path, in: root) { text in
                try VaultEdits.toggleTask(in: text, line: line, status: status, expected: expected, today: .today(), statuses: statuses)
            }
            changed([path])
            requestSync()
            return true
        } catch VaultEdits.Failure.taskMoved {
            notice = "The note changed before the click. Nothing was written; the note is shown again."
            changed([path])
        } catch {
            notice = "The task could not be written: \(error.localizedDescription)"
        }
        return false
    }

    // MARK: Unlinked mentions

    /// Where other notes write [path]'s name or an alias without linking to
    /// it. The notes that link to it already are left out, as in Obsidian.
    func unlinkedMentions(of path: String) async -> [MentionHit] {
        guard let root, let note = index.notes[path] else { return [] }
        let names = [Vault.title(of: path)] + note.parsed.aliases
        let linking = Set((index.backlinks[path] ?? []).map(\.source))
        let search = search, excluded = excluded
        return await Task.detached(priority: .userInitiated) {
            // The full-text searches too: each runs SQLite, after every save of the note.
            var sources = Set<String>()
            for name in names where name.count >= UnlinkedMentions.shortest {
                for hit in search.search("\"\(name)\"", limit: 300) { sources.insert(hit.path) }
            }
            let candidates = sources.filter { $0 != path && !linking.contains($0) && Vault.isNote($0) && !excluded.contains($0) }.sorted()
            var out: [MentionHit] = []
            for source in candidates {
                guard let text = try? String(contentsOf: root.appending(path: source), encoding: .utf8) else { continue }
                // A few from each note, so that one note that names it all
                // the time does not fill the list.
                out += UnlinkedMentions.find(names, in: text).prefix(5).map { MentionHit(source: source, mention: $0) }
                if out.count >= 300 { break }
            }
            return out
        }.value
    }

    /// The mention in [source] made a link to [target], with the shortest
    /// name that still finds it.
    func link(_ mention: UnlinkedMentions.Mention, in source: String, to target: String) {
        afterEditors { self.linkNow(mention, in: source, to: target) }
    }

    private func linkNow(_ mention: UnlinkedMentions.Mention, in source: String, to target: String) -> Bool {
        guard let root, url(of: source) != nil else { return false }
        let title = Vault.title(of: target)
        let name = index.resolve(title, from: source) == target ? title : String(target.dropLast(3))
        do {
            try ownEdit(source, in: root) { try UnlinkedMentions.link(mention, to: name, in: $0) }
            changed([source])
            requestSync()
            return true
        } catch VaultEdits.Failure.textMoved {
            notice = "The note changed before the click. Nothing was written; the list is made again."
            changed([source])
        } catch {
            notice = "The link could not be written: \(error.localizedDescription)"
        }
        return false
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
        readBookmarks(root)
        bookmarks.toggle(path)
        saveBookmarks(root)
    }

    /// The file as it is now, before a change to it: a pull or Obsidian
    /// may have written it since it was read, and what the store remembers
    /// would write their bookmarks away.
    private func readBookmarks(_ root: URL) {
        let read = Bookmarks.load(root)
        if read != bookmarks { bookmarks = read }
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
        places.follow(change)
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

    /// The template notes of the vault, for New Note.
    var templateNotes: [String] { templates.templates(in: index.files) }

    /// [template]'s text filled for a note named [name], made now.
    func filled(template: String, name: String) -> String {
        guard let text = text(of: template) else { return "" }
        return templates.fill(text, title: name, day: .today(), clock: .now())
    }

    /// The periodic note of the period [day] falls in, made from the Daily
    /// notes plugin's template when it is not there yet; its vault path.
    func periodicNote(for day: Day = .today()) throws -> String {
        let path = periodic.path(for: day)
        if index.files.contains(path) { return path }
        let parts = path.split(separator: "/").map(String.init)
        let name = String(parts.last!.dropLast(3))
        var body = ""
        let template = periodic.config.template
        if !template.isEmpty, let source = text(of: Vault.isNote(template) ? template : template + ".md") {
            body = templates.fill(source, title: name, day: day, clock: .now())
        }
        return try createNote(named: name, in: parts.dropLast().joined(separator: "/"), text: body)
    }

    /// The scratchpad: the one inbox note the `scratchpad.note` setting
    /// names (`Scratchpad.md`), made empty when it is not there yet. Never
    /// a note for each day and never a folder of them: the vault keeps one
    /// inbox, as Daftar for Android does (`scratchpadPath`).
    func scratchpad() throws -> String {
        let path = scratchpadPath
        if let found = index.files.first(where: { Slugs.fold($0) == Slugs.fold(path) }) { return found }
        let parts = path.split(separator: "/").map(String.init)
        return try createNote(named: String(parts.last!.dropLast(3)), in: parts.dropLast().joined(separator: "/"))
    }

    /// The scratchpad's vault path, whether it is there or not.
    var scratchpadPath: String {
        let named = settings.scratchpadNote.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let note = named.isEmpty ? "Scratchpad.md" : named
        return Vault.isNote(note) ? note : note + ".md"
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
        readBookmarks(root)
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
        readBookmarks(root)
        let before = bookmarks.entries
        bookmarks.remove(path)
        if bookmarks.entries != before { saveBookmarks(root) }
        // Its icon goes too: left in Iconic's file, it would be the icon
        // of the next note of that name.
        if let data = try? Data(contentsOf: iconicFile(root)), let without = try? Iconic.removing(path, in: data) {
            try? without.write(to: iconicFile(root), options: .atomic)
            iconic = Iconic.parse(without)
        }
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
        afterEditors { self.moveTaskNow(task, to: drop) }
    }

    private func moveTaskNow(_ task: VaultTask, to drop: TaskBoard.Drop) -> Bool {
        guard let root, url(of: task.path) != nil, index.files.contains(task.path) else { return false }
        let statuses = index.statuses
        do {
            try ownEdit(task.path, in: root) { text in
                try VaultEdits.moveTask(in: text, line: task.task.line, task: task.task, to: drop, today: .today(), statuses: statuses)
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

    /// Sets the `job_stage` of [application]'s note to [stage], a card
    /// dropped on the job board: only that property's line is written, with
    /// the properties form's writer. False when the note's stage is no
    /// longer the one the card showed.
    @discardableResult
    func setJobStage(_ application: JobApplication, to stage: String) -> Bool {
        afterEditors { self.setJobStageNow(application, to: stage) }
    }

    private func setJobStageNow(_ application: JobApplication, to stage: String) -> Bool {
        guard let root, url(of: application.path) != nil, index.files.contains(application.path) else { return false }
        do {
            try ownEdit(application.path, in: root) { try JobSearch.settingStage(in: $0, from: application.stage, to: stage) }
            changed([application.path])
            requestSync()
            return true
        } catch JobSearch.StageFailure.unwritable(let reason) {
            notice = "\(application.company)'s properties are YAML the form cannot write back the same, so the stage was not changed. \(reason)"
        } catch {
            notice = "\(application.company)'s stage changed in its note before the drop. Nothing was written."
            changed([application.path])
        }
        return false
    }

    /// Sets [task]'s status to [status] from a status menu, with [reason]
    /// or none. False when its line no longer holds the task the menu showed.
    @discardableResult
    func setTaskStatus(_ task: VaultTask, to status: Character, reason: String? = nil) -> Bool {
        afterEditors { self.setTaskStatusNow(task, to: status, reason: reason) }
    }

    private func setTaskStatusNow(_ task: VaultTask, to status: Character, reason: String?) -> Bool {
        guard let root, url(of: task.path) != nil, index.files.contains(task.path) else { return false }
        let statuses = index.statuses
        do {
            try ownEdit(task.path, in: root) { text in
                try VaultEdits.setTaskStatus(in: text, line: task.task.line, task: task.task, to: status, reason: reason,
                                             today: .today(), statuses: statuses)
            }
            changed([task.path])
            requestSync()
            return true
        } catch {
            notice = "\(TaskRow.plain(task.task.text)) changed in its note before the change. Nothing was written."
            changed([task.path])
            return false
        }
    }

    /// Writes the task on [line] of [path] from [fields]. False when the
    /// line no longer holds the task the form was opened on.
    func editTask(path: String, line: Int, before: TaskFields, fields: TaskFields) -> Bool {
        afterEditors {
            self.editTaskNow(path: path, line: line, before: before, fields: fields)
        } otherwise: {
            self.notice = "The note changed before the save. Nothing was written."
        }
    }

    private func editTaskNow(path: String, line: Int, before: TaskFields, fields: TaskFields) -> Bool {
        guard let root, url(of: path) != nil, index.files.contains(path) else { return false }
        do {
            try ownEdit(path, in: root) { text in
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

    /// A new task in [path], at the end of the section of the heading on
    /// [headingLine], or at the end of the note. The note is read again at
    /// the write, after the editors save, and every line it had stays.
    @discardableResult
    func addTask(_ fields: TaskFields, to path: String, headingLine: Int?) -> Bool {
        guard let line = TaskLine.written(fields) else { return false }
        return afterEditors {
            self.addTaskNow(line, to: path, headingLine: headingLine)
        } otherwise: {
            self.notice = "The task could not be added to \(Vault.title(of: path))."
        }
    }

    private func addTaskNow(_ line: String, to path: String, headingLine: Int?) -> Bool {
        guard let root, url(of: path) != nil, index.files.contains(path), isText(path) else { return false }
        do {
            try ownEdit(path, in: root) { text in
                QuickCapture.append(line, to: text, headingLine: headingLine)
            }
            changed([path])
            requestSync()
            return true
        } catch {
            changed([path])
            return false
        }
    }

    // MARK: Whole notes

    /// The tasks of [path] sorted as the vault's Task Sorter plugin does:
    /// done and cancelled first in each section. False when none moved.
    @discardableResult
    func sortTasks(_ path: String) -> Bool {
        afterEditors {
            self.sortTasksNow(path)
        } otherwise: {
            if self.notice == nil { self.notice = "The tasks are in order already." }
        }
    }

    private func sortTasksNow(_ path: String) -> Bool {
        guard let root, url(of: path) != nil, index.files.contains(path) else { return false }
        var sorted = false
        do {
            try ownEdit(path, in: root) { text in
                guard let result = TaskSorter.sort(text) else { return text }
                sorted = true
                return result
            }
        } catch {
            notice = "The tasks could not be sorted: \(error.localizedDescription)"
            return false
        }
        if sorted {
            changed([path])
            requestSync()
        }
        return sorted
    }

    /// Gives the block that starts on [line] of [path] and says [text] the
    /// id [id], read from the file first. False, with a notice, when the
    /// block changed since it was listed.
    @discardableResult
    func addBlockId(_ id: String, to path: String, line: Int, text: String) -> Bool {
        // Not through `afterEditors`: its callers need the answer at once
        // (the link is copied only when the id went in), and the one that
        // can meet an editor saves the editors itself first.
        guard let root, url(of: path) != nil, index.files.contains(path) else { return false }
        do {
            try ownEdit(path, in: root) { try BlockRefs.addId(id, toBlockAt: line, expected: text, in: $0) }
        } catch {
            notice = "\(Vault.title(of: path)) changed, so the block got no id. Nothing was written there."
            changed([path])
            return false
        }
        changed([path])
        requestSync()
        return true
    }

    /// The notes that have the tag [tag] or one under it.
    func notes(tagged tag: String) -> [String] {
        let folded = Slugs.fold(tag.hasPrefix("#") ? String(tag.dropFirst()) : tag)
        return index.notes.values
            .filter { $0.parsed.tags.contains { Slugs.fold($0) == folded || Slugs.fold($0).hasPrefix(folded + "/") } }
            .map(\.path).sorted()
    }

    /// Renames the tag [old], and those under it, in every note that has it,
    /// once the editors have saved. The number of notes written.
    @discardableResult
    func renameTag(_ old: String, to new: String) async -> Int {
        await flushEditors()
        return writeTagRename(old, to: new)
    }

    /// The rename itself, on the files as they are.
    @discardableResult
    func writeTagRename(_ old: String, to new: String) -> Int {
        guard let root, TagRename.isValid(old), TagRename.isValid(new) else { return 0 }
        var written: Set<String> = []
        // The notes are read, renamed and written several at a time.
        let paths = notes(tagged: old).filter { url(of: $0) != nil }
        let outcomes = VaultEdits.apply(paths, in: root) { TagRename.rename($0, from: old, to: new) }
        for (path, outcome) in zip(paths, outcomes) {
            switch outcome {
            case .success(let changedNote):
                places.markRead(path)
                if changedNote { written.insert(path) }
            case .failure(let error):
                notice = "\(Vault.title(of: path)) could not be written: \(error.localizedDescription)"
            }
        }
        if !written.isEmpty {
            changed(written)
            requestSync()
        }
        return written.count
    }

    // MARK: Replace in the vault

    /// The notes "Replace in Vault" reads: the `.md` files in [folder], or
    /// in the whole vault for "", without Obsidian's excluded files.
    func replaceScope(_ folder: String) -> [String] {
        index.files
            .filter { Vault.isNote($0) && !excluded.contains($0) && (folder.isEmpty || $0.hasPrefix(folder + "/")) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The matches of [pattern] in each note of [folder], read from disk:
    /// the notes with a match, in path order.
    func replaceMatches(_ pattern: VaultReplace.Pattern, in folder: String) async -> [NoteMatches] {
        guard let root else { return [] }
        let paths = replaceScope(folder)
        return await Task.detached {
            paths.compactMap { path -> NoteMatches? in
                guard let file = Self.file(path, in: root), let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                let matches = VaultReplace.matches(in: text, pattern: pattern)
                return matches.isEmpty ? nil : NoteMatches(path: path, matches: matches)
            }
        }.value
    }

    /// Replaces the [chosen] matches of each note. Each note is read again
    /// and refused when its matches are not the [shown] ones; the rest are
    /// written with `write`, so the next sync commits them.
    func replace(_ pattern: VaultReplace.Pattern, shown: [NoteMatches], chosen: Set<MatchKey>) -> ReplaceSummary {
        var summary = ReplaceSummary()
        for note in shown {
            let ids = Set(note.matches.map(\.id).filter { chosen.contains(MatchKey(path: note.path, id: $0)) })
            guard !ids.isEmpty else { continue }
            guard let text = text(of: note.path) else {
                summary.refused.append(note.path)
                continue
            }
            do {
                let result = try VaultReplace.replace(in: text, pattern: pattern, shown: note.matches, chosen: ids)
                guard result != text else { continue }
                try write(result, to: note.path)
                summary.notes += 1
                summary.replacements += ids.count
            } catch {
                summary.refused.append(note.path)
            }
        }
        return summary
    }

    // MARK: History

    /// [text], an older text of [path], in the note's place, once the
    /// editors have saved: an editor with unsaved typing would write it
    /// over the restored text.
    func restore(_ text: String, to path: String) async throws {
        await flushEditors()
        try write(text, to: path)
    }

    /// The commits that changed [path], newest first; none outside a repository.
    func history(of path: String) async -> [Git.Revision] {
        guard let root, isRepository else { return [] }
        return (try? await Git(root: root).history(of: path)) ?? []
    }

    /// [revision]'s text of its note.
    func text(of revision: Git.Revision) async -> String? {
        guard let root else { return nil }
        return try? await Git(root: root).content(of: revision.path, at: revision.hash)
    }

    // MARK: Git

    /// Commit, pull and push now. With a conflict open, the conflicts show instead.
    func sync() async {
        guard let root else { return }
        if rebasing { return conflictStops += 1 }
        // What the editors hold is committed with the rest, and a pull
        // that changes the open note meets no unsaved text to lose to.
        await flushEditors()
        await run { try await Git(root: root).sync(message: Git.message()) }
    }

    /// Pull only: nothing is committed or pushed.
    func pull() async {
        guard let root else { return }
        if rebasing { return conflictStops += 1 }
        await flushEditors()
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
        } catch let stopped as Git.Stopped {
            rebasing = true
            unstashing = stopped.unstashed
            conflicts = stopped.conflicts
            conflictStops += 1
            syncError = stopped.description
        } catch {
            syncError = String(describing: error)
            // A hook's refusal is the person's to mend (a lint, an audit):
            // it is said at once, by its name, with the hook's last words.
            if let failure = error as? Git.Failure, let hook = failure.hook {
                let last = failure.output.split(separator: "\n").last.map(String.init) ?? ""
                notice = "The \(hook) hook stopped the commit, so nothing was synced" + (last.isEmpty ? "." : ": " + last)
            }
        }
        await refreshStatus()
    }

    // MARK: Conflicts

    /// Reads whether a rebase is open and the files it stopped on.
    func refreshConflicts(show: Bool = false) async {
        guard let root, isRepository else { return }
        let git = Git(root: root)
        await readStop(git)
        if rebasing, show { conflictStops += 1 }
        await refreshStatus()
    }

    private func readStop(_ git: Git) async {
        let stop = try? await git.openStop()
        rebasing = stop != nil
        unstashing = stop == .unstash
        conflicts = rebasing ? ((try? await git.conflicts()) ?? []) : []
    }

    /// Resolves every file as chosen, goes on with the rebase and pushes;
    /// where the stop is not a rebase, the changes are as they were before
    /// the pull, not committed, and the next sync commits them.
    /// Returns false when the next replayed commit stopped on a conflict too,
    /// or something failed; `conflicts` then holds what is open.
    func finishConflicts(_ resolutions: [(Git.Conflicted, Git.Resolution)]) async -> Bool {
        guard let root, rebasing, !syncing else { return false }
        syncing = true
        defer { syncing = false }
        let git = Git(root: root)
        do {
            let open = unstashing ? try await git.finishUnstash(resolutions) : try await git.finishRebase(resolutions)
            changed(Set(resolutions.map(\.0.path)))
            if open.isEmpty {
                rebasing = false
                unstashing = false
                conflicts = []
                lastSync = Date()
                syncError = nil
            } else {
                conflicts = open
                syncError = Git.Stopped(conflicts: open).description
            }
        } catch {
            syncError = String(describing: error)
            notice = "The sync could not go on: \(error)"
            await readStop(git)
        }
        await refreshStatus()
        return !rebasing
    }

    /// Ends the open rebase: the branch is as it was before the pull, and
    /// the next sync pulls again. What the person wrote in other notes
    /// while the conflict was open stays (`Git.abortRebase`).
    func abortConflicts() async {
        guard let root, rebasing, !unstashing, !syncing else { return }
        // What the editors hold is on disk before the tree is reset.
        await flushEditors()
        syncing = true
        defer { syncing = false }
        do {
            let copies = try await Git(root: root).abortRebase()
            syncError = nil
            notice = "The sync was stopped. Your commits are as they were before the pull, and what you wrote since is kept."
                + (copies.isEmpty ? "" : " A copy was made of \(copies.joined(separator: ", ")).")
        } catch {
            notice = "The sync could not be stopped: \(error)"
        }
        await refreshConflicts()
    }

    func refreshStatus() async {
        guard let root, isRepository else { return }
        gitStatus = try? await Git(root: root).status()
    }

    /// After an edit: a sync a little later, when automatic sync is on, so
    /// that several ticks in a row make one commit.
    private func requestSync() {
        guard settings.syncInterval > 0, !rebasing else { return }
        syncSoon?.cancel()
        syncSoon = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, !rebasing else { return }
            await sync()
        }
    }

    func scheduleAutoSync() {
        autoSync?.cancel()
        let minutes = settings.syncInterval
        guard minutes > 0, isRepository else { return }
        autoSync = Task {
            while !Task.isCancelled {
                // Automatic sync waits while a conflict is open.
                if !rebasing { await sync() }
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
        let excluded = excluded
        let statuses = index.statuses
        for task in index.tasks where task.task.isOpen(in: statuses) && !excluded.contains(task.path) {
            guard let text = task.task.day, let day = Day(text) else {
                if statuses.type(task.task.status) == .inProgress { groups.inProgress.append(task) }
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

    /// Every file for the switcher, best first (`QuickSwitcher`): every
    /// word, in any order, in the name, an alias or the folders, and a word
    /// with a `/` in the path.
    func quickOpen(_ query: String, recent: [String], limit: Int = 100) -> [String] {
        switcher(query, recent: recent, limit: limit).paths
    }

    func switcher(_ query: String, recent: [String], limit: Int = 100) -> QuickSwitcher.Ranking {
        let present = recent.filter { index.files.contains($0) && !excluded.contains($0) }
        return QuickSwitcher.ranking(query, in: quickOpenCandidates(), recent: present, limit: limit)
    }

    /// ⌘P's rows: files, or with `Note#Heading` the headings of the note
    /// that matches best, of [current] when the note part is empty.
    func switcherRows(_ query: String, recent: [String], current: String?) -> (rows: [SwitcherRow], loose: Bool) {
        guard let (file, heading) = QuickSwitcher.heading(in: query) else {
            let ranking = switcher(query, recent: recent)
            return (ranking.paths.map { SwitcherRow(path: $0, heading: nil) }, ranking.loose)
        }
        let path = file.isEmpty ? current : switcher(file, recent: recent).paths.first(where: Vault.isNote)
        guard let path, let headings = index.notes[path]?.parsed.headings else { return ([], false) }
        return (QuickSwitcher.headings(heading, in: headings).map { SwitcherRow(path: path, heading: $0) }, false)
    }

    /// The files the switcher can offer, notes and attachments, folded once
    /// for each version of the index rather than on every keystroke.
    @ObservationIgnored private var candidates: (revision: Int, files: Int, items: [QuickSwitcher.Candidate])?
    /// Each file's candidate, with the aliases it was folded from and
    /// whether it is hidden, for a [hiddenRevision]: a save folds its own
    /// note again, not the 20,000 others.
    @ObservationIgnored private var folded = FoldedCandidates()
    @ObservationIgnored private var prewarming: Task<Void, Never>?

    struct FoldedCandidates: Sendable {
        var hidden = -1
        var entries: [String: Entry] = [:]

        struct Entry: Sendable {
            var aliases: [String]
            var hidden: Bool
            var candidate: QuickSwitcher.Candidate
        }

        /// The candidates of [index]'s files, reusing each one whose aliases did not change.
        mutating func update(_ index: VaultIndex, excluded: ExcludedFiles, hidden revision: Int) -> [QuickSwitcher.Candidate] {
            if hidden != revision { self = FoldedCandidates(hidden: revision) }
            var fresh: [String: Entry] = [:]
            fresh.reserveCapacity(index.files.count)
            var items: [QuickSwitcher.Candidate] = []
            items.reserveCapacity(index.files.count)
            for path in index.files {
                let aliases = index.notes[path]?.parsed.aliases ?? []
                let entry: Entry
                if let known = entries[path], known.aliases == aliases {
                    entry = known
                } else {
                    entry = Entry(aliases: aliases, hidden: excluded.contains(path), candidate: QuickSwitcher.Candidate(path: path, title: Vault.title(of: path), aliases: aliases))
                }
                fresh[path] = entry
                if !entry.hidden { items.append(entry.candidate) }
            }
            entries = fresh
            return items
        }
    }

    private func quickOpenCandidates() -> [QuickSwitcher.Candidate] {
        if let candidates, candidates.revision == revision, candidates.files == index.files.count { return candidates.items }
        let items = folded.update(index, excluded: excluded, hidden: hiddenRevision)
        candidates = (revision, index.files.count, items)
        return items
    }

    /// The switcher's candidates for the index as it is now, made off the
    /// main thread after the index changed, so the next key in quick open
    /// or the sidebar's search does not fold the vault's names first.
    private func prewarmCandidates() {
        prewarming?.cancel()
        let index = index, excluded = excluded, hidden = hiddenRevision, revision = revision, files = index.files.count
        let start = folded
        prewarming = Task {
            let (items, made) = await Task.detached(priority: .utility) {
                var folded = start
                let items = folded.update(index, excluded: excluded, hidden: hidden)
                return (items, folded)
            }.value
            guard !Task.isCancelled, self.revision == revision, self.hiddenRevision == hidden, self.candidates?.revision != revision else { return }
            self.folded = made
            self.candidates = (revision, files, items)
        }
    }

}

/// A place in [source] that names a note without linking to it.
struct MentionHit: Hashable {
    var source: String
    var mention: UnlinkedMentions.Mention
}

/// A row of ⌘P: a file, or a heading in a note.
struct SwitcherRow: Hashable {
    var path: String
    var heading: Heading?
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
    case notText(String)

    var errorDescription: String? {
        switch self {
        case .notText(let path): "“\(path)” is not UTF-8 text, so it is not written over"
        case .gone(let path): "“\(path)” is no longer in the vault"
        case .outside(let path): "“\(path)” is outside the vault"
        }
    }
}

/// One note's matches for "Replace in Vault".
struct NoteMatches: Sendable, Identifiable, Equatable {
    var path: String
    var matches: [VaultReplace.Match]
    var id: String { path }
}

/// A match of a note, for the checkboxes of "Replace in Vault".
struct MatchKey: Hashable {
    var path: String
    var id: Int
}

/// What "Replace in Vault" did.
struct ReplaceSummary: Equatable {
    var notes = 0
    var replacements = 0
    /// The notes that changed after the preview, or could not be read or written.
    var refused: [String] = []
}
