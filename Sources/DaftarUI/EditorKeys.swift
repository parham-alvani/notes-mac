import AppKit
import DaftarCore

/// The plain editor's keys: lists and tables, moving and copying lines,
/// the shortcuts, pairs, the slash menu, completion, and what is dropped
/// or pasted. The rules are `EditorCommands` and `MarkdownTable` (core).
extension NoteTextView {
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

    func replace(_ range: NSRange, with text: String, select: NSRange? = nil) {
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

    func moveLines(up: Bool) {
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
        // The shortcut's key on the Latin layout: ⌘B is bold with the Persian layout on too.
        let key = chordCharacters(event)
        if flags == .command {
            switch key {
            case "\r": toggleTask(); return true
            case "b": wrap("**"); return true
            case "i": wrap("*"); return true
            case "k": insertLink(); return true
            default: break
            }
        }
        if flags == [.command, .shift] {
            switch key.lowercased() {
            case "h": wrap("=="); return true
            case "x": wrap("~~"); return true
            case "c": wrap("`"); return true
            case "k": deleteLines(); return true
            default: break
            }
        }
        // ⌥⌘1 to ⌥⌘6 make the line a heading, ⌥⌘0 plain text.
        if flags == [.command, .option], let digit = Int(key), (0...6).contains(digit) {
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
    func duplicateLines(up: Bool) {
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
        if insertAtCursors(string) { return }
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

    @objc func formatNote(_ sender: Any?) { controller?.formatNote() }

    // MARK: Pairs

    /// What a mark wraps a selection in, as Obsidian does: `*`, `_`, `` ` ``,
    /// `~`, `=` and the brackets and quotes.
    private static let wrapping: [String: String] = ["*": "*", "_": "_", "`": "`", "~": "~", "=": "=", "(": ")", "[": "]", "{": "}", "\"": "\""]
    private static let closing: [String: String] = ["(": ")", "[": "]", "{": "}"]

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
        if pasteAtCursors() { return }
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
        guard board.string(forType: .string) == nil, let controller, controller.store.root != nil,
            let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return super.paste(sender) }
        guard let name = controller.savePastedImage(png) else { return }
        if vimActive { vim?.paste("![[\(name)]]") } else { insertText("![[\(name)]]", replacementRange: selectedRange()) }
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
