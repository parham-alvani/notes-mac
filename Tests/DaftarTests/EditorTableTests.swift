import AppKit
import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// Where `EditorTableTests.picture` writes the editor as a picture, when asked:
/// `DAFTAR_TABLE_PICTURE=/tmp/table swift test --filter EditorTableTests/picture`
/// writes `/tmp/table-dark.png` and `/tmp/table-light.png`. The views draw
/// it, so it needs no screen and brings no window to the front.
private let tablePicture = ProcessInfo.processInfo.environment["DAFTAR_TABLE_PICTURE"]

/// A Markdown table drawn as a grid in the editor, and its keys, on a
/// made-up vault in a temporary folder (docs/specs/look.md in notes-linux,
/// part 2).
@MainActor
@Suite(.serialized) struct EditorTableTests {
    let root: URL
    let store: VaultStore
    let controller: EditorController
    let view: NoteTextView
    let window: NSWindow

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-table-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Notes"), withIntermediateDirectories: true)
        let settings = AppSettings(url: root.appending(path: "config/config.toml"))
        store = VaultStore(settings: settings, openVault: false)
        store.openSynchronously(root)
        controller = EditorController(store: store)
        let scroll = NoteTextView.scrollableNoteView()
        view = scroll.documentView as! NoteTextView
        view.controller = controller
        controller.view = view
        // Off every screen: the view is laid out, and nothing is shown.
        window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 760, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        // One step to undo for each key: a test has no event loop to close a group.
        view.undoManager?.groupsByEvent = false
    }

    var text: NSString { view.string as NSString }
    var size: CGFloat { CGFloat(store.settings.textSize) }

    static let table = "| A | B |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |"

    func open(_ note: String) throws {
        try note.write(to: root.appending(path: "Notes/Table.md"), atomically: true, encoding: .utf8)
        store.openSynchronously(root)
        controller.load("Notes/Table.md")
    }

    func at(_ word: String) -> Int { text.range(of: word).location }

    func caret(in word: String, plus: Int = 0) {
        view.setSelectedRange(NSRange(location: at(word) + plus, length: 0))
    }

    /// How the line of [word] is drawn: a grid's row, when it is one.
    func row(at word: String) -> TableRowPart? {
        let start = text.lineRange(for: text.range(of: word)).location
        return (view.textStorage?.attribute(NoteTextView.tableRow, at: start, effectiveRange: nil) as? String).flatMap(TableRowPart.init)
    }

    func attribute<T>(_ key: NSAttributedString.Key, at offset: Int) -> T? {
        view.textStorage?.attribute(key, at: offset, effectiveRange: nil) as? T
    }

    func hidden(_ offset: Int) -> Bool { (attribute(.foregroundColor, at: offset) as NSColor?) == .clear }

    /// One key as one undo step.
    func key(_ action: () -> Void) {
        view.undoManager?.beginUndoGrouping()
        action()
        view.undoManager?.endUndoGrouping()
    }

    func cell(_ word: String) -> String {
        let place = at(word)
        let line = text.lineRange(for: NSRange(location: place, length: 0))
        let row = TableGrid.row(text, line: NSRange(location: line.location, length: text.substring(with: line).trimmingCharacters(in: .newlines).utf16.count))
        return row.cell(at: view.selectedRange().location).map { text.substring(with: row.cells[$0]) } ?? ""
    }

    @Test func aTableIsDrawnAsAGridAndTheTextStaysATable() throws {
        let note = "Top\n\n" + Self.table + "\n\nEnd\n"
        try open(note)
        // Each line knows its part of the grid; the last row closes the box.
        #expect(row(at: "| A")?.role == .header && row(at: "| ---")?.role == .delimiter)
        #expect(row(at: "| 1")?.role == .body && row(at: "| 1")?.last == false && row(at: "| 3")?.last == true)
        #expect(row(at: "Top") == nil && row(at: "End") == nil)
        // The pipes and the padding spaces are drawn at no width, and the cells' text is.
        let header = at("| A")
        for offset in [0, 1, 3, 4, 5, 7, 8] { #expect(hidden(header + offset), "\(offset)") }
        #expect(!hidden(at("A")) && !hidden(at("B")) && !hidden(at("4")))
        #expect((attribute(.font, at: header) as NSFont?)?.pointSize ?? 1 < 0.1)
        // The room at a cell's side is after the hidden mark before it: 0.7 em before the first cell,
        // and the rest of the column before it with the two sides between two cells.
        let widths = try #require(row(at: "| A")?.widths)
        #expect(widths.count == 2)
        #expect((attribute(.kern, at: at("A") - 1) as CGFloat?) == size * 0.7)
        let letter = ceil(("1" as NSString).size(withAttributes: [.font: Fonts.text(size: size)]).width)
        #expect((attribute(.kern, at: at("2") - 1) as CGFloat?) == widths[0] - letter + size * 1.4)
        // The header at weight 600, the delimiter row a hairline high and not drawn as text.
        #expect((attribute(.font, at: at("A")) as NSFont?) == Fonts.text(size: size, weight: .semibold))
        #expect((attribute(.font, at: at("1")) as NSFont?) == Fonts.text(size: size))
        #expect((attribute(.paragraphStyle, at: at("---")) as NSParagraphStyle?)?.maximumLineHeight == 1)
        #expect(hidden(at("---")))
        // A row's line has 0.35 em of room above its text and as much under it.
        let paragraph = try #require(attribute(.paragraphStyle, at: at("1")) as NSParagraphStyle?)
        #expect(paragraph.paragraphSpacing == ceil(size * 0.35) && paragraph.maximumLineHeight == paragraph.minimumLineHeight)
        // The box is as wide as its columns, and the rows stand under each other.
        let first = try #require(row(at: "| 1")), second = try #require(row(at: "| 3"))
        let box = try #require(view.gridBox(first, at: at("| 1")))
        #expect(box.width == widths[0] + widths[1] + size * 2.8)
        let under = try #require(view.gridBox(second, at: at("| 3")))
        #expect(abs(under.minY - box.maxY) < 0.5 && under.minX == box.minX)
        // The text is the file's: nothing was written.
        #expect(view.string == note)
        // Live preview off: the table is raw, in the code font.
        store.settings.livePreview = false
        controller.restyle(all: true)
        #expect(row(at: "| A") == nil && !hidden(header))
        #expect((attribute(.font, at: at("A")) as NSFont?) == Fonts.code(size: size * 0.86))
        store.settings.livePreview = true
    }

    @Test func onlyAHeaderWithItsDelimiterRowAtTheLinesStartIsAGrid() throws {
        let rows = (0..<201).map { "| \($0)x | y |" }.joined(separator: "\n")
        try open("| A | B |\n\n| C | D |\n| 1 | 2 |\n\n> | Q | R |\n> | --- | --- |\n\n```\n| X | Y |\n| --- | --- |\n```\n\n| Many | rows |\n| --- | --- |\n" + rows + "\n\n| H | I |\n| --- | --- |\n")
        for word in ["| A", "| C", "| 1", "| Q", "| X", "| Many", "| 200x"] { #expect(row(at: word) == nil, "\(word)") }
        // In a code block the lines are code.
        #expect((attribute(NoteTextView.codeBlock, at: at("| X")) as Bool?) == true)
        // A header and its delimiter row alone are a grid already: the box closes under the header.
        #expect(row(at: "| H")?.role == .header && row(at: "| H")?.last == true)
        // One row less, and the 200 rows are a grid.
        let last = text.lineRange(for: text.range(of: "| 200x"))
        key { view.insertText("", replacementRange: last) }
        #expect(row(at: "| Many")?.role == .header && row(at: "| 0x")?.role == .body && row(at: "| 199x")?.last == true)
    }

    @Test func theTableShowsRawOnTheDelimiterRowAndUnderASelectionOverTwoCells() throws {
        try open("Top\n\n" + Self.table + "\n\nEnd\n")
        // The caret in a cell: the pipes stay away, the cell is edited in place.
        caret(in: "1")
        #expect(row(at: "| 1") != nil && hidden(at("| 1")))
        // On the delimiter row the whole table is raw, in the code font.
        caret(in: "---")
        for word in ["| A", "| ---", "| 1", "| 3"] { #expect(row(at: word) == nil && !hidden(at(word)), "\(word)") }
        #expect((attribute(.font, at: at("A")) as NSFont?) == Fonts.code(size: size * 0.86))
        #expect((attribute(.paragraphStyle, at: at("---")) as NSParagraphStyle?)?.maximumLineHeight == 0)
        caret(in: "4")
        for word in ["| A", "| ---", "| 1", "| 3"] { #expect(row(at: word) != nil, "\(word)") }
        // A selection in one cell keeps the grid; one that reaches a second cell shows the table raw.
        view.setSelectedRange(NSRange(location: at("3"), length: 1))
        #expect(row(at: "| A") != nil)
        view.setSelectedRange(NSRange(location: at("3"), length: 5))
        for word in ["| A", "| 1", "| 3"] { #expect(row(at: word) == nil, "\(word)") }
        view.setSelectedRange(NSRange(location: at("3"), length: 1))
        #expect(row(at: "| A") != nil && row(at: "| 3") != nil)
        // A selection from above that reaches into the table, and Select All.
        view.setSelectedRange(NSRange(location: 0, length: at("B")))
        #expect(row(at: "| A") == nil && row(at: "| 3") == nil)
        view.setSelectedRange(NSRange(location: 0, length: text.length))
        #expect(row(at: "| 3") == nil)
        caret(in: "End")
        #expect(row(at: "| A") != nil && row(at: "| ---") != nil && row(at: "| 3") != nil)
    }

    @Test func aKeyInACellStylesItsTableAndTheTextIsWhatWasTyped() throws {
        try open("Top\n\n" + Self.table + "\n\nEnd\n")
        let before = try #require(row(at: "| A")?.widths)
        // Letters in a cell: the column grows in every row, and only the letters are in the text.
        caret(in: "1", plus: 1)
        key { view.insertText("23456789", replacementRange: view.selectedRange()) }
        #expect(view.string == "Top\n\n| A | B |\n| --- | --- |\n| 123456789 | 2 |\n| 3 | 4 |\n\nEnd\n")
        let after = try #require(row(at: "| A")?.widths)
        #expect(after[0] > before[0] && after[1] == before[1])
        #expect(row(at: "| 3")?.widths == after && row(at: "| 123")?.widths == after)
        // A space typed at a cell's end is padding until the next letter: the caret stays after it.
        key { view.insertText(" ", replacementRange: view.selectedRange()) }
        #expect(view.selectedRange().location == at("9") + 2)
        key { view.insertText("x", replacementRange: view.selectedRange()) }
        #expect(text.substring(with: text.lineRange(for: text.range(of: "9"))) == "| 123456789 x | 2 |\n")
        // A pipe typed is a pipe: the row has one more cell, and so has the grid.
        caret(in: "| 4", plus: 3)
        key { view.insertText(" | 5", replacementRange: view.selectedRange()) }
        #expect(row(at: "| A")?.widths.count == 3 && view.string.contains("| 3 | 4 | 5 |\n"))
        // The delimiter row taken away: no grid. Put back: the grid.
        let delimiter = text.lineRange(for: text.range(of: "| ---"))
        key { view.insertText("", replacementRange: delimiter) }
        for word in ["| A", "| 123", "| 3"] { #expect(row(at: word) == nil && !hidden(at(word)), "\(word)") }
        view.undoManager?.undo()
        for word in ["| A", "| ---", "| 123", "| 3"] { #expect(row(at: word) != nil, "\(word)") }
        // A line that is no row ends the table above it.
        caret(in: "| 3")
        key { view.insertText("text\n", replacementRange: NSRange(location: at("| 3"), length: 0)) }
        #expect(row(at: "| 123")?.last == true && row(at: "| 3") == nil && !hidden(at("| 3")))
    }

    @Test func enterGoesToTheRowBelowAndAddsARow() throws {
        try open("Top\n\n" + Self.table + "\n\nEnd\n")
        let formatted = "| A   | B   |\n| --- | --- |\n| 1   | 2   |\n| 3   | 4   |"
        // In `2`: the start of `4`, and the table is formatted.
        caret(in: "2", plus: 1)
        key { view.insertNewline(nil) }
        #expect(view.string == "Top\n\n" + formatted + "\n\nEnd\n")
        #expect(view.selectedRange() == NSRange(location: at("4"), length: 0))
        // In `4`: a new empty row, the caret in its second cell.
        key { view.insertNewline(nil) }
        #expect(view.string == "Top\n\n" + formatted + "\n|     |     |\n\nEnd\n")
        #expect(view.selectedRange() == NSRange(location: at("|     |     |") + 8, length: 0))
        #expect(row(at: "|     |")?.last == true && row(at: "| 3")?.last == false)
        // On the empty last row: the table ends, the caret on an empty line under it.
        key { view.insertNewline(nil) }
        #expect(view.string == "Top\n\n" + formatted + "\n\n\nEnd\n")
        #expect(view.selectedRange() == NSRange(location: at("4   |") + 6, length: 0))
        #expect(row(at: "| 3")?.last == true)
        // Each key is one step to undo, with its formatting.
        view.undoManager?.undo()
        #expect(view.string == "Top\n\n" + formatted + "\n|     |     |\n\nEnd\n")
        view.undoManager?.undo()
        #expect(view.string == "Top\n\n" + formatted + "\n\nEnd\n")
        view.undoManager?.undo()
        #expect(view.string == "Top\n\n" + Self.table + "\n\nEnd\n")
        // On the header row: the first row under the delimiter row. Control-Return is the same key.
        caret(in: "B")
        key { view.insertLineBreak(nil) }
        #expect(view.selectedRange() == NSRange(location: at("2"), length: 0))
        // Raw, the key is the same: on the delimiter row it goes to the row under it.
        caret(in: "---")
        #expect(row(at: "| A") == nil)
        key { view.insertNewline(nil) }
        #expect(view.selectedRange() == NSRange(location: at("1"), length: 0) && row(at: "| A") != nil)
        // A row with no delimiter row under a header is as before: Return in it breaks the line.
        try open("| A | B |\n\nEnd\n")
        caret(in: "A", plus: 1)
        key { view.insertNewline(nil) }
        #expect(view.string == "| A\n | B |\n\nEnd\n")
    }

    @Test func tabMovesBetweenCellsAndAddsARow() throws {
        try open("Top\n\n" + Self.table + "\n\nEnd\n")
        caret(in: "1")
        key { view.insertTab(nil) }
        #expect(cell("2") == "2" && view.selectedRange().location == at("2"))
        key { view.insertTab(nil) }
        #expect(view.selectedRange().location == at("3"))
        // The delimiter row is passed over.
        caret(in: "B")
        key { view.insertTab(nil) }
        #expect(view.selectedRange().location == at("1"))
        key { view.insertBacktab(nil) }
        #expect(view.selectedRange().location == at("B"))
        caret(in: "A")
        key { view.insertBacktab(nil) }
        #expect(view.selectedRange().location == at("A"))
        // In the last cell: a new empty row, the caret in its first cell; one step to undo.
        caret(in: "4")
        key { view.insertTab(nil) }
        #expect(view.string.hasSuffix("| 3   | 4   |\n|     |     |\n\nEnd\n"))
        #expect(view.selectedRange().location == at("|     |     |") + 2)
        #expect(row(at: "|     |")?.last == true)
        view.undoManager?.undo()
        #expect(view.string.hasSuffix("| 3   | 4   |\n\nEnd\n"))
    }

    @Test func theCaretKeepsToTheCellsText() throws {
        try open("Top\n\n| A   | Bc  |\n| --- | --- |\n| 1   |     |\n\nEnd\n")
        // Right at a cell's end: the next cell's text, over the padding and the pipe.
        caret(in: "A", plus: 1)
        view.moveRight(nil)
        #expect(view.selectedRange().location == at("Bc"))
        view.moveLeft(nil)
        #expect(view.selectedRange().location == at("A") + 1)
        // The start and the end of the line are the first cell's start and the last cell's end.
        view.moveToEndOfLine(nil)
        #expect(view.selectedRange().location == at("Bc") + 2)
        view.moveToBeginningOfLine(nil)
        #expect(view.selectedRange().location == at("A"))
        // Left at the first cell's start leaves the table; right from above comes into the first cell.
        view.moveLeft(nil)
        #expect(view.selectedRange().location == at("| A") - 1)
        view.moveRight(nil)
        #expect(view.selectedRange().location == at("A"))
        // Right at a row's end goes on to the delimiter row, where the table is raw and the caret is free.
        caret(in: "Bc", plus: 2)
        view.moveRight(nil)
        #expect(view.selectedRange().location == at("| ---") && row(at: "| A") == nil)
        // An empty cell holds the caret between its two padding spaces.
        caret(in: "1", plus: 1)
        #expect(row(at: "| A") != nil)
        view.moveRight(nil)
        #expect(view.selectedRange().location == at("|     |") + 2)
        // A place on a pipe or in the padding, as a click or a line up or down gives it: the nearest cell's text.
        view.setSelectedRange(NSRange(location: at("| 1"), length: 0))
        #expect(view.selectedRange().location == at("1"))
        view.setSelectedRange(NSRange(location: at("|     |") + 5, length: 0))
        #expect(view.selectedRange().location == at("|     |") + 2)
        // A click in a cell: that cell, at the place in its text nearest the click.
        let drawn = try #require(row(at: "| A"))
        let box = try #require(view.gridBox(drawn, at: at("| A")))
        let first = try #require(view.gridCell(at: NSPoint(x: box.minX + 4, y: box.midY)))
        #expect(first.line == at("| A") && first.column == 0)
        #expect(view.gridCell(at: NSPoint(x: box.maxX - 4, y: box.midY))?.column == 1)
        #expect(view.gridCell(at: NSPoint(x: box.maxX + 20, y: box.midY)) == nil)
        view.clickedCell = (at("| A"), 1)
        view.setSelectedRange(NSRange(location: at("A") + 1, length: 0))
        view.clickedCell = nil
        #expect(view.selectedRange().location == at("Bc"))
    }

    @Test func aPersianTableReadsFromTheRight() throws {
        let note = "Top\n\n| نام | Age | نقش |\n| --- | --- | --- |\n| علی | 30 | مهندس |\n\n| Item | مورد |\n| :-- | --: |\n| Tea | چای |\n"
        try open(note)
        // The first cell with a letter gives the table its direction: the columns go from the right.
        let persian = try #require(row(at: "| نام"))
        #expect(persian.rtl)
        let paragraph = try #require(attribute(.paragraphStyle, at: at("علی")) as NSParagraphStyle?)
        #expect(paragraph.baseWritingDirection == .rightToLeft && paragraph.alignment == .right)
        let box = try #require(view.gridBox(persian, at: at("| نام")))
        let sides = view.textContainerOrigin.x + (view.textContainer?.size.width ?? 0) - (view.textContainer?.lineFragmentPadding ?? 0)
        #expect(abs(box.maxX - sides) < 0.5)
        // Each cell's text reads in its own direction, whatever stands beside it.
        let rtl = [NSWritingDirection.rightToLeft.rawValue | NSWritingDirectionFormatType.embedding.rawValue]
        let ltr = [NSWritingDirection.leftToRight.rawValue | NSWritingDirectionFormatType.embedding.rawValue]
        #expect((attribute(.writingDirection, at: at("علی")) as [Int]?) == rtl)
        #expect((attribute(.writingDirection, at: at("30")) as [Int]?) == ltr)
        // The first column is drawn at the right: its text is right of the second column's.
        let name = try #require(view.letterBox(text.range(of: "علی"))), age = try #require(view.letterBox(text.range(of: "30")))
        let job = try #require(view.letterBox(text.range(of: "مهندس")))
        #expect(name.minX > age.maxX && age.minX > job.maxX)
        #expect(name.maxX <= box.maxX && job.minX >= box.minX)
        // In a table that reads from the left, a Persian cell keeps its own direction in its column.
        let mixed = try #require(row(at: "| Item"))
        #expect(!mixed.rtl)
        #expect((attribute(.writingDirection, at: at("چای")) as [Int]?) == rtl)
        let tea = try #require(view.letterBox(text.range(of: "Tea"))), chai = try #require(view.letterBox(text.range(of: "چای")))
        #expect(tea.maxX < chai.minX)
        // Tab in it formats the table and goes to the next cell; the text is a Markdown table still.
        caret(in: "علی")
        key { view.insertTab(nil) }
        #expect(view.selectedRange().location == at("30"))
        #expect(view.string.contains("| نام | Age | نقش   |\n| --- | --- | ----- |\n| علی | 30  | مهندس |\n"))
        #expect(row(at: "| نام")?.rtl == true)
    }

    @Test func aTableWiderThanTheMeasureShowsRaw() throws {
        let wide = "| " + (0..<14).map { "Column \($0)" }.joined(separator: " | ") + " |\n| " + (0..<14).map { _ in "---" }.joined(separator: " | ") + " |\n"
        try open("Top\n\n" + wide + "\n| A | B |\n| --- | --- |\n")
        // No box that scrolls sideways: the table is raw, in the code font, and wraps as text.
        #expect(row(at: "| Column") == nil && !hidden(at("| Column")))
        #expect((attribute(NoteTextView.tableRow, at: at("| Column")) as String?)?.hasPrefix("wide:") == true)
        #expect((attribute(.font, at: at("Column 3")) as NSFont?) == Fonts.code(size: size * 0.86))
        #expect(row(at: "| A") != nil)
        // In a pane too narrow for it, the small table is raw too; wide again, a grid.
        window.setContentSize(NSSize(width: 110, height: 500))
        view.enclosingScrollView?.layoutSubtreeIfNeeded()
        controller.refitTables()
        #expect(row(at: "| A") == nil && !hidden(at("| A")))
        window.setContentSize(NSSize(width: 760, height: 500))
        view.enclosingScrollView?.layoutSubtreeIfNeeded()
        controller.refitTables()
        #expect(row(at: "| A")?.role == .header && row(at: "| Column") == nil)
    }

    @Test func aRowReadsBackAsItWasWritten() {
        let rows = [
            TableRowPart(role: .header, last: false, rtl: false, widths: [12, 40.5]), TableRowPart(role: .body, last: true, rtl: true, widths: [20]),
            TableRowPart(role: .delimiter, last: false, rtl: false, widths: [19.2, 19.2, 30]),
        ]
        for row in rows { #expect(TableRowPart(row.value) == row) }
        #expect(TableRowPart("wide:900") == nil && TableRowPart("nothing") == nil)
        #expect(rows[0].total(em: 10) == 12 + 40.5 + 28)
    }

    /// The editor with tables in it, as a picture, to look at.
    @Test(.enabled(if: tablePicture != nil)) func picture() throws {
        let note = """
            # Tables

            Text before the table, to the measure of the editor.

            | Name | Role | Since |
            | :-- | :-: | --: |
            | Parham | **Engineer** with `code` | 2019 |
            | A longer name | [a link](https://example.com) | 7 |
            | ==marked== |  | 2026-11-22 |

            | نام | نقش | سال |
            | --- | --- | --- |
            | پرهام | مهندس | 1398 |
            | Elaheh | طراح | 2020 |

            | Item | مورد | Price |
            | --- | --- | --: |
            | Bread | نان | 2.50 |
            | The caret is here | چای | 12 |

            | Only | A header |
            | --- | --- |

            | Raw | under | a selection |
            | --- | --- | --- |
            | one | two | three |

            > | In | a quote |
            > | --- | --- |
            > | is | as before |

            | Wide | Table | That | Does | Not | Fit | The | Measure | Of | The | Editor | At | All |
            | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
            | wide | table | that | does | not | fit | the | measure | of | the | editor | at | all |

            After.

            """
        try open(note)
        window.setContentSize(NSSize(width: 820, height: 1250))
        caret(in: "The caret is here", plus: 4)
        let scroll = try #require(view.enclosingScrollView)
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            window.appearance = NSAppearance(named: appearance)
            controller.restyle(all: true)
            // A selection over two cells shows its table raw; then the caret goes to a cell of another.
            view.setSelectedRange(NSRange(location: at("under"), length: 12))
            caret(in: "The caret is here", plus: 4)
            scroll.layoutSubtreeIfNeeded()
            scroll.displayIfNeeded()
            let bitmap = try #require(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
            scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(filePath: "\(tablePicture ?? "")-\(name).png"))
        }
    }
}
