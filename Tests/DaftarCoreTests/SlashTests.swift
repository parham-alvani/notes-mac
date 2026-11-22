import Foundation
import Testing

@testable import DaftarCore

@Suite struct SlashTests {
    let commands = EditorCommands.slashCommands(today: Day(year: 2026, month: 10, day: 25), time: "15:30")
    func snippet(_ id: String) -> Snippet { commands.first { $0.id == id }! }

    @Test func opensOnlyAtAWordStart() {
        #expect(EditorCommands.opensSlashMenu(in: "/", at: 1))
        #expect(EditorCommands.opensSlashMenu(in: "Text /", at: 6))
        #expect(EditorCommands.opensSlashMenu(in: "Line\n/", at: 6))
        #expect(!EditorCommands.opensSlashMenu(in: "a/b", at: 2))
        #expect(!EditorCommands.opensSlashMenu(in: "https://", at: 7))
        #expect(!EditorCommands.opensSlashMenu(in: "text", at: 4))
    }

    @Test func anInlineSnippetTakesTheSlashsPlace() {
        let text = "See /" as NSString
        let edit = EditorCommands.apply(snippet("link"), slashAt: 4, in: text)
        #expect(edit.range == NSRange(location: 4, length: 1))
        #expect(edit.text == "[[]]")
        #expect(edit.cursor == 6)
        #expect(EditorCommands.apply(snippet("date"), slashAt: 4, in: text).text == "2026-10-25")
        #expect(EditorCommands.apply(snippet("red"), slashAt: 4, in: text).cursor == 4 + 4)
    }

    @Test func aBlockStartsItsOwnLine() {
        let start = EditorCommands.apply(snippet("code"), slashAt: 0, in: "/" as NSString)
        #expect(start.text == "```\n\n```")
        #expect(start.cursor == 4)
        #expect(EditorCommands.apply(snippet("math"), slashAt: 0, in: "/" as NSString).cursor == 3)
        let after = EditorCommands.apply(snippet("h2"), slashAt: 5, in: "Some /" as NSString)
        #expect(after.text == "\n## ")
        #expect(after.cursor == 5 + 4)
    }

    @Test func everyCursorIsInsideItsSnippet() {
        for snippet in commands {
            #expect(snippet.cursor >= 0 && snippet.cursor <= (snippet.text as NSString).length, "\(snippet.id)")
        }
        // The table's cursor is before its first header cell's word; the task's before its date.
        let table = snippet("table").text as NSString
        #expect(table.substring(from: snippet("table").cursor).hasPrefix("Column | Column |\n"))
        let mermaid = snippet("mermaid").text as NSString
        #expect(mermaid.substring(to: snippet("mermaid").cursor).hasSuffix("A --> B"))
        #expect((snippet("task-today").text as NSString).substring(from: snippet("task-today").cursor) == " 📅 2026-10-25")
    }
}

/// The slash bar, focus mode and the link's card: the tests of part 2 every
/// app has, by name (`docs/specs/look.md` in notes-linux, tests 14 to 17 and 23).
@Suite struct SlashBarTests {
    let items = EditorCommands.slashCommands(today: Day(year: 2026, month: 11, day: 22), time: "09:05")

    /// [typed] put at the end of [before], a key at a time, as the editor
    /// does: the bar opens at a `/` and follows each key after it.
    func type(_ typed: String, after before: String = "") -> (bar: SlashBar?, text: NSString) {
        var text = before
        var bar: SlashBar?
        for letter in typed {
            text.append(letter)
            let now = text as NSString
            if letter == "/" {
                bar = SlashBar(typedAt: now.length, in: now, items: items)
            } else {
                bar = bar?.following(now, caret: now.length)
            }
        }
        return (bar, text as NSString)
    }

    /// The note after Enter on the chosen row, with `▮` where the caret is.
    func entered(_ typed: String, after before: String = "") -> String? {
        let (bar, text) = type(typed, after: before)
        guard let bar, let choice = bar.choice else { return nil }
        let edit = bar.edit(choice, in: text)
        let out = text.replacingCharacters(in: edit.range, with: edit.text) as NSString
        return out.replacingCharacters(in: NSRange(location: edit.cursor, length: 0), with: "▮")
    }

