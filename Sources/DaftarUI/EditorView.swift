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
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return container
    }

    func updateNSView(_ container: EditorContainer, context: Context) {
        let controller = context.coordinator
        controller.onExtract = onExtract
        controller.onCursor = onCursor
        if controller.path != path {
            controller.saveNow()
            controller.load(path)
        } else {
            controller.followDisk()
        }
        controller.applyTextSize()
        controller.followVimSetting()
    }

    static func dismantleNSView(_ container: EditorContainer, coordinator: EditorController) {
        coordinator.saveNow()
        coordinator.stopVim()
        coordinator.store.flushers[ObjectIdentifier(coordinator)] = nil
        coordinator.store.followers[ObjectIdentifier(coordinator)] = nil
    }
}

@MainActor
final class EditorController: NSObject, NSTextStorageDelegate, NSTextViewDelegate {
    let store: VaultStore
    weak var view: NoteTextView?
    weak var container: EditorContainer?
    private(set) var path: String?
    /// Neovim, in Neovim mode: it owns the buffer and writes the file.
    private(set) var session: NeovimSession?
    /// What the file said when it was last read or written.
    private var saved = ""
    private var saveTask: Task<Void, Never>?
    private var seenRevision = -1
    private var fontKey = ""
    /// The note's block delimiters in order: fences, `$$`, `%%` and `---`
    /// lines. An edit that changes them restyles the rest of the note; any
    /// other edit restyles its own lines only.
    private var structure: [String] = []
    /// The text is being replaced whole, and styled after.
    private var replacing = false
    private var styling: Task<Void, Never>?
    private var shownMode = ""

