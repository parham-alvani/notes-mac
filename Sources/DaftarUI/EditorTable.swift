import AppKit
import DaftarCore

/// A Markdown table drawn as a grid (docs/specs/look.md in notes-linux,
/// part 2). The text stays a Markdown table: the styling hides the pipes,
/// the padding spaces and the delimiter row with attributes, and gives each
/// cell its column's place with a `.kern` on the hidden mark before it; the
/// view draws the box, the header's panel and the hairlines behind the
/// text. Which lines are a grid, what a cell is and when the table shows
/// raw are `TableGrid`'s rules (core).

/// One line of a grid, as the styling wrote it into the `tableRow`
/// attribute. The value is a string, so the rows of one table that are
/// drawn alike are one run.
struct TableRowPart: Equatable {
    enum Role: String {
        case header = "h"
        case delimiter = "d"
        case body = "b"
    }

    var role: Role
    /// The box ends under this line: the last row, or a header with no row.
    var last: Bool
    /// The columns go from the right.
    var rtl: Bool
    /// Each column's width, without the room at its sides.
    var widths: [CGFloat]

    var value: String {
        "grid:\(role.rawValue)\(last ? "e" : ""):\(rtl ? "r" : "l"):" + widths.map { String(format: "%.2f", $0) }.joined(separator: ",")
    }

    init(role: Role, last: Bool, rtl: Bool, widths: [CGFloat]) {
        self.role = role
        self.last = last
        self.rtl = rtl
        self.widths = widths
    }

    init?(_ value: String) {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "grid", let mark = parts[1].first, let role = Role(rawValue: String(mark)) else { return nil }
        self.role = role
        last = parts[1].hasSuffix("e")
        rtl = parts[2] == "r"
        widths = parts[3].split(separator: ",").map { CGFloat(Double($0) ?? 0) }
    }

    /// The room at each side of a cell's text, in em.
    static let side: CGFloat = 0.7

    /// The box's width at the text size [em].
    func total(em: CGFloat) -> CGFloat {
        widths.reduce(0) { $0 + $1 + em * Self.side * 2 }
    }
}

extension EditorController {
    /// The rows next to each other that a styled range touches, and their
    /// grid when they are drawn as one.
    struct TableDraw {
        var run: NSRange
        var grid: TableGrid?
    }

    /// The widths of a grid's cells and columns.
    struct GridMeasure {
        var widths: [CGFloat]
        var cells: [[CGFloat]]
        var rtl: Bool
        var total: CGFloat
    }


    /// The room above and under a row's text: 0.35 em.
    static func rowRoom(_ em: CGFloat) -> CGFloat { ceil(em * 0.35) }

    /// A grid row's line: the text's own, and the room above it.
    private var rowHeight: CGFloat {
        let font = Fonts.text(size: em)
        return ceil(font.ascender - font.descender + font.leading) + Self.rowRoom(em)
    }

    /// The room a table has: the text's measure.
    var gridRoom: CGFloat {
        guard let container = view?.textContainer, container.size.width > 0 else { return .greatestFiniteMagnitude }
        return container.size.width - container.lineFragmentPadding * 2
    }

    /// Whether [grid] shows raw now: the caret on its delimiter row, or a
    /// selection that reaches outside one cell. In Neovim mode it is raw
    /// while the cursor is anywhere in it: Neovim's cursor walks over the
    /// pipes and the padding.
    func isRaw(_ grid: TableGrid) -> Bool {
        guard let view else { return false }
        let selection = view.selectedRange()
        if view.vimActive { return selection.location <= NSMaxRange(grid.range) && NSMaxRange(selection) >= grid.range.location }
        return grid.isRaw(with: selection)
    }