    @Test func theSlashBarOpensOnlyAtAWordsStart() {
        func opens(_ text: String) -> Bool { SlashBar.opens(in: text as NSString, at: (text as NSString).length) }
        #expect(opens("/"))
        #expect(opens("a /"))
        #expect(opens("line\n/"))
        #expect(!opens("a/"))
        #expect(!opens("https:/"))
        #expect(!opens("10/"))
        // Not in a code block, inline code or the front matter; nor in math or a comment.
        #expect(!opens("```\n/"))
        #expect(!opens("```sh\ncd /"))
        #expect(!opens("---\ntitle: /"))
        #expect(!opens("$$\n/"))
        #expect(!opens("%%\nhidden /"))
        let code = "a `b /` c" as NSString
        #expect(!SlashBar.opens(in: code, at: code.range(of: "/").location + 1))
        // After a closed code block a `/` opens it again.
        #expect(opens("```\ncode\n```\n/"))
        // The state the line starts in, when the editor knows it, is used as given.
        #expect(!SlashBar.opens(in: "/", at: 1, startingIn: .fence("```")))
        #expect(SlashBar(typedAt: 2, in: "a/", items: items) == nil)
    }

    @Test func theSlashBarFiltersByTitleAndId() {
        #expect(type("/tab").bar?.rows.first?.id == "table")
        #expect(type("/h2").bar?.rows.first?.id == "h2")
        #expect(type("/rule").bar?.rows.first?.id == "divider")
        #expect(type("/divider").bar?.rows.first?.id == "divider")
        let call = type("/call").bar?.rows.map(\.id) ?? []
        #expect(call.first == "callout")
        #expect(Set(call.dropFirst()) == ["note", "info", "tip", "important", "warning", "danger", "example", "question", "success", "summary", "todo"])
        // Two that match the same are in the list's order.
        #expect(type("/task").bar?.rows.prefix(2).map(\.id) == ["task", "task-today"])
        // Nothing matches: no row, the bar still listens, and the text is as typed.
        let none = type("/zzz")
        #expect(none.bar != nil && none.bar?.rows.isEmpty == true && none.bar?.choice == nil)
        #expect(none.text == "/zzz")
        // One Backspace can bring it back.
        #expect(none.bar?.following("/z", caret: 2)?.rows.isEmpty == true)
        #expect(none.bar?.following("/", caret: 1)?.rows.count == items.count)
        // With nothing typed every item shows, under its group's header, Heading 1 first.
        let all = type("/").bar
        #expect(all?.rows.map(\.id) == items.map(\.id))
        #expect(all?.choice?.id == "h1")
        #expect(all?.header(over: 0) == "Text" && all?.header(over: 1) == nil && all?.header(over: 3) == "Lists")
        #expect((0..<items.count).compactMap { all?.header(over: $0) } == ["Text", "Lists", "Blocks", "Links", "Insert", "Highlight"])
        // With a query there are no headers.
        #expect(type("/h").bar?.header(over: 0) == nil)
        // The order and the ids are the spec's.
        #expect(items.map(\.id) == [
            "h1", "h2", "h3", "task", "task-today", "bullet", "number", "quote", "callout", "note", "info", "tip", "important", "warning", "danger",
            "example", "question", "success", "summary", "todo", "code", "mermaid", "math", "tasks", "table", "divider", "link", "embed", "date", "time",
            "red", "orange", "yellow", "green", "blue", "purple",
        ])
    }

    @Test func enterInsertsAndEscapeLeavesTheSlash() {
        #expect(entered("/task") == "- [ ] ▮")
        #expect(entered("/warn") == "> [!warning] ▮\n> ")
        #expect(entered("/rule") == "---\n▮")
        // Escape closes the list and changes nothing: the line is as typed.
        #expect(type("/tab").text == "/tab")
        // A block after other text starts a line of its own.
        #expect(entered("/code", after: "text ") == "text \n\n```\n▮\n```")
        #expect(entered("/h2", after: "text ") == "text \n## ▮")
        // What is inserted takes the `/` and the query, and nothing else of the line.
        let text = "On /dat we met" as NSString
        var after = SlashBar(typedAt: 4, in: "On / we met", items: items)
        for (typed, caret) in [("On /d we met", 5), ("On /da we met", 6), ("On /dat we met", 7)] { after = after?.following(typed as NSString, caret: caret) }
        #expect(after?.choice?.id == "date")
        let edit = after!.edit(after!.choice!, in: text)
        #expect(text.replacingCharacters(in: edit.range, with: edit.text) == "On 2026-11-22 we met")
        // The items' text, with the caret.
        func written(_ id: String) -> String {
            let item = items.first { $0.id == id }!
            return (item.text as NSString).replacingCharacters(in: NSRange(location: item.cursor, length: 0), with: "▮")
        }
        #expect(written("callout") == "> [!note] ▮\n> ")
        #expect(written("question") == "> [!question] ▮\n> ")
        #expect(written("table") == "| ▮Column | Column |\n| ------ | ------ |\n|        |        |")
        #expect(written("task-today") == "- [ ] ▮ 📅 2026-11-22")
        #expect(written("red") == "==🔴▮==" && written("yellow") == "==▮==" && written("purple") == "==🟣▮==")
        #expect(written("link") == "[[▮]]" && written("embed") == "![[▮]]" && written("time") == "09:05▮")
    }

    /// The note after item [id] is chosen for `/query` typed at `▮` of
    /// [note], with `▮` where the caret is and `◂` where a selection ends.
    func chosen(_ id: String, at note: String, query: String = "") -> String {
        let place = (note as NSString).range(of: "▮").location
        let text = (note as NSString).replacingCharacters(in: NSRange(location: place, length: 1), with: "/" + query) as NSString
        let item = items.first { $0.id == id }!
        let edit = EditorCommands.apply(item, slashAt: place, query: (query as NSString).length, in: text)
        // Only the `/` and the query are replaced.
        #expect(edit.range == NSRange(location: place, length: 1 + (query as NSString).length))
        var out = text.replacingCharacters(in: edit.range, with: edit.text) as NSString
        if edit.selected > 0 { out = out.replacingCharacters(in: NSRange(location: edit.cursor + edit.selected, length: 0), with: "◂") as NSString }
        return out.replacingCharacters(in: NSRange(location: edit.cursor, length: 0), with: "▮")
    }

    static let table = "| ▮Column◂ | Column |\n| ------ | ------ |\n|        |        |"

    @Test func aBlockApartHasABlankLineAtEachSideAndTakesNoText() {
        let table = Self.table
        // The fault: a table typed on the blank line between two paragraphs had no blank line under
        // it, and the formatter made the paragraph under it a row of the table.
        #expect(chosen("table", at: "x\n▮\nA first paragraph.\n\nA second paragraph.\n", query: "tab")
            == "x\n\n\(table)\n\nA first paragraph.\n\nA second paragraph.\n")
        // At the start of a line with text: the text goes under the table, after a blank line.
        #expect(chosen("table", at: "▮x\n\nA first paragraph.\n\nA second paragraph.\n", query: "tab")
            == "\(table)\n\nx\n\nA first paragraph.\n\nA second paragraph.\n")
        // Blank lines that are there are kept, and none is added.
        #expect(chosen("table", at: "x\n\n▮\n\nA first paragraph.\n") == "x\n\n\(table)\n\nA first paragraph.\n")
        #expect(chosen("table", at: "▮") == table)
        #expect(chosen("table", at: "x\n\n▮\n") == "x\n\n\(table)\n")
        // After other text on the line, and with text after it.
        #expect(chosen("table", at: "before ▮after\nnext\n") == "before \n\n\(table)\n\nafter\nnext\n")
        // A line of spaces is a blank line.
        #expect(chosen("code", at: "x\n  \n▮\n \ny\n") == "x\n  \n```\n▮\n```\n \ny\n")
        // Windows line breaks: the line under is not taken for a blank one, nor the one over.
        #expect(chosen("code", at: "x\r\n▮\r\ny\r\n") == "x\r\n\n```\n▮\n```\n\r\ny\r\n")
        // Every item that stands apart, between two lines of text and at a line's start before text.
        let between = [
            "callout": "> [!note] ▮\n> ", "warning": "> [!warning] ▮\n> ", "code": "```\n▮\n```", "math": "$$\n▮\n$$",
            "mermaid": "```mermaid\nflowchart LR\n    A --> B▮\n```", "tasks": "```tasks\nnot done\ndue before tomorrow\n```▮", "table": table,
        ]
        for (id, written) in between {
            #expect(chosen(id, at: "one\n▮\ntwo\n") == "one\n\n\(written)\n\ntwo\n", "\(id)")
            #expect(chosen(id, at: "one\n▮two\n") == "one\n\n\(written)\n\ntwo\n", "\(id)")
            #expect(chosen(id, at: "one ▮\ntwo\n") == "one \n\n\(written)\n\ntwo\n", "\(id)")
        }
        // A rule: the caret's empty line under it is the blank line. Straight under text, `---` would make that text a heading.
        #expect(chosen("divider", at: "one\n▮\ntwo\n") == "one\n\n---\n▮\ntwo\n")
        #expect(chosen("divider", at: "one\n▮two\n") == "one\n\n---\n▮\ntwo\n")
        #expect(chosen("divider", at: "one\n\n▮\n\ntwo\n") == "one\n\n---\n▮\n\ntwo\n")
        // Every item of the list that stands apart is one of these, and each is a block.
        #expect(Set(items.filter(\.apart).map(\.id)) == Set(between.keys).union([
            "note", "info", "tip", "important", "danger", "example", "question", "success", "summary", "todo", "divider",
        ]))
        #expect(items.filter(\.apart).allSatisfy { $0.block })
        // A heading or a list item is the start of its line: no blank line, and the line's text is its own.
        #expect(chosen("h2", at: "one\n▮two\n") == "one\n## ▮two\n")
        #expect(chosen("task", at: "- [ ] a\n▮\n- [ ] b\n") == "- [ ] a\n- [ ] ▮\n- [ ] b\n")
        #expect(chosen("bullet", at: "one ▮\n") == "one \n- ▮\n")
        // No item takes a letter of the note: every line that was there is there after, in order.
        for item in items {
            for note in ["x\n▮\nA first paragraph.\n\nA second paragraph.\n", "▮x\n\nA first paragraph.\n", "a ▮b\nc\n", "a\n▮"] {
                let after = chosen(item.id, at: note).replacingOccurrences(of: "▮", with: "").replacingOccurrences(of: "◂", with: "")
                var rest = after[...]
                for piece in note.components(separatedBy: "▮").flatMap({ $0.components(separatedBy: "\n") }) where !piece.isEmpty {
                    let found = rest.range(of: piece)
                    #expect(found != nil, "\(item.id) lost \(piece)")
                    if let found { rest = rest[found.upperBound...] }
                }
            }
        }
    }

    @Test func theTableItemSelectsItsFirstPlaceholder() {
        let table = items.first { $0.id == "table" }!
        #expect(MarkdownTable.placeholder == "Column")
        #expect((table.text as NSString).substring(with: NSRange(location: table.cursor, length: table.selected)) == "Column")
        // No other item selects anything.
        #expect(items.filter { $0.selected > 0 }.map(\.id) == ["table"])
        // The table keys take rows only: a line with no pipe at its start is never a row.
        #expect(!MarkdownTable.isRow("A first paragraph of the note."))
        #expect(!MarkdownTable.isRow("a | b"))
        #expect(MarkdownTable.isRow("  | a | b |"))
    }

    @Test func theBarClosesWhenTheCaretLeavesWhatWasTyped() {
        let (bar, text) = type("/tab", after: "a ")
        // Down and Up stop at the ends.
        var moved = bar!
        moved.move(by: -1)
        #expect(moved.chosen == 0)
        moved.move(by: 100)
        #expect(moved.chosen == moved.rows.count - 1)
        // Left inside the query makes it shorter; before the `/` and after the end it closes.
        #expect(bar?.following(text, caret: 4)?.query == "t")
        #expect(bar?.following(text, caret: 2) == nil)
        #expect(bar?.following("a /tab\nmore", caret: 7) == nil)
        // A space closes it, and so does the `/` going away.
        #expect(bar?.following("a /tab ", caret: 7) == nil)
        #expect(bar?.following("a ", caret: 2) == nil)
        #expect(bar?.following("a xtab", caret: 6) == nil)
    }

    @Test func focusKeepsTheCaretsParagraph() {
        let text = "a\n\nb\nc\n\nd" as NSString
        func bright(_ selections: [NSRange]) -> [String] { FocusParagraph.ranges(for: selections, in: text).map(text.substring(with:)) }
        // The caret in `c`: `b` and `c`.
        #expect(bright([NSRange(location: 5, length: 0)]) == ["b\nc\n"])
        // On a blank line, that line.
        #expect(bright([NSRange(location: 2, length: 0)]) == ["\n"])
        // A selection from `a` to `b`: `a`, the blank line and `b` with `c`.
        #expect(bright([NSRange(location: 0, length: 4)]) == ["a\n\nb\nc\n"])
        // Many cursors: each one's paragraph.
        #expect(bright([NSRange(location: 9, length: 0), NSRange(location: 0, length: 0)]) == ["a\n", "d"])
        #expect(bright([NSRange(location: 3, length: 0), NSRange(location: 5, length: 0)]) == ["b\nc\n"])
        #expect(FocusParagraph.ranges(for: [], in: text).isEmpty)
        #expect(FocusParagraph.dimmed == 0.45)
        // Off with no setting.
        #expect(ResolvedSettings.resolved(vault: "", computer: "", root: nil).bool("editor.focus") == false)
    }

    @Test func theNewSettingsHaveTheirDefaults() {
        let neither = ResolvedSettings.resolved(vault: "", computer: "", root: nil)
        #expect(neither.bool("editor.slash_menu") == true)
        #expect(neither.bool("editor.focus") == false)
        #expect(neither.bool("appearance.link_preview") == true)
        // A vault that sets each is followed, and none is refused.
        let vault = ResolvedSettings.resolved(vault: "[editor]\nslash_menu = false\nfocus = true\n", computer: "", root: nil)
        #expect(vault.bool("editor.slash_menu") == false)
        #expect(vault.bool("editor.focus") == true)
        #expect(vault.refused.isEmpty)
        #expect(Set(vault.fromVault) == ["editor.slash_menu", "editor.focus"])
        // A value of another kind is as not there.
        #expect(ResolvedSettings.resolved(vault: "[editor]\nslash_menu = \"yes\"\n", computer: "", root: nil).bool("editor.slash_menu") == true)
        // Focus mode was the Mac's own: a value a Mac wrote to its table is still read first.
        let both = ResolvedSettings.resolved(vault: "[editor]\nfocus = false\n\n[macos.editor]\nfocus = true\n", computer: "", root: nil)
        #expect(both.bool("editor.focus") == true)
        #expect(both.refused.isEmpty)
    }
}

