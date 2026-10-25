import AppKit
import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// The editor on a made-up vault in a temporary folder, with its own
/// settings file: nothing here may reach the person's config or vault.
@MainActor
@Suite(.serialized) struct EditorTests {
    let root: URL
    let store: VaultStore
    let controller: EditorController
    let view: NoteTextView

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Notes"), withIntermediateDirectories: true)
        try "# Plan\n- [ ] first\n".write(to: root.appending(path: "Notes/Plan.md"), atomically: true, encoding: .utf8)
        try "Kubernetes notes".write(to: root.appending(path: "Notes/Kubernetes.md"), atomically: true, encoding: .utf8)
        let settings = AppSettings(url: root.appending(path: "config/config.toml"))
        store = VaultStore(settings: settings, openVault: false)
        store.openSynchronously(root)
        controller = EditorController(store: store)
        let scroll = NoteTextView.scrollableNoteView()
        view = scroll.documentView as! NoteTextView
        view.controller = controller
        controller.view = view
        controller.load("Notes/Plan.md")
    }

    func end() {
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
    }

    @Test func aSlashCommandReplacesTheSlash() throws {
        // A window, off screen, gives the view its undo manager.
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        end()
        view.insertText("Notes /", replacementRange: view.selectedRange())
        let slash = (view.string as NSString).length - 1
        let menu = view.slashMenu(at: slash)
        #expect(menu.items.contains { $0.title == "Code block" && $0.image != nil })
        let snippet = try #require(EditorCommands.slashCommands(today: Day(year: 2026, month: 10, day: 25), time: "09:00").first { $0.id == "code" })
        view.applySlash(snippet, slashAt: slash)
        #expect(view.string == "# Plan\n- [ ] first\nNotes \n```\n\n```")
        #expect(view.selectedRange().location == (view.string as NSString).length - 4)
        // In a test the typing and the snippet are one undo group; in the
        // app they are two keystrokes. Either way, undo takes the snippet away.
        let undo = try #require(view.undoManager)
        undo.undo()
        #expect(!view.string.contains("```"))
    }

    @Test func extractPutsALinkWhereTheSelectionWas() throws {
        var extracted: String?
        controller.onExtract = { text, replace in
            extracted = text
            replace("[[First]]")
        }
        let range = (view.string as NSString).range(of: "- [ ] first")
        view.setSelectedRange(range)
        controller.extract()
        #expect(extracted == "- [ ] first")
        #expect(view.string == "# Plan\n[[First]]\n")
    }

    @Test func returnContinuesATaskList() {
        view.setSelectedRange(NSRange(location: ("# Plan\n- [ ] first" as NSString).length, length: 0))
        view.insertNewline(nil)
        view.insertText("second", replacementRange: view.selectedRange())
        #expect(view.string == "# Plan\n- [ ] first\n- [ ] second\n")
    }

    @Test func doubleBracketClosesTheLink() {
        end()
        view.insertText("[", replacementRange: view.selectedRange())
        view.insertText("[", replacementRange: view.selectedRange())
        #expect(view.string.hasSuffix("[[]]"))
        #expect(view.selectedRange().location == (view.string as NSString).length - 2)
    }

    @Test func completionOffersNotes() {
        end()
        view.insertText("[[Kub", replacementRange: view.selectedRange())
        let range = view.rangeForUserCompletion
        #expect((view.string as NSString).substring(with: range) == "Kub")
        let names = controller.textView(view, completions: [], forPartialWordRange: range, indexOfSelectedItem: nil)
        #expect(names.first == "Kubernetes")
    }

    @Test func savesToTheFile() throws {
        end()
        view.insertText("more\n", replacementRange: view.selectedRange())
        controller.saveNow()
        let disk = try String(contentsOf: root.appending(path: "Notes/Plan.md"), encoding: .utf8)
        #expect(disk == "# Plan\n- [ ] first\nmore\n")
    }

    @Test func diskChangeIsTakenWhenNothingIsUnsaved() throws {
        try "# Plan\n- [x] first\n".write(to: root.appending(path: "Notes/Plan.md"), atomically: true, encoding: .utf8)
        store.noteChanged("Notes/Plan.md")
        controller.followDisk()
        #expect(view.string == "# Plan\n- [x] first\n")
    }

    @Test func diskChangeNeverReplacesTyping() throws {
        end()
        view.insertText("typed", replacementRange: view.selectedRange())
        try "other\n".write(to: root.appending(path: "Notes/Plan.md"), atomically: true, encoding: .utf8)
        store.noteChanged("Notes/Plan.md")
        controller.followDisk()
        #expect(view.string.hasSuffix("typed"))
        #expect(store.notice != nil)
    }

    @Test func tabIndentsAListItemByFour() {
        view.setSelectedRange(NSRange(location: ("# Plan\n- [ ] fi" as NSString).length, length: 0))
        view.insertTab(nil)
        #expect(view.string == "# Plan\n    - [ ] first\n")
        view.insertBacktab(nil)
        #expect(view.string == "# Plan\n- [ ] first\n")
    }

    @Test func anEmbeddedImageGetsRoomUnderItsLine() throws {
        let image = NSImage(size: NSSize(width: 200, height: 100), flipped: false) { rect in
            NSColor.orange.setFill()
            rect.fill()
            return true
        }
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try FileManager.default.createDirectory(at: root.appending(path: "uploads"), withIntermediateDirectories: true)
        try png.write(to: root.appending(path: "uploads/pic.png"))
        try "Before\n![[pic.png]]\nAfter\n".write(to: root.appending(path: "Notes/Pic.md"), atomically: true, encoding: .utf8)
        store.openSynchronously(root)
        controller.load("Notes/Pic.md")
        let at = ("Before\n" as NSString).length
        let embedded = view.textStorage?.attribute(.daftarImage, at: at, effectiveRange: nil) as? EmbeddedImage
        #expect(embedded?.size.height == 100)
        let paragraph = view.textStorage?.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle
        #expect((paragraph?.paragraphSpacing ?? 0) > 100)
        #expect(view.string == "Before\n![[pic.png]]\nAfter\n")
    }

    @Test func linksOpenNotesInTheirMode() {
        let model = WindowModel()
        model.handle(URL(string: "daftar://open?path=Notes/Plan.md&mode=edit")!, store: store)
        #expect(model.path == "Notes/Plan.md" && model.editing)
        model.handle(URL(string: "daftar://open?path=Notes/Kubernetes.md")!, store: store)
        #expect(model.path == "Notes/Kubernetes.md" && !model.editing)
        model.handle(URL(string: "daftar://open?path=today")!, store: store)
        #expect(model.showsToday)
        model.handle(URL(string: "daftar://terminal")!, store: store)
        #expect(model.terminal)
    }

    @Test func headingsAreStyled() {
        let font = view.textStorage?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        #expect((font?.pointSize ?? 0) > CGFloat(store.settings.textSize))
    }

    func isCode(_ word: String) -> Bool {
        let at = (view.string as NSString).range(of: word).location
        let font = view.textStorage?.attribute(.font, at: at, effectiveRange: nil) as? NSFont
        return font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true
    }

    @Test func aFenceRestylesWhatFollowsItAndNothingElseDoes() throws {
        try "intro\nlater words\n\nmore prose\n".write(to: root.appending(path: "Notes/Fence.md"), atomically: true, encoding: .utf8)
        controller.load("Notes/Fence.md")
        #expect(!isCode("later"))
        view.setSelectedRange(NSRange(location: 6, length: 0))
        view.insertText("```\n", replacementRange: view.selectedRange())
        #expect(isCode("later") && isCode("more"))
        #expect(!isCode("intro"))
        // One backtick less, and there is no fence: the rest is prose again.
        view.setSelectedRange(NSRange(location: 7, length: 1))
        view.insertText("", replacementRange: view.selectedRange())
        #expect(!isCode("later") && !isCode("more"))
    }

    @Test func theStructureIsTheBlockLinesInOrder() {
        let text = "---\ntags: [a]\n---\n# T\n> ```swift\ncode\n```\n$$ x $$\na %% b\n| --- |\n- [ ] task\n"
        #expect(EditorController.structure(of: text as NSString) == ["---", "---", "```swift", "```", "$$ x $$\n", "a %% b\n"])
        // A new line above a fence changes where it is, not the structure.
        #expect(EditorController.structure(of: ("\n" + text) as NSString) == EditorController.structure(of: text as NSString))
    }

    @Test func aLongNoteIsStyledToItsEnd() async throws {
        let long = String(repeating: "Some prose to fill the note with words.\n", count: 1500) + "# The last heading\n"
        try long.write(to: root.appending(path: "Notes/Long.md"), atomically: true, encoding: .utf8)
        controller.load("Notes/Long.md")
        let at = (view.string as NSString).range(of: "The last heading").location
        func size() -> CGFloat { (view.textStorage?.attribute(.font, at: at, effectiveRange: nil) as? NSFont)?.pointSize ?? 0 }
        let heading = CGFloat(store.settings.textSize) * 1.75
        // The first screens are styled at once; the end comes a moment later.
        #expect(abs(size() - heading) > 0.5)
        for _ in 0..<100 {
            if abs(size() - heading) < 0.5 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(abs(size() - heading) < 0.5)
    }

    @Test func theEditorOpensAtTheReadingLineAndSaysWhereItIs() async throws {
        try "zero\none\ntwo\nthree\n".write(to: root.appending(path: "Notes/Lines.md"), atomically: true, encoding: .utf8)
        var reported: [Int] = []
        controller.onCursor = { reported.append($0) }
        controller.load("Notes/Lines.md")
        controller.go(toLine: 2)
        #expect(view.selectedRange().location == ("zero\none\n" as NSString).length)
        try await Task.sleep(for: .milliseconds(300))
        #expect(reported.last == 2)
    }

    func put(_ text: String, cursor: Int) {
        view.textStorage?.setAttributedString(NSAttributedString(string: text))
        view.setSelectedRange(NSRange(location: cursor, length: 0))
    }

    @Test func tabInATableGoesToTheNextCellAndLinesItUp() {
        put("intro\n| a | b |\n|-|-|\n| long cell | x |\nafter", cursor: 9)
        view.insertTab(nil)
        #expect(view.string == "intro\n| a         | b   |\n| --------- | --- |\n| long cell | x   |\nafter")
        // In cell b now; Tab again goes over the separator to the next row.
        #expect(view.selectedRange().location == ("intro\n| a         | " as NSString).length)
        view.insertTab(nil)
        #expect(view.selectedRange().location == ("intro\n| a         | b   |\n| --------- | --- |\n| " as NSString).length)
        // Return at the end of the last row starts a new one.
        view.setSelectedRange(NSRange(location: ("intro\n| a         | b   |\n| --------- | --- |\n| long cell | x   |" as NSString).length, length: 0))
        view.insertNewline(nil)
        #expect(view.string.contains("| long cell | x   |\n|           |     |\nafter"))
    }

    @Test func aSelectionIsWrappedAndBracketsComeInPairs() {
        put("make this bold", cursor: 0)
        view.setSelectedRange(NSRange(location: 5, length: 4))
        view.insertText("*", replacementRange: view.selectedRange())
        view.insertText("*", replacementRange: view.selectedRange())
        #expect(view.string == "make **this** bold")
        put("call ", cursor: 5)
        view.insertText("(", replacementRange: view.selectedRange())
        #expect(view.string == "call ()")
        view.insertText("x", replacementRange: view.selectedRange())
        view.insertText(")", replacementRange: view.selectedRange())
        #expect(view.string == "call (x)")
        #expect(view.selectedRange().location == 8)
        // An empty pair goes with one backspace; `[[` still makes a link.
        put("a ", cursor: 2)
        view.insertText("(", replacementRange: view.selectedRange())
        view.deleteBackward(nil)
        #expect(view.string == "a ")
        view.insertText("[", replacementRange: view.selectedRange())
        view.insertText("[", replacementRange: view.selectedRange())
        #expect(view.string == "a [[]]")
        #expect(view.selectedRange().location == 4)
    }

    @Test func aLinkPastedOnWordsAndLinesThatMove() {
        put("see the docs here", cursor: 0)
        view.setSelectedRange(NSRange(location: 8, length: 4))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("https://example.com/docs", forType: .string)
        view.paste(nil)
        #expect(view.string == "see the [docs](https://example.com/docs) here")
        put("one\ntwo\n", cursor: 5)
        let up = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: 126)!
        view.keyDown(with: up)
        #expect(view.string == "two\none\n")
    }

    func hidden(_ text: String, occurrence: Int = 0) -> Bool {
        var range = NSRange(location: 0, length: 0), from = 0
        for _ in 0...occurrence {
            range = (view.string as NSString).range(of: text, range: NSRange(location: from, length: (view.string as NSString).length - from))
            from = NSMaxRange(range)
        }
        let color = view.textStorage?.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        return color == .clear
    }

    @Test func liveMarksHideAwayFromTheCursor() throws {
        try "## Head\n\nSome **bold** and [a link](https://x.y) here.\n\n> quote\n".write(to: root.appending(path: "Notes/Live.md"), atomically: true, encoding: .utf8)
        controller.load("Notes/Live.md")
        // The cursor is on the heading: its marks show, the others do not.
        #expect(!hidden("##"))
        #expect(hidden("**") && hidden("(https"))
        #expect(!hidden(">"))
        try "Top\n\nOn ==🟢 Friday== now.\n".write(to: root.appending(path: "Notes/H.md"), atomically: true, encoding: .utf8)
        controller.load("Notes/H.md")
        #expect(hidden("🟢"))
        controller.load("Notes/Live.md")
        // On the line of the bold word, its marks come back, the heading's go.
        view.setSelectedRange(NSRange(location: (view.string as NSString).range(of: "bold").location, length: 0))
        #expect(!hidden("**") && !hidden("(https"))
        #expect(hidden("##"))
        store.settings.livePreview = false
        controller.restyle(all: true)
        #expect(!hidden("##"))
        store.settings.livePreview = true
    }

    @Test func marksHideInQuotesAndOnTheLastLine() throws {
        try "Top\n\nBring the ~~old~~ new.\n\n> Bring the ~~gone~~ one.".write(to: root.appending(path: "Notes/S.md"), atomically: true, encoding: .utf8)
        controller.load("Notes/S.md")
        #expect(hidden("~~") && hidden("~~", occurrence: 2))
        // The cursor at the very end shows the last line's marks.
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        #expect(!hidden("~~", occurrence: 2) && hidden("~~"))
    }
}
