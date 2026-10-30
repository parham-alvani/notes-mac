import AppKit
import DaftarCore

/// What the editor keeps beside its text view's own state: the many
/// cursors, and what focus and typewriter mode last did.
@MainActor
final class EditorExtras {
    /// Every cursor, in order, while there are many; empty while there is one.
    var cursors: [NSRange] = []
    /// The view's own selection when the cursors were set. A click, a find
    /// or an undo changes it, and the many cursors are gone with it.
    var native: [NSRange] = []
    /// ⌥⌘E from a caret finds whole words of this text, as Xcode and Sublime do.
    var wholeWord: String?
    /// The cursors are being moved one by one: the scroll and the dimming wait.
    var moving = false
    var overlay: CaretOverlay?
    /// Neovim's completion menu while it shows (`NeovimMenu.swift`).
    var menu: NeovimMenu?
    /// Neovim mode's cursor, block or bar, that slides (`NeovimOverlays.swift`).
    var neovimCursor: NeovimCursor?
    /// The cursor's particles, while `cursor_effect` names one.
    var cursorEffects: CursorEffectsView?
    /// The paragraph focus mode keeps bright, and the length of the text then.
    var focused: (NSRange, Int)?
    /// The scroll view's own insets, before typewriter mode added room at the end.
    var insets: NSEdgeInsets?
}

/// The carets that are not the text view's own, drawn over the text; a
/// click goes through to the text.
final class CaretOverlay: NSView {
    weak var textView: NoteTextView?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView else { return }
        NSPalette.accent.setFill()
        for rect in textView.extraCaretRects() where rect.intersects(dirtyRect) { rect.fill() }
    }
}

extension NoteTextView {
    /// Neovim mode: the view's text is Neovim's.
    var neovimOwnsText: Bool { vim.map { $0.state == .running || $0.state == .starting } ?? false }

    private var text: NSString { string as NSString }

    // MARK: The cursors

    /// Every cursor: the many while they hold, else the view's own selection.
    var cursorRanges: [NSRange] {
        let native = selectedRanges.map(\.rangeValue)
        if extras.cursors.count > 1, native == extras.native { return extras.cursors }
        return native
    }

    var hasManyCursors: Bool { cursorRanges.count > 1 }