/// The card of a link, and the link under a place of a line.
@Suite struct LinkCardTests {
    @Test func theLinkUnderAPlaceOfALine() {
        let line = "See [[Plan#Next|the plan]] and ![[Shot.png]] or [[Other]]." as NSString
        let first = LinkCard.link(at: 6, in: line)
        #expect(first?.range == line.range(of: "[[Plan#Next|the plan]]"))
        #expect(first?.link.target == "Plan" && first?.link.anchor == "Next" && first?.link.alias == "the plan")
        // The brackets count, at both ends; the letter after does not.
        #expect(LinkCard.link(at: 4, in: line) != nil && LinkCard.link(at: 25, in: line) != nil)
        #expect(LinkCard.link(at: 3, in: line) == nil && LinkCard.link(at: 26, in: line) == nil)
        // An embed has no card, and the link after it has one.
        #expect(LinkCard.link(at: line.range(of: "Shot").location, in: line) == nil)
        #expect(LinkCard.link(at: line.range(of: "Other").location, in: line)?.link.target == "Other")
        // A link into the same note, a block id, and what is no link.
        #expect(LinkCard.link(at: 3, in: "[[#Next]]")?.link.anchor == "Next")
        #expect(LinkCard.link(at: 3, in: "[[Plan#^b1]]")?.link.anchor == "^b1")
        #expect(LinkCard.link(at: 2, in: "[[]]") == nil)
        #expect(LinkCard.link(at: 3, in: "[[open") == nil)
        #expect(LinkCard.link(at: 3, in: "[text](https://example.com)") == nil)
        #expect(LinkCard.link(at: 0, in: "") == nil && LinkCard.link(at: 9, in: "[[a]]") == nil)
    }