    var onExtract: ((String, @escaping (String) -> Void) -> Void)?

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
    /// to undo. Neovim owns its buffer, so there the file is sorted and
    /// Neovim reads it again.
    func sortTasks() {
        guard let view, let path else { return }
        if session != nil {
            saveNow()
            if !store.sortTasks(path) { store.notice = "The tasks are in order already." }
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
        seenRevision = store.revision
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
        if store.settings.vimMode { startVim() }
    }

    // MARK: Neovim mode

    func followVimSetting() {
        if store.settings.vimMode, session == nil, path != nil { startVim() }
        if !store.settings.vimMode, session != nil {
            stopVim()
            if let path { load(path) }
        }
    }

    private func startVim() {
        guard let path, let root = store.root, let view else { return }
        saveNow()
        guard let session = NeovimSession(path: path, root: root, view: view, settings: store.settings) else {
            store.notice = "Neovim mode is on, but there is no nvim. Install it with `brew install neovim`, or set `nvim` in the config file."
            return
        }
        self.session = session
        view.vim = session
        view.allowsUndo = false
        // Neovim owns the buffer: a rewrite must come through it, not around it.
        view.writingToolsBehavior = .none
        session.onChange = { [weak self] in self?.showStatus() }
        showStatus()
        Task { await session.start() }
    }

    func stopVim() {
        guard let session else { return }
        self.session = nil
        view?.vim = nil
        view?.allowsUndo = true
        view?.writingToolsBehavior = .complete
        container?.setStatus(nil, mode: nil)
        Task { await session.stop() }
    }

    private func showStatus() {
        updateCounts()
        guard let session else { return container?.setStatus(nil, mode: nil) ?? () }
        switch session.state {
        case .failed(let message): container?.setStatus(message, mode: "NEOVIM")
        case .ended: container?.setStatus("Neovim ended. Open the note again to start it.", mode: "NEOVIM")
        case .starting: container?.setStatus("Starting Neovim…", mode: "NEOVIM")
        case .running: container?.setStatus(session.status, mode: session.modeName)
        }
        // The block cursor and the bar differ: the cursor's line is drawn
        // again when the mode changes, not the whole page at every key.
        if session.modeName != shownMode {
            shownMode = session.modeName
            view?.redrawCursorLine()
        }
    }

    /// The file changed on disk. A change this editor wrote is already here;
    /// any other is taken when there is no unsaved typing, and kept out when
    /// there is, so nothing typed is lost.
    func followDisk() {
        guard let path, let view, store.revision != seenRevision else { return }
        seenRevision = store.revision
        if let session {
            // Neovim wrote it (the view already says so), or someone else
            // did, and Neovim reads it again.
            if store.lastChanged.contains(path), store.text(of: path) != view.string { session.checkDisk() }
            return
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
            self.path = nil
        }
    }

    /// The text on disk, in place of a view with nothing unsaved.
    private func take(_ disk: String) {
        guard let view else { return }
        let selection = view.selectedRange()
        saved = disk
        view.string = disk
        restyle(all: true)
        view.setSelectedRange(NSRange(location: min(selection.location, (disk as NSString).length), length: 0))
    }

    func applyTextSize() {
        let settings = store.settings
        let key = "\(settings.textSize)|\(settings.font)|\(settings.codeFont)"
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
            let location = min(view.selectedRange().location, (view.string as NSString).length)
            let before = (view.string as NSString).substring(to: location)
            self.onCursor?(before.utf8.reduce(0) { $1 == 10 ? $0 + 1 : $0 })
        }
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
        updateCounts()
        // The tint of the cursor's line moves with it: the two lines are drawn again, not the page.
        view?.cursorLineMoved()
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
        if let session {
            session.save()
            return
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

    // MARK: Styling

    nonisolated func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        // The text view edits its storage on the main thread only.
        nonisolated(unsafe) let textStorage = textStorage
        MainActor.assumeIsolated {
            guard !replacing else { return }
            let text = textStorage.string as NSString
            let lines = text.lineRange(for: editedRange)
            // A fence, a comment or the front matter that came or went
            // changes the lines after it too; any other edit, only its own.
            let now = Self.structure(of: text)
            let rest = now != structure
            structure = now
            style(textStorage, range: rest ? NSRange(location: lines.location, length: text.length - lines.location) : lines)
        }
    }

    func restyle(all: Bool) {
        guard let storage = view?.textStorage else { return }
        styling?.cancel()
        structure = Self.structure(of: storage.string as NSString)
        storage.beginEditing()
        style(storage, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        view?.typingAttributes = base
    }

    /// The first screens at once, the rest a part at a time between frames:
    /// a long note opens without a pause, and its end is styled a moment later.
    func restyleProgressively() {
        guard let storage = view?.textStorage else { return }
        styling?.cancel()
        structure = Self.structure(of: storage.string as NSString)
        view?.typingAttributes = base
        let part = 12_000
        func next(after start: Int) -> NSRange? {
            let length = storage.length
            guard start < length else { return nil }
            let text = storage.string as NSString
            let end = NSMaxRange(text.paragraphRange(for: NSRange(location: min(start + part, length - 1), length: 0)))
            return NSRange(location: start, length: end - start)
        }
        guard let first = next(after: 0) else { return style(storage, range: NSRange(location: 0, length: 0)) }
        style(storage, range: first)
        var done = NSMaxRange(first)
        guard done < storage.length else { return }
        styling = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1))
                guard !Task.isCancelled, let storage = self.view?.textStorage, let range = next(after: done) else { return }
                storage.beginEditing()
                self.style(storage, range: range)
                storage.endEditing()
                done = NSMaxRange(range)
            }
        }
    }

    /// The lines that open or close a block, as written. It runs on every
    /// key, so it looks at each line's first letters, and finds `$$` and
    /// `%%` with one search each over the whole text.
    static func structure(of text: NSString) -> [String] {
        let length = text.length
        var marks: [(Int, String)] = []
        for needle in ["$$", "%%"] {
            var from = 0
            while from < length {
                let found = text.range(of: needle, options: .literal, range: NSRange(location: from, length: length - from))
                guard found.location != NSNotFound else { break }
                let line = text.lineRange(for: found)
                marks.append((line.location, text.substring(with: line)))
                from = NSMaxRange(line)
            }
        }
        var start = 0
        while start < length {
            var end = 0, contents = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contents, for: NSRange(location: start, length: 0))
            var at = start
            while at < contents, [32, 9, 62].contains(text.character(at: at)) { at += 1 }
            if at < contents {
                let first = text.character(at: at)
                // ` ~ -
                if first == 96 || first == 126 || first == 45 {
                    let rest = text.substring(with: NSRange(location: at, length: contents - at))
                    if rest.hasPrefix("```") || rest.hasPrefix("~~~") {
                        marks.append((start, rest))
                    } else if rest.hasPrefix("---"), rest.allSatisfy({ $0 == "-" || $0 == " " }) {
                        marks.append((start, "---"))
                    }
                }
            }
            start = end
        }
        // In the order of the lines; where they are does not count, so a
        // new line above a fence keeps the structure as it was.
        return marks.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private var fontSize: CGFloat { CGFloat(store.settings.textSize) }

    var base: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        // Obsidian's line height, 1.6.
        paragraph.lineHeightMultiple = 1.6
        paragraph.paragraphSpacing = fontSize * 0.2
        // Each paragraph takes the direction of its first strong letter.
        paragraph.baseWritingDirection = .natural
        return [.font: Fonts.text(size: fontSize), .foregroundColor: NSPalette.text, .paragraphStyle: paragraph]
    }

    private func style(_ storage: NSTextStorage, range: NSRange) {
        guard range.length > 0 || storage.length == 0 else { return }
        storage.setAttributes(base, range: range)
        let mono = Fonts.code(size: fontSize * 0.86)
        let text = storage.string as NSString
        // A highlight goes on top of bold and italic, so its text colour wins
        // and they keep their weight and slant; the marks go on last and dim.
        func rank(_ kind: MarkdownHighlighter.Kind) -> Int {
            switch kind {
            case .highlight: 1
            case .markup, .blockId: 2
            default: 0
            }
        }
        let spans = MarkdownHighlighter.spans(in: text, range: range).enumerated()
            .sorted { (rank($0.element.kind), $0.offset) < (rank($1.element.kind), $1.offset) }.map(\.element)
        let highlights = spans.filter { $0.kind == .highlight }.map(\.range)
        for span in spans {
            let r = span.range
            guard NSMaxRange(r) <= storage.length else { continue }
            switch span.kind {
            case .heading(let level):
                // Cupertino's sizes and weights: light large headings, medium small ones.
                let scale: [CGFloat] = [1.75, 1.5, 1.25, 1.0, 1.0, 0.875]
                storage.addAttributes([
                    .font: Fonts.text(size: fontSize * scale[min(level, 6) - 1], weight: level <= 3 ? .regular : .medium),
                    .foregroundColor: NSPalette.heading(level),
                ], range: r)
            case .markup, .blockId:
                // On a highlight the marks dim in the highlight's own text colour.
                let marked = highlights.contains { NSIntersectionRange($0, r).length == r.length }
                storage.addAttribute(.foregroundColor, value: marked ? NSPalette.markOnHighlight : NSPalette.faint, range: r)
            case .bold:
                storage.addAttributes([.font: Fonts.text(size: fontSize, weight: .bold), .foregroundColor: NSPalette.strong], range: r)
            case .italic:
                storage.addAttributes([.font: Fonts.text(size: fontSize, italic: true), .foregroundColor: NSPalette.italic], range: r)
            case .strike:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            case .highlight:
                // `==🔴 text==`: the circle picks the colour, as in Obsidian.
                let inner = text.substring(with: r).dropFirst(2)
                let color = NSPalette.highlightColor(inner.unicodeScalars.first.map { String($0) } ?? "")
                storage.addAttributes([.backgroundColor: NSPalette.named(color, alpha: 0.45), .foregroundColor: NSPalette.text], range: r)
            case .code:
                storage.addAttributes([.font: mono, .foregroundColor: NSPalette.raw, .backgroundColor: NSPalette.panel], range: r)
            case .codeBlock:
                storage.addAttributes([.font: mono, .backgroundColor: NSPalette.panel], range: r)
            case .fence:
                // The fence line in its language's colour, as the reader's label.
                let language = text.substring(with: r).trimmingCharacters(in: CharacterSet(charactersIn: "`~> \t\n"))
                    .split(separator: " ").first.map(String.init) ?? ""
                let color = NSPalette.named(NSPalette.languageColor(language))
                storage.addAttributes([.font: mono, .foregroundColor: color, .backgroundColor: NSPalette.panel], range: r)
            case .frontMatter:
                storage.addAttributes([.font: mono, .foregroundColor: NSPalette.muted], range: r)
            case .link:
                storage.addAttributes([
                    .foregroundColor: NSPalette.link, .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: NSPalette.named("aqua", alpha: 0.4),
                ], range: r)
            case .embed:
                storage.addAttributes([
                    .foregroundColor: NSPalette.pink, .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: NSPalette.named("pink", alpha: 0.4),
                ], range: r)
                embedImage(text.substring(with: r), line: text.lineRange(for: r), in: storage)
            case .url:
                storage.addAttributes([.foregroundColor: NSPalette.link.withAlphaComponent(0.7)], range: r)
            case .tag:
                // The same colour per tag as the reader's pills.
                let name = NSPalette.tagColor(String(text.substring(with: r).drop { $0 == "#" }))
                storage.addAttributes([
                    .foregroundColor: NSPalette.named(name), .backgroundColor: NSPalette.named(name, alpha: 0.16),
                ], range: r)
            case .taskOpen, .taskOther:
                storage.addAttributes([.font: mono, .foregroundColor: NSPalette.accent], range: r)
            case .taskDone, .taskCancelled:
                storage.addAttributes([.foregroundColor: NSPalette.faint, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: r)
            case .listMarker:
                // Each level of a list has its own colour, as in the reader.
                let line = text.lineRange(for: r)
                let before = text.substring(with: NSRange(location: line.location, length: r.location - line.location))
                let indent = before + text.substring(with: r).prefix { $0 == " " || $0 == "\t" }
                let depth = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : $1 == " " ? 1 : 0) } / 4
                let colors = ["orange", "aqua", "pink", "chartreuse"]
                storage.addAttributes([
                    .foregroundColor: NSPalette.named(colors[depth % colors.count]),
                    .font: Fonts.text(size: fontSize, weight: .bold),
                ], range: r)
            case .quote:
                storage.addAttributes([.foregroundColor: NSPalette.quote, .backgroundColor: NSPalette.named("orange", alpha: 0.07)], range: r)
            case .calloutTitle:
                let title = text.substring(with: r)
                let kind = title.firstMatch(of: /\[!([A-Za-z-]+)\]/).map { String($0.1) } ?? "note"
                let color = NSPalette.calloutColor(kind)
                storage.addAttributes([
                    .font: Fonts.text(size: fontSize, weight: .bold), .foregroundColor: NSPalette.named(color),
                    .backgroundColor: NSPalette.named(color, alpha: 0.12),
                ], range: r)
            case .comment, .rule:
                storage.addAttribute(.foregroundColor, value: NSPalette.faint, range: r)
            case .math:
                storage.addAttributes([.font: mono, .foregroundColor: NSPalette.purple, .backgroundColor: NSPalette.named("purple", alpha: 0.08)], range: r)
            case .metadata:
                storage.addAttributes([.foregroundColor: NSPalette.muted, .font: Fonts.text(size: fontSize * 0.85)], range: r)
            }
        }
        if store.settings.livePreview { hideMarks(spans, in: storage) }
    }

    // MARK: Live preview

    /// The lines the selection is on, where every mark shows.
    private var revealed = NSRange(location: 0, length: 0)
    /// Next to nothing: a mark away from the cursor takes no room.
    /// The emoji that give a highlight its colour.
    private static let swatches: Set<Character> = ["🔴", "🟠", "🟡", "🟢", "🔵", "🟣"]
    private static let hidden: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear]

    /// Away from the cursor's lines the marks go -- `**`, `==`, `[[` and a
    /// link's target, a heading's `#` -- so the note reads as it will look.
    /// A quote's `>` and a callout's type stay: they say what the line is.
    private func hideMarks(_ spans: [MarkdownHighlighter.Span], in storage: NSTextStorage) {
        let text = storage.string as NSString
        // The cursor's line, or the lines a selection touches.
        let shown = { (line: NSRange) in
            self.revealed.length > 0 ? NSIntersectionRange(line, self.revealed).length > 0 : NSLocationInRange(self.revealed.location, line)
        }
        for (index, span) in spans.enumerated() where NSMaxRange(span.range) <= storage.length {
            let line = text.lineRange(for: span.range)
            guard !shown(line) else { continue }
            switch span.kind {
            case .markup:
                let mark = text.substring(with: span.range)
                if mark.hasPrefix(">") || mark.hasPrefix("[!") { continue }
                storage.addAttributes(Self.hidden, range: span.range)
            case .highlight:
                // `==🔴 text==`: the colour's emoji goes too, as in the reader.
                let inner = NSRange(location: span.range.location + 2, length: max(0, span.range.length - 4))
                let body = text.substring(with: inner)
                guard let first = body.first, Self.swatches.contains(first) else { continue }
                let width = (String(first) as NSString).length + (body.dropFirst().first == " " ? 1 : 0)
                storage.addAttributes(Self.hidden, range: NSRange(location: inner.location, length: width))
            case .link:
                // `[label](target)`: the brackets and the target go, the label reads.
                guard index + 1 < spans.count, spans[index + 1].kind == .url, spans[index + 1].range.location == NSMaxRange(span.range),
                    span.range.length >= 2 else { continue }
                storage.addAttributes(Self.hidden, range: NSRange(location: span.range.location, length: 1))
                storage.addAttributes(Self.hidden, range: NSRange(location: NSMaxRange(span.range) - 1, length: 1))
                storage.addAttributes(Self.hidden, range: spans[index + 1].range)
            default:
                continue
            }
        }
    }

    /// The selection moved to other lines: the old ones hide their marks
    /// again and the new ones show them.
    func revealSelection() {
        guard store.settings.livePreview, let view, let storage = view.textStorage else { return }
        let text = storage.string as NSString
        let now = text.lineRange(for: view.selectedRange())
        guard now != revealed else { return }
        let old = revealed
        revealed = now
        storage.beginEditing()
        for range in [old, now] where NSMaxRange(range) <= storage.length {
            style(storage, range: text.lineRange(for: range))
        }
        storage.endEditing()
    }

    // MARK: Images

    private var images: [String: NSImage] = [:]

    /// `![[picture.png]]` (or `![[picture.png|300]]`): the line keeps room
    /// for the picture under it, and `ImageLayoutFragment` draws it there.
    private func embedImage(_ embed: String, line: NSRange, in storage: NSTextStorage) {
        guard let path, embed.hasPrefix("![["), embed.hasSuffix("]]") else { return }
        let link = Wikilink(String(embed.dropFirst(3).dropLast(2)))
        let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "tiff", "svg"]
        guard let target = store.index.resolve(link.target, from: path),
            extensions.contains((target as NSString).pathExtension.lowercased()), let url = store.url(of: target)
        else { return }
        let image = images[target] ?? NSImage(contentsOf: url)
        guard let image, image.size.width > 0 else { return }
        images[target] = image
        let available = min(CGFloat(store.settings.textSize) * 44, max(200, (view?.textContainer?.size.width ?? 600) - 20))
        var width = min(image.size.width, available)
        if let alias = link.alias, let requested = Double(alias.split(separator: "x").first ?? "") { width = min(CGFloat(requested), available) }
        let height = min(width * image.size.height / image.size.width, 480)
        width = height * image.size.width / image.size.height
        let size = NSSize(width: width, height: height)

        let paragraph = ((storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        paragraph.paragraphSpacing = height + EmbeddedImage.gap * 2
        storage.addAttributes([.paragraphStyle: paragraph, .daftarImage: EmbeddedImage(image: image, size: size)], range: line)
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
    weak var vim: NeovimSession?
    private var vimActive: Bool { vim.map { $0.state == .running || $0.state == .starting } ?? false }

    // MARK: Neovim mode

    /// An edit Neovim made, applied as it is: no undo, no autosave.
    func applyRemote(_ range: NSRange, _ text: String) {
        guard let storage = textStorage, NSMaxRange(range) <= storage.length else { return }
        storage.replaceCharacters(in: range, with: text)
    }

    func showSelection(_ range: NSRange) {
        let length = (string as NSString).length
        let clamped = NSRange(location: min(range.location, length), length: min(range.length, length - min(range.location, length)))
        setSelectedRange(clamped)
        if vimActive { scrollSoon() } else { scrollRangeToVisible(clamped) }
        updateInsertionPointStateAndRestartTimer(true)
    }

    /// [offset]'s line in the middle of the view, at once.
    func center(_ offset: Int) {
        guard let scroll = enclosingScrollView, let line = lineRect(at: offset) else { return scrollRangeToVisible(NSRange(location: offset, length: 0)) }
        let clip = scroll.contentView
        let y = max(0, min(line.midY - clip.bounds.height / 2, max(0, frame.height - clip.bounds.height)))
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    /// Visual block mode: a range on each row, and the cursor's row in view.
    func showSelections(_ ranges: [NSRange], cursor: Int) {
        let length = (string as NSString).length
        let clamped = ranges.map { NSRange(location: min($0.location, length), length: min($0.length, length - min($0.location, length))) }
        guard !clamped.isEmpty else { return }
        setSelectedRanges(clamped.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
        scrollSoon()
    }

    // MARK: Scrolling with Neovim

    /// Where Neovim's window starts, when it moved since the last scroll.
    private var neovimTop: Int?
    private var scrollPending = false

    /// Neovim's window moved: `zz`, `<C-e>`, `<C-d>`.
    func follow(top offset: Int) {
        neovimTop = offset
        scrollSoon()
    }

    /// The cursor and the window move in the same Neovim update, as two
    /// messages: one scroll for both, a moment later, not two jumps.
    private func scrollSoon() {
        guard !scrollPending else { return }
        scrollPending = true
        DispatchQueue.main.async { [weak self] in
            self?.scrollPending = false
            self?.scroll()
        }
    }

    private func scroll() {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let height = clip.bounds.height
        var y = clip.bounds.origin.y
        if let top = neovimTop, let line = lineRect(at: top) { y = line.minY - textContainerOrigin.y }
        neovimTop = nil
        // Whatever Neovim's window says, the cursor stays on screen: the view
        // fits fewer lines than Neovim thinks, under a heading.
        if let cursor = lineRect(at: selectedRange().location) {
            let margin = min(cursor.height * 2, height / 4)
            if cursor.minY - margin < y { y = cursor.minY - margin } else if cursor.maxY + margin > y + height { y = cursor.maxY + margin - height }
        }
        y = max(0, min(y, max(0, frame.height - height)))
        guard abs(y - clip.bounds.origin.y) > 0.5 else { return }
        let target = NSPoint(x: clip.bounds.origin.x, y: y)
        // A short glide within two screens; a jump, as `G`, goes at once.
        // A window not on screen runs no animation: it would never get there.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || abs(y - clip.bounds.origin.y) > height * 2 || window?.isVisible != true {
            clip.setBoundsOrigin(target)
            scroll.reflectScrolledClipView(clip)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            clip.animator().setBoundsOrigin(target)
        } completionHandler: {
            scroll.reflectScrolledClipView(clip)
        }
    }

    /// The view never edits its own text while Neovim owns it.
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        vimActive ? false : super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override func keyDown(with event: NSEvent) {
        guard let vim, vimActive else {
            // ⌥↑ and ⌥↓ move the line, or the selected lines.
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if flags == .option, event.keyCode == 126 || event.keyCode == 125 { return moveLines(up: event.keyCode == 126) }
            // ⇧⌥↑ and ⇧⌥↓ copy them above or below.
            if flags == [.option, .shift], event.keyCode == 126 || event.keyCode == 125 { return duplicateLines(up: event.keyCode == 126) }
            return super.keyDown(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: VimKeys.Modifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.command) { modifiers.insert(.command) }
        let raw = event.charactersIgnoringModifiers ?? ""
        if flags.contains(.control) || flags.contains(.command) || VimKeys.isSpecial(raw) {
            if let keys = VimKeys.notation(characters: raw, modifiers: modifiers) { vim.input(keys) }
            return
        }
        // Text goes through the input system, so an input method and the
        // Persian layout type what they type; `insertText` sends it.
        interpretKeyEvents([event])
    }

    override func doCommand(by selector: Selector) {
        if vimActive { return }
        super.doCommand(by: selector)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if vimActive { vim?.moveCursor(to: selectedRange().location) }
    }

    /// Leaving the editor -- for the other pane, a sheet, the sidebar --
    /// saves the note, and coming back takes what was saved since: the same
    /// note in the other pane of a split shows each edit when it gets the focus.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { controller?.saveNow() }
        return resigned
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { controller?.catchUp() }
        return became
    }

    private var tintedLine: NSRect?

    func redrawCursorLine() {
        if let line = cursorLineRect() { setNeedsDisplay(line.insetBy(dx: 0, dy: -1)) }
    }

    /// The cursor's line before and after a move, drawn again.
    func cursorLineMoved() {
        let now = selectedRange().length == 0 ? cursorLineRect() : nil
        guard now != tintedLine else { return }
        if let tintedLine { setNeedsDisplay(tintedLine.insetBy(dx: 0, dy: -1)) }
        if let now { setNeedsDisplay(now.insetBy(dx: 0, dy: -1)) }
        tintedLine = now
    }

    /// The line that holds the cursor, tinted, with a thin accent bar.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard selectedRange().length == 0, let line = cursorLineRect() else { return }
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
    private var blockWidth: CGFloat {
        let font = self.font ?? NSFont.systemFont(ofSize: 14)
        return ("m" as NSString).size(withAttributes: [.font: font]).width
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard vimActive, vim?.isNormal == true else { return super.drawInsertionPoint(in: rect, color: color, turnedOn: flag) }
        var block = rect
        block.size.width = blockWidth
        if flag {
            color.withAlphaComponent(0.45).setFill()
            block.fill(using: .sourceOver)
        } else {
            setNeedsDisplay(block, avoidAdditionalLayout: true)
        }
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
        view.insertionPointColor = NSPalette.accent
        view.selectedTextAttributes = [.backgroundColor: NSPalette.selection]
        view.textContainerInset = NSSize(width: 40, height: 28)
        scroll.documentView = view
        return scroll
    }

    /// A readable line length: the text keeps to about 46em in a wide window.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let measure = CGFloat(AppSettings.shared.textSize) * 46
        let side = max(32, (newSize.width - measure) / 2)
        if abs(textContainerInset.width - side) > 1 { textContainerInset = NSSize(width: side, height: 28) }
    }

    // MARK: Lines

    private var ns: NSString { string as NSString }

    private func currentLineRange() -> NSRange {
        let range = ns.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        var content = range
        while content.length > 0, let scalar = Unicode.Scalar(ns.character(at: NSMaxRange(content) - 1)),
            CharacterSet.newlines.contains(scalar)
        {
            content.length -= 1
        }
        return content
    }

    private func replace(_ range: NSRange, with text: String, select: NSRange? = nil) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        if let select { setSelectedRange(select) }
    }

    private func linesInSelection() -> NSRange { ns.lineRange(for: selectedRange()) }

    // MARK: Keys

    /// Return continues a list, and on an empty item ends it.
    override func insertNewline(_ sender: Any?) {
        let line = currentLineRange()
        let cursor = selectedRange()
        // Return at the end of a table row: a new row, the cursor in its first cell.
        if cursor.length == 0, cursor.location == NSMaxRange(line), let table = tableBlock(), !MarkdownTable.cells(ns.substring(with: line)).allSatisfy(\.isEmpty) {
            let rows = Array(table.lines[...table.row])
            let formatted = MarkdownTable.newRow(rows)
            let replaced = NSRange(location: table.range.location, length: NSMaxRange(line) - table.range.location)
            let text = formatted.joined(separator: "\n")
            let start = replaced.location + (text as NSString).length - (formatted.last! as NSString).length
            return replace(replaced, with: text, select: NSRange(location: start + MarkdownTable.cellStart(formatted.last!, column: 0), length: 0))
        }
        guard cursor.length == 0, cursor.location == NSMaxRange(line) else { return super.insertNewline(sender) }
        switch EditorCommands.onReturn(after: ns.substring(with: line)) {
        case .insert(let text):
            insertText(text, replacementRange: cursor)
        case .endList:
            replace(line, with: "", select: NSRange(location: line.location, length: 0))
        case nil:
            super.insertNewline(sender)
        }
    }

    /// Tab and ⇧Tab move list items in and out by four spaces.
    override func insertTab(_ sender: Any?) {
        if selectedRange().length == 0, tableTab(back: false) { return }
        let lines = linesInSelection()
        let text = ns.substring(with: lines)
        guard text.split(separator: "\n").allSatisfy({ EditorCommands.isListItem(String($0)) }), !text.isEmpty else {
            return insertText(EditorCommands.indentUnit, replacementRange: selectedRange())
        }
        shift(lines) { EditorCommands.indent($0) }
    }

    override func insertBacktab(_ sender: Any?) {
        if selectedRange().length == 0, tableTab(back: true) { return }
        shift(linesInSelection()) { EditorCommands.outdent($0) }
    }

    // MARK: Tables

    /// The rows of the table the cursor is in: their range, their lines, and
    /// which of them holds the cursor.
    private func tableBlock() -> (range: NSRange, lines: [String], row: Int)? {
        let line = currentLineRange()
        guard MarkdownTable.isRow(ns.substring(with: line)) else { return nil }
        let isRow = { (range: NSRange) in MarkdownTable.isRow(self.ns.substring(with: range)) }
        var start = ns.lineRange(for: line).location, end = NSMaxRange(line)
        while start > 0 {
            let above = ns.lineRange(for: NSRange(location: start - 1, length: 0))
            guard isRow(above) else { break }
            start = above.location
        }
        var next = NSMaxRange(ns.lineRange(for: line))
        while next < ns.length {
            let below = ns.lineRange(for: NSRange(location: next, length: 0))
            guard isRow(below) else { break }
            // The row without its newline.
            end = NSMaxRange(below) - (ns.character(at: NSMaxRange(below) - 1) == 10 ? 1 : 0)
            next = NSMaxRange(below)
        }
        let range = NSRange(location: start, length: end - start)
        let lines = ns.substring(with: range).components(separatedBy: "\n")
        let row = ns.substring(with: NSRange(location: start, length: line.location - start)).filter { $0 == "\n" }.count
        return (range, lines, row)
    }

    /// Tab in a table: the next cell, the columns lined up.
    private func tableTab(back: Bool) -> Bool {
        guard let table = tableBlock() else { return false }
        let line = currentLineRange()
        let column = MarkdownTable.column(at: selectedRange().location - line.location, in: ns.substring(with: line))
        let moved = MarkdownTable.tab(table.lines, row: table.row, column: column, back: back)
        var start = table.range.location
        for line in moved.lines[..<moved.row] { start += (line as NSString).length + 1 }
        replace(table.range, with: moved.lines.joined(separator: "\n"),
            select: NSRange(location: start + MarkdownTable.cellStart(moved.lines[moved.row], column: moved.column), length: 0))
        return true
    }

    // MARK: Moving lines

    private func moveLines(up: Bool) {
        guard let edit = EditorCommands.moveLines(in: ns, selection: selectedRange(), up: up) else { return NSSound.beep() }
        replace(edit.range, with: edit.text, select: edit.selection)
    }

    private func shift(_ lines: NSRange, _ change: (String) -> String) {
        let text = ns.substring(with: lines)
        let trailing = text.hasSuffix("\n")
        var parts = text.components(separatedBy: "\n")
        if trailing { parts.removeLast() }
        let changed = parts.map(change).joined(separator: "\n") + (trailing ? "\n" : "")
        let selection = selectedRange()
        replace(lines, with: changed)
        let delta = (changed as NSString).length - lines.length
        setSelectedRange(NSRange(location: max(lines.location, selection.location + (parts.count == 1 ? delta : 0)), length: parts.count == 1 ? selection.length : (changed as NSString).length))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, !vimActive else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            switch event.charactersIgnoringModifiers {
            case "\r": toggleTask(); return true
            case "b": wrap("**"); return true
            case "i": wrap("*"); return true
            case "k": insertLink(); return true
            default: break
            }
        }
        if flags == [.command, .shift] {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "h": wrap("=="); return true
            case "x": wrap("~~"); return true
            case "c": wrap("`"); return true
            case "k": deleteLines(); return true
            default: break
            }
        }
        // ⌥⌘1 to ⌥⌘6 make the line a heading, ⌥⌘0 plain text.
        if flags == [.command, .option], let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (0...6).contains(digit) {
            let line = currentLineRange()
            let text = ns.substring(with: line)
            let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
            let headed = EditorCommands.heading(body, level: digit)
            replace(NSRange(location: line.location, length: (body as NSString).length), with: headed,
                select: NSRange(location: line.location + (headed as NSString).length, length: 0))
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The selected lines again, above or below them; the copy is selected.
    private func duplicateLines(up: Bool) {
        let lines = linesInSelection()
        var text = ns.substring(with: lines)
        let selection = selectedRange()
        if !text.hasSuffix("\n") {
            // The last line: the copy needs its own line break.
            replace(NSRange(location: NSMaxRange(lines), length: 0), with: "\n" + text,
                select: NSRange(location: selection.location + (up ? 0 : (text as NSString).length + 1), length: selection.length))
            return
        }
        text = String(text)
        replace(NSRange(location: lines.location, length: 0), with: text,
            select: NSRange(location: selection.location + (up ? 0 : (text as NSString).length), length: selection.length))
    }

    /// ⇧⌘K: the selected lines go, and the cursor stays on the line after them.
    private func deleteLines() {
        var lines = linesInSelection()
        // The last line takes the line break before it.
        if NSMaxRange(lines) == ns.length, lines.location > 0, !ns.substring(with: lines).hasSuffix("\n") {
            lines = NSRange(location: lines.location - 1, length: lines.length + 1)
        }
        replace(lines, with: "", select: NSRange(location: min(lines.location, ns.length), length: 0))
    }

    /// ⌘↩: tick, open, or make a task of the line.
    private func toggleTask() {
        let line = currentLineRange()
        let lines = EditorCommands.toggleTask(ns.substring(with: line), today: .today())
        let text = lines.joined(separator: "\n")
        replace(line, with: text, select: NSRange(location: line.location + (lines[0] as NSString).length, length: 0))
    }

    /// Wraps the selection in a marker, or takes it off when it is there.
    private func wrap(_ marker: String) {
        let range = selectedRange()
        let selected = ns.substring(with: range)
        let width = (marker as NSString).length
        if selected.hasPrefix(marker), selected.hasSuffix(marker), selected.count >= 2 * marker.count {
            let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
            replace(range, with: inner, select: NSRange(location: range.location, length: (inner as NSString).length))
        } else {
            replace(range, with: marker + selected + marker, select: NSRange(location: range.location + width, length: range.length))
        }
    }

    /// ⌘K: `[[selection]]`, and the note completion when nothing is selected.
    private func insertLink() {
        let range = selectedRange()
        let selected = ns.substring(with: range)
        replace(range, with: "[[" + selected + "]]", select: NSRange(location: range.location + 2, length: range.length))
        if range.length == 0 { complete(nil) }
    }

    // MARK: `[[` completion

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if vimActive {
            let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
            vim?.input(VimKeys.escape(text))
            return
        }
        if let typed = string as? String, handlePair(typed, replacementRange: replacementRange) { return }
        super.insertText(string, replacementRange: replacementRange)
        if let typed = string as? String, typed == "/", EditorCommands.opensSlashMenu(in: ns, at: selectedRange().location) {
            let slash = selectedRange().location - 1
            // After the key is handled, so the slash is on screen under the menu.
            DispatchQueue.main.async { [weak self] in self?.showSlashMenu(at: slash) }
            return
        }
        if let typed = string as? String { completeAfterTyping(typed) }
        guard let typed = string as? String, typed == "[" else { return }
        let at = selectedRange().location
        if at >= 2, ns.substring(with: NSRange(location: at - 2, length: 2)) == "[[" {
            // Close the link at once, as Obsidian does, and offer notes.
            super.insertText("]]", replacementRange: NSRange(location: at, length: 0))
            setSelectedRange(NSRange(location: at, length: 0))
            complete(nil)
        }
    }

    @objc func extractSelection(_ sender: Any?) { controller?.extract() }

    @objc func sortTasks(_ sender: Any?) { controller?.sortTasks() }

    // MARK: Pairs

    /// What a mark wraps a selection in, as Obsidian does: `*`, `_`, `` ` ``,
    /// `~`, `=` and the brackets and quotes.
    private static let wrapping: [String: String] = ["*": "*", "_": "_", "`": "`", "~": "~", "=": "=", "(": ")", "[": "]", "{": "}", "\"": "\""]
    private static let closing: [String: String] = ["(": ")", "[": "]", "{": "}"]
    /// Where a closing bracket was put that the person did not type, so
    /// typing it steps over it.
    private var autoClosed: Int?

    /// A selection is wrapped; an opening bracket gets its closing one; a
    /// closing bracket typed where one was put steps over it. True when the
    /// key is handled here.
    private func handlePair(_ typed: String, replacementRange: NSRange) -> Bool {
        let selection = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        if selection.length > 0, let close = Self.wrapping[typed], !ns.substring(with: selection).contains("\n") {
            let inner = ns.substring(with: selection)
            replace(selection, with: typed + inner + close, select: NSRange(location: selection.location + 1, length: selection.length))
            return true
        }
        guard selection.length == 0 else { return false }
        let at = selection.location
        if let auto = autoClosed, auto == at, at < ns.length, ns.substring(with: NSRange(location: at, length: 1)) == typed, Self.closing.values.contains(typed) {
            autoClosed = nil
            setSelectedRange(NSRange(location: at + 1, length: 0))
            return true
        }
        // `[[`: the link's own closing, and the note completion.
        if typed == "[", at >= 1, at < ns.length, ns.substring(with: NSRange(location: at - 1, length: 2)) == "[]", autoClosed == at {
            replace(NSRange(location: at, length: 1), with: "[]]", select: NSRange(location: at + 1, length: 0))
            autoClosed = nil
            complete(nil)
            return true
        }
        guard let close = Self.closing[typed] else {
            // Text typed inside the pair moves its closing bracket on; the
            // cursor out of the pair forgets it.
            if let auto = autoClosed { autoClosed = at <= auto && !typed.contains("\n") ? auto + (typed as NSString).length : nil }
            return false
        }
        // Only before a space, the end of a line or another closing mark.
        let next = at < ns.length ? ns.substring(with: NSRange(location: at, length: 1)) : "\n"
        guard next == "\n" || next == " " || next == "\t" || Self.closing.values.contains(next) || next == "," || next == "." else { return false }
        replace(selection, with: typed + close, select: NSRange(location: at + 1, length: 0))
        autoClosed = at + 1
        return true
    }

    /// Backspace in an empty pair takes both.
    override func deleteBackward(_ sender: Any?) {
        let at = selectedRange()
        if !vimActive, at.length == 0, at.location >= 1, at.location < ns.length, autoClosed == at.location,
            let close = Self.closing[ns.substring(with: NSRange(location: at.location - 1, length: 1))],
            ns.substring(with: NSRange(location: at.location, length: 1)) == close
        {
            autoClosed = nil
            return replace(NSRange(location: at.location - 1, length: 2), with: "", select: NSRange(location: at.location - 1, length: 0))
        }
        if let auto = autoClosed { autoClosed = at.length == 0 && at.location <= auto && at.location > 0 ? auto - 1 : nil }
        super.deleteBackward(sender)
    }

    // MARK: Slash commands

    /// The snippets under the `/` at [slash], each with its icon in its colour.
    func slashMenu(at slash: Int) -> NSMenu {
        let menu = NSMenu()
        let time = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        var group = ""
        for snippet in EditorCommands.slashCommands(today: .today(), time: time) {
            if snippet.group != group {
                menu.addItem(NSMenuItem.sectionHeader(title: snippet.group))
                group = snippet.group
            }
            let item = NSMenuItem(title: snippet.title, action: #selector(chooseSlash(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = SlashChoice(snippet: snippet, slash: slash)
            let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                .applying(.init(paletteColors: [NSPalette.named(snippet.color)]))
            item.image = NSImage(systemSymbolName: snippet.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            menu.addItem(item)
        }
        return menu
    }

    private func showSlashMenu(at slash: Int) {
        guard slash < ns.length, ns.character(at: slash) == 0x2F, window != nil else { return }
        let rect = firstRect(forCharacterRange: NSRange(location: slash, length: 1), actualRange: nil)
        slashMenu(at: slash).popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.minY - 4), in: nil)
    }

    @objc private func chooseSlash(_ item: NSMenuItem) {
        guard let choice = item.representedObject as? SlashChoice else { return }
        applySlash(choice.snippet, slashAt: choice.slash)
    }

    /// Puts [snippet] in place of the `/` at [slash], as one step to undo.
    func applySlash(_ snippet: Snippet, slashAt slash: Int) {
        guard slash < ns.length, ns.character(at: slash) == 0x2F else { return }
        let edit = EditorCommands.apply(snippet, slashAt: slash, in: ns)
        guard shouldChangeText(in: edit.range, replacementString: edit.text) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.text)
        didChangeText()
        setSelectedRange(NSRange(location: edit.cursor, length: 0))
        if snippet.id == "link" || snippet.id == "embed" { complete(nil) }
    }

    override var rangeForUserCompletion: NSRange {
        completionRange() ?? super.rangeForUserCompletion
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        // A row shows a label; what goes in is the row's own text.
        super.insertCompletion(completion.insert(for: word), forPartialWordRange: charRange, movement: movement, isFinal: flag)
        if flag { finishCompletion(word, movement: movement) }
    }

    // MARK: Dropping files

    /// A note or a file dragged from the sidebar becomes a link where it is
    /// dropped; a file from outside the vault is copied into the attachment
    /// folder first. Pictures, sound, video and PDFs are embedded.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !vimActive, let controller, controller.store.root != nil else { return super.performDragOperation(sender) }
        let board = sender.draggingPasteboard
        var paths: [String] = []
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for url in urls {
                if let path = controller.store.vaultPath(of: url) {
                    paths.append(path)
                } else if let copied = controller.importAttachment(url) {
                    paths.append(copied)
                }
            }
        } else if let text = board.string(forType: .string), controller.store.index.files.contains(text) {
            paths = [text]
        }
        guard !paths.isEmpty else { return super.performDragOperation(sender) }
        let at = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        setSelectedRange(NSRange(location: min(at, ns.length), length: 0))
        let links = paths.map { EditorCommands.link(to: $0, files: controller.store.index.files) }
        insertText(links.joined(separator: " "), replacementRange: selectedRange())
        window?.makeFirstResponder(self)
        return true
    }

    // MARK: Pasting an image

    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if vimActive, let text = board.string(forType: .string) {
            vim?.paste(text)
            return
        }
        // A web address pasted on selected words makes them a link to it.
        let selection = selectedRange()
        if selection.length > 0, let text = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
            EditorCommands.isWebAddress(text), !ns.substring(with: selection).contains("\n")
        {
            let label = ns.substring(with: selection)
            return replace(selection, with: "[\(label)](\(text))", select: NSRange(location: selection.location + (label as NSString).length + (text as NSString).length + 4, length: 0))
        }
        // A web page or a document pasted as rich text keeps its headings,
        // links and lists as Markdown. ⌥⇧⌘V pastes the plain text.
        if board.string(forType: .string) != nil, let html = board.string(forType: .html), let markdown = HTMLMarkdown.convert(html) {
            return replace(selection, with: markdown, select: NSRange(location: selection.location + (markdown as NSString).length, length: 0))
        }
        guard board.string(forType: .string) == nil, let controller, let root = controller.store.root,
            let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return super.paste(sender) }
        let folder = controller.attachmentFolder
        let name = EditorCommands.pastedImageName()
        let relative = folder.isEmpty ? name : folder + "/" + name
        let url = root.appending(path: relative)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            if vimActive { vim?.paste("![[\(name)]]") } else { insertText("![[\(name)]]", replacementRange: selectedRange()) }
        } catch {
            controller.store.notice = "The image could not be saved: \(error.localizedDescription)"
        }
    }
}

