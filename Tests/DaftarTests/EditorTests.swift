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
}
