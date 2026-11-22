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

    /// The tables here are the reader's: every status and kind it draws has
    /// an icon by the same name.
    @Test func theTablesNameTheReadersIcons() {
        #expect(TaskBox.icons.count == 21)
        #expect(Callout.icons.contains("pencil") && Callout.icons.contains("book-open"))
        #expect(Callout.icon(of: "TLDR") == "clipboard-list")
    }
}
