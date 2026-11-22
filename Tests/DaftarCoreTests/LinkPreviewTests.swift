import Foundation
import Testing

@testable import DaftarCore

/// The first lines a link's card shows (`docs/specs/look.md` in
/// notes-linux, "Link preview" and test 18 of part 2).
@Suite struct LinkPreviewTests {
    static let twenty = (1...20).map { "l\($0)" }.joined(separator: "\n")

    @Test func thePreviewIsTheFirstLines() {
        // A front matter, the title as a heading, a blank line and 20 lines: the first 12, and `…`.
        let plan = "---\ntags: [a]\n---\n# Plan\n\n\(Self.twenty)\n"
        let first = (1...12).map { "l\($0)" }.joined(separator: "\n")
        #expect(LinkPreview.excerpt(of: plan, title: "Plan") == first + "\n\n…")
        // A link to a heading: the lines under it up to the next heading of its level or higher, without it.
        let sections = "# Plan\n\nintro\n\n## Next\n\none\n\n### Deeper\n\ntwo\n\n## Later\n\nthree\n"
        #expect(LinkPreview.excerpt(of: sections, title: "Plan", anchor: "Next") == "one\n\n### Deeper\n\ntwo")
        #expect(LinkPreview.excerpt(of: sections, title: "Plan", anchor: "Later") == "three")
        #expect(LinkPreview.excerpt(of: sections, title: "Plan", anchor: "Next#Deeper") == "two")
        // One line of 900 letters: 600 of them, and `…`.
        let long = String(repeating: "a", count: 900)
        #expect(LinkPreview.excerpt(of: long, title: "Long") == String(repeating: "a", count: 600) + "…")
        // A note that is only a front matter is empty.
        #expect(LinkPreview.excerpt(of: "---\ntags: [a]\n---\n", title: "Plan") == "")
        #expect(LinkPreview.excerpt(of: "", title: "Plan") == "")
        // A name with no note has its own line.
        #expect(LinkPreview.missing == "No note yet.")
        #expect(LinkPreview.empty == "The note is empty.")
    }

    @Test func aShortNoteIsShownWholeWithNoDots() {
        #expect(LinkPreview.excerpt(of: "\n\none\ntwo\n\n", title: "Note") == "one\ntwo")
        // Twelve lines are all of it.
        let twelve = (1...12).map { "l\($0)" }.joined(separator: "\n")
        #expect(LinkPreview.excerpt(of: twelve, title: "Note") == twelve)
        // 600 letters are all of it too.
        let full = String(repeating: "b", count: 600)
        #expect(LinkPreview.excerpt(of: full, title: "Note") == full)
    }

    @Test func onlyAFirstHeadingThatIsTheTitleIsLeftOut() {
        #expect(LinkPreview.excerpt(of: "# Plan\n\ntext", title: "Plan") == "text")
        #expect(LinkPreview.excerpt(of: "## plan\ntext", title: "Plan") == "text")
        // Another heading stays, and so does the title when it is not the first line.
        #expect(LinkPreview.excerpt(of: "# Other\n\ntext", title: "Plan") == "# Other\n\ntext")
        #expect(LinkPreview.excerpt(of: "text\n\n# Plan\n\nmore", title: "Plan") == "text\n\n# Plan\n\nmore")
    }

    @Test func theCutIsAtALinesEndWhenOneIsInReach() {
        // Two lines of 400 letters: the second does not fit, so the first is all, with `…` under it.
        let line = String(repeating: "c", count: 400)
        #expect(LinkPreview.excerpt(of: "\(line)\n\(line)", title: "Note") == line + "\n\n…")
        // The line breaks count: 300 + 1 + 299 is 600.
        let a = String(repeating: "a", count: 300), b = String(repeating: "b", count: 299)
        #expect(LinkPreview.excerpt(of: "\(a)\n\(b)", title: "Note") == "\(a)\n\(b)")
        #expect(LinkPreview.excerpt(of: "\(a)\n\(b)b", title: "Note") == a + "\n\n…")
        // A blank line the cut ends on is not kept.
        #expect(LinkPreview.excerpt(of: "\(a)\n\n\(a)", title: "Note") == a + "\n\n…")
    }

    @Test func aCodeBlockThatIsCutIsClosed() {
        let code = "```swift\n" + (1...20).map { "let x\($0) = 1" }.joined(separator: "\n") + "\n```\nafter\n"
        let lines = LinkPreview.excerpt(of: code, title: "Note").components(separatedBy: "\n")
        #expect(lines.count == 15)
        #expect(lines[0] == "```swift" && lines[11] == "let x11 = 1")
        #expect(Array(lines[12...]) == ["```", "", "…"])
        // A longer fence is closed with its own marks, and a block that ends in the lines needs nothing.
        let tildes = "~~~~\n" + String(repeating: "x\n", count: 30) + "~~~~\n"
        #expect(LinkPreview.excerpt(of: tildes, title: "Note").hasSuffix("x\n~~~~\n\n…"))
        #expect(LinkPreview.excerpt(of: "```\na\n```\n", title: "Note") == "```\na\n```")
    }

    @Test func anEmbedIsItsLinkAndIsNotFollowed() {
        #expect(LinkPreview.excerpt(of: "See ![[Other]] and ![[a.png|100]].", title: "Note") == "See [[Other]] and [[a.png|100]].")
        // In a code block it is text.
        #expect(LinkPreview.excerpt(of: "```\n![[Other]]\n```", title: "Note") == "```\n![[Other]]\n```")
    }

    @Test func aLinkToABlockShowsThatBlockAlone() {
        let note = "# Note\n\nfirst\n\nThe second one. ^b1\n\n- item one\n- item two ^b2\n\nlast\n"
        #expect(LinkPreview.excerpt(of: note, title: "Note", anchor: "^b1") == "The second one. ^b1")
        #expect(LinkPreview.excerpt(of: note, title: "Note", anchor: "^b2") == "- item two ^b2")
        // An anchor that names nothing gives no lines.
        #expect(LinkPreview.excerpt(of: note, title: "Note", anchor: "^none") == "")
        #expect(LinkPreview.excerpt(of: note, title: "Note", anchor: "Nowhere") == "")
    }

    @Test func persianTextIsCutByLettersNotBytes() {
        let line = String(repeating: "س", count: 700)
        let cut = LinkPreview.excerpt(of: line, title: "یادداشت")
        #expect(cut.count == 601 && cut.hasSuffix("…"))
    }
}
