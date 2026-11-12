import AppKit
import DaftarCore
import SwiftUI

/// The editor: the note's markdown source in a native text view, styled as
/// it is typed. The file on disk is the record; the editor saves to it a
/// moment after the typing stops, and when it is left.
struct EditorView: NSViewRepresentable {
    var path: String
    var store: VaultStore
    /// The source line to open at: where the reading cursor was.
    var line: Int?
    /// The cursor moved to a source line.
    var onCursor: ((Int) -> Void)?
    /// The selection to become a note: its text, and how to put the link back.
    var onExtract: ((String, @escaping (String) -> Void) -> Void)?
    /// Headings were renamed in the note: the change, to offer their links.
    var onHeadingsRenamed: ((HeadingRename.Change) -> Void)?
    /// The outline asked for a heading.
    var jump: EditorJump?
    /// Neovim quit on its own -- `:wq`, `:q`, `ZZ` -- and the pane reads again.
    var onQuit: (() -> Void)?
    /// Another note was opened inside Neovim (`:e`, `gf`): the pane opens it.
    var onOpen: ((String) -> Void)?
    /// What the audit found in the note, by line, for the margin.
    var problems: [Int: [Problem]] = [:]
    /// The pane's Neovim while it reads, for the editor's next open.
    var keeper: NeovimKeeper?

    func makeCoordinator() -> EditorController { EditorController(store: store) }

    func makeNSView(context: Context) -> EditorContainer {
        let scroll = NoteTextView.scrollableNoteView()
        let view = scroll.documentView as! NoteTextView
        let container = EditorContainer(scroll: scroll)
        view.controller = context.coordinator
        context.coordinator.view = view
        context.coordinator.container = container
        container.onLayout = { [weak controller = context.coordinator] in controller?.session?.resize() }
        context.coordinator.onCursor = onCursor
        context.coordinator.keeper = keeper
        context.coordinator.load(path)
        if let line { context.coordinator.go(toLine: line) }
        context.coordinator.onExtract = onExtract
        context.coordinator.onHeadingsRenamed = onHeadingsRenamed
        context.coordinator.onQuit = onQuit
        context.coordinator.onOpen = onOpen
        context.coordinator.lastJump = jump
        view.focusWhenShown = true
        view.show(problems: problems)
        return container
    }

    func updateNSView(_ container: EditorContainer, context: Context) {
        let controller = context.coordinator
        controller.onExtract = onExtract
        controller.onCursor = onCursor
        controller.onHeadingsRenamed = onHeadingsRenamed
        controller.onQuit = onQuit
        controller.onOpen = onOpen
        if controller.path != path {
            let left = controller.leaving
            controller.saveNow()
            controller.load(path)
            controller.formatOnLeave(left, at: .otherNote)
        } else {
            controller.followDisk()
        }
        controller.applyTextSize()
        controller.followVimSetting()
        controller.jump(jump)
        controller.followWritingModes()
        controller.view?.show(problems: problems)
    }

    static func dismantleNSView(_ container: EditorContainer, coordinator: EditorController) {
        coordinator.checkHeadings()
        let left = coordinator.leaving
        coordinator.saveNow()
        coordinator.parkVim()
        coordinator.formatOnLeave(left, at: .closed)
        coordinator.animator.stop()
        coordinator.store.flushers[ObjectIdentifier(coordinator)] = nil
        coordinator.store.followers[ObjectIdentifier(coordinator)] = nil
        coordinator.store.checks.editors[ObjectIdentifier(coordinator)] = nil
    }
}

/// Who owns the note's text. The view edits and saves it (`plain`), or
/// Neovim does: while Neovim starts and runs, the view shows what Neovim
/// says and refuses every edit of its own, and Neovim writes the file. A
/// Neovim that failed or ended (`neovimDead`) owns nothing any more, and
/// the view is not yet a plain editor: nothing is typed into it and nothing
/// is saved from it, until the controller lets it go (`showStatus`).
/// Saving, following the disk and taking an edit all go by this one answer.
enum TextOwner: Equatable {
    case plain, neovimStarting, neovimRunning, neovimDead
}