    /// The tables with a row in the lines of [range], or in the line above
    /// or below them: a row typed or taken there changes the table.
    func tables(touching range: NSRange, text: NSString) -> [TableDraw] {
        var out: [TableDraw] = []
        /// The table of the line at [location]; the end of its rows.
        func add(at location: Int) -> Int? {
            guard TableGrid.isRow(text, at: location), let run = TableGrid.run(around: location, in: text) else { return nil }
            if out.last?.run == run.range { return NSMaxRange(run.range) }
            var grid = run.whole ? TableGrid(run.range, in: text) : nil
            // Not in a code block, the front matter, math or a comment; and not while it shows raw.
            if let found = grid, blockStates.peek(before: found.range.location, in: text) != .normal || isRaw(found) { grid = nil }
            out.append(TableDraw(run: run.range, grid: grid))
            return NSMaxRange(run.range)
        }
        let lines = text.lineRange(for: range)
        if lines.location > 0 { _ = add(at: text.lineRange(for: NSRange(location: lines.location - 1, length: 0)).location) }
        var at = lines.location
        while at < NSMaxRange(lines) {
            let next = NSMaxRange(text.lineRange(for: NSRange(location: add(at: at) ?? at, length: 0)))
            guard next > at else { break }
            at = next
        }
        if NSMaxRange(lines) < text.length, at <= NSMaxRange(lines) { _ = add(at: NSMaxRange(lines)) }
        return out
    }

    /// What a cell may hold that is drawn narrower or wider than its
    /// letters: marks that hide, code, a tag. Such a cell is measured as styled.
    private static let cellMarks = CharacterSet(charactersIn: "*_=[]()`~$#\\!<>^%&:")

