import Foundation
import Testing

@testable import DaftarCore

@Suite struct SendToDaftarTests {
    @Test func aSelectionIsOneListItem() {
        #expect(SendToDaftar.scratchpadLine(text: "  Call Sara\n about the trip ", url: nil) == "- Call Sara about the trip")
        #expect(SendToDaftar.scratchpadLine(text: "- already an item", url: nil) == "- already an item")
        #expect(SendToDaftar.scratchpadLine(text: "سلام دنیا", url: nil) == "- سلام دنیا")
        #expect(SendToDaftar.scratchpadLine(text: " \n ", url: nil) == nil)
        #expect(SendToDaftar.scratchpadLine(text: nil, url: nil) == nil)
    }

    @Test func aWebAddressIsInAngleBrackets() {
        #expect(SendToDaftar.scratchpadLine(text: "https://example.com/a?b=1#c", url: nil) == "- <https://example.com/a?b=1#c>")
        #expect(SendToDaftar.scratchpadLine(text: nil, url: "https://example.com/") == "- <https://example.com/>")
        #expect(SendToDaftar.scratchpadLine(text: "<https://example.com>", url: nil) == "- <https://example.com>")
        // The same address twice is one.
        #expect(SendToDaftar.scratchpadLine(text: "https://example.com", url: "https://example.com") == "- <https://example.com>")
        // Not an address: words, a file, a scheme that runs something.
        #expect(SendToDaftar.scratchpadLine(text: "see https://example.com", url: nil) == "- see https://example.com")
        #expect(SendToDaftar.scratchpadLine(text: nil, url: "file:///etc/hosts") == nil)
        #expect(SendToDaftar.scratchpadLine(text: "javascript:alert(1)", url: nil) == "- javascript:alert(1)")
        #expect(SendToDaftar.scratchpadLine(text: "https://", url: nil) == "- https://")
    }

    @Test func aSelectedLinkIsAMarkdownLink() {
        #expect(SendToDaftar.scratchpadLine(text: "Daftar's [docs]", url: "https://example.com/docs") == #"- [Daftar's [docs\]](https://example.com/docs)"#)
        #expect(SendToDaftar.taskText(text: "Read the RFC", url: "https://www.rfc-editor.org/rfc/rfc9110") == "[Read the RFC](https://www.rfc-editor.org/rfc/rfc9110)")
    }

    @Test func aTaskStartsWithTheSelectionWithoutItsMarks() {
        #expect(SendToDaftar.taskText(text: "Renew the passport\nbefore May", url: nil) == "Renew the passport before May")
        #expect(SendToDaftar.taskText(text: "- [ ] Pay rent", url: nil) == "Pay rent")
        #expect(SendToDaftar.taskText(text: "* Pay rent", url: nil) == "Pay rent")
        #expect(SendToDaftar.taskText(text: "- ", url: nil) == nil)
        #expect(SendToDaftar.taskText(text: "", url: nil) == nil)
    }

    @Test func theScratchpadHasASectionForEachDay() {
        let line = SendToDaftar.scratchpadLine(text: "New", url: nil)!
        let heading = SendToDaftar.heading(on: Day("2026-11-12")!)
        #expect(heading == "## 2026-11-12")
        #expect(QuickCapture.append(line, to: "## 2026-11-11\n\n- old\n", heading: heading) == "## 2026-11-11\n\n- old\n\n## 2026-11-12\n\n- New\n")
        #expect(QuickCapture.append(line, to: "## 2026-11-12\n\n- old\n\n## 2026-11-13\n", heading: heading) == "## 2026-11-12\n\n- old\n- New\n\n## 2026-11-13\n")
    }

    @Test func theNewTaskAddressCarriesTheText() throws {
        let url = try #require(SendToDaftar.newTaskURL(text: "Call Sara & Ali #home 100%"))
        #expect(url.absoluteString.hasPrefix("daftar://new-task?text="))
        #expect(SendToDaftar.newTaskText(url) == "Call Sara & Ali #home 100%")
        #expect(SendToDaftar.newTaskText(URL(string: "daftar://new-task?text=a%0Ab")!) == "a b")
        #expect(SendToDaftar.newTaskText(URL(string: "daftar://new-task")!) == "")
        #expect(SendToDaftar.newTaskText(URL(string: "daftar://open?path=a.md")!) == nil)
        #expect(SendToDaftar.newTaskText(URL(string: "https://new-task?text=x")!) == nil)
    }
}