@MainActor
final class EditorController: NSObject, NSTextStorageDelegate, NSTextViewDelegate {
    let store: VaultStore
    weak var view: NoteTextView?
    weak var container: EditorContainer?
    private(set) var path: String?
    /// Neovim, in Neovim mode: it owns the buffer and writes the file.
    private(set) var session: NeovimSession?
    /// Who edits and saves the text now.
    var owner: TextOwner { session?.owner ?? .plain }
    /// Neovim did not start for this note, which is in the plain editor
    /// until it is opened again or the setting changes: no start at every
    /// update of the view.
    private(set) var neovimRefused = false
    /// Where `nvim` is, from the setting; a test gives a machine without one.
    var locateNeovim: (String) -> URL? = { NeovimClient.locate($0) }
    /// Keeps this editor's Neovim while its pane reads (`NeovimKeeper`).
    var keeper: NeovimKeeper?
    /// What the file said when it was last read or written.
    private var saved = ""
    /// What the note said when this editor took it, or took a change on
    /// disk: format on save formats only a note typed in since
    /// (`EditorFormat.swift`).
    var loadedText = ""
    /// A Neovim that was let go is still writing its file: format on save
    /// waits for it.
    var stopping: Task<Void, Never>?
    /// The file's date and size just after this editor wrote it: while they
    /// are the same, the file holds [saved] and is not read back.
    private var savedStamp: (path: String, stamp: FileStamp)?
    private var saveTask: Task<Void, Never>?
    private var seenRevision = -1
    private var fontKey = ""
    /// The note's block delimiters in order: fences, `$$`, `%%` and `---`
    /// lines. An edit that changes them restyles the rest of the note; any
    /// other edit restyles its own lines only.
    var structure: [String] = []
    /// The text is being replaced whole, and styled after.
    var replacing = false
    var styling: Task<Void, Never>?
    /// The part of the note styled so far while the rest is styled a part
    /// at a time (`restyleProgressively`); nil when all of it is.
    var progressive: NSRange?
    private var shownMode = ""
    // What the styling keeps (`EditorStyling.swift`).
    /// The lines the selection is on, where every mark shows.
    var revealed = NSRange(location: 0, length: 0)
    /// The block states of the lines styled last (fence, comment, math).
    var blockStates = MarkdownHighlighter.BlockStates()
    var images: [String: NSImage] = [:]
    /// Animated GIFs, WebPs and PNGs move (`EditorImages.swift`).
    let animator = ImageAnimator()
    /// The front matter the properties form shows in its place, in UTF-16
    /// units: hidden here, and out of the cursor's reach (`PropertiesView`).
    var hiddenFront = 0

    var onExtract: ((String, @escaping (String) -> Void) -> Void)?
    var onHeadingsRenamed: ((HeadingRename.Change) -> Void)?
    var onQuit: (() -> Void)?
    var onOpen: ((String) -> Void)?
    /// The headings at the last look, to find one renamed; the start of the
    /// heading line the cursor is on; the outline's last jump.
    var headingBaseline: [Heading] = []
    var headingLine: Int?
    var lastJump: EditorJump?

    /// ⌥⌘X: the selection goes to a new note, and a link takes its place.
    func extract() {
        guard let view, let onExtract else { return }
        if session != nil {
            store.notice = "Extract works in the editor without Neovim mode."
            return
        }
        let range = view.selectedRange()
        guard range.length > 0 else {
            store.notice = "Select the text to extract first."
            return
        }
        let text = (view.string as NSString).substring(with: range)
        onExtract(text) { [weak self, weak view] link in
            guard let view, NSMaxRange(range) <= (view.string as NSString).length,
                (view.string as NSString).substring(with: range) == text, view.shouldChangeText(in: range, replacementString: link)
            else {
                self?.store.notice = "The note changed, so the link was not put in. The new note is made."
                return
            }
            view.textStorage?.replaceCharacters(in: range, with: link)
            view.didChangeText()
            view.setSelectedRange(NSRange(location: range.location + (link as NSString).length, length: 0))
        }
    }