    /// Sets the cursors. The view shows the selections itself (it drops a
    /// caret from a list of ranges); the carets it cannot hold are drawn over it.
    func setCursors(_ ranges: [NSRange]) {
        let length = text.length
        let all = MultiCursor.normalize(ranges.map { range in
            let location = min(max(0, range.location), length)
            return NSRange(location: location, length: min(max(0, range.length), length - location))
        })
        if all.count <= 1 {
            extras.cursors = []
            setSelectedRange(all.first ?? NSRange(location: min(selectedRange().location, length), length: 0))
        } else {
            extras.cursors = all
            let selected = all.filter { $0.length > 0 }
            if selected.isEmpty {
                setSelectedRange(all[0])
            } else {
                setSelectedRanges(selected.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
            }
            extras.native = selectedRanges.map(\.rangeValue)
        }
        showCarets()
    }

    /// The carets drawn again: after a move, an edit, or when they go.
    func showCarets() {
        if extras.overlay == nil, extras.cursors.isEmpty { return }
        let overlay = extras.overlay ?? {
            let overlay = CaretOverlay(frame: bounds)
            overlay.textView = self
            overlay.autoresizingMask = [.width, .height]
            addSubview(overlay)
            extras.overlay = overlay
            return overlay
        }()
        if overlay.frame != bounds { overlay.frame = bounds }
        overlay.needsDisplay = true
    }

    /// Where the carets that the view does not draw are, in its coordinates.
    func extraCaretRects() -> [NSRect] {
        guard hasManyCursors else { return [] }
        let own = selectedRanges.map(\.rangeValue)
        return extras.cursors.filter { $0.length == 0 && !own.contains($0) }.compactMap { letterCaret(at: $0.location) }
    }

    func caretRect(at offset: Int) -> NSRect? {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
            let location = content.location(content.documentRange.location, offsetBy: offset)
        else { return nil }
        layout.ensureLayout(for: NSTextRange(location: location))
        var found: NSRect?
        layout.enumerateTextSegments(in: NSTextRange(location: location), type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
            found = frame
            return false
        }
        guard let frame = found else { return nil }
        return NSRect(x: frame.minX + textContainerOrigin.x - 0.5, y: frame.minY + textContainerOrigin.y, width: 1.5, height: max(frame.height, 1))
    }

    // MARK: Edits at every cursor

    /// The edits and the carets after them, as one step to undo.
    func applyCursorEdits(_ change: (edits: [MultiCursor.Edit], carets: [NSRange])) {
        guard let storage = textStorage else { return }
        guard !change.edits.isEmpty else { return setCursors(change.carets) }
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
        guard shouldChangeText(inRanges: change.edits.map { NSValue(range: $0.range) }, replacementStrings: change.edits.map(\.text)) else { return }
        storage.beginEditing()
        // From the end, so each range is still where it was.
        for edit in change.edits.reversed() { storage.replaceCharacters(in: edit.range, with: edit.text) }
        storage.endEditing()
        didChangeText()
        setCursors(change.carets)
    }

    /// Typed text at every cursor. False when there is one cursor, or while
    /// an input method is composing.
    func insertAtCursors(_ string: Any) -> Bool {
        guard hasManyCursors, !hasMarkedText(), !neovimOwnsText else { return false }
        let typed = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        applyCursorEdits(MultiCursor.replace(cursorRanges, with: [typed]))
        return true
    }

    /// The keys that edit or move, at every cursor; Escape leaves one. Any
    /// other command acts on the first, and the rest go.
    func commandAtCursors(_ selector: Selector) -> Bool {
        guard hasManyCursors, !neovimOwnsText else { return false }
        let ranges = cursorRanges
        let name = NSStringFromSelector(selector)
        switch name {
        case "cancelOperation:":
            setCursors([ranges[0]])
        case "insertNewline:", "insertLineBreak:", "insertNewlineIgnoringFieldEditor:":
            return insertAtCursors("\n")
        case "insertTab:", "insertTabIgnoringFieldEditor:":
            return insertAtCursors(EditorCommands.indentUnit)
        case "deleteBackward:", "deleteBackwardByDecomposingPreviousCharacter:", "deleteForward:":
            applyCursorEdits(MultiCursor.replace(MultiCursor.deletions(ranges, in: text, forward: name == "deleteForward:"), with: [""]))
        case "deleteWordBackward:", "deleteWordForward:", "deleteToBeginningOfLine:", "deleteToEndOfLine:":
            let motion = [
                "deleteWordBackward:": "moveWordBackwardAndModifySelection:", "deleteWordForward:": "moveWordForwardAndModifySelection:",
                "deleteToBeginningOfLine:": "moveToBeginningOfLineAndModifySelection:", "deleteToEndOfLine:": "moveToEndOfLineAndModifySelection:",
            ][name]!
            let gone = ranges.map { $0.length > 0 ? $0 : moved($0, by: NSSelectorFromString(motion)) }
            applyCursorEdits(MultiCursor.replace(gone, with: [""]))
        case _ where name.hasPrefix("move") && !name.hasPrefix("moveParagraph"):
            setCursors(ranges.map { moved($0, by: selector) })
        default:
            return false
        }
        return true
    }

    /// Where the view's own command takes [range] when it is the only selection.
    private func moved(_ range: NSRange, by selector: Selector) -> NSRange {
        extras.moving = true
        defer { extras.moving = false }
        setSelectedRange(range)
        super.doCommand(by: selector)
        return selectedRange()
    }

    /// A paste at every cursor: a line each when the text has as many lines.
    func pasteAtCursors() -> Bool {
        guard hasManyCursors, !neovimOwnsText, let pasted = NSPasteboard.general.string(forType: .string) else { return false }
        let ranges = MultiCursor.normalize(cursorRanges)
        applyCursorEdits(MultiCursor.replace(ranges, with: MultiCursor.pieces(of: pasted, cursors: ranges.count)))
        return true
    }

    /// The selected text of every cursor, a line each.
    private var selectedPieces: [String] { cursorRanges.filter { $0.length > 0 }.map { text.substring(with: $0) } }

    override func copy(_ sender: Any?) {
        guard hasManyCursors, !selectedPieces.isEmpty else { return super.copy(sender) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedPieces.joined(separator: "\n"), forType: .string)
    }

    override func cut(_ sender: Any?) {
        guard hasManyCursors, !neovimOwnsText, !selectedPieces.isEmpty else { return super.cut(sender) }
        copy(sender)
        applyCursorEdits(MultiCursor.replace(cursorRanges, with: [""]))
    }

    /// Edit › Spelling's "Check Spelling While Typing" is the setting in the config file.
    override func toggleContinuousSpellChecking(_ sender: Any?) {
        guard let settings = controller?.store.settings else { return super.toggleContinuousSpellChecking(sender) }
        settings.spellCheck.toggle()
        isContinuousSpellCheckingEnabled = settings.spellCheck
    }

    // MARK: Selecting occurrences

    /// ⌥⌘E: from a caret, the word it is in; from a selection, the next place
    /// the same text is, as one more cursor.
    @objc func selectNextOccurrence(_ sender: Any?) {
        guard !refusedInNeovim() else { return }
        let ranges = cursorRanges
        if ranges.allSatisfy({ $0.length == 0 }) {
            let words = ranges.compactMap { MultiCursor.word(at: $0.location, in: text) }
            guard let first = words.first else { return NSSound.beep() }
            extras.wholeWord = text.substring(with: first)
            return setCursors(words)
        }
        let needle = text.substring(with: ranges.first { $0.length > 0 }!)
        let selections = ranges.filter { $0.length > 0 }
        guard let found = MultiCursor.nextOccurrence(of: needle, in: text, after: selections, wholeWord: extras.wholeWord == needle) else {
            return NSSound.beep()
        }
        setCursors(ranges + [found])
        scrollRangeToVisible(found)
    }

    /// ⌃⌘G: every place the selected text, or the caret's word, is.
    @objc func selectAllOccurrences(_ sender: Any?) {
        guard !refusedInNeovim() else { return }
        let first = cursorRanges.first { $0.length > 0 } ?? MultiCursor.word(at: selectedRange().location, in: text)
        guard let first else { return NSSound.beep() }
        let needle = text.substring(with: first)
        let whole = cursorRanges.allSatisfy { $0.length == 0 } || extras.wholeWord == needle
        let all = MultiCursor.occurrences(of: needle, in: text, wholeWord: whole)
        guard !all.isEmpty else { return NSSound.beep() }
        setCursors(all)
    }

    private func refusedInNeovim() -> Bool {
        guard neovimOwnsText else { return false }
        controller?.store.notice = "Many cursors work in the editor without Neovim mode; Neovim has its own."
        return true
    }

    // MARK: The mouse

    /// ⌥-drag selects a column, a caret on each line when it goes straight
    /// down; ⌃⇧-click adds a caret. True when the click is handled here.
    func cursorClick(_ event: NSEvent) -> Bool {
        guard !neovimOwnsText else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let at = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        if flags == [.control, .shift] {
            window?.makeFirstResponder(self)
            setCursors(cursorRanges + [NSRange(location: at, length: 0)])
            return true
        }
        guard flags == .option, event.clickCount == 1, let window else {
            extras.cursors = []
            return false
        }
        window.makeFirstResponder(self)
        setCursors([NSRange(location: at, length: 0)])
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            columnSelect(from: at, to: characterIndexForInsertion(at: convert(next.locationInWindow, from: nil)))
            if next.type == .leftMouseUp { break }
            autoscroll(with: next)
        }
        return true
    }

    /// The column between two places, as an ⌥-drag makes it.
    func columnSelect(from anchor: Int, to head: Int) {
        setCursors(MultiCursor.column(in: text, from: anchor, to: head))
    }
}