    @Test func theCardSaysTheTitleTheHeadingAndTheFolder() {
        let text = "---\ntags: [a]\n---\n# Plan\n\nintro\n\n## Next\n\none ^b1\n\n## Later\n\nthree\n"
        let whole = LinkCard(link: Wikilink("Plan"), path: "Work/2026/Plan.md", text: text)
        #expect(whole.title == "Plan" && whole.heading == nil && whole.folder == "Work › 2026" && whole.path == "Work/2026/Plan.md")
        #expect(whole.body == .lines("intro\n\n## Next\n\none ^b1\n\n## Later\n\nthree"))
        // A heading: its section without it, and its name in the head.
        let next = LinkCard(link: Wikilink("Plan#next|x"), path: "Plan.md", text: text)
        #expect(next.heading == "Next" && next.folder == "" && next.body == .lines("one ^b1"))
        // A block: that block alone.
        #expect(LinkCard(link: Wikilink("Plan#^b1"), path: "Plan.md", text: text).body == .lines("one ^b1"))
        // A heading the note does not have: the note's first lines, and no heading in the head.
        let gone = LinkCard(link: Wikilink("Plan#Gone"), path: "Plan.md", text: text)
        #expect(gone.heading == nil && gone.body == whole.body)
        // An empty note, and a name with no note.
        let empty = LinkCard(link: Wikilink("Plan"), path: "Plan.md", text: "---\ntags: [a]\n---\n")
        #expect(empty.body == .empty && empty.body.words == "The note is empty.")
        let missing = LinkCard(link: Wikilink("Nowhere#x"), path: nil, text: nil)
        #expect(missing.title == "Nowhere" && missing.body == .missing && missing.body.words == "No note yet." && missing.path == nil)
    }
}