    /// Sorts the tasks as the vault's Task Sorter plugin does, as one step
    /// to undo. Neovim owns its buffer, so there the file is sorted, once
    /// Neovim has written it, and Neovim reads it again.
    func sortTasks() {
        guard let view, let path else { return }
        if session != nil {
            // Sorted from the file only once Neovim has written it: a save
            // sent without waiting left the last keys out of the sort.
            Task {
                await flush()
                if !store.sortTasks(path) { store.notice = "The tasks are in order already." }
            }
            return
        }
        guard let sorted = TaskSorter.sort(view.string) else {
            store.notice = "The tasks are in order already."
            return
        }
        let whole = NSRange(location: 0, length: (view.string as NSString).length)
        guard view.shouldChangeText(in: whole, replacementString: sorted) else { return }
        let cursor = view.selectedRange().location
        view.textStorage?.replaceCharacters(in: whole, with: sorted)
        view.didChangeText()
        view.setSelectedRange(NSRange(location: min(cursor, (sorted as NSString).length), length: 0))
    }

    init(store: VaultStore) {
        self.store = store
        super.init()
        store.flushers[ObjectIdentifier(self)] = { [weak self] in await self?.flush() }
        store.followers[ObjectIdentifier(self)] = { [weak self] in self?.follow($0) }
        store.checks.editors[ObjectIdentifier(self)] = { [weak self] in self?.leaving }
    }

    /// Everything typed is on disk when this returns.
    func flush() async {
        saveNow()
        await session?.saveAndWait()
    }

