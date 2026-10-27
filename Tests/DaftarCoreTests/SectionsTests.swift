import Foundation
import Testing

@testable import DaftarCore

@Suite struct SectionsTests {
    static let note = """
        ---
        title: x
        # not a heading
        ---
        Intro
        # A
        a
        ```
        # in a fence
        ```
        ## A1
        a1

        ## A2
        a2

        # B
        Setext
        ===
        b
        %% # in a comment %%
        """

    @Test func theHeadingsAreTheIndexs() {
        let headings = Sections.headings(in: Self.note)
        #expect(headings.map(\.text) == ["A", "A1", "A2", "B"])
        #expect(headings == NoteParser.parse(Self.note).headings)
    }

    @Test func aSectionRunsToTheNextHeadingOfItsLevel() {
        let headings = Sections.headings(in: Self.note)
        let count = Sections.lines(Self.note).lines.count
        #expect(Sections.end(of: 0, in: headings, lineCount: count) == 16)
        #expect(Sections.end(of: 1, in: headings, lineCount: count) == 13)
        #expect(Sections.end(of: 2, in: headings, lineCount: count) == 16)
        #expect(Sections.end(of: 3, in: headings, lineCount: count) == count)
        #expect(Sections.heading(at: 4, in: headings) == nil)
        #expect(Sections.heading(at: 8, in: headings) == 0)
        #expect(Sections.heading(at: 18, in: headings) == 3)
        #expect(Sections.siblings(of: 2, in: headings) == [1, 2])
        #expect(Sections.siblings(of: 3, in: headings) == [0, 3])
    }

    @Test func aSectionMovesWithItsSubsectionsAndLeavesTheBlankLines() throws {
        let text = "# A\na\n## A1\nx\n\n# B\nb\n\n# C\nc\n"
        let down = try #require(Sections.move(text, heading: 0, to: 1))
        #expect(down.text == "# B\nb\n\n# A\na\n## A1\nx\n\n# C\nc\n")
        #expect(down.from == 0 && down.to == 3)
        let last = try #require(Sections.move(text, heading: 0, to: 2))
        #expect(last.text == "# B\nb\n\n# C\nc\n\n# A\na\n## A1\nx\n")
        let up = try #require(Sections.move("# A\na\n\n# B\nb", heading: 1, to: 0))
        #expect(up.text == "# B\nb\n\n# A\na")
        #expect(Sections.move(text, heading: 0, to: 0) == nil)
        // A subsection stays in its parent.
        #expect(Sections.siblings(of: 1, in: Sections.headings(in: text)) == [1])
    }

    @Test func aFencedHashMovesWithItsSection() throws {
        let text = "# A\n```\n# code\n```\n# B\nb"
        #expect(try #require(Sections.move(text, heading: 1, to: 0)).text == "# B\nb\n# A\n```\n# code\n```")
    }

    @Test func theKeysMoveTheSectionOrTheLines() throws {
        let text = "---\nk: v\n---\n# A\na\n# B\nb\n" as NSString
        // The cursor on `b`, after its `b`.
        let up = try #require(Sections.moveSection(in: text, selection: NSRange(location: 24, length: 0), up: true))
        let moved = text.replacingCharacters(in: up.range, with: up.text)
        #expect(moved == "---\nk: v\n---\n# B\nb\n# A\na\n")
        #expect(up.selection == NSRange(location: 18, length: 0))
        #expect((moved as NSString).substring(with: NSRange(location: up.selection.location - 1, length: 1)) == "b")
        // The first section goes no higher; the front matter is not a section.
        #expect(Sections.moveSection(in: text, selection: NSRange(location: 14, length: 0), up: true) == nil)
        #expect(Sections.moveSection(in: text, selection: NSRange(location: 24, length: 0), up: false) == nil)
        // Above the first heading the lines move, as with ⌥↑.
        let lines = try #require(Sections.moveSection(in: "x\ny\n# A" as NSString, selection: NSRange(location: 0, length: 0), up: false))
        #expect(("x\ny\n# A" as NSString).replacingCharacters(in: lines.range, with: lines.text) == "y\nx\n# A")
    }

    @Test func moveSectionKeepsTheTextOfEmoji() throws {
        let text = "# 😀 A\n😀\n# 😀 B\n😃" as NSString
        let edit = try #require(Sections.moveSection(in: text, selection: NSRange(location: 0, length: 0), up: false))
        #expect(text.replacingCharacters(in: edit.range, with: edit.text) == "# 😀 B\n😃\n# 😀 A\n😀")
    }
}

@Suite struct HeadingRenameTests {
    static let target = """
        # Project
        ## Old Heading
        ### Child
        ## Other
        ## Old heading
        """
    static var change: HeadingRename.Change {
        HeadingRename.Change(path: "Notes/Target.md", headings: Sections.headings(in: target), renames: [1: "New: Name"])
    }