    private func cellWidth(_ cell: NSRange, header: Bool, in storage: NSTextStorage, text: NSString) -> CGFloat {
        let string = text.substring(with: cell)
        let plain = string.rangeOfCharacter(from: Self.cellMarks) == nil
        let key = (header ? "h" : "b") + string
        if plain, let known = tableWidths[key] { return known }
        let letters = plain
            ? NSAttributedString(string: string, attributes: [.font: Fonts.text(size: em, weight: header ? .semibold : .regular)])
            : storage.attributedSubstring(from: cell)
        let width = ceil(CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(letters), nil, nil, nil)))
        if plain { tableWidths[key] = width }
        return width
    }

    /// Each column as wide as its widest cell as drawn. A plain cell's
    /// width is kept by its text: a key in a table measures its own cell.
    private func measure(_ grid: TableGrid, in storage: NSTextStorage, text: NSString) -> GridMeasure {
        let fonts = "\(AppSettings.shared.font)|\(em)"
        if tableWidthsFor != fonts || tableWidths.count > 8000 {
            tableWidths = [:]
            tableWidthsFor = fonts
        }
        // An empty column keeps room to click in.
        var widths = [CGFloat](repeating: ceil(em * 1.2), count: grid.columns)
        var cells: [[CGFloat]] = []
        for (index, row) in grid.rows.enumerated() {
            guard index != 1 else {
                cells.append([])
                continue
            }
            var own: [CGFloat] = []
            for (column, cell) in row.cells.enumerated() {
                let width = cell.length == 0 ? 0 : cellWidth(cell, header: index == 0, in: storage, text: text)
                own.append(width)
                widths[column] = max(widths[column], width)
            }
            cells.append(own)
        }
        let rtl = grid.rightToLeft(in: text)
        return GridMeasure(widths: widths, cells: cells, rtl: rtl, total: TableRowPart(role: .body, last: false, rtl: rtl, widths: widths).total(em: em))
    }

    /// The header's letters at weight 600; code and italic keep their own font.
    private func embolden(_ row: TableGrid.Row, in storage: NSTextStorage) {
        let plain = Fonts.text(size: em), bold = Fonts.text(size: em, weight: .semibold)
        for cell in row.cells where cell.length > 0 {
            var runs: [NSRange] = []
            storage.enumerateAttribute(.font, in: cell, options: []) { font, range, _ in
                if (font as? NSFont) == plain { runs.append(range) }
            }
            for run in runs { storage.addAttribute(.font, value: bold, range: run) }
        }
    }

    /// One line of a grid: its pipes and padding at no width, each cell at
    /// its column's place, the delimiter row a hairline high.
    private func apply(row index: Int, of grid: TableGrid, measure: GridMeasure, value: String, in storage: NSTextStorage, text: NSString) {
        let row = grid.rows[index]
        let whole = text.lineRange(for: row.line)
        storage.addAttribute(NoteTextView.tableRow, value: value, range: whole)
        let paragraph = NSMutableParagraphStyle()
        paragraph.baseWritingDirection = measure.rtl ? .rightToLeft : .leftToRight
        paragraph.alignment = measure.rtl ? .right : .left
        // The table fits the measure, and a letter's rounding never breaks a row in two.
        paragraph.lineBreakMode = .byClipping
        guard index != 1 else {
            paragraph.minimumLineHeight = 1
            paragraph.maximumLineHeight = 1
            storage.addAttributes(Self.hidden, range: row.line)
            storage.addAttribute(.paragraphStyle, value: paragraph, range: whole)
            return
        }
        // A line's room is above its letters: 0.35 em there, and as much under the line.
        let height = rowHeight
        paragraph.minimumLineHeight = height
        paragraph.maximumLineHeight = height
        paragraph.paragraphSpacing = Self.rowRoom(em)
        storage.addAttribute(.paragraphStyle, value: paragraph, range: whole)
        storage.removeAttribute(.kern, range: row.line)
        let pad = em * TableRowPart.side
        var from = row.line.location
        /// The room after the cell before, to its column's end.
        var owed: CGFloat = 0
        for (column, cell) in row.cells.enumerated() {
            let room = measure.widths[column] - measure.cells[index][column]
            let fromRight = cell.length > 0 ? TextDirection.ofLine(text.substring(with: cell)) ?? false : measure.rtl
            var side = column < grid.sides.count ? grid.sides[column] : .none
            // With no colon a cell stands where its own text starts, as the reader's does.
            if side == .none { side = fromRight == measure.rtl ? .start : .end }
            let before: CGFloat = side == .centre ? floor(room / 2) : side == .end ? room : 0
            let marks = NSRange(location: from, length: cell.location - from)
            if marks.length > 0 {
                storage.addAttributes(Self.hidden, range: marks)
                storage.addAttribute(.kern, value: owed + pad + before, range: NSRange(location: NSMaxRange(marks) - 1, length: 1))
            }
            if cell.length > 0 {
                // A cell's text reads in its own direction, whatever the cells beside it hold.
                let direction = (fromRight ? NSWritingDirection.rightToLeft : .leftToRight).rawValue | NSWritingDirectionFormatType.embedding.rawValue
                storage.addAttribute(.writingDirection, value: [direction], range: cell)
            }
            owed = room - before + pad
            from = NSMaxRange(cell)
        }
        if from < NSMaxRange(row.line) { storage.addAttributes(Self.hidden, range: NSRange(location: from, length: NSMaxRange(row.line) - from)) }
    }

    /// The tables of the lines just styled, drawn as grids: the rows in
    /// [styled] get their attributes, and a row outside it only when its
    /// own changed (a column grew, the last row is another). The rows
    /// outside it that must be styled from nothing -- the table became a
    /// grid, or stopped being one -- are given back.
    func drawGrids(_ tables: [TableDraw], in storage: NSTextStorage, styled: NSRange, text: NSString, mono: NSFont) -> [NSRange] {
        guard !tables.isEmpty else { return [] }
        let styledLines = text.lineRange(for: styled)
        let room = gridRoom
        var again: [NSRange] = []
        for table in tables {
            var measured: GridMeasure?
            var wide: String?
            if let grid = table.grid {
                let header = grid.rows[0].line.location
                if header >= styledLines.location, header < NSMaxRange(styledLines) { embolden(grid.rows[0], in: storage) }
                let measure = measure(grid, in: storage, text: text)
                // A table wider than the measure shows raw: the view has no box that scrolls sideways.
                if measure.total <= room { measured = measure } else { wide = "wide:\(Int(measure.total.rounded(.up)))" }
            }
            var at = table.run.location, index = 0
            while at <= NSMaxRange(table.run), at < text.length {
                let line = text.lineRange(for: NSRange(location: at, length: 0))
                let inside = at >= styledLines.location && at < NSMaxRange(styledLines)
                let had = inside ? nil : storage.attribute(NoteTextView.tableRow, at: at, effectiveRange: nil) as? String
                var want = wide
                if let grid = table.grid, let measured, index < grid.rows.count {
                    let rows = grid.rows.count
                    let role: TableRowPart.Role = index == 0 ? .header : index == 1 ? .delimiter : .body
                    want = TableRowPart(role: role, last: index == 1 ? rows == 2 : index == rows - 1 || rows == 2, rtl: measured.rtl, widths: measured.widths).value
                }
                let wantGrid = measured != nil, hadGrid = had?.hasPrefix("grid:") == true
                if inside {
                    if let grid = table.grid, let measured, let want {
                        apply(row: index, of: grid, measure: measured, value: want, in: storage, text: text)
                    } else if let wide {
                        lineUp(line, of: storage, text: text, mono: mono)
                        storage.addAttribute(NoteTextView.tableRow, value: wide, range: line)
                    }
                } else if had != want {
                    if hadGrid != wantGrid {
                        again.append(line)
                    } else if let grid = table.grid, let measured, let want {
                        apply(row: index, of: grid, measure: measured, value: want, in: storage, text: text)
                    } else if let want {
                        storage.addAttribute(NoteTextView.tableRow, value: want, range: line)
                    } else {
                        storage.removeAttribute(NoteTextView.tableRow, range: line)
                    }
                }
                guard NSMaxRange(line) > at else { break }
                at = NSMaxRange(line)
                index += 1
            }
        }
        // Lines next to each other are one piece.
        var pieces: [NSRange] = []
        for line in again {
            if let last = pieces.last, NSMaxRange(last) == line.location { pieces[pieces.count - 1] = NSUnionRange(last, line) } else { pieces.append(line) }
        }
        return pieces
    }

    /// The selection moved: the table it is in, and the one it was in,
    /// show raw or as a grid by where it is now. A move from one cell to
    /// another styles nothing.
    func followTables() {
        guard store.settings.livePreview, let view, let storage = view.textStorage, storage.length > 0 else { return }
        let text = storage.string as NSString
        let selection = view.selectedRange()
        var places = [selection.location]
        if selection.length > 0 { places.append(NSMaxRange(selection)) }
        if let last = tableAt, !places.contains(last) { places.append(last) }
        tableAt = nil
        var seen: [NSRange] = []
        for place in places where place <= text.length {
            let start = text.lineRange(for: NSRange(location: place, length: 0)).location
            guard TableGrid.isRow(text, at: start), let run = TableGrid.run(around: start, in: text), !seen.contains(run.range) else { continue }
            seen.append(run.range)
            if place == selection.location { tableAt = place }
            let had = storage.attribute(NoteTextView.tableRow, at: run.range.location, effectiveRange: nil) as? String
            // Too wide for the measure, it is raw wherever the selection is.
            if had?.hasPrefix("wide:") == true { continue }
            var want = false
            if run.whole, let grid = TableGrid(run.range, in: text) { want = blockStates.peek(before: grid.range.location, in: text) == .normal && !isRaw(grid) }
            guard want != (had != nil) else { continue }
            storage.beginEditing()
            style(storage, range: text.lineRange(for: run.range))
            storage.endEditing()
        }
    }

    /// The view is wider or narrower: a table that now fits the measure is
    /// a grid, and one that no longer does shows raw.
    func refitTables() {
        guard store.settings.livePreview, let view, let storage = view.textStorage, storage.length > 0 else { return }
        let room = gridRoom
        guard room != tableRoom else { return }
        tableRoom = room
        var again: [NSRange] = []
        storage.enumerateAttribute(NoteTextView.tableRow, in: NSRange(location: 0, length: storage.length), options: []) { value, range, _ in
            guard let value = value as? String else { return }
            let wide = value.hasPrefix("wide:")
            guard let total = wide ? Double(value.dropFirst(5)).map({ CGFloat($0) }) : TableRowPart(value)?.total(em: em), (total <= room) == wide else { return }
            again.append(range)
        }
        guard !again.isEmpty else { return }
        storage.beginEditing()
        for range in again where NSMaxRange(range) <= storage.length { style(storage, range: range) }
        storage.endEditing()
    }

    /// The caret keeps to the cells' text in a grid: off a pipe and out of
    /// the padding, on to the next cell or back to the one before, and over
    /// a row's end to the next row. A place typed to stays: a space at a
    /// cell's end is padding until the next letter. The delimiter row takes
    /// the caret as it comes, and the table shows raw.
    func cellCaret(in textView: NSTextView, from old: [NSValue], to new: [NSValue]) -> [NSValue] {
        guard store.settings.livePreview, new.count == 1, new[0].rangeValue.length == 0, let view = textView as? NoteTextView, !view.vimActive,
            !view.hasMarkedText(), let storage = view.textStorage, storage.length > 0
        else { return new }
        var offset = new[0].rangeValue.location
        if let typed = typedCaret {
            // The edit is not made yet, or this is where it leaves the caret.
            if textGeneration == typed.generation || offset == typed.offset { return new }
            typedCaret = nil
        }
        let text = storage.string as NSString
        var step = TableGrid.Step.near
        if old.count == 1, old[0].rangeValue.length == 0 {
            let moved = offset - old[0].rangeValue.location
            step = moved == 1 ? .forward : moved == -1 ? .back : .near
        }
        for _ in 0..<4 where offset <= text.length {
            var start = 0, end = 0, contents = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contents, for: NSRange(location: offset, length: 0))
            guard start < contents, let value = storage.attribute(NoteTextView.tableRow, at: start, effectiveRange: nil) as? String,
                let drawn = TableRowPart(value), drawn.role != .delimiter
            else { break }
            let row = TableGrid.row(text, line: NSRange(location: start, length: contents - start))
            // A click in a cell: the nearest place in that cell's text.
            if let click = view.clickedCell, click.line == start, click.column < row.cells.count {
                let cell = row.cells[click.column]
                offset = min(max(offset, cell.location), NSMaxRange(cell))
                break
            }
            if let place = TableGrid.caret(offset, in: row, step: step) {
                offset = place
                break
            }
            let near = TableGrid.caret(offset, in: row, step: .near) ?? offset
            if step == .forward, end > contents {
                offset = end
            } else if step == .back, start > 0 {
                offset = start - 1
            } else {
                offset = near
                break
            }
        }
        return [NSValue(range: NSRange(location: min(offset, text.length), length: 0))]
    }
}

