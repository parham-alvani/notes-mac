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
}