/// The editor and a bar under it: the words and characters of the note or
/// of the selection, and in Neovim mode the mode and the command line, as
/// Neovim's own status and command lines are.
final class EditorContainer: NSView {
    let scroll: NSScrollView
    private let bar = NSView()
    private let mode = NSTextField(labelWithString: "")
    private let message = NSTextField(labelWithString: "")
    private let counts = NSTextField(labelWithString: "")
    private var barHeight: NSLayoutConstraint!
    var onLayout: (() -> Void)?

    init(scroll: NSScrollView) {
        self.scroll = scroll
        super.init(frame: .zero)
        for view in [scroll, bar, mode, message, counts] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(scroll)
        addSubview(bar)
        bar.addSubview(mode)
        bar.addSubview(message)
        bar.addSubview(counts)
        counts.alignment = .right
        counts.setContentCompressionResistancePriority(.required, for: .horizontal)
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSPalette.panel.cgColor
        mode.font = Fonts.code(size: 11)
        mode.textColor = NSPalette.background
        mode.wantsLayer = true
        mode.layer?.cornerRadius = 4
        mode.alignment = .center
        message.font = Fonts.code(size: 12)
        message.textColor = NSPalette.text
        message.lineBreakMode = .byTruncatingTail
        barHeight = bar.heightAnchor.constraint(equalToConstant: 24)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            barHeight,
            mode.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            mode.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            mode.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            message.leadingAnchor.constraint(equalTo: mode.trailingAnchor, constant: 10),
            message.trailingAnchor.constraint(lessThanOrEqualTo: counts.leadingAnchor, constant: -12),
            message.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            counts.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            counts.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        mode.isHidden = true
    }