@Suite struct ExtractTests {
    @Test func namesFromTheFirstLine() {
        #expect(EditorCommands.extractName(from: "## Kafka: partitions & [[Consumer|consumers]]\nbody") == "Kafka partitions & consumers")
        #expect(EditorCommands.extractName(from: "- [ ] Call the bank") == "Call the bank")
        #expect(EditorCommands.extractName(from: "   \n") == "Untitled")
        #expect(EditorCommands.extractName(from: "...hidden thought") == "hidden thought")
        #expect(VaultMoves.isValidName(EditorCommands.extractName(from: "# .env notes")))
        #expect(EditorCommands.extractName(from: ". . .") == "Untitled")
        #expect(EditorCommands.extractName(from: String(repeating: "word ", count: 30)).count <= 60)
    }

    @Test func aHeadingMovesToTheTitle() {
        #expect(EditorCommands.extractBody("## Partitions\n\nThey order messages.") == "They order messages.")
        #expect(EditorCommands.extractBody("Plain text\nmore") == "Plain text\nmore")
    }
}

@Suite struct HeadingShortcutTests {
    @Test func theLevelIsSetChangedOrTakenOff() {
        #expect(EditorCommands.heading("Plan", level: 2) == "## Plan")
        #expect(EditorCommands.heading("## Plan", level: 3) == "### Plan")
        #expect(EditorCommands.heading("## Plan", level: 2) == "Plan")
        #expect(EditorCommands.heading("### Plan", level: 0) == "Plan")
        #expect(EditorCommands.heading("#tag line", level: 1) == "# #tag line")
    }
}
