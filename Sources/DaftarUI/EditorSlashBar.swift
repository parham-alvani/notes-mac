import AppKit
import DaftarCore

/// The slash bar: a small list under a typed `/`, filtered as the person
/// types (`editor.slash_menu`, docs/specs/look.md in notes-linux, part 2).
/// It never has the keys: every key goes to the text first, and the text
/// view gives the bar the few it uses (`slashKey`). The rules are
/// `SlashBar` (core); this is how the list looks.
final class SlashList: NSView {
    weak var textView: NoteTextView?
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static let width: CGFloat = 280
    static let rowHeight: CGFloat = 32
    static let headerHeight: CGFloat = 24
    /// At most this many rows show; the rest scroll.
    static let most = 8

    /// What the list shows: a row of the bar, or the header over a group.
    enum Line: Equatable {
        case header(String)
        case row(Int)
    }

    private(set) var bar: SlashBar
    private(set) var lines: [Line] = []
    private let rows = SlashRows()
    /// How far the rows are scrolled.
    private var scrolled: CGFloat = 0

    init(bar: SlashBar) {
        self.bar = bar
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -5)
        self.shadow = shadow
        rows.list = self
        rows.wantsLayer = true
        rows.layer?.cornerRadius = 11
        rows.layer?.masksToBounds = true
        addSubview(rows)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Slash commands")
        show(bar)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The palette's colours, as the window's appearance has them now.
    override func updateLayer() {
        layer?.backgroundColor = NSPalette.background.cgColor
        layer?.borderColor = NSPalette.selection.cgColor
    }

    /// The bar as it is now: its rows, under their groups' headers with
    /// nothing typed, and the chosen row in view.
    func show(_ bar: SlashBar) {
        let changed = bar.rows != self.bar.rows || lines.isEmpty
        self.bar = bar
        if changed {
            lines = bar.rows.indices.flatMap { index in (bar.header(over: index).map { [Line.header($0)] } ?? []) + [Line.row(index)] }
            scrolled = 0
            setFrameSize(NSSize(width: Self.width, height: min(contentHeight, CGFloat(Self.most) * Self.rowHeight) + 8))
            rows.frame = bounds.insetBy(dx: 1, dy: 1)
        }
        reveal(bar.chosen)
        rows.needsDisplay = true
    }

    private func height(of line: Line) -> CGFloat {
        if case .header = line { Self.headerHeight } else { Self.rowHeight }
    }

    private var contentHeight: CGFloat { lines.reduce(0) { $0 + height(of: $1) } }

    /// Where each line is, from the top of the list's content.
    func frames() -> [(line: Line, frame: NSRect)] {
        var y: CGFloat = 4
        return lines.map { line in
            defer { y += height(of: line) }
            return (line, NSRect(x: 0, y: y, width: rows.bounds.width, height: height(of: line)))
        }
    }

    /// The chosen row scrolled into view, its group's header with it when it is the first of the group.
    private func reveal(_ chosen: Int) {
        let all = frames()
        guard let index = all.firstIndex(where: { $0.line == .row(chosen) }) else { return }
        var frame = all[index].frame
        if index > 0, case .header = all[index - 1].line { frame = frame.union(all[index - 1].frame) }
        let visible = rows.bounds.height
        if frame.minY - 4 < scrolled { scrolled = frame.minY - 4 }
        if frame.maxY + 4 > scrolled + visible { scrolled = frame.maxY + 4 - visible }
        scrolled = max(0, min(scrolled, contentHeight + 8 - visible))
    }

    override func scrollWheel(with event: NSEvent) {
        let most = max(0, contentHeight + 8 - rows.bounds.height)
        scrolled = max(0, min(most, scrolled - event.scrollingDeltaY))
        rows.needsDisplay = true
    }

    /// The row at [point] of the list, or nil on a header and between rows.
    func row(at point: NSPoint) -> Int? {
        let inRows = rows.convert(point, from: self)
        for (line, frame) in frames() where frame.offsetBy(dx: 0, dy: -scrolled).contains(inRows) {
            if case .row(let index) = line { return index }
        }
        return nil
    }

    /// A click on a row inserts it. The keys stay in the text.
    override func mouseDown(with event: NSEvent) {
        guard let index = row(at: convert(event.locationInWindow, from: nil)), bar.rows.indices.contains(index) else { return }
        textView?.insertSlash(bar.rows[index])
    }

