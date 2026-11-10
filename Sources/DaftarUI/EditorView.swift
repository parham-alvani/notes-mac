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
        context.coordinator.load(path)
        if let line { context.coordinator.go(toLine: line) }
        context.coordinator.onExtract = onExtract
        context.coordinator.onHeadingsRenamed = onHeadingsRenamed
        context.coordinator.onQuit = onQuit
        context.coordinator.onOpen = onOpen
        context.coordinator.lastJump = jump
        view.focusWhenShown = true
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
            controller.saveNow()
            controller.load(path)
        } else {
            controller.followDisk()
        }
        controller.applyTextSize()
        controller.followVimSetting()
        controller.jump(jump)
        controller.followWritingModes()
    }

    static func dismantleNSView(_ container: EditorContainer, coordinator: EditorController) {
        coordinator.checkHeadings()
        coordinator.saveNow()
        coordinator.stopVim()
        coordinator.animator.stop()
        coordinator.store.flushers[ObjectIdentifier(coordinator)] = nil
        coordinator.store.followers[ObjectIdentifier(coordinator)] = nil
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
    /// What the file said when it was last read or written.
    private var saved = ""
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
    private var shownMode = ""
    // What the styling keeps (`EditorStyling.swift`).
    /// The lines the selection is on, where every mark shows.
    var revealed = NSRange(location: 0, length: 0)
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
        // A new note: the cursor is on its first line.
        revealed = (text as NSString).lineRange(for: NSRange(location: 0, length: 0))
        replacing = false
        restyleProgressively()
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.scrollToBeginningOfDocument(nil)
        view.undoManager?.removeAllActions()
        updateCounts()
        stopVim()
        neovimRefused = false
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
        guard let session = NeovimSession(path: path, root: root, view: view, settings: store.settings, locate: locateNeovim) else {
            // Said once for the note, not at every update of the view.
            neovimRefused = true
            store.notice = "Neovim mode is on, but there is no nvim. Install it with `brew install neovim`, or set `nvim` in the config file."
            return
        }
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
        Task { await session.start() }
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
        guard let session else { return }
        self.session = nil
        view?.hideNeovimMenu()
        view?.vim = nil
        view?.allowsUndo = true
        view?.writingToolsBehavior = .complete
        container?.setStatus(nil, mode: nil)
        // Before the next line of this turn puts another note in the view.
        session.detach()
        Task { await session.stop(writing: writing) }
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
        switch owner {
        case .plain:
            saveNow()
        case .neovimRunning:
            if let session { Task { await session.saveAndWait() } }
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
        guard store.lastChanged.contains(path), let disk = store.text(of: path), disk != saved else { return }
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
        guard session == nil, let path, let view, view.string == saved, let disk = store.text(of: path), disk != saved else { return }
        take(disk)
    }

    /// A move or a delete, made in this window or another. The editor was
    /// saved just before it, so the file holds all that was typed.
    func follow(_ change: VaultChange) {
        guard let path else { return }
        switch change {
        case .moved(let moves, let touched):
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
            guard path == gone || path.hasPrefix(gone + "/") else { return }
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

    func applyTextSize() {
        let settings = store.settings
        let key = "\(settings.textSize)|\(settings.font)|\(settings.codeFont)|\(settings.propertiesForm)"
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
        if let session {
            session.go(to: offset)
            return
        }
        view.setSelectedRange(NSRange(location: offset, length: 0))
        view.center(offset)
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

/// The text view, with the markdown editing commands on its keys.
final class NoteTextView: NSTextView {
    weak var controller: EditorController?
    /// What the open `[[` or `#` completion offers, and what each row writes.
    var completion = CompletionState()
    /// Neovim mode: the keys go here, and the text changes only when Neovim says.
    weak var vim: NeovimSession? {
        didSet { showCaretStyle() }
    }
    /// The many cursors, and what focus and typewriter mode did (`EditorCursors.swift`).
    let extras = EditorExtras()
    /// Who edits the text: this view, or Neovim (`TextOwner`).
    var owner: TextOwner { vim?.owner ?? .plain }
    /// Neovim has the keys and the text.
    var vimActive: Bool { owner == .neovimStarting || owner == .neovimRunning }
    /// A new editor takes the keys once it is in its window: SwiftUI may put
    /// it there after the next turn of the run loop, and the keys typed
    /// until then went nowhere.
    var focusWhenShown = false
    // What the scroll keeps through an edit and with Neovim (`NeovimView.swift`).
    /// The first letter on screen, how far below the top of the view it
    /// was, and where the view was then: through the layout an edit brings,
    /// that letter stays where it was on screen.
    var anchor: (offset: Int, y: CGFloat, origin: CGFloat)?
    var anchorUntil = Date.distantPast
    /// Where Neovim's window starts, when it moved since the last scroll.
    var neovimTop: Int?
    var scrollPending = false
    /// Where `zz`, `zt` or `zb` puts the cursor's line at the next scroll.
    var placing: Place?
    /// Where a closing bracket was put that the person did not type, so
    /// typing it steps over it (`EditorKeys.swift`).
    var autoClosed: Int?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The window's closing saves the note: the view may never be taken down.
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: window)
        }
        guard focusWhenShown, let window else { return }
        focusWhenShown = false
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }

    @objc private func windowWillClose(_ notification: Notification) { controller?.windowClosing() }

    override func doCommand(by selector: Selector) {
        if vimActive || commandAtCursors(selector) { return }
        super.doCommand(by: selector)
    }

    override func mouseDown(with event: NSEvent) {
        if cursorClick(event) { return }
        super.mouseDown(with: event)
        if vimActive { vim?.moveCursor(to: selectedRange().location) }
    }

    /// Leaving the editor -- for the other pane, a sheet, the sidebar --
    /// saves the note, and coming back takes what was saved since: the same
    /// note in the other pane of a split shows each edit when it gets the focus.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            fitCaret()
            controller?.checkHeadings()
            controller?.saveNow()
        }
        return resigned
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            controller?.catchUp()
            DispatchQueue.main.async { [weak self] in self?.fitCaret() }
        }
        return became
    }

    private var tintedLine: NSRect?
    private var lineToDraw: NSRect?

    func redrawCursorLine() {
        if let line = cursorLineRect() { setNeedsDisplay(line.insetBy(dx: 0, dy: -1)) }
    }

    /// The cursor's line before and after a move, drawn again.
    func cursorLineMoved() {
        let now = selectedRange().length == 0 ? cursorLineRect() : nil
        showCaretStyle()
        // The block moves along the line, so Neovim's line is drawn again.
        guard now != tintedLine || vimActive else { return }
        if let tintedLine { setNeedsDisplay(tintedLine.insetBy(dx: 0, dy: -1)) }
        if let now { setNeedsDisplay(now.insetBy(dx: 0, dy: -1)) }
        tintedLine = now
    }

    /// The lines of a fenced code block, marked by the styling: the view
    /// draws one panel behind them, as the reader and Obsidian do, not a
    /// strip behind each line's letters.
    static let codeBlock = NSAttributedString.Key("DaftarCodeBlock")
    /// A quote's lines, with the name of the bar's colour: a name, so the
    /// lines of one quote are one run (two colours made alike are not equal).
    static let quoteBar = NSAttributedString.Key("DaftarQuoteBar")
    /// A callout's lines, with the name of its panel's colour.
    static let calloutPanel = NSAttributedString.Key("DaftarCalloutPanel")

    /// The panels of the code blocks in [rect].
    private func drawCodePanels(in rect: NSRect) {
        guard let storage = textStorage, storage.length > 0, let layout = textLayoutManager, let content = layout.textContentManager,
            let viewport = layout.textViewportLayoutController.viewportRange
        else { return }
        let start = content.offset(from: content.documentRange.location, to: viewport.location)
        let end = content.offset(from: content.documentRange.location, to: viewport.endLocation)
        let visible = NSRange(location: max(0, start), length: max(0, min(storage.length, end) - max(0, start)))
        // The whole lines of the blocks that reach into the viewport.
        let lines = (storage.string as NSString).lineRange(for: visible)
        let left = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0) - 2
        let right = textContainerOrigin.x + (textContainer?.size.width ?? bounds.width) - (textContainer?.lineFragmentPadding ?? 0) + 2
        /// The rect of a run of whole lines, from the first's top to the last's bottom.
        func box(_ range: NSRange) -> NSRect? {
            guard let first = lineRect(at: range.location), let last = lineRect(at: max(range.location, NSMaxRange(range) - 1)) else { return nil }
            return NSRect(x: left, y: first.minY - 2, width: right - left, height: last.maxY - first.minY + 4)
        }
        let text = storage.string as NSString
        /// The runs of [key], one per block: a line break left out of a run,
        /// as a line just added has it, does not split the block.
        func blocks(_ key: NSAttributedString.Key) -> [(String, NSRange)] {
            var out: [(String, NSRange)] = []
            storage.enumerateAttribute(key, in: lines, options: []) { value, range, _ in
                guard let value else { return }
                let name = value as? String ?? "\(value)"
                if let last = out.last, last.0 == name, NSMaxRange(last.1) <= range.location,
                    text.substring(with: NSRange(location: NSMaxRange(last.1), length: range.location - NSMaxRange(last.1))).allSatisfy({ $0 == "\n" }),
                    range.location - NSMaxRange(last.1) <= 1
                {
                    out[out.count - 1].1 = NSUnionRange(last.1, range)
                } else {
                    out.append((name, range))
                }
            }
            return out
        }
        for (name, range) in blocks(Self.calloutPanel) {
            guard let panel = box(range), panel.intersects(rect) else { continue }
            NSPalette.named(name, alpha: 0.1).setFill()
            NSBezierPath(roundedRect: panel, xRadius: 6, yRadius: 6).fill()
        }
        for (_, range) in blocks(Self.codeBlock) {
            guard let panel = box(range), panel.intersects(rect) else { continue }
            NSPalette.panel.setFill()
            NSBezierPath(roundedRect: panel, xRadius: 6, yRadius: 6).fill()
        }
        for (name, range) in blocks(Self.quoteBar) {
            guard let panel = box(range) else { continue }
            let colour = name == "quote" ? NSPalette.named("orange", alpha: 0.6) : NSPalette.named(name)
            let bar = NSRect(x: panel.minX - 10, y: panel.minY + 4, width: 3, height: panel.height - 8)
            guard bar.intersects(rect) else { continue }
            colour.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    /// The line that holds the cursor, tinted, with a thin accent bar.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawCodePanels(in: rect)
        guard selectedRange().length == 0, let line = cursorLineRect() else { return }
        // Where the tint is, as drawn: the next move clears this rect, even
        // when live preview moved the lines since.
        tintedLine = tintedLine.map { $0.union(line) } ?? line
        // Live preview laid the lines out again after the move: the line is
        // somewhere this draw does not reach, so it is drawn once more there.
        let shown = line.intersection(visibleRect)
        if !shown.isEmpty, !rect.contains(shown), lineToDraw != line {
            lineToDraw = line
            DispatchQueue.main.async { [weak self] in
                self?.lineToDraw = nil
                self?.setNeedsDisplay(line.insetBy(dx: 0, dy: -1))
                self?.fitCaret()
            }
        }
        NSPalette.named("orange", alpha: 0.07).setFill()
        line.fill(using: .sourceOver)
        NSPalette.named("orange", alpha: 0.8).setFill()
        NSRect(x: line.minX, y: line.minY + 2, width: 2.5, height: max(0, line.height - 4)).fill(using: .sourceOver)
    }

    private func cursorLineRect() -> NSRect? { lineRect(at: selectedRange().location) }

    /// The line of text at [offset], across the view, laid out first when
    /// it is far from what is on screen.
    func lineRect(at offset: Int) -> NSRect? {
        guard let layout = textLayoutManager, let content = layout.textContentManager else { return nil }
        let documentStart = content.documentRange.location
        guard let location = content.location(documentStart, offsetBy: offset) ?? (offset == 0 ? documentStart : nil) else { return nil }
        if layout.textLayoutFragment(for: location) == nil || !(layout.textLayoutFragment(for: location)!.state == .layoutAvailable) {
            layout.ensureLayout(for: NSTextRange(location: location))
        }
        guard let fragment = layout.textLayoutFragment(for: location) else { return nil }
        let frame = fragment.layoutFragmentFrame
        let paragraphStart = content.offset(from: documentStart, to: fragment.rangeInElement.location)
        let inParagraph = offset - paragraphStart
        let lines = fragment.textLineFragments
        let line = lines.first { NSLocationInRange(inParagraph, $0.characterRange) } ?? lines.last
        var rect = line.map { $0.typographicBounds.offsetBy(dx: frame.minX, dy: frame.minY) } ?? frame
        rect.origin.x = 0
        rect.origin.y += textContainerOrigin.y
        rect.size.width = bounds.width
        return rect
    }

    /// Normal mode draws a block over the character, as Neovim does.
    /// An `m` of the body text: the view's own font is its first letter's,
    /// and live preview shrinks a heading's `#` away from the cursor.
    private var blockWidth: CGFloat {
        let font = Fonts.text(size: CGFloat(controller?.store.settings.textSize ?? 14))
        return ("m" as NSString).size(withAttributes: [.font: font]).width
    }

    var showsBlock: Bool { vimActive && vim?.isNormal == true && selectedRange().length == 0 }

    /// The view's own caret is as high as the line, and a line is 1.6 times
    /// its letters with the room above them: the caret stood above the text.
    /// It is clear, and this one is drawn at the letters' height instead; in
    /// normal mode the block is drawn under the text with the cursor's line.
    private lazy var caret: NSTextInsertionIndicator = {
        let caret = NSTextInsertionIndicator(frame: .zero)
        caret.color = NSPalette.cursor
        caret.displayMode = .hidden
        addSubview(caret)
        return caret
    }()

    func showCaretStyle() {
        if insertionPointColor != .clear { insertionPointColor = .clear }
        fitCaret()
    }

    /// The caret at [offset], as high as the letters there and on their
    /// baseline: a line is 1.6 times its letters, with the room above them,
    /// and a caret as high as the line stands above the text.
    func letterCaret(at offset: Int) -> NSRect? {
        guard let caret = caretRect(at: offset) else { return nil }
        let text = string as NSString
        let at = offset < text.length ? offset : offset - 1
        let font = (at >= 0 && at < text.length ? textStorage?.attribute(.font, at: at, effectiveRange: nil) as? NSFont : nil) ?? self.font
        guard let font else { return caret }
        let height = min(caret.height, ceil(font.ascender - font.descender))
        return NSRect(x: caret.minX, y: caret.maxY - height, width: caret.width, height: height)
    }

    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        fitCaret()
    }

    /// The caret where the cursor is, while the view has the keys and
    /// nothing is selected.
    func fitCaret() {
        // In Neovim mode the cursor is NeovimCursor's, block or bar.
        moveNeovimCursor()
        let shown = window?.isKeyWindow == true && window?.firstResponder === self && selectedRange().length == 0 && !vimActive
        guard shown, let fitted = letterCaret(at: selectedRange().location) else {
            if caret.displayMode != .hidden { caret.displayMode = .hidden }
            return
        }
        let frame = NSRect(x: fitted.minX, y: fitted.minY, width: 0, height: fitted.height)
        if caret.frame != frame { caret.frame = frame }
        if caret.displayMode != .automatic { caret.displayMode = .automatic }
    }

    /// The block over the character at the cursor: its own box on the line,
    /// or an `m` at the end of a line. Two carets do not give the box: where
    /// Persian and English meet, the caret after a letter is at the other
    /// end of the run, and the block was as wide as a word. At the end of a
    /// line the block goes away from the last letter, to the left after a
    /// Persian one.
    func blockRect() -> NSRect? {
        let offset = selectedRange().location
        guard let caret = letterCaret(at: offset) else { return nil }
        let text = string as NSString
        if offset < text.length, text.character(at: offset) != 0x0A,
            let box = letterBox(text.rangeOfComposedCharacterSequence(at: offset)), box.width > 0.5
        {
            return NSRect(x: box.minX, y: caret.minY, width: box.width, height: caret.height)
        }
        var block = NSRect(x: caret.minX + 0.5, y: caret.minY, width: blockWidth, height: caret.height)
        if offset > 0, text.character(at: offset - 1) != 0x0A,
            let last = letterBox(text.rangeOfComposedCharacterSequence(at: offset - 1)),
            abs(last.midY - caret.midY) < caret.height, last.midX > caret.midX
        {
            block.origin.x = caret.minX + 0.5 - blockWidth
        }
        return block
    }

    /// Where [range]'s letters are drawn, in the view: the union of their
    /// segments on the line; nil off the laid out text.
    func letterBox(_ range: NSRange) -> NSRect? {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
            let from = content.location(content.documentRange.location, offsetBy: range.location),
            let to = content.location(from, offsetBy: range.length),
            let textRange = NSTextRange(location: from, end: to)
        else { return nil }
        layout.ensureLayout(for: textRange)
        var box: NSRect?
        layout.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
            box = box.map { $0.union(frame) } ?? frame
            return true
        }
        return box?.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        var rect = invalidRect
        if vimActive { rect.size.width += blockWidth }
        super.setNeedsDisplay(rect, avoidAdditionalLayout: flag)
    }

    static func scrollableNoteView() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSPalette.background
        _ = NoteTextView.viewportHook
        let view = NoteTextView(usingTextLayoutManager: true)
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.usesFindBar = true
        // Apple Intelligence's Writing Tools rewrite in place, as plain text:
        // the note is markdown source, and rich text would not survive a save.
        view.writingToolsBehavior = .complete
        view.allowedWritingToolsResultOptions = [.plainText]
        view.isIncrementalSearchingEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        view.drawsBackground = true
        view.backgroundColor = NSPalette.background
        // NoteTextView draws its own caret, at the letters' height.
        view.insertionPointColor = .clear
        view.selectedTextAttributes = [.backgroundColor: NSPalette.selection]
        view.textContainerInset = NSSize(width: 40, height: 28)
        scroll.documentView = view
        return scroll
    }

    /// A readable line length: the text keeps to `appearance.text_width`
    /// em in a wide window.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitMargins()
    }

    /// The margins for the view's width now, and the settings now.
    func fitMargins() {
        let settings = AppSettings.shared
        let side = Self.sideMargin(width: bounds.width, textSize: settings.textSize, textWidth: settings.textWidth)
        if abs(textContainerInset.width - side) > 1 { textContainerInset = NSSize(width: side, height: 28) }
    }

    /// Each side's margin in a view [width] wide: what the measure of
    /// [textWidth] em leaves, and at least 32 points -- 16 in a narrow pane
    /// (a split, a small window), where the room is worth more than the
    /// air. The reader's CSS keeps the same rule (`#note`).
    static func sideMargin(width: CGFloat, textSize: Int, textWidth: Int) -> CGFloat {
        let least: CGFloat = width < narrowPane ? 16 : 32
        guard textWidth > 0 else { return least }
        return max(least, (width - CGFloat(textSize * textWidth)) / 2)
    }

    /// Narrower than this, a pane has the small margins, in the editor and the reader.
    static let narrowPane: CGFloat = 720
}
