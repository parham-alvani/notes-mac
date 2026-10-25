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
        #expect(EditorCommands.apply(snippet("red"), slashAt: 4, in: text).cursor == 4 + 5)
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
        // The table's cursor is in its first empty cell; the task's before its date.
        let table = snippet("table").text as NSString
        #expect(table.substring(with: NSRange(location: snippet("table").cursor - 2, length: 2)) == "| ")
        let mermaid = snippet("mermaid").text as NSString
        #expect(mermaid.substring(to: snippet("mermaid").cursor).hasSuffix("A --> B"))
        #expect((snippet("task-today").text as NSString).substring(from: snippet("task-today").cursor) == " 📅 2026-10-25")
    }
}

@Suite struct ExtractTests {
    @Test func namesFromTheFirstLine() {
        #expect(EditorCommands.extractName(from: "## Kafka: partitions & [[Consumer|consumers]]\nbody") == "Kafka partitions & consumers")
        #expect(EditorCommands.extractName(from: "- [ ] Call the bank") == "Call the bank")
        #expect(EditorCommands.extractName(from: "   \n") == "Untitled")
        #expect(EditorCommands.extractName(from: String(repeating: "word ", count: 30)).count <= 60)
    }

    @Test func aHeadingMovesToTheTitle() {
        #expect(EditorCommands.extractBody("## Partitions\n\nThey order messages.") == "They order messages.")
        #expect(EditorCommands.extractBody("Plain text\nmore") == "Plain text\nmore")
    }
}
