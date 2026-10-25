import Foundation
import Testing

@testable import DaftarCore

@Suite struct MarkdownTableTests {
    @Test func formatLinesTheColumnsUp() {
        let lines = ["| Name | Age |", "|:-|-:|", "| Sara | 7 |", "| Alexander | 30 | extra |"]
        #expect(MarkdownTable.format(lines) == [
            "| Name      | Age |       |",
            "| :-------- | --: | ----- |",
            "| Sara      | 7   |       |",
            "| Alexander | 30  | extra |",
        ])
        #expect(MarkdownTable.cells(#"| a \| b | c |"#) == [#"a \| b"#, "c"])
    }

    @Test func tabGoesToTheNextCellAndMakesARowAtTheEnd() {
        let lines = ["| a | b |", "| - | - |", "| c | d |"]
        let next = MarkdownTable.tab(lines, row: 0, column: 1, back: false)
        // Over the separator, to the first cell of the next row.
        #expect(next.row == 2 && next.column == 0)
        let end = MarkdownTable.tab(lines, row: 2, column: 1, back: false)
        #expect(end.lines.count == 4 && end.row == 3 && end.column == 0)
        #expect(end.lines[3] == "|     |     |")
        let back = MarkdownTable.tab(lines, row: 2, column: 0, back: true)
        #expect(back.row == 0 && back.column == 1)
        #expect(MarkdownTable.cellStart("| abc | de  |", column: 1) == 8)
        #expect(MarkdownTable.column(at: 9, in: "| abc | de  |") == 1)
    }

    @Test func persianAndWideLettersKeepTheColumns() {
        let table = MarkdownTable.format(["| نام | x |", "| --- | --- |", "| 中文 | y |"])
        // The column is as wide as 中文, two wide letters.
        #expect(table[0] == "| نام  | x   |")
        #expect(table[2] == "| 中文 | y   |")
    }
}

@Suite struct MoveLinesTests {
    @Test func aLineGoesUpAndDown() throws {
        let text = "one\ntwo\nthree\n" as NSString
        let up = try #require(EditorCommands.moveLines(in: text, selection: NSRange(location: 5, length: 0), up: true))
        #expect(text.replacingCharacters(in: up.range, with: up.text) == "two\none\nthree\n")
        #expect(up.selection.location == 1)
        let down = try #require(EditorCommands.moveLines(in: text, selection: NSRange(location: 5, length: 0), up: false))
        #expect(text.replacingCharacters(in: down.range, with: down.text) == "one\nthree\ntwo\n")
        #expect(down.selection.location == 11)
        #expect(EditorCommands.moveLines(in: text, selection: NSRange(location: 0, length: 0), up: true) == nil)
    }

    @Test func theLastLineWithNoNewlineAndASelectionOfLines() throws {
        let text = "a\nb\nc" as NSString
        let down = try #require(EditorCommands.moveLines(in: text, selection: NSRange(location: 2, length: 0), up: false))
        #expect(text.replacingCharacters(in: down.range, with: down.text) == "a\nc\nb")
        let up = try #require(EditorCommands.moveLines(in: text, selection: NSRange(location: 4, length: 0), up: true))
        #expect(text.replacingCharacters(in: up.range, with: up.text) == "a\nc\nb")
        // Two lines, selected to the start of the next: those two move.
        let two = try #require(EditorCommands.moveLines(in: text, selection: NSRange(location: 0, length: 4), up: false))
        #expect(text.replacingCharacters(in: two.range, with: two.text) == "c\na\nb")
    }
}

@Suite struct DroppedLinkTests {
    @Test func aDroppedFileGetsTheShortestLink() {
        let files: Set<String> = ["Notes/Plan.md", "Old/Plan.md", "Notes/Kit.md", "uploads/photo.png", "docs/spec.pdf", "data.csv"]
        #expect(EditorCommands.link(to: "Notes/Kit.md", files: files) == "[[Kit]]")
        #expect(EditorCommands.link(to: "Notes/Plan.md", files: files) == "[[Notes/Plan]]")
        #expect(EditorCommands.link(to: "uploads/photo.png", files: files) == "![[photo.png]]")
        #expect(EditorCommands.link(to: "docs/spec.pdf", files: files) == "![[spec.pdf]]")
        #expect(EditorCommands.link(to: "data.csv", files: files) == "[[data.csv]]")
        #expect(EditorCommands.isWebAddress("https://example.com/a?b=1") && !EditorCommands.isWebAddress("two words") && !EditorCommands.isWebAddress("example.com"))
    }
}
