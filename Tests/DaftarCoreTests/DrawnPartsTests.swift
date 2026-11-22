import Foundation
import Testing

@testable import DaftarCore

/// What the editor draws in place of its text: the task box, the date
/// chips, a callout and a code block (docs/specs/look.md in notes-linux,
/// part 2; the spec's tests by name, with today as 2026-11-22).
@Suite struct DrawnPartsTests {
    let today = Day(year: 2026, month: 11, day: 22)
    /// A vault with `[r]` "In Review".
    let statuses = TaskStatuses(json: TaskReasonTests.settings)

    func kinds(_ text: String) -> [MarkdownHighlighter.Kind: [String]] {
        var out: [MarkdownHighlighter.Kind: [String]] = [:]
        for span in MarkdownHighlighter.spans(in: text, today: today.description) {
            out[span.kind, default: []].append((text as NSString).substring(with: span.range))
        }
        return out
    }

    @Test func aTaskBoxIsDrawnWhenTheMarkIsComplete() {
        #expect(TaskBox.find(in: "- [ ] ") != nil)
        #expect(TaskBox.find(in: "- [ ]") == nil)
        for line in ["  * [x] a", "1. [/] a", "> - [ ] a", "- [r] a"] { #expect(TaskBox.find(in: line) != nil, "\(line)") }
        for line in ["- [] a", "- [xx] a", "-[ ] a", "[ ] a"] { #expect(TaskBox.find(in: line) == nil, "\(line)") }
        // The styling draws it where the rule says, and not in code.
        #expect(kinds("- [ ] a")[.taskBox] == ["- [ ]"])
        #expect(kinds("```\n- [ ] a\n```")[.taskBox] == nil)
        #expect(kinds("---\ntitle: x\n- [ ] a\n---")[.taskBox] == nil)
        #expect(kinds("- [ ]")[.taskBox] == nil)
    }

    @Test func theBoxCoversTheMarkAndTheBrackets() throws {
        let box = try #require(TaskBox.find(in: "- [ ] Buy"))
        #expect(box.cover == NSRange(location: 0, length: 5))
        #expect(box.text == 6)
        #expect(try #require(TaskBox.find(in: "1. [x] a")).cover == NSRange(location: 3, length: 3))
        // The indent and a quote's marks stay; the marker goes with the brackets.
        #expect(try #require(TaskBox.find(in: "  * [x] a")).cover == NSRange(location: 2, length: 5))
        #expect(try #require(TaskBox.find(in: "> - [ ] a")).cover == NSRange(location: 2, length: 5))
        for caret in [0, 3, 5] { #expect(!box.isDrawn(with: NSRange(location: caret, length: 0)), "\(caret)") }
        #expect(box.isDrawn(with: NSRange(location: 6, length: 0)))
        // A selection that reaches into the marks shows them, too.
        #expect(!box.isDrawn(with: NSRange(location: 4, length: 3)))
        #expect(box.isDrawn(with: NSRange(location: 6, length: 3)))
    }

    @Test func aClickOnTheBoxIsTheTaskToggle() throws {
        let day = today.description
        let open = "- [ ] Call ➕ 2026-11-20"
        let done = try #require(TaskBox.clicked(open, today: day))
        #expect(done == ["- [x] Call ➕ 2026-11-20 ✅ 2026-11-22"])
        #expect(TaskBox.clicked(done[0], today: day) == [open])
        #expect(TaskBox.clicked("- [/] a", today: day) == ["- [x] a ✅ 2026-11-22"])
        #expect(TaskBox.clicked("- [-] a ❌ 2026-11-01", today: day) == ["- [ ] a"])
        #expect(TaskBox.clicked("- [/] a [reason:: waiting]", today: day) == ["- [x] a ✅ 2026-11-22"])
        // No box, no click.
        #expect(TaskBox.clicked("- [ ]", today: day) == nil)
        #expect(TaskBox.clicked("Call", today: day) == nil)
        // The result is always what the task toggle gives.
        let lines = [open, done[0], "- [/] a", "- [-] a ❌ 2026-11-01", "1. [r] b", "> - [ ] Water 🔁 every week 📅 2026-11-20", "- [x] c ✅ 2026-11-01 ^id"]
        for line in lines {
            #expect(TaskBox.clicked(line, today: day, statuses: statuses) == TaskLine.toggled(line, today: day, statuses: statuses), "\(line)")
        }
        // The caret keeps its offset in the line; a place before the line stays, one after moves with the text.
        let line = NSRange(location: 10, length: (open as NSString).length)
        #expect(TaskBox.moved(17, line: line, lines: done) == 17)
        #expect(TaskBox.moved(4, line: line, lines: done) == 4)
        #expect(TaskBox.moved(NSMaxRange(line) + 3, line: line, lines: done) == NSMaxRange(line) + 3 + 13)
        // A task opened again is shorter: the caret past its end goes to its end.
        let closed = NSRange(location: 0, length: (done[0] as NSString).length)
        #expect(TaskBox.moved(closed.length, line: closed, lines: [open]) == (open as NSString).length)
        // A repeating task leaves its next occurrence above: the caret stays on the same text.
        let repeating = "- [ ] Water 🔁 every week 📅 2026-11-20"
        let two = try #require(TaskBox.clicked(repeating, today: day))
        #expect(two.count == 2)
        let above = (two[0] as NSString).length + 1
        #expect(TaskBox.moved(8, line: NSRange(location: 0, length: (repeating as NSString).length), lines: two) == above + 8)
    }

    @Test func eachStatusHasItsDrawing() {
        #expect(TaskBox.drawing(" ") == TaskBox.Drawing("square", "listMarker"))
        #expect(TaskBox.drawing("x") == TaskBox.Drawing("square-check-big", "done"))
        #expect(TaskBox.drawing("X") == TaskBox.Drawing("square-check-big", "done"))
        #expect(TaskBox.drawing("/") == TaskBox.Drawing("square-dot", "accent"))
        #expect(TaskBox.drawing("-") == TaskBox.Drawing("square-x", "done"))
        #expect(TaskBox.drawing(">") == TaskBox.Drawing("square-arrow-right", "blue"))
        #expect(TaskBox.drawing("r", statuses: statuses) == TaskBox.Drawing("square-dot", "accent"))
        #expect(TaskBox.drawing("~", statuses: statuses) == TaskBox.Drawing("square-dashed", "listMarker"))
        #expect(TaskBox.drawing("r", statuses: .defaults) == TaskBox.Drawing("square-dashed", "listMarker"))
    }

    @Test func datesOnATaskAreChips() {
        let line = "- [ ] Pay 📅 2026-11-20 ⏳ 2026-11-18 🔁 every week ➕ 2026-11-01"
        let chips = DateChip.chips(in: line, today: today)
        #expect(chips.map { (line as NSString).substring(with: $0.range) } == ["📅 2026-11-20", "⏳ 2026-11-18", "🔁 every week", "➕ 2026-11-01"])
        #expect(chips.map(\.kind) == [.late, .scheduled, .repeats, .created])
        #expect(DateChip.chips(in: "- [ ] a 📅 2026-02-30", today: today).isEmpty)
        #expect(DateChip.chips(in: "Meeting 📅 2026-11-20", today: today).isEmpty)
        // A rule ends before a priority and before a block id; a date in code is code.
        let rule = "- [ ] a 🔁 every 2 weeks on Monday ⏫ ^abc"
        #expect(DateChip.chips(in: rule, today: today).map { (rule as NSString).substring(with: $0.range) } == ["🔁 every 2 weeks on Monday"])
        let last = "- [ ] a 🔁 every day ^abc"
        #expect(DateChip.chips(in: last, today: today).map { (last as NSString).substring(with: $0.range) } == ["🔁 every day"])
        // A mark outside the basic plane is found with no other mark on the line.
        for (line, want) in [("- [ ] a 🛫 2026-11-20", ["🛫 2026-11-20"]), ("- [ ] a 🔁 every day 🔼", ["🔁 every day"]), ("- [ ] a 🔁 every day 🔺 🛫 2026-11-20", ["🔁 every day", "🛫 2026-11-20"])] {
            #expect(DateChip.chips(in: line, today: today).map { (line as NSString).substring(with: $0.range) } == want, "\(line)")
        }
        #expect(kinds("- [ ] a `📅 2026-11-20`")[.dateChip(.late)] == nil)
        #expect(kinds("- [x] a ✅ 2026-11-21")[.dateChip(.done)] == ["✅ 2026-11-21"])
        #expect(kinds("```\n- [ ] a 📅 2026-11-20\n```")[.dateChip(.late)] == nil)
        // The reason field is named, so the strike of a closed task leaves it.
        #expect(kinds("- [-] a [reason:: no budget] ❌ 2026-11-01")[.taskReason] == ["[reason:: no budget]"])
    }

    @Test func aLateDueDateIsRed() {
        func due(_ line: String) -> DateChip.Kind? { DateChip.chips(in: line, today: today, statuses: statuses).first?.kind }
        #expect(due("- [ ] a 📅 2026-11-21") == .late)
        #expect(due("- [ ] a 📅 2026-11-22") == .due)
        #expect(due("- [x] a 📅 2026-11-21 ✅ 2026-11-22") == .due)
        #expect(due("- [-] a 📅 2026-11-21") == .due)
        #expect(due("- [/] a 📅 2026-11-21") == .late)
        #expect(due("- [r] a 📅 2026-11-21") == .late)
        #expect(due("- [ ] a ⏳ 2026-11-01") == .scheduled)
        #expect(DateChip.Kind.late.colour == "red" && DateChip.Kind.scheduled.colour == "blue" && DateChip.Kind.due.colour == "orange")
    }

    @Test func aChipIsRawWithTheCaretInIt() throws {
        let line = "- [ ] a 📅 2026-11-20" as NSString
        let chip = try #require(DateChip.chips(in: line as String, today: today).first)
        let start = line.range(of: "📅").location
        #expect(chip.range == NSRange(location: start, length: line.length - start))
        for caret in [start, start + 6, line.length] {
            #expect(DrawnParts.isInside(NSRange(location: caret, length: 0), of: chip.range), "\(caret)")
        }
        #expect(!DrawnParts.isInside(NSRange(location: line.range(of: "a").location, length: 0), of: chip.range))
    }

    @Test func aCalloutHasItsKindsLook() throws {
        let two = Callout.panels(in: "> [!warning] Mind\n> the gap")
        #expect(two == [Callout.Panel(lines: 0..<2, kind: "warning", title: "Mind")])
        #expect(Callout.head(of: "> [!tip]")?.title == "Tip")
        #expect(Callout.head(of: "> [!tip]")?.titled == false)
        let unknown = try #require(Callout.head(of: "> [!nonsense] x"))
        #expect(unknown.drawn == "note" && unknown.title == "x")
        #expect(Callout.icon(of: "nonsense") == Callout.icon(of: "note"))
        #expect(Callout.icon(of: "warning") == "triangle-alert")
        #expect(Callout.head(of: "> plain") == nil)
        #expect(Callout.panels(in: "> plain\n> more").isEmpty)
        #expect(Callout.panels(in: "> [!note]- x\n> y") == Callout.panels(in: "> [!note] x\n> y"))
        // An empty `>` line stays in the panel, and text under the run ends it.
        #expect(Callout.panels(in: "a\n\n> [!info] One\n>\n> body\n\n> [!bug]\nafter").map(\.lines) == [2..<5, 6..<7])
        // A `>` line in a code block is code.
        #expect(Callout.panels(in: "```\n> [!note] x\n```").isEmpty)
    }

    @Test func aCodeBlockHasItsLanguageWord() {
        #expect(CodeBlock.panels(in: "```Rust\nlet x = 1;\n```") == [CodeBlock.Panel(lines: 0..<3, word: "rust")])
        #expect(CodeBlock.panels(in: "```\nx\n```") == [CodeBlock.Panel(lines: 0..<3, word: nil)])
        #expect(CodeBlock.panels(in: "a\n~~~sh\nls\nmore") == [CodeBlock.Panel(lines: 1..<4, word: "sh")])
        // The styling knows a closing fence from an opening one.
        #expect(kinds("```rust\nx\n```")[.fenceEnd] == ["```"])
        #expect(kinds("```rust\nx")[.fenceEnd] == nil)
    }

    // MARK: A table as a grid

    let table = ["| A | B |", "| --- | --- |", "| 1 | 2 |"]

    @Test func aTableIsAGridOnlyWithItsDelimiterRow() throws {
        let grid = try #require(TableGrid.find(in: table))
        #expect(grid.rows.count == 3 && grid.columns == 2)
        // The header alone is not, nor a header with a row and no delimiter row.
        #expect(TableGrid.find(in: [table[0]]) == nil)
        #expect(TableGrid.find(in: [table[0], table[2]]) == nil)
        // In a quote, a callout or a list item it is drawn as before.
        #expect(TableGrid.find(in: table.map { "> " + $0 }) == nil)
        #expect(TableGrid.find(in: table.map { "- " + $0 }) == nil)
        // Spaces before the pipe are an indent.
        #expect(TableGrid.find(in: table.map { "  " + $0 }) != nil)
        // 200 rows are a grid; 201 are not.
        let rows = { (count: Int) in Array(self.table.prefix(2)) + (0..<count).map { "| \($0) | x |" } }
        #expect(TableGrid.find(in: rows(200)) != nil)
        #expect(TableGrid.find(in: rows(201)) == nil)
        #expect(MarkdownTable.isDelimiter("| --- | :-: |") && !MarkdownTable.isDelimiter("| a | --- |") && !MarkdownTable.isDelimiter("---"))
        // The grid is found from any of its lines, and ends at a line that is no row.
        let text = "Top\n\n" + table.joined(separator: "\n") + "\nUnder\n" as NSString
        for word in ["A", "---", "2"] {
            let found = try #require(TableGrid.find(around: text.range(of: word).location, in: text))
            #expect(text.substring(with: found.range) == table.joined(separator: "\n"))
        }
        #expect(TableGrid.find(around: 0, in: text) == nil && TableGrid.find(around: text.range(of: "Under").location, in: text) == nil)
    }

    @Test func aGridKnowsItsCellsAndItsSides() throws {
        let text = "| Name  | نام | n |\n| :-- | :-: | --: |\n| a \\| b |  | 12 |\n|x|y" as NSString
        let grid = try #require(TableGrid.find(around: 0, in: text))
        let cells = grid.rows.map { $0.cells.map { text.substring(with: $0) } }
        // The padding spaces are not a cell's text, an escaped pipe is, and a row may lack its closing pipe.
        #expect(cells == [["Name", "نام", "n"], [":--", ":-:", "--:"], ["a \\| b", "", "12"], ["x", "y"]])
        #expect(grid.sides == [.start, .centre, .end])
        #expect(try #require(TableGrid.find(in: table)).sides == [.none, .none])
        // An empty cell is the place between its two padding spaces.
        let empty = grid.rows[2].cells[1]
        #expect(empty.length == 0 && text.substring(with: NSRange(location: empty.location - 2, length: 4)) == "|  |")
        // The first cell with a letter gives the table its direction.
        #expect(!grid.rightToLeft(in: text))
        let persian = "| نام | Age |\n| --- | --- |\n| علی | 30 |" as NSString
        #expect(try #require(TableGrid.find(around: 0, in: persian)).rightToLeft(in: persian))
        let numbers = "| 1 | 2 |\n| --- | --- |\n| 3 | سلام |" as NSString
        #expect(try #require(TableGrid.find(around: 0, in: numbers)).rightToLeft(in: numbers))
    }

    @Test func aTableIsRawOnlyOutsideOneCell() throws {
        let text = table.joined(separator: "\n") as NSString
        let grid = try #require(TableGrid.find(around: 0, in: text))
        let at = { (word: String) in text.range(of: word).location }
        // A caret in a cell edits it in place; on the delimiter row the table is raw.
        for place in [0, at("A"), at("A") + 1, at("2"), text.length] { #expect(!grid.isRaw(with: NSRange(location: place, length: 0)), "\(place)") }
        for place in [at("---") - 2, at("---"), at("---") + 11] { #expect(grid.isRaw(with: NSRange(location: place, length: 0)), "\(place)") }
        // A selection in one cell, padding and all, is not raw; one that takes a pipe or another line is.
        #expect(!grid.isRaw(with: NSRange(location: at("A"), length: 1)))
        #expect(!grid.isRaw(with: NSRange(location: at("A") - 1, length: 3)))
        #expect(grid.isRaw(with: NSRange(location: at("A"), length: 3)))
        #expect(grid.isRaw(with: NSRange(location: at("A"), length: at("1") - at("A"))))
        #expect(grid.isRaw(with: NSRange(location: 0, length: text.length)))
        let under = "x\n" + table.joined(separator: "\n") + "\ny" as NSString
        let lower = try #require(TableGrid.find(around: 3, in: under))
        // A selection that ends where the table starts, or starts where it ends, does not reach into it.
        #expect(!lower.isRaw(with: NSRange(location: 0, length: 2)) && !lower.isRaw(with: NSRange(location: NSMaxRange(lower.range), length: 2)))
        #expect(lower.isRaw(with: NSRange(location: 0, length: 4)))
    }

    @Test func theCaretSkipsThePipesAndThePadding() throws {
        let text = "| A   | Bc  |" as NSString
        let row = TableGrid.row(text, line: NSRange(location: 0, length: text.length))
        // In a cell's text, its two ends counted, the caret stays.
        for place in [2, 3, 8, 10] { #expect(TableGrid.caret(place, in: row, step: .near) == place) }
        // Right at a cell's end goes to the next cell's text; left at its start to the end of the one before.
        #expect(TableGrid.caret(4, in: row, step: .forward) == 8)
        #expect(TableGrid.caret(7, in: row, step: .back) == 3)
        // Past the last cell, or before the first, the caret leaves the row.
        #expect(TableGrid.caret(11, in: row, step: .forward) == nil && TableGrid.caret(1, in: row, step: .back) == nil)
        // From anywhere, the nearest place in a cell: the line's start is the first cell, its end the last.
        #expect(TableGrid.caret(0, in: row, step: .near) == 2 && TableGrid.caret(13, in: row, step: .near) == 10)
        #expect(TableGrid.caret(7, in: row, step: .near) == 8)
        // The cell a place is in: between its pipes.
        #expect(row.cell(at: 0) == nil && row.cell(at: 1) == 0 && row.cell(at: 6) == 0 && row.cell(at: 7) == 1 && row.cell(at: 13) == nil)
    }

    /// The table of case 8 with a second row, the place of [word]'s cell,
    /// and the text after the key.
    func enter(in word: String, _ lines: [String]? = nil) -> MarkdownTable.Enter {
        let lines = lines ?? table + ["| 3 | 4 |"]
        let row = lines.firstIndex { $0.contains(word) }!
        let offset = (lines[row] as NSString).range(of: word).location
        return MarkdownTable.enter(lines, row: row, column: MarkdownTable.column(at: offset, in: lines[row]))
    }

    let formatted = ["| A   | B   |", "| --- | --- |", "| 1   | 2   |", "| 3   | 4   |"]

    @Test func enterGoesToTheRowBelow() {
        // The same column of the row below, the table formatted.
        #expect(enter(in: "2") == .moved(lines: formatted, row: 3, column: 1))
        #expect(MarkdownTable.cellStart(formatted[3], column: 1) == (formatted[3] as NSString).range(of: "4").location)
        // On the last row, a new empty row, the caret in the same column.
        #expect(enter(in: "4") == .moved(lines: formatted + ["|     |     |"], row: 4, column: 1))
        // On the header row, the first row under the delimiter row.
        #expect(enter(in: "B") == .moved(lines: formatted, row: 2, column: 1))
        // A header and its delimiter row alone: the first row is made.
        #expect(enter(in: "A", Array(table.prefix(2))) == .moved(lines: Array(formatted.prefix(2)) + ["|     |     |"], row: 2, column: 0))
    }

    @Test func enterOnAnEmptyLastRowEndsTheTable() {
        let lines = formatted + ["|     |     |"]
        #expect(MarkdownTable.enter(lines, row: 4, column: 1) == .ended(lines: formatted))
        // An empty row that is not the last is a row as any other.
        #expect(MarkdownTable.enter(Array(lines.prefix(3)) + [lines[4], lines[3]], row: 3, column: 0) == .moved(lines: Array(formatted.prefix(3)) + [lines[4], formatted[3]], row: 4, column: 0))
    }

    @Test func tabMovesBetweenCellsAndAddsARow() {
        let lines = table + ["| 3 | 4 |"]
        func tab(_ word: String, back: Bool = false) -> (row: Int, column: Int, lines: [String]) {
            let row = lines.firstIndex { $0.contains(word) }!
            let moved = MarkdownTable.tab(lines, row: row, column: MarkdownTable.column(at: (lines[row] as NSString).range(of: word).location, in: lines[row]), back: back)
            return (moved.row, moved.column, moved.lines)
        }
        #expect(tab("1").row == 2 && tab("1").column == 1)
        #expect(tab("2").row == 3 && tab("2").column == 0)
        // The delimiter row is passed over.
        #expect(tab("B").row == 2 && tab("B").column == 0)
        // In the last cell, a new empty row, the caret in its first cell.
        #expect(tab("4").lines == formatted + ["|     |     |"] && tab("4").row == 4 && tab("4").column == 0)
        #expect(tab("3", back: true).row == 2 && tab("3", back: true).column == 1)
        #expect(tab("A", back: true).row == 0 && tab("A", back: true).column == 0)
        #expect(tab("1").lines == formatted)
    }

    /// The tables here are the reader's: every status and kind it draws has
    /// an icon by the same name.
    @Test func theTablesNameTheReadersIcons() {
        #expect(TaskBox.icons.count == 21)
        #expect(Callout.icons.contains("pencil") && Callout.icons.contains("book-open"))
        #expect(Callout.icon(of: "TLDR") == "clipboard-list")
    }
}
