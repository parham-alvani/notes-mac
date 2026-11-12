import AppKit
import DaftarCore

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
    /// What the audit found in the note, by source line from 0: a dot in the
    /// margin, its message on hover (`EditorProblems.swift`).
    var problemMarks: [Int: [Problem]] = [:]
    /// The margin's tooltip, and who answers it.
    var problemTip: NSView.ToolTipTag?
    lazy var problemTips = ProblemTips(view: self)
    /// The source line of a line start the margin looked for last, and the
    /// text's generation then (`EditorController.textGeneration`).
    var problemLine: (generation: Int, offset: Int, line: Int)?
    var scrollPending = false
    /// The last scroll with Neovim: the glide it started (a later one
    /// replaces it), the letter at the cursor, and where on screen its
    /// line was put (`NeovimView.swift`).
    var glide = 0
    var placed: (offset: Int, y: CGFloat)?
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

    /// The text laid out on screen, in UTF-16 offsets; nil before the first layout.
    func viewportOffsets() -> NSRange? {
        guard let storage = textStorage, let layout = textLayoutManager, let content = layout.textContentManager,
            let viewport = layout.textViewportLayoutController.viewportRange
        else { return nil }
        let start = max(0, content.offset(from: content.documentRange.location, to: viewport.location))
        let end = min(storage.length, content.offset(from: content.documentRange.location, to: viewport.endLocation))
        return NSRange(location: min(start, storage.length), length: max(0, end - min(start, storage.length)))
    }

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
        drawProblemMarks(in: rect)
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
        if abs(textContainerInset.width - side) > 1 {
            textContainerInset = NSSize(width: side, height: 28)
            showProblemTips()
        }
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
