import Testing

@testable import DaftarCore

@Suite struct QuickCaptureTests {
    @Test func theTypedTextIsOneLine() {
        #expect(QuickCapture.line("  Call Sara \n about the trip ", task: false) == "Call Sara about the trip")
        #expect(QuickCapture.line("Call Sara", task: true) == "- [ ] Call Sara")
        #expect(QuickCapture.line("[ ] Call Sara", task: true) == "- [ ] Call Sara")
        #expect(QuickCapture.line("- [ ] Call Sara 📅 2026-10-27", task: true) == "- [ ] Call Sara 📅 2026-10-27")
        #expect(QuickCapture.line(" \n ", task: true) == nil)
        #expect(QuickCapture.line("", task: false) == nil)
    }

    @Test func goesAtTheEndOfTheNote() {
        #expect(QuickCapture.append("- [ ] New", to: "") == "- [ ] New\n")
        #expect(QuickCapture.append("- [ ] New", to: "# Day\n- [ ] Old\n") == "# Day\n- [ ] Old\n- [ ] New\n")
        // Blank lines at the end stay at the end.
        #expect(QuickCapture.append("- [ ] New", to: "# Day\n- [ ] Old\n\n\n") == "# Day\n- [ ] Old\n- [ ] New\n\n\n")
        #expect(QuickCapture.append("- [ ] New", to: "- [ ] Old") == "- [ ] Old\n- [ ] New")
        // Under a heading, at once.
        #expect(QuickCapture.append("Idea", to: "# Day\n") == "# Day\nIdea\n")
    }

    @Test func aBlankLineKeepsItOutOfTheParagraphAbove() {
        #expect(QuickCapture.append("Idea", to: "Some text\n") == "Some text\n\nIdea\n")
        #expect(QuickCapture.append("- [ ] New", to: "Some text\n") == "Some text\n\n- [ ] New\n")
        #expect(QuickCapture.append("Idea", to: "- item\n") == "- item\n\nIdea\n")
        // Text right under `---` would make a heading of it.
        #expect(QuickCapture.append("Idea", to: "---\nkind: day\n---\n") == "---\nkind: day\n---\n\nIdea\n")
        #expect(QuickCapture.append("- b", to: "1. a\n    - nested\n") == "1. a\n    - nested\n- b\n")
    }

    @Test func goesAtTheEndOfItsSection() {
        let note = "# 2026-10-26\n## Inbox\n- [ ] Old\n\n### Later\n- [ ] Sub\n\n## Notes\nText\n"
        #expect(
            QuickCapture.append("- [ ] New", to: note, heading: "inbox")
                == "# 2026-10-26\n## Inbox\n- [ ] Old\n\n### Later\n- [ ] Sub\n- [ ] New\n\n## Notes\nText\n")
        #expect(
            QuickCapture.append("- [ ] New", to: note, heading: "## Notes")
                == "# 2026-10-26\n## Inbox\n- [ ] Old\n\n### Later\n- [ ] Sub\n\n## Notes\nText\n\n- [ ] New\n")
        // An empty section: right under its heading.
        #expect(QuickCapture.append("x", to: "## Inbox\n\n## Notes\n", heading: "Inbox") == "## Inbox\nx\n\n## Notes\n")
        // An empty heading setting is the end of the note.
        #expect(QuickCapture.append("x", to: "## Inbox\n- a\n## Notes\n", heading: " ") == "## Inbox\n- a\n## Notes\nx\n")
    }

    @Test func aMissingHeadingIsMadeAtTheEnd() {
        #expect(QuickCapture.append("- [ ] New", to: "# Day\nText\n", heading: "Inbox") == "# Day\nText\n\n## Inbox\n- [ ] New\n")
        #expect(QuickCapture.append("- [ ] New", to: "", heading: "### Inbox") == "### Inbox\n- [ ] New\n")
        // A heading in code is not a heading.
        #expect(
            QuickCapture.append("x", to: "```\n## Inbox\n```\n", heading: "Inbox") == "```\n## Inbox\n```\n\n## Inbox\nx\n")
    }

    @Test func keepsCRLF() {
        #expect(QuickCapture.append("x", to: "## Inbox\r\n- a\r\n", heading: "Inbox") == "## Inbox\r\n- a\r\n\r\nx\r\n")
        #expect(QuickCapture.append("- b", to: "- a\r\n") == "- a\r\n- b\r\n")
    }

    @Test func readsAShortcut() throws {
        let spec = try #require(HotKeySpec.parse("ctrl+opt+n"))
        #expect(spec == HotKeySpec(keyCode: 0x2D, key: "N", control: true, option: true))
        #expect(spec.symbols == "⌃⌥N")
        #expect(HotKeySpec.parse(" Cmd + Shift + Space ")?.symbols == "⇧⌘Space")
        #expect(HotKeySpec.parse("control+option+command+shift+k")?.symbols == "⌃⌥⇧⌘K")
        #expect(HotKeySpec.parse("alt+1")?.keyCode == 0x12)
        #expect(HotKeySpec.parse("ctrl+opt+0")?.keyCode == 0x1D)
        #expect(HotKeySpec.parse("cmd+opt+/")?.keyCode == 0x2C)
        #expect(HotKeySpec.parse("ctrl+up")?.symbols == "⌃↑")
        // A function key may stand alone.
        #expect(HotKeySpec.parse("f13") == HotKeySpec(keyCode: 0x69, key: "F13"))
        #expect(HotKeySpec.parse("F1")?.keyCode == 0x7A)
    }

    @Test func refusesWhatItCannotRead() {
        for spec in ["", " ", "n", "shift+n", "ctrl+", "+n", "ctrl++", "ctrl+opt+nn", "hyper+n", "ctrl+opt", "ctrl+f21", "ctrl+ü", "ctrl n"] {
            #expect(HotKeySpec.parse(spec) == nil, "\(spec)")
        }
    }
}