extension NoteTextView {
    /// A line of a table drawn as a grid, and how (`TableRowPart.value`); or
    /// `wide:` and its width, for a table too wide for the measure.
    static let tableRow = NSAttributedString.Key("DaftarTableRow")

    private var em: CGFloat { controller?.em ?? 16 }

    /// Where the grid's rows start and end, across the view: the text's measure.
    private var gridSides: (left: CGFloat, right: CGFloat) {
        let padding = textContainer?.lineFragmentPadding ?? 0
        return (textContainerOrigin.x + padding, textContainerOrigin.x + (textContainer?.size.width ?? bounds.width) - padding)
    }

    /// The top and the bottom of the paragraph at [offset], in the view.
    private func paragraphSpan(at offset: Int) -> (top: CGFloat, bottom: CGFloat)? {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
            let location = content.location(content.documentRange.location, offsetBy: offset)
        else { return nil }
        if layout.textLayoutFragment(for: location)?.state != .layoutAvailable { layout.ensureLayout(for: NSTextRange(location: location)) }
        guard let frame = layout.textLayoutFragment(for: location)?.layoutFragmentFrame else { return nil }
        return (frame.minY + textContainerOrigin.y, frame.maxY + textContainerOrigin.y)
    }

    /// The box of the grid row that starts at [offset].
    func gridBox(_ row: TableRowPart, at offset: Int) -> NSRect? {
        guard let span = paragraphSpan(at: offset) else { return nil }
        let total = row.total(em: em), sides = gridSides
        return NSRect(x: row.rtl ? sides.right - total : sides.left, y: span.top, width: total, height: span.bottom - span.top)
    }