    fileprivate func drawRows(in dirty: NSRect) {
        let em: CGFloat = 14
        let title = NSFont.systemFont(ofSize: em)
        let small = NSFont.systemFont(ofSize: em * 0.82)
        for (line, placed) in frames() {
            let frame = placed.offsetBy(dx: 0, dy: -scrolled)
            guard frame.intersects(dirty) else { continue }
            switch line {
            case .header(let group):
                let text = NSAttributedString(string: group, attributes: [.font: NSFont.systemFont(ofSize: em * 0.82, weight: .semibold), .foregroundColor: NSPalette.faint])
                text.draw(at: NSPoint(x: 12, y: frame.maxY - text.size().height - 3))
            case .row(let index):
                guard bar.rows.indices.contains(index) else { continue }
                let snippet = bar.rows[index]
                if index == bar.chosen {
                    // The accent at 14% behind the chosen row, and no border in the accent.
                    NSPalette.accent.withAlphaComponent(0.14).setFill()
                    NSBezierPath(roundedRect: frame.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6).fill()
                }
                let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold).applying(.init(paletteColors: [NSPalette.named(snippet.color)]))
                if let icon = NSImage(systemSymbolName: snippet.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                    // 16 px, kept to its shape.
                    let size = icon.size, scale = min(16 / max(size.width, 1), 16 / max(size.height, 1), 1.4)
                    let box = NSSize(width: size.width * scale, height: size.height * scale)
                    icon.draw(in: NSRect(x: 12 + (16 - box.width) / 2, y: frame.midY - box.height / 2, width: box.width, height: box.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
                let group = NSAttributedString(string: snippet.group, attributes: [.font: small, .foregroundColor: NSPalette.faint])
                let groupSize = group.size()
                group.draw(at: NSPoint(x: frame.maxX - 12 - groupSize.width, y: frame.midY - groupSize.height / 2))
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byTruncatingTail
                let name = NSAttributedString(string: snippet.title, attributes: [.font: title, .foregroundColor: NSPalette.text, .paragraphStyle: paragraph])
                let height = name.size().height
                name.draw(in: NSRect(x: 38, y: frame.midY - height / 2, width: frame.maxX - 12 - groupSize.width - 8 - 38, height: height))
            }
        }
    }
}

/// The rows of the slash list, cut to the list's corners.
private final class SlashRows: NSView {
    weak var list: SlashList?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { list?.drawRows(in: dirtyRect) }
}

extension NoteTextView {
    /// A `/` was typed at the caret: the bar opens where the spec lets it,
    /// in the plain editor with one cursor, in a vault that can be written.
    /// A pasted `/` never comes here.
    func openSlashBar() {
        closeSlashBar()
        guard let controller, controller.store.settings.slashMenu, !controller.store.readOnly, !vimActive, !hasManyCursors, isEditable else { return }
        let text = string as NSString
        let caret = selectedRange().location
        guard EditorCommands.opensSlashMenu(in: text, at: caret) else { return }
        let line = text.lineRange(for: NSRange(location: caret - 1, length: 0))
        let time = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        // The state the line starts in, from the nearest line the styling knows above it.
        let state = controller.blockStates.peek(before: line.location, in: text)
        guard let bar = SlashBar(typedAt: caret, in: text, items: EditorCommands.slashCommands(today: .today(), time: time), startingIn: state) else { return }
        extras.slash = bar
        showSlashList()
    }

    func closeSlashBar() {
        guard extras.slash != nil || extras.slashList != nil else { return }
        extras.slash = nil
        extras.slashList?.removeFromSuperview()
        extras.slashList = nil
    }

    /// The text or the caret changed: the bar filters by what is typed
    /// after the `/`, or closes when the caret left that place.
    func followSlashBar() {
        guard let bar = extras.slash else { return }
        let selection = selectedRange()
        guard selection.length == 0, !hasManyCursors, let next = bar.following(string as NSString, caret: selection.location) else { return closeSlashBar() }
        guard next != bar else { return }
        extras.slash = next
        showSlashList()
    }

    /// The list under the `/`, 4 px away, its start edge on the `/`; over
    /// it when there is no room below; inside the editor by 8 px. With no
    /// row it hides, and the bar still listens.
    private func showSlashList() {
        guard let bar = extras.slash, !bar.rows.isEmpty, let slash = letterCaret(at: bar.slash) else {
            extras.slashList?.isHidden = true
            return
        }
        let list = extras.slashList ?? {
            let list = SlashList(bar: bar)
            list.textView = self
            addSubview(list)
            extras.slashList = list
            return list
        }()
        list.show(bar)
        let visible = visibleRect
        var origin = NSPoint(x: slash.minX, y: slash.maxY + 4)
        if origin.y + list.frame.height > visible.maxY - 8, slash.minY - 4 - list.frame.height >= visible.minY + 8 { origin.y = slash.minY - 4 - list.frame.height }
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - list.frame.width - 8))
        list.setFrameOrigin(origin)
        list.isHidden = false
    }

    /// The keys the bar uses while it shows rows: Down and Up (Ctrl+N and
    /// Ctrl+P are the same commands) choose, Return and Tab insert, Escape
    /// closes and leaves the `/` and what was typed. True when the key was
    /// the bar's; with the list hidden, Return and Tab are ordinary keys.
    func slashKey(_ selector: Selector) -> Bool {
        guard var bar = extras.slash else { return false }
        switch selector {
        case #selector(cancelOperation(_:)):
            closeSlashBar()
            return true
        case #selector(moveDown(_:)), #selector(moveUp(_:)):
            guard !bar.rows.isEmpty else { return false }
            bar.move(by: selector == #selector(moveDown(_:)) ? 1 : -1)
            extras.slash = bar
            extras.slashList?.show(bar)
            return true
        case #selector(insertNewline(_:)), #selector(insertTab(_:)):
            guard let choice = bar.choice else { return false }
            insertSlash(choice)
            return true
        default:
            return false
        }
    }

    /// Puts [snippet] in place of the `/` and what was typed after it, as
    /// one step to undo, and closes the bar.
    func insertSlash(_ snippet: Snippet) {
        guard let bar = extras.slash else { return }
        closeSlashBar()
        let text = string as NSString
        guard bar.slash < text.length, text.character(at: bar.slash) == 0x2F else { return }
        let edit = bar.edit(snippet, in: text)
        guard NSMaxRange(edit.range) <= text.length else { return }
        breakUndoCoalescing()
        replace(edit.range, with: edit.text, select: NSRange(location: edit.cursor, length: 0))
        breakUndoCoalescing()
        // A link's list of notes opens at once.
        if snippet.id == "link" || snippet.id == "embed" { complete(nil) }
    }
}
