import AppKit
import DaftarCore

/// Neovim's own completion menu -- `<C-n>`, `<C-p>`, a dictionary, an
/// omnifunc -- drawn by the editor under the word, as Neovide draws it.
/// Neovim keeps the menu: its keys move the selection and it says which
/// item is selected; the view only shows the list. A click goes through
/// to the text.
final class NeovimMenu: NSView {
    struct Item: Equatable {
        let word: String
        /// Neovim's kind letter (`v`, `f`) or the source, as `[ID]`.
        let detail: String
    }

    static let visibleRows = 8

    private(set) var items: [Item] = []
    /// The selected item, or -1 while none is.
    private(set) var selected = -1
    /// The first item in sight; the list scrolls to keep the selection in it.
    private(set) var first = 0
    var font = NSFont.systemFont(ofSize: 14)

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var rowHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) + 8 }
    private var detailFont: NSFont { NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.75, weight: .regular) }

    func show(_ items: [Item], selected: Int) {
        self.items = items
        first = 0
        select(selected)
        setFrameSize(fittingSize)
    }

    func select(_ index: Int) {
        selected = index
        if index >= 0 {
            if index < first { first = index }
            if index >= first + Self.visibleRows { first = index - Self.visibleRows + 1 }
        }
        needsDisplay = true
    }

    override var fittingSize: NSSize {
        let words = items.map { ($0.word as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let details = items.map { ($0.detail as NSString).size(withAttributes: [.font: detailFont]).width }.max() ?? 0
        let width = min(420, ceil(words + (details > 0 ? details + 24 : 0) + 24))
        return NSSize(width: max(120, width), height: CGFloat(min(items.count, Self.visibleRows)) * rowHeight + 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSPalette.panel.setFill()
        panel.fill()
        NSColor.separatorColor.setStroke()
        panel.stroke()
        let shown = items.indices.dropFirst(first).prefix(Self.visibleRows)
        for (row, index) in shown.enumerated() {
            let rect = NSRect(x: 4, y: 4 + CGFloat(row) * rowHeight, width: bounds.width - 8, height: rowHeight)
            if index == selected {
                NSPalette.named("orange", alpha: 0.28).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            }
            let item = items[index]
            let word = NSAttributedString(string: item.word, attributes: [
                .font: font, .foregroundColor: index == selected ? NSPalette.text : NSPalette.text.withAlphaComponent(0.85),
            ])
            let height = word.size().height
            let detail = NSAttributedString(string: item.detail, attributes: [.font: detailFont, .foregroundColor: NSPalette.faint])
            let detailWidth = item.detail.isEmpty ? 0 : detail.size().width
            word.draw(with: NSRect(x: rect.minX + 8, y: rect.midY - height / 2, width: rect.width - detailWidth - 24, height: height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            if detailWidth > 0 {
                let size = detail.size()
                detail.draw(at: NSPoint(x: rect.maxX - 8 - size.width, y: rect.midY - size.height / 2))
            }
        }
        // More items below or above: a thin bar along the right edge.
        if items.count > Self.visibleRows {
            let track = bounds.height - 16
            let bar = NSRect(
                x: bounds.width - 5, y: 8 + track * CGFloat(first) / CGFloat(items.count),
                width: 2.5, height: max(12, track * CGFloat(Self.visibleRows) / CGFloat(items.count)))
            NSPalette.faint.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.25, yRadius: 1.25).fill()
        }
    }
}

extension NoteTextView {
    /// Neovim shows its menu for the word that ends at the cursor; [row]
    /// is -1 for the command line's, which shows above the status bar.
    func showNeovimMenu(_ items: [NeovimMenu.Item], selected: Int, forCommandLine: Bool) {
        guard !items.isEmpty else { return hideNeovimMenu() }
        let menu = extras.menu ?? {
            let menu = NeovimMenu(frame: .zero)
            addSubview(menu)
            extras.menu = menu
            return menu
        }()
        menu.font = Fonts.text(size: CGFloat(controller?.store.settings.textSize ?? 14))
        menu.show(items, selected: selected)
        placeNeovimMenu(menu, forCommandLine: forCommandLine)
        menu.needsDisplay = true
    }

    func selectNeovimMenu(_ selected: Int) { extras.menu?.select(selected) }

    func hideNeovimMenu() {
        extras.menu?.removeFromSuperview()
        extras.menu = nil
    }

    /// Under the word the cursor is in, or above it where there is no room
    /// below; in the view's sight either way.
    private func placeNeovimMenu(_ menu: NeovimMenu, forCommandLine: Bool) {
        let size = menu.frame.size
        let visible = visibleRect
        if forCommandLine {
            // Under the floating command line, at its left edge.
            if let panel = controller?.container?.commandPanel {
                let rect = convert(panel.bounds, from: panel)
                menu.setFrameOrigin(NSPoint(x: max(visible.minX + 4, rect.minX + 8), y: rect.maxY + 4))
            } else {
                menu.setFrameOrigin(NSPoint(x: visible.minX + 12, y: visible.maxY - size.height - 6))
            }
            return
        }
        let text = string as NSString
        var start = min(selectedRange().location, text.length)
        while start > 0 {
            let previous = text.rangeOfComposedCharacterSequence(at: start - 1)
            let character = text.substring(with: previous)
            guard character.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }) else { break }
            start = previous.location
        }
        guard let caret = letterCaret(at: start), let line = lineRect(at: start) else { return }
        var origin = NSPoint(x: caret.minX - 12, y: line.maxY + 2)
        if origin.y + size.height > visible.maxY, line.minY - size.height - 2 >= visible.minY {
            origin.y = line.minY - size.height - 2
        }
        origin.x = max(visible.minX + 4, min(origin.x, visible.maxX - size.width - 4))
        menu.setFrameOrigin(origin)
    }
}

/// Neovim's command line -- `:`, `/`, `?`, an `input()` prompt -- as a
/// panel floating near the top of the editor, with its own cursor.
final class CommandLinePanel: NSView {
    var line = NeovimSession.CommandLine(prefix: ":", text: "", position: 0) {
        didSet { if line != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    private var font: NSFont { Fonts.code(size: 14) }

    /// What a cursor at UTF-8 byte [position] of [text] is before, in UTF-16.
    static func offset(of position: Int, in text: String) -> Int {
        let bytes = Array(text.utf8.prefix(max(0, position)))
        return (String(decoding: bytes, as: UTF8.self) as NSString).length
    }

    override func draw(_ dirtyRect: NSRect) {
        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        NSPalette.panel.setFill()
        panel.fill()
        NSPalette.named("orange", alpha: 0.6).setStroke()
        panel.lineWidth = 1
        panel.stroke()
        let prefix = NSAttributedString(string: line.prefix, attributes: [.font: font, .foregroundColor: NSPalette.accent])
        let text = NSAttributedString(string: line.text, attributes: [.font: font, .foregroundColor: NSPalette.text])
        let height = text.size().height == 0 ? prefix.size().height : text.size().height
        let y = bounds.midY - height / 2
        prefix.draw(at: NSPoint(x: 14, y: y))
        let start = 14 + prefix.size().width + 6
        // The end of a long line in sight: the text slides left past the edge.
        let before = NSAttributedString(
            string: (line.text as NSString).substring(to: min((line.text as NSString).length, Self.offset(of: line.position, in: line.text))),
            attributes: [.font: font])
        let room = bounds.width - start - 16
        let shift = max(0, before.size().width - room)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: start, y: 0, width: max(0, room + 4), height: bounds.height)).addClip()
        text.draw(at: NSPoint(x: start - shift, y: y))
        NSPalette.accent.setFill()
        NSRect(x: start - shift + before.size().width, y: y + 1, width: 2, height: height - 2).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Neovim mode's cursor: a block in normal mode, a bar while typing, that
/// slides to where it goes, as Neovide's does. It is behind the text, so
/// the letter under the block reads; without the keys it is an outline.
final class NeovimCursor: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 2
    }

    required init?(coder: NSCoder) { nil }

    private var look: (block: Bool, focused: Bool)?

    func style(block: Bool, focused: Bool) {
        guard look.map({ $0 != (block, focused) }) ?? true else { return }
        look = (block, focused)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = NSPalette.accent
            layer?.backgroundColor = focused ? accent.withAlphaComponent(block ? 0.55 : 1).cgColor : NSColor.clear.cgColor
            layer?.borderColor = accent.cgColor
            layer?.borderWidth = focused ? 0 : 1
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let look { self.look = nil; style(block: look.block, focused: look.focused) }
    }
}

extension NoteTextView {
    /// Where Neovim's cursor is: the block over the letter in normal mode,
    /// a bar at the letters' height while typing; none over a selection.
    func moveNeovimCursor() {
        let visual = vim.map { $0.mode.first == "v" || $0.mode.first == "V" || $0.mode == "\u{16}" } ?? false
        guard vimActive, let vim, !visual, selectedRange().length == 0 else {
            extras.neovimCursor?.removeFromSuperview()
            extras.neovimCursor = nil
            return
        }
        let target: NSRect
        if vim.isNormal {
            guard let block = blockRect() else { return }
            target = block
        } else {
            guard let caret = letterCaret(at: selectedRange().location) else { return }
            target = NSRect(x: caret.minX, y: caret.minY, width: 2, height: caret.height)
        }
        let cursor = extras.neovimCursor ?? {
            let cursor = NeovimCursor(frame: .zero)
            // Behind the text, over the editor's own background and tint.
            addSubview(cursor, positioned: .below, relativeTo: nil)
            extras.neovimCursor = cursor
            return cursor
        }()
        cursor.style(block: vim.isNormal, focused: window?.isKeyWindow == true && window?.firstResponder === self)
        guard cursor.frame != target else { return }
        // A jump of a screen or more, or a first place, is at once.
        let near = cursor.frame != .zero && abs(cursor.frame.midY - target.midY) < visibleRect.height
        if near, controller?.store.settings.animateCursor ?? true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            window?.isVisible == true
        {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.09
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                cursor.animator().frame = target
            }
        } else {
            cursor.frame = target
        }
    }
}