    /// The grids of the lines [rect] reaches, behind the text: the box, the
    /// header's panel, a hairline under each row and between the columns.
    func drawTables(in rect: NSRect) {
        guard let storage = textStorage, storage.length > 0, let range = offsets(in: rect) else { return }
        let text = storage.string as NSString
        storage.enumerateAttribute(Self.tableRow, in: text.lineRange(for: range), options: []) { value, run, _ in
            guard let value = value as? String, let row = TableRowPart(value) else { return }
            var at = run.location
            while at < NSMaxRange(run) {
                if let box = gridBox(row, at: at), box.insetBy(dx: -1, dy: -1).intersects(rect) { draw(row, in: box) }
                let next = NSMaxRange(text.lineRange(for: NSRange(location: at, length: 0)))
                guard next > at else { break }
                at = next
            }
        }
    }

    private func draw(_ row: TableRowPart, in box: NSRect) {
        let hairline = NSPalette.tableHairline
        let corner: CGFloat = 12
        // The header's top corners and the last row's bottom corners are the box's.
        var outline: NSBezierPath?
        switch (row.role, row.last) {
        case (.header, true): outline = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: corner, yRadius: corner)
        case (.header, false):
            outline = NSBezierPath(roundedRect: NSRect(x: box.minX + 0.5, y: box.minY + 0.5, width: box.width - 1, height: box.height + corner * 2), xRadius: corner, yRadius: corner)
        case (.body, true):
            outline = NSBezierPath(
                roundedRect: NSRect(x: box.minX + 0.5, y: box.minY - corner * 2, width: box.width - 1, height: box.height + corner * 2 - 0.5), xRadius: corner, yRadius: corner)
        default: break
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: box).addClip()
        if row.role == .header, let outline {
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            NSPalette.panel.setFill()
            box.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        hairline.setFill()
        if row.role == .delimiter {
            // The delimiter row is the hairline under the header.
            if !row.last { box.fill() }
            return
        }
        // Between the columns, in the order the cells are drawn.
        var edge: CGFloat = 0
        for width in row.widths.dropLast() {
            edge += width + em * TableRowPart.side * 2
            let x = row.rtl ? box.maxX - edge : box.minX + edge
            NSRect(x: (x - 0.5).rounded(), y: box.minY, width: 1, height: box.height).fill()
        }
        if row.role == .body, !row.last { NSRect(x: box.minX, y: box.maxY - 1, width: box.width, height: 1).fill() }
        if let outline {
            hairline.setStroke()
            outline.lineWidth = 1
            outline.stroke()
        } else {
            NSRect(x: box.minX, y: box.minY, width: 1, height: box.height).fill()
            NSRect(x: box.maxX - 1, y: box.minY, width: 1, height: box.height).fill()
        }
    }

