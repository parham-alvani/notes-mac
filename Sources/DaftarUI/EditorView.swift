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

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NoteTextView.scrollableNoteView()
        let view = scroll.documentView as! NoteTextView
        view.controller = context.coordinator
        context.coordinator.view = view
        context.coordinator.load(path)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let controller = context.coordinator
        if controller.path != path {
            controller.saveNow()
            controller.load(path)
        } else {
            controller.followDisk()
        }
        controller.applyTextSize()
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: EditorController) {
        coordinator.saveNow()
    }
}

@MainActor
final class EditorController: NSObject, NSTextStorageDelegate, NSTextViewDelegate {
    let store: VaultStore
    weak var view: NoteTextView?
    private(set) var path: String?
    /// What the file said when it was last read or written.
    private var saved = ""
    private var saveTask: Task<Void, Never>?
    private var seenRevision = -1
    private var fontKey = ""

    init(store: VaultStore) { self.store = store }

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
    }

    /// The file changed on disk. A change this editor wrote is already here;
    /// any other is taken when there is no unsaved typing, and kept out when
    /// there is, so nothing typed is lost.
    func followDisk() {
        guard let path, let view, store.revision != seenRevision else { return }
        seenRevision = store.revision
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

    func textDidChange(_ notification: Notification) {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
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
                storage.addAttributes([.backgroundColor: NSPalette.highlightBackground, .foregroundColor: NSPalette.highlightText], range: r)
            case .code:
                storage.addAttributes([.font: mono, .foregroundColor: NSPalette.raw, .backgroundColor: NSPalette.panel], range: r)
            case .codeBlock:
                storage.addAttributes([.font: mono, .backgroundColor: NSPalette.panel], range: r)
            case .fence, .frontMatter:
                storage.addAttributes([.font: mono, .foregroundColor: NSPalette.muted], range: r)
            case .link:
                storage.addAttribute(.foregroundColor, value: NSPalette.link, range: r)
            case .embed:
                storage.addAttribute(.foregroundColor, value: NSPalette.link, range: r)
                embedImage(text.substring(with: r), line: text.lineRange(for: r), in: storage)
            case .url:
                storage.addAttributes([.foregroundColor: NSPalette.link.withAlphaComponent(0.7)], range: r)
            case .tag:
                storage.addAttribute(.foregroundColor, value: NSPalette.accent, range: r)
            case .taskOpen, .taskOther:
                storage.addAttributes([.font: mono, .foregroundColor: NSPalette.accent], range: r)
            case .taskDone, .taskCancelled:
                storage.addAttributes([.foregroundColor: NSPalette.faint, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: r)
            case .listMarker:
                storage.addAttribute(.foregroundColor, value: NSPalette.accent, range: r)
            case .quote:
                storage.addAttribute(.foregroundColor, value: NSPalette.quote, range: r)
            case .calloutTitle:
                storage.addAttributes([.font: Fonts.text(size: fontSize, weight: .bold), .foregroundColor: NSPalette.blue], range: r)
            case .comment, .rule:
                storage.addAttribute(.foregroundColor, value: NSPalette.faint, range: r)
            case .math:
                storage.addAttributes([.font: mono, .foregroundColor: NSPalette.purple], range: r)
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
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
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
            insertText("![[\(name)]]", replacementRange: selectedRange())
        } catch {
            controller.store.notice = "The image could not be saved: \(error.localizedDescription)"
        }
    }
}
