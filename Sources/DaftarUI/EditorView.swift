import AppKit
import DaftarCore
import SwiftUI

/// The editor: the note's markdown source in a native text view, styled as
/// it is typed. The file on disk is the record; the editor saves to it a
/// moment after the typing stops, and when it is left.
struct EditorView: NSViewRepresentable {
    var path: String
    var store: VaultStore

    func makeCoordinator() -> EditorController { EditorController(store: store) }

    func makeNSView(context: Context) -> EditorContainer {
        let scroll = NoteTextView.scrollableNoteView()
        let view = scroll.documentView as! NoteTextView
        let container = EditorContainer(scroll: scroll)
        view.controller = context.coordinator
        context.coordinator.view = view
        context.coordinator.container = container
        container.onLayout = { [weak controller = context.coordinator] in controller?.session?.resize() }
        context.coordinator.load(path)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return container
    }

    func updateNSView(_ container: EditorContainer, context: Context) {
        let controller = context.coordinator
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

    init(store: VaultStore) {
        self.store = store
        super.init()
        store.flushers[ObjectIdentifier(self)] = { [weak self] in await self?.flush() }
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
        view.string = text
        restyle(all: true)
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
        session.onChange = { [weak self] in self?.showStatus() }
        showStatus()
        Task { await session.start() }
    }

    func stopVim() {
        guard let session else { return }
        self.session = nil
        view?.vim = nil
        view?.allowsUndo = true
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
        view?.needsDisplay = true
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
            let selection = view.selectedRange()
            saved = disk
            view.string = disk
            restyle(all: true)
            view.setSelectedRange(NSRange(location: min(selection.location, (disk as NSString).length), length: 0))
        } else {
            store.notice = "\(Vault.title(of: path)) changed on disk while you typed. Your text is kept; it is saved over the other change."
        }
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
            let text = view.string as NSString
            let selection = view.selectedRange()
            let words = Self.words(in: text, range: NSRange(location: 0, length: text.length))
            let selected = selection.length > 0 ? Self.words(in: text, range: selection) : nil
            self.container?.setCounts(
                words: words, characters: text.length, selectedWords: selected, selectedCharacters: selection.length > 0 ? selection.length : nil)
        }
    }

    static func words(in text: NSString, range: NSRange) -> Int {
        var count = 0
        text.enumerateSubstrings(in: range, options: [.byWords, .substringNotRequired]) { _, _, _, _ in count += 1 }
        return count
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateCounts()
        // The tint of the cursor's line moves with it.
        if let view { view.setNeedsDisplay(view.visibleRect) }
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
            let text = textStorage.string as NSString
            let lines = text.lineRange(for: editedRange)
            // A fence, a comment or the front matter changes the lines after
            // it too; anything else changes only its own lines.
            let edited = text.substring(with: lines)
            let all = ["```", "~~~", "%%", "$$", "---"].contains { edited.contains($0) } || lines.location == 0
            style(textStorage, range: all ? NSRange(location: 0, length: text.length) : lines)
        }
    }

    func restyle(all: Bool) {
        guard let storage = view?.textStorage else { return }
        storage.beginEditing()
        style(storage, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        view?.typingAttributes = base
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
        for span in MarkdownHighlighter.spans(in: text, range: range) {
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
                storage.addAttribute(.foregroundColor, value: NSPalette.faint, range: r)
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
        guard let view = textView as? NoteTextView, view.completingLink else { return words }
        let query = (textView.string as NSString).substring(with: charRange)
        let paths = store.quickOpen(query, recent: [], limit: 30)
        // The shortest name that still finds the note, as Obsidian writes it.
        let names = paths.map { path -> String in
            let title = Vault.title(of: path)
            return store.index.resolve(title, from: self.path ?? "") == path ? title : String(path.dropLast(3))
        }
        index?.pointee = names.isEmpty ? -1 : 0
        return names
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
    /// True while `[[` completion is open, so the delegate offers notes.
    private(set) var completingLink = false
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
        scrollRangeToVisible(clamped)
        updateInsertionPointStateAndRestartTimer(true)
    }

    /// The view never edits its own text while Neovim owns it.
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        vimActive ? false : super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override func keyDown(with event: NSEvent) {
        guard let vim, vimActive else { return super.keyDown(with: event) }
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

    /// The line that holds the cursor, tinted, with a thin accent bar.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard selectedRange().length == 0, let line = cursorLineRect() else { return }
        NSPalette.named("orange", alpha: 0.07).setFill()
        line.fill(using: .sourceOver)
        NSPalette.named("orange", alpha: 0.8).setFill()
        NSRect(x: line.minX, y: line.minY + 2, width: 2.5, height: max(0, line.height - 4)).fill(using: .sourceOver)
    }

    private func cursorLineRect() -> NSRect? {
        guard let layout = textLayoutManager, let content = layout.textContentManager else { return nil }
        let offset = selectedRange().location
        let documentStart = content.documentRange.location
        guard let location = content.location(documentStart, offsetBy: offset) ?? (offset == 0 ? documentStart : nil),
            let fragment = layout.textLayoutFragment(for: location)
        else { return nil }
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
        let lines = linesInSelection()
        let text = ns.substring(with: lines)
        guard text.split(separator: "\n").allSatisfy({ EditorCommands.isListItem(String($0)) }), !text.isEmpty else {
            return insertText(EditorCommands.indentUnit, replacementRange: selectedRange())
        }
        shift(lines) { EditorCommands.indent($0) }
    }

    override func insertBacktab(_ sender: Any?) {
        shift(linesInSelection()) { EditorCommands.outdent($0) }
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
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "h" {
            wrap("=="); return true
        }
        return super.performKeyEquivalent(with: event)
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
        super.insertText(string, replacementRange: replacementRange)
        guard let typed = string as? String, typed == "[" else { return }
        let at = selectedRange().location
        if at >= 2, ns.substring(with: NSRange(location: at - 2, length: 2)) == "[[" {
            // Close the link at once, as Obsidian does, and offer notes.
            super.insertText("]]", replacementRange: NSRange(location: at, length: 0))
            setSelectedRange(NSRange(location: at, length: 0))
            complete(nil)
        }
    }

    override var rangeForUserCompletion: NSRange {
        if let query = EditorCommands.linkQuery(in: ns, at: selectedRange().location) {
            completingLink = true
            return query
        }
        completingLink = false
        return super.rangeForUserCompletion
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        guard flag, completingLink else { return }
        completingLink = false
        // Step over the `]]` that the `[[` put there.
        let at = selectedRange().location
        if at + 2 <= ns.length, ns.substring(with: NSRange(location: at, length: 2)) == "]]" {
            setSelectedRange(NSRange(location: at + 2, length: 0))
        }
    }

    // MARK: Pasting an image

    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if vimActive, let text = board.string(forType: .string) {
            vim?.paste(text)
            return
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
}