    /// The cell of a grid under [point]: its line's start and its column.
    func gridCell(at point: NSPoint) -> (line: Int, column: Int)? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let text = storage.string as NSString
        let start = text.lineRange(for: NSRange(location: min(characterIndexForInsertion(at: point), text.length), length: 0)).location
        guard start < storage.length, let value = storage.attribute(Self.tableRow, at: start, effectiveRange: nil) as? String, let row = TableRowPart(value),
            row.role != .delimiter, let box = gridBox(row, at: start), box.contains(point)
        else { return nil }
        var edge: CGFloat = 0
        let from = row.rtl ? box.maxX - point.x : point.x - box.minX
        for (column, width) in row.widths.enumerated() {
            edge += width + em * TableRowPart.side * 2
            if from <= edge { return (start, column) }
        }
        return nil
    }

    /// The text of the grid's cell the caret is in, its two ends counted.
    /// Nil with a selection, with many cursors, in Neovim mode, on a line
    /// that is no row of a drawn grid, and in a cell's padding, where an
    /// edit left the caret (a space or a pipe just typed).
    func caretCell() -> NSRange? {
        guard !vimActive, !hasManyCursors, controller?.store.settings.livePreview == true, let storage = textStorage, storage.length > 0 else { return nil }
        let selection = selectedRange()
        guard selection.length == 0, selection.location <= storage.length else { return nil }
        let text = storage.string as NSString
        var start = 0, contents = 0
        text.getLineStart(&start, end: nil, contentsEnd: &contents, for: NSRange(location: selection.location, length: 0))
        guard start < contents, let value = storage.attribute(Self.tableRow, at: start, effectiveRange: nil) as? String, let drawn = TableRowPart(value),
            drawn.role != .delimiter
        else { return nil }
        return TableGrid.row(text, line: NSRange(location: start, length: contents - start)).cells.first {
            selection.location >= $0.location && selection.location <= NSMaxRange($0)
        }
    }

    /// A key that deletes, with the caret in a grid's cell.
    enum CellDelete {
        case back, forward, wordBack, wordForward, toStart, toEnd
    }

    /// A delete key in a grid's cell takes that cell's text and no more: the
    /// pipes and the padding beside it are not drawn, and a key never takes
    /// what the person cannot see. So Backspace at a cell's start and Delete
    /// at its end do nothing, and a word or a line is cut at the cell's
    /// ends. True when the key is used. A pipe goes with a selection over
    /// it, which shows the table raw.
    func deleteInCell(_ kind: CellDelete) -> Bool {
        guard let cell = caretCell(), let storage = textStorage else { return false }
        let caret = selectedRange().location
        let gone: NSRange
        switch kind {
        case .back:
            return caret == cell.location
        case .forward:
            return caret == NSMaxRange(cell)
        case .wordBack:
            let from = caret > cell.location ? max(cell.location, storage.nextWord(from: caret, forward: false)) : caret
            gone = NSRange(location: from, length: caret - from)
        case .wordForward:
            let to = caret < NSMaxRange(cell) ? min(NSMaxRange(cell), storage.nextWord(from: caret, forward: true)) : caret
            gone = NSRange(location: caret, length: to - caret)
        case .toStart:
            gone = NSRange(location: cell.location, length: caret - cell.location)
        case .toEnd:
            gone = NSRange(location: caret, length: NSMaxRange(cell) - caret)
        }
        if gone.length > 0 { replace(gone, with: "", select: NSRange(location: gone.location, length: 0)) }
        return true
    }

    override func deleteForward(_ sender: Any?) {
        if deleteInCell(.forward) { return }
        super.deleteForward(sender)
    }

    override func deleteWordBackward(_ sender: Any?) {
        if deleteInCell(.wordBack) { return }
        super.deleteWordBackward(sender)
    }

    override func deleteWordForward(_ sender: Any?) {
        if deleteInCell(.wordForward) { return }
        super.deleteWordForward(sender)
    }

    override func deleteToBeginningOfLine(_ sender: Any?) {
        if deleteInCell(.toStart) { return }
        super.deleteToBeginningOfLine(sender)
    }

    override func deleteToBeginningOfParagraph(_ sender: Any?) {
        if deleteInCell(.toStart) { return }
        super.deleteToBeginningOfParagraph(sender)
    }

    override func deleteToEndOfLine(_ sender: Any?) {
        if deleteInCell(.toEnd) { return }
        super.deleteToEndOfLine(sender)
    }

    override func deleteToEndOfParagraph(_ sender: Any?) {
        if deleteInCell(.toEnd) { return }
        super.deleteToEndOfParagraph(sender)
    }

    /// A plain click in a grid's cell, kept while the click moves the caret.
    func noteCellClick(_ event: NSEvent) {
        clickedCell = nil
        guard event.clickCount == 1, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty, !vimActive,
            controller?.store.settings.livePreview == true
        else { return }
        clickedCell = gridCell(at: convert(event.locationInWindow, from: nil))
    }

    /// After the view's width changed: the tables fit the measure again, a turn later.
    func refitTablesSoon() {
        guard !refitPending else { return }
        refitPending = true
        DispatchQueue.main.async { [weak self] in
            self?.refitPending = false
            self?.controller?.refitTables()
        }
    }
}

extension NSPalette {
    /// The line around a table and between its rows and columns, the reader's `--table-hairline`.
    static let tableHairline = dynamic(dark: 0x4A4A4A, light: 0xD8D5CC)
}