    /// "1,204 words · 6,880 characters", or "12 of 1,204 words" over a
    /// selection, the numbers in the accent colours.
    func setCounts(words: Int, characters: Int, selectedWords: Int?, selectedCharacters: Int?) {
        let number = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let label = NSFont.systemFont(ofSize: 11)
        let out = NSMutableAttributedString()
        func add(_ text: String, _ color: NSColor, _ font: NSFont) {
            out.append(NSAttributedString(string: text, attributes: [.foregroundColor: color, .font: font]))
        }
        func part(_ selected: Int?, _ total: Int, _ unit: String, _ color: NSColor) {
            if let selected {
                add(selected.formatted(), color, number)
                add(" of ", NSPalette.muted, label)
            }
            add(total.formatted(), selected == nil ? color : NSPalette.muted, number)
            add(" " + unit + (total == 1 ? "" : "s"), NSPalette.muted, label)
        }
        part(selectedWords, words, "word", NSPalette.accent)
        add("  ·  ", NSPalette.faint, label)
        part(selectedCharacters, characters, "character", NSPalette.link)
        counts.attributedStringValue = out
    }

    required init?(coder: NSCoder) { nil }

    /// Nil hides the mode: the editor is not in Neovim mode.
    func setStatus(_ text: String?, mode name: String?) {
        guard let name else {
            mode.isHidden = true
            message.stringValue = ""
            return
        }
        mode.isHidden = false
        mode.stringValue = " \(name) "
        let color: NSColor = switch name {
        case "INSERT": NSPalette.link
        case "VISUAL", "V-LINE", "V-BLOCK": NSPalette.purple
        case "REPLACE": NSPalette.red
        default: NSPalette.accent
        }
        mode.layer?.backgroundColor = color.cgColor
        message.stringValue = text ?? ""
    }

    override func layout() {
        super.layout()
        onLayout?()
    }

    /// A layer's colour is fixed when it is set: the bar takes the theme again.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bar.layer?.backgroundColor = NSPalette.panel.cgColor
        }
    }
}

/// A slash menu item's snippet and the slash it replaces.
final class SlashChoice: NSObject {
    let snippet: Snippet
    let slash: Int
    init(snippet: Snippet, slash: Int) {
        self.snippet = snippet
        self.slash = slash
    }
}
