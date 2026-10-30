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
            menu.setFrameOrigin(NSPoint(x: visible.minX + 12, y: visible.maxY - size.height - 6))
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