    static func rename(_ text: String, source: String = "Source.md") throws -> String {
        let edits = HeadingRename.edits(in: text, source: source, change: change) { ["Target", "Notes/Target", "Notes/Target.md", "Target.md"].contains($0) }
        return try HeadingRename.apply(edits, to: text)
    }

    @Test func everyLinkFormIsRewritten() throws {
        let text = """
            [[Target#Old Heading]] and [[Target#old   heading|the old one]]
            ![[Notes/Target#Old Heading]] [[Target#Project#Old Heading#Child]]
            [x](Notes/Target.md#Old%20Heading) [y](<Target.md#Old Heading>)
            | [[Target#Old Heading\\|alias]] |
            """
        #expect(try Self.rename(text) == """
            [[Target#New Name]] and [[Target#New Name|the old one]]
            ![[Notes/Target#New Name]] [[Target#Project#New Name#Child]]
            [x](Notes/Target.md#New%20Name) [y](<Target.md#New Name>)
            | [[Target#New Name\\|alias]] |
            """)
    }

    @Test func similarHeadingsAndOtherNotesStay() throws {
        let text = """
            [[Target#Old Heading 2]] [[Target#Other]] [[Elsewhere#Old Heading]] [[Target]]
            [[Target#Other#Old Heading]] `[[Target#Old Heading]]`
            ```
            [[Target#Old Heading]]
            ```
            [[#Old Heading]] https://example.com/Target.md#Old%20Heading
            """
        #expect(try Self.rename(text) == text)
    }

    @Test func theFirstOfTwoSameHeadingsIsTheOneNamed() throws {
        var second = Self.change
        second.renames = [4: "Renamed"]
        let text = "[[Target#Old Heading]]"
        let edits = HeadingRename.edits(in: text, source: "S.md", change: second) { $0 == "Target" }
        #expect(edits.isEmpty)
    }

    @Test func theNoteItselfUsesBareAnchors() throws {
        let text = "See [[#Old Heading]] and [[#Old Heading#Child|c]]."
        #expect(try Self.rename(text, source: "Notes/Target.md") == "See [[#New Name]] and [[#New Name#Child|c]].")
        // In another note, `[[#…]]` is its own heading.
        #expect(try Self.rename(text) == text)
    }

    @Test func aChildRenamedRewritesTheNestedLink() throws {
        var child = Self.change
        child.renames = [2: "Kid"]
        let edits = HeadingRename.edits(in: "[[Target#Old Heading#Child]] [[Target#Child]]", source: "S.md", change: child) { $0 == "Target" }
        #expect(try HeadingRename.apply(edits, to: "[[Target#Old Heading#Child]] [[Target#Child]]") == "[[Target#Old Heading#Kid]] [[Target#Kid]]")
    }

    @Test func applyRefusesAChangedLine() {
        let edits = [HeadingRename.Edit(line: 0, before: "[[A#B]]", after: "[[A#C]]")]
        #expect(throws: HeadingRename.Failure.changed) { try HeadingRename.apply(edits, to: "[[A#B]] typed") }
        #expect(throws: HeadingRename.Failure.changed) { try HeadingRename.apply(edits, to: "") }
    }

    @Test func renamesAreFoundBetweenTwoTexts() {
        let old = Sections.headings(in: "# A\n## B\n## C\n# D")
        #expect(HeadingRename.renamed(from: old, to: Sections.headings(in: "# A\n## Bee\n## C\n# D")) == [1: "Bee"])
        #expect(HeadingRename.renamed(from: old, to: Sections.headings(in: "# A\n## b\n## C\n# D")).isEmpty)
        // A heading added or removed is not a rename.
        #expect(HeadingRename.renamed(from: old, to: Sections.headings(in: "# A\n## B\n## X\n## C\n# D")).isEmpty)
        #expect(HeadingRename.renamed(from: old, to: Sections.headings(in: "# A\n## C\n# D")).isEmpty)
        // A level changed is not a rename either.
        #expect(HeadingRename.renamed(from: old, to: Sections.headings(in: "# A\n### Bee\n## C\n# D")).isEmpty)
        // A rename and a deletion elsewhere.
        #expect(HeadingRename.renamed(from: old, to: Sections.headings(in: "# Ay\n## B\n# D")) == [0: "Ay"])
    }

    @Test func theHeadingLineKeepsItsLevel() {
        #expect(HeadingRename.retitle("### Old ###", to: " New ") == "### New")
        #expect(HeadingRename.anchorText("A [[X]] | #b ^c") == "A X b c")
    }
}