    func load(_ path: String) {
        self.path = path
        let text = store.text(of: path) ?? ""
        saved = text
        loadedText = text
        headingBaseline = Sections.headings(in: text)
        headingLine = nil
        seenRevision = store.revision
        // The pictures of the note before, and their frames, are not kept
        // for the life of the pane; a picture changed on disk is read again.
        images = [:]
        animator.reset()
        guard let view else { return }
        view.textStorage?.delegate = self
        view.delegate = self
        view.textLayoutManager?.delegate = self
        replacing = true
        // Plain, until it is styled: `string =` would give it the old
        // text's attributes, a heading's perhaps.
        view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: base))
        view.forgetNeovimCursor()
        // A new note: the cursor is on its first line.
        revealed = (text as NSString).lineRange(for: NSRange(location: 0, length: 0))
        replacing = false
        restyleProgressively()
        // Styled with the fonts of now: the view's first update does not style it all again.
        fontKey = textSizeKey
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.scrollToBeginningOfDocument(nil)
        view.undoManager?.removeAllActions()
        updateCounts()
        neovimRefused = false
        // Another note in the same Neovim: the one left is written first,
        // and format on save waits for that write.
        if let session, store.settings.vimMode, let root = store.root, session.reusable(with: store.settings, root: root) {
            stopping = session.written()
            session.reopen(path, in: view, textSize: store.settings.textSize)
            showStatus()
            return
        }
        stopVim()
        if store.settings.vimMode { startVim() }
    }

    // MARK: Neovim mode

    func followVimSetting() {
        if store.settings.vimMode, session == nil, path != nil, !neovimRefused { startVim() }
        if !store.settings.vimMode { neovimRefused = false }
        if !store.settings.vimMode, session != nil {
            stopVim()
            if let path { load(path) }
        }
    }

    private func startVim() {
        guard let path, let root = store.root, let view else { return }
        saveNow()
        // The pane's Neovim, kept while it read.
        if let kept = keeper?.take(for: store.settings, root: root) {
            kept.reopen(path, in: view, textSize: store.settings.textSize)
            use(kept)
            return
        }
        guard let session = NeovimSession(path: path, root: root, view: view, settings: store.settings, locate: locateNeovim) else {
            // Said once for the note, not at every update of the view.
            neovimRefused = true
            store.notice = "Neovim mode is on, but there is no nvim. Install it with `brew install neovim`, or set `nvim` in the config file."
            return
        }
        use(session)
        Task { await session.start() }
    }

    /// [session] is the editor's: the view shows what it says and sends it the keys.
    private func use(_ session: NeovimSession) {
        guard let view else { return }
        self.session = session
        view.vim = session
        view.allowsUndo = false
        // Neovim owns the buffer: a rewrite must come through it, not around it.
        view.writingToolsBehavior = .none
        session.onChange = { [weak self] in self?.showStatus() }
        session.onOpen = { [weak self] file in self?.openFromNeovim(file) }
        // A Neovim that is stopped and does not write in time: its buffer
        // is all there is of the last typing, and the store writes it.
        session.onUnwritten = { [store] path, text in
            guard store.text(of: path) != text else { return }
            do {
                try store.write(text, to: path)
                store.notice = "Neovim did not answer, so Daftar wrote \(Vault.title(of: path)) itself."
            } catch {
                store.notice = "\(Vault.title(of: path)) could not be saved: \(error.localizedDescription)"
            }
        }
        showStatus()
    }

    /// A file opened inside Neovim: a file of the vault opens in the pane,
    /// as a click on its link would; any other is not Daftar's to edit.
    private func openFromNeovim(_ file: String) {
        guard let path = store.vaultPath(of: URL(filePath: file)), store.url(of: path) != nil,
            FileManager.default.fileExists(atPath: file), let onOpen
        else {
            store.notice = "\((file as NSString).lastPathComponent) is not a file of this vault, so it was not opened."
            return
        }
        onOpen(path)
    }

    func stopVim(writing: Bool = true) {
        guard let session = letGo() else { return }
        // Before the next line of this turn puts another note in the view.
        session.detach()
        stopping = Task { await session.stop(writing: writing) }
    }

    /// The editor's view goes (⌘E, a closed pane): its Neovim writes the
    /// note and the pane keeps it, for the next edit. With no keeper, or a
    /// Neovim that does not run, it is ended as before.
    func parkVim() {
        guard let session, let keeper, store.settings.vimMode, case .running = session.state, !session.crashed else { return stopVim() }
        letGo()
        let saving = session.park()
        stopping = saving
        keeper.keep(session, store: store, saving: saving)
    }

    /// The view is a plain editor's again; the session, no longer the editor's.
    @discardableResult
    private func letGo() -> NeovimSession? {
        guard let session else { return nil }
        self.session = nil
        view?.hideNeovimMenu()
        view?.vim = nil
        view?.allowsUndo = true
        view?.writingToolsBehavior = .complete
        container?.setStatus(nil, mode: nil)
        return session
    }

    private func showStatus() {
        updateCounts()
        container?.setCommandLine(session?.state == .running ? session?.commandLine : nil, blurred: store.settings.blurPanels)
        guard let session else { return container?.setStatus(nil, mode: nil) ?? () }
        switch session.state {
        case .failed(let message):
            // Neovim did not start: the note is in the plain editor, which
            // saves what is typed, and shows the file as it is.
            neovimRefused = true
            stopVim(writing: false)
            takeDisk()
            store.notice = "Neovim did not start, so this note is in the plain editor. \(message)"
            return
        case .ended:
            // `:wq`, `:q` and `ZZ` mean "done" to a Vim hand: the note is
            // read again, and the next edit starts a new Neovim. Neovim
            // wrote what `:w` asked for; nothing is written after it: the
            // view takes the file, so `:q!` leaves no text here to save.
            // A Neovim that was killed wrote nothing, and what the view
            // shows is all there is of the typing: that is saved.
            if session.crashed {
                // Killed, or ended because it did not answer: the note
                // stays open, in the plain editor, with all that was typed.
                neovimRefused = true
                stopVim(writing: false)
                saveNow()
                store.notice = "Neovim stopped, so this note is in the plain editor. What you typed is kept."
                return
            }
            if let onQuit {
                stopVim(writing: false)
                takeDisk()
                onQuit()
                return
            }
            container?.setStatus("Neovim ended. Open the note again to start it.", mode: "NEOVIM")
        // What Neovim says as it starts -- an error in the config, a question -- shows too.
        case .starting: container?.setStatus(session.status.isEmpty ? "Starting Neovim…" : session.status, mode: "NEOVIM")
        case .running: container?.setStatus(session.status, mode: session.modeName)
        }
        // The block cursor and the bar differ: the cursor's line is drawn
        // again when the mode changes, not the whole page at every key.
        if session.modeName != shownMode {
            shownMode = session.modeName
            view?.showCaretStyle()
            view?.redrawCursorLine()
        }
    }

    /// The window closes. SwiftUI does not always take the editor's view
    /// down then (as it does not on Quit), and what was typed in the last
    /// second, or in Neovim since the last Escape, was in no file. The
    /// plain editor saves at once; Neovim is asked to write and is kept
    /// until it has, or until its limit.
    func windowClosing() {
        checkHeadings()
        let left = leaving
        switch owner {
        case .plain:
            saveNow()
            formatOnLeave(left, at: .closed)
        case .neovimRunning:
            if let session {
                Task {
                    await session.saveAndWait()
                    self.formatOnLeave(left, at: .closed)
                }
            }
        case .neovimStarting, .neovimDead:
            break
        }
    }

    /// The file changed on disk. A change this editor wrote is already here;
    /// any other is taken when there is no unsaved typing, and kept out when
    /// there is, so nothing typed is lost.
    func followDisk() {
        guard let path, let view, store.revision != seenRevision else { return }
        seenRevision = store.revision
        switch owner {
        case .neovimRunning:
            // Neovim wrote it (the view already says so), or someone else
            // did, and Neovim reads it again.
            if store.lastChanged.contains(path), store.text(of: path) != view.string { session?.checkDisk() }
            return
        case .neovimStarting, .neovimDead:
            // Neovim reads the file when it opens it; a dead one reads nothing.
            return
        case .plain:
            break
        }
        guard store.lastChanged.contains(path), !holdsOwnSave(path), let disk = store.text(of: path), disk != saved else { return }
        if view.string == saved {
            take(disk)
        } else {
            store.notice = "\(Vault.title(of: path)) changed on disk while you typed. Your text is kept; it is saved over the other change."
        }
    }

    /// The text on disk, at once and without waiting for the file watcher,
    /// when nothing here is unsaved: the same note in the other pane may
    /// have saved since this view last looked.
    func catchUp() {
        guard session == nil, let path, let view, view.string == saved, !holdsOwnSave(path), let disk = store.text(of: path), disk != saved else { return }
        take(disk)
    }

    /// The file is as this editor last wrote it: same date and size.
    private func holdsOwnSave(_ path: String) -> Bool {
        guard let savedStamp, savedStamp.path == path, let now = FileStamp(store.url(of: path)) else { return false }
        return now == savedStamp.stamp
    }

    /// A move or a delete, made in this window or another. The editor was
    /// saved just before it, so the file holds all that was typed.
    func follow(_ change: VaultChange) {
        guard let path else { return }
        switch change {
        case .moved(let moves, let touched):
            session?.forget(moves.keys.filter { $0 != path })
            let now = moves[path] ?? path
            guard now != path || touched.contains(path) else { return }
            if let session {
                self.path = now
                if now != path { Task { await session.rename(to: now) } } else { session.checkDisk() }
                return
            }
            self.path = now
            // The links in it were written again: take them now, before the
            // next save writes the old ones back.
            if let view, view.string == saved, let disk = store.text(of: now), disk != saved { take(disk) }
        case .deleted(let gone):
            guard path == gone || path.hasPrefix(gone + "/") else {
                session?.forget([gone])
                return
            }
            saveTask?.cancel()
            stopVim(writing: false)
            self.path = nil
        }
    }

    /// Neovim is gone and the file is what it wrote: the view shows the
    /// file, and nothing here is unsaved.
    private func takeDisk() {
        guard let path, let view, let disk = store.text(of: path) else { return }
        if view.string == disk {
            saved = disk
            headingBaseline = Sections.headings(in: disk)
        } else {
            take(disk)
        }
    }

    /// The text on disk, in place of a view with nothing unsaved: only what
    /// differs is replaced, so the rest keeps its styles, its layout and
    /// the scroll, and only the changed lines are styled again. Never
    /// `string =`, which gives the new text the old one's attributes.
    ///
    /// The undo stack goes: its steps name places in the text as it was,
    /// and an undo after a pull or a property set in the form put the old
    /// typing back at those places in the new text, which was then saved.
    private func take(_ disk: String) {
        guard let view, let storage = view.textStorage else { return }
        let selection = view.selectedRange()
        saved = disk
        loadedText = disk
        headingBaseline = Sections.headings(in: disk)
        let edit = Self.smallestEdit(from: storage.string as NSString, to: disk as NSString)
        let length = (edit.text as NSString).length
        if edit.range.length > 0 || length > 0 {
            view.holdScroll(editing: edit.range, with: length)
            storage.replaceCharacters(in: edit.range, with: edit.text)
            view.redrawPanels()
        }
        // The front matter the form stands for got longer or shorter: an
        // edit styles its own lines, and these are hidden by their place.
        if frontMatterToHide() != hiddenFront { restyle(all: true) }
        view.undoManager?.removeAllActions()
        // The cursor stays on its letter: after the edit it moves with the
        // text, inside it it goes to the edit's end.
        var cursor = selection.location
        if cursor >= NSMaxRange(edit.range) {
            cursor += length - edit.range.length
        } else if cursor > edit.range.location {
            cursor = edit.range.location + length
        }
        view.setSelectedRange(NSRange(location: min(max(0, cursor), storage.length), length: 0))
    }

    /// The one range of [old] that differs from [new], and what [new] has
    /// there: what is the same at both ends stays. A surrogate pair is
    /// never cut in two.
    static func smallestEdit(from old: NSString, to new: NSString) -> (range: NSRange, text: String) {
        let limit = min(old.length, new.length)
        var prefix = 0
        while prefix < limit, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        if prefix > 0, UTF16.isLeadSurrogate(old.character(at: prefix - 1)) { prefix -= 1 }
        var suffix = 0
        while suffix < limit - prefix, old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        if suffix > 0, UTF16.isTrailSurrogate(old.character(at: old.length - suffix)) { suffix -= 1 }
        return (
            NSRange(location: prefix, length: old.length - prefix - suffix),
            new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
        )
    }

    /// What the styling's fonts depend on: a change styles the whole note again.
    private var textSizeKey: String {
        let settings = store.settings
        return "\(settings.textSize)|\(settings.font)|\(settings.codeFont)|\(settings.propertiesForm)"
    }

    func applyTextSize() {
        let key = textSizeKey
        view?.fitMargins()
        guard key != fontKey else { return }
        fontKey = key
        restyle(all: true)
    }

    // MARK: Saving

    private var countTask: Task<Void, Never>?

    /// The bar's words and characters, a moment after the text or the
    /// selection changes.
    func updateCounts() {
        countTask?.cancel()
        countTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, let view = self.view else { return }
            let string = view.string
            let selection = view.selectedRange()
            // Counting a long note's words takes milliseconds: not on the main thread.
            let (characters, words, selected) = await Task.detached {
                let text = string as NSString
                return (
                    text.length, Self.words(in: text, range: NSRange(location: 0, length: text.length)),
                    selection.length > 0 && NSMaxRange(selection) <= text.length ? Self.words(in: text, range: selection) : nil
                )
            }.value
            guard !Task.isCancelled else { return }
            self.container?.setCounts(
                words: words, characters: characters, selectedWords: selected, selectedCharacters: selection.length > 0 ? selection.length : nil)
        }
    }

    nonisolated static func words(in text: NSString, range: NSRange) -> Int {
        var count = 0
        text.enumerateSubstrings(in: range, options: [.byWords, .substringNotRequired]) { _, _, _, _ in count += 1 }
        return count
    }

    var onCursor: ((Int) -> Void)?
    private var cursorTask: Task<Void, Never>?

    /// The cursor's source line, a moment after it stops, for the reader.
    private func reportLine() {
        guard onCursor != nil else { return }
        cursorTask?.cancel()
        cursorTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, let view = self.view else { return }
            self.onCursor?(Self.line(of: view.selectedRange().location, in: view.string as NSString))
        }
    }

    /// The source line (from 0) [location] is on: the newlines before it,
    /// found one by one, with no copy of the text above the cursor.
    static func line(of location: Int, in text: NSString) -> Int {
        let end = min(max(0, location), text.length)
        var line = 0, from = 0
        while from < end {
            let found = text.range(of: "\n", options: .literal, range: NSRange(location: from, length: end - from))
            guard found.location != NSNotFound else { break }
            line += 1
            from = NSMaxRange(found)
        }
        return line
    }

    /// The cursor at the start of source line [line], in the middle of the view.
    func go(toLine line: Int) {
        guard let view else { return }
        let text = view.string as NSString
        var offset = 0
        for _ in 0..<line {
            guard offset < text.length else { break }
            offset = NSMaxRange(text.lineRange(for: NSRange(location: offset, length: 0)))
        }
        offset = min(offset, text.length)
        // A note still being styled a part at a time is styled from this
        // line first, so the line is laid out as it will stay.
        if let done = progressive, !NSLocationInRange(offset, done) { restyleProgressively(around: offset) }
        // The view shows the line at once, Neovim or not: while Neovim
        // starts, a view left at the top of the note showed the top first
        // and then jumped to the line.
        view.setSelectedRange(NSRange(location: offset, length: 0))
        view.center(offset)
        session?.go(to: offset)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        revealSelection()
        reportLine()
        followHeadingLine()
        updateCounts()
        // The tint of the cursor's line moves with it: the two lines are drawn again, not the page.
        view?.cursorLineMoved()
        followCursor()
    }

    func textDidChange(_ notification: Notification) {
        updateCounts()
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        switch owner {
        case .neovimRunning:
            session?.save()
            return
        case .neovimStarting, .neovimDead:
            // Nothing typed is in the view: the keys wait for Neovim, and
            // a dead Neovim's view takes no edit.
            return
        case .plain:
            break
        }
        guard let path, let view, view.string != saved else { return }
        let text = view.string
        do {
            try store.write(text, to: path)
            saved = text
            savedStamp = FileStamp(store.url(of: path)).map { (path, $0) }
        } catch {
            store.notice = "\(Vault.title(of: path)) could not be saved: \(error.localizedDescription)"
        }
    }

    // MARK: `[[` completion

    func textView(
        _ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>?
    ) -> [String] {
        guard let view = textView as? NoteTextView, view.completion.kind != nil else { return words }
        // Notes, headings, blocks or tags: EditorCompletion.swift.
        let rows = completions(for: view, range: charRange)
        index?.pointee = rows.isEmpty ? -1 : 0
        return rows
    }

    /// A file from outside the vault, copied into the attachment folder under
    /// a name no other file has; its vault path.
    func importAttachment(_ url: URL) -> String? {
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let path = VaultMoves.freeName(base, ext: ext, in: attachmentFolder, files: store.index.files)
        guard let target = store.url(of: path) else { return nil }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: target)
            return path
        } catch {
            store.notice = "\(url.lastPathComponent) could not be copied into the vault: \(error.localizedDescription)"
            return nil
        }
    }

    /// A pasted picture, written into the attachment folder under a name no
    /// file has: its name, for the embed. The name is the second it was
    /// pasted in, as Obsidian's, so two pastes in one second, or a picture
    /// another device pasted then, would be the same file: the second gets
    /// a number, and no file is ever written over. A folder that leaves the
    /// vault (`..` in `app.json`) is refused.
    func savePastedImage(_ data: Data, at date: Date = Date()) -> String? {
        let stem = (EditorCommands.pastedImageName(at: date) as NSString).deletingPathExtension
        var files = store.index.files
        do {
            while true {
                let path = VaultMoves.freeName(stem, ext: "png", in: attachmentFolder, files: files)
                guard let url = store.url(of: path) else {
                    store.notice = "The image was not saved: the attachment folder is outside the vault."
                    return nil
                }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                do {
                    try data.write(to: url, options: .withoutOverwriting)
                    return url.lastPathComponent
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    // On disk, and not in the index yet: the next name.
                    files.insert(path)
                }
            }
        } catch {
            store.notice = "The image could not be saved: \(error.localizedDescription)"
            return nil
        }
    }

    /// Where a pasted image goes: Obsidian's attachment folder for the vault.
    var attachmentFolder: String {
        guard let root = store.root,
            let data = try? Data(contentsOf: root.appending(path: ".obsidian/app.json")),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let folder = json["attachmentFolderPath"] as? String, !folder.isEmpty, folder != "/"
        else { return "" }
        return folder.hasPrefix("./") ? "" : folder
    }
}

/// A file's modification date and size, to tell that it was not written since.
struct FileStamp: Equatable {
    var modified: Date
    var size: Int

    init?(_ url: URL?) {
        guard let values = try? url?.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
            let modified = values.contentModificationDate, let size = values.fileSize
        else { return nil }
        self.modified = modified
        self.size = size
    }
}
