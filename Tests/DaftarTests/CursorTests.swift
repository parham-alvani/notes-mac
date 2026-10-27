import AppKit
import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// Many cursors, focus mode and spelling in the editor, on a made-up vault
/// in a temporary folder, off screen.
@MainActor
@Suite(.serialized) struct CursorTests {
    let root: URL
    let store: VaultStore
    let controller: EditorController
    let view: NoteTextView
    let window: NSWindow

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-cursors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Notes"), withIntermediateDirectories: true)
        try "cat one\ncat two\ncat three\n".write(to: root.appending(path: "Notes/Cats.md"), atomically: true, encoding: .utf8)
        let settings = AppSettings(url: root.appending(path: "config/config.toml"))
        store = VaultStore(settings: settings, openVault: false)
        store.openSynchronously(root)
        controller = EditorController(store: store)
        let scroll = NoteTextView.scrollableNoteView()
        view = scroll.documentView as! NoteTextView
        view.controller = controller
        controller.view = view
        // A window, off screen, gives the view its undo manager and its layout.
        window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        controller.load("Notes/Cats.md")
    }

    func r(_ location: Int, _ length: Int = 0) -> NSRange { NSRange(location: location, length: length) }

    @Test func typingGoesInAtEveryCursorAsOneUndo() throws {
        // In the app each key is its own event, and its own group to undo;
        // a test has no event loop, so the groups are the editor's own.
        let undo = try #require(view.undoManager)
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        view.setCursors([r(0), r(8), r(16)])
        #expect(view.hasManyCursors)
        view.insertText("a ", replacementRange: r(NSNotFound))
        #expect(view.string == "a cat one\na cat two\na cat three\n")
        #expect(view.cursorRanges == [r(2), r(12), r(22)])
        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(view.string == "acat one\nacat two\nacat three\n")
        // Each key is one step to undo, all cursors together.
        undo.undo()
        #expect(view.string == "a cat one\na cat two\na cat three\n")
        undo.undo()
        #expect(view.string == "cat one\ncat two\ncat three\n")
    }

    func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    @Test func realKeysReachEveryCursor() {
        window.makeFirstResponder(view)
        view.setCursors([r(0), r(8)])
        view.keyDown(with: key("x", code: 7))
        #expect(view.string == "xcat one\nxcat two\ncat three\n")
        // Backspace, the right arrow and Escape, as the keyboard sends them.
        view.keyDown(with: key("\u{7F}", code: 51))
        view.keyDown(with: key(String(UnicodeScalar(NSRightArrowFunctionKey)!), code: 124, flags: [.numericPad, .function]))
        #expect(view.cursorRanges == [r(1), r(9)])
        view.keyDown(with: key("\u{1B}", code: 53))
        #expect(view.cursorRanges == [r(1)])
    }

    @Test func arrowsMoveEveryCursorAndEscapeLeavesOne() {
        view.setCursors([r(0), r(8)])
        view.doCommand(by: #selector(NSResponder.moveRight(_:)))
        #expect(view.cursorRanges == [r(1), r(9)])
        view.doCommand(by: #selector(NSResponder.moveToEndOfLine(_:)))
        #expect(view.cursorRanges == [r(7), r(15)])
        view.insertText("!", replacementRange: r(NSNotFound))
        #expect(view.string == "cat one!\ncat two!\ncat three\n")
        // ⇧→ selects at every cursor, and goes on from where it is.
        view.setCursors([r(0), r(9)])
        view.doCommand(by: #selector(NSResponder.moveRightAndModifySelection(_:)))
        view.doCommand(by: #selector(NSResponder.moveRightAndModifySelection(_:)))
        #expect(view.cursorRanges == [r(0, 2), r(9, 2)])
        view.doCommand(by: #selector(NSResponder.moveLeftAndModifySelection(_:)))
        #expect(view.cursorRanges == [r(0, 1), r(9, 1)])
        view.setCursors([r(0), r(8)])
        view.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(!view.hasManyCursors)
        #expect(view.selectedRange() == r(0))
        // The extra carets are drawn while they are there, not after.
        #expect(view.extraCaretRects().isEmpty)
    }

    @Test func aClickWithoutKeysEndsTheCursors() {
        view.setCursors([r(0), r(8)])
        #expect(view.extraCaretRects().count == 1)
        view.setSelectedRange(r(3))
        #expect(!view.hasManyCursors)
        #expect(view.cursorRanges == [r(3)])
    }

    @Test func nextAndAllOccurrences() {
        view.setSelectedRange(r(1))
        // From a caret, the word first; then the next one each time.
        view.selectNextOccurrence(nil)
        #expect(view.cursorRanges == [r(0, 3)])
        view.selectNextOccurrence(nil)
        view.selectNextOccurrence(nil)
        #expect(view.cursorRanges == [r(0, 3), r(8, 3), r(16, 3)])
        view.insertText("dog", replacementRange: r(NSNotFound))
        #expect(view.string == "dog one\ndog two\ndog three\n")
        view.setSelectedRange(r(9))
        view.selectAllOccurrences(nil)
        #expect(view.cursorRanges == [r(0, 3), r(8, 3), r(16, 3)])
    }

    @Test func aPasteOfAsManyLinesGivesOneToEach() {
        let board = NSPasteboard.general
        let saved = board.string(forType: .string)
        defer {
            board.clearContents()
            if let saved { board.setString(saved, forType: .string) }
        }
        board.clearContents()
        board.setString("1\n2\n3", forType: .string)
        view.setCursors([r(0), r(8), r(16)])
        view.paste(nil)
        #expect(view.string == "1cat one\n2cat two\n3cat three\n")
    }

    @Test func aColumnTakesTypingOnEachLine() {
        // A drag straight down from after `cat` on the first line to the third.
        view.columnSelect(from: 3, to: 19)
        #expect(view.cursorRanges == [r(3), r(11), r(19)])
        view.insertText("s", replacementRange: r(NSNotFound))
        #expect(view.string == "cats one\ncats two\ncats three\n")
        // A wider column replaces what it covers on each line.
        view.columnSelect(from: 0, to: 22)
        #expect(view.cursorRanges == [r(0, 4), r(9, 4), r(18, 4)])
        view.insertText("x", replacementRange: r(NSNotFound))
        #expect(view.string == "x one\nx two\nx three\n")
    }

    @Test func focusDimsWithoutTouchingTheText() throws {
        try "First paragraph\nstill first\n\nSecond one\n".write(to: root.appending(path: "Notes/Cats.md"), atomically: true, encoding: .utf8)
        controller.load("Notes/Cats.md")
        let before = NSAttributedString(attributedString: try #require(view.textStorage))
        store.settings.focusMode = true
        view.setSelectedRange(r(2))
        controller.followCursor()
        let layout = try #require(view.textLayoutManager)
        var dimmed: [NSRange] = []
        let content = try #require(layout.textContentManager)
        layout.enumerateRenderingAttributes(from: content.documentRange.location, reverse: false) { _, attributes, range in
            if attributes[.foregroundColor] != nil {
                dimmed.append(NSRange(location: content.offset(from: content.documentRange.location, to: range.location),
                    length: content.offset(from: range.location, to: range.endLocation)))
            }
            return true
        }
        #expect(dimmed.map { NSMaxRange($0) }.max() == (view.string as NSString).length)
        #expect(dimmed.allSatisfy { $0.location >= 28 })
        #expect(view.textStorage?.isEqual(to: before) == true)
        store.settings.focusMode = false
        controller.followWritingModes()
        var left = 0
        layout.enumerateRenderingAttributes(from: content.documentRange.location, reverse: false) { _, attributes, _ in
            if attributes[.foregroundColor] != nil { left += 1 }
            return true
        }
        #expect(left == 0)
    }

    @Test func typewriterKeepsTheLineInTheMiddleToTheLastLine() throws {
        let lines = (1...200).map { "Line \($0)" }.joined(separator: "\n")
        try lines.write(to: root.appending(path: "Notes/Cats.md"), atomically: true, encoding: .utf8)
        controller.load("Notes/Cats.md")
        controller.restyle(all: true)
        store.settings.typewriter = true
        // On screen the view grows as its text is laid out; off screen, now.
        let layout = try #require(view.textLayoutManager)
        layout.ensureLayout(for: layout.documentRange)
        layout.textViewportLayoutController.layoutViewport()
        let scroll = try #require(view.enclosingScrollView)
        let clip = scroll.contentView
        for offset in [(lines as NSString).range(of: "Line 100").location, (lines as NSString).length] {
            view.setSelectedRange(r(offset))
            // As the view does when the cursor moves there: its line on screen, and laid out.
            view.scrollRangeToVisible(r(offset))
            layout.textViewportLayoutController.layoutViewport()
            controller.followCursor()
            let line = try #require(view.lineRect(at: min(offset, (lines as NSString).length - 1)))
            #expect(abs(line.midY - (clip.bounds.origin.y + clip.bounds.height / 2)) < 2)
        }
        store.settings.typewriter = false
        controller.followWritingModes()
        #expect(scroll.automaticallyAdjustsContentInsets)
    }

    @Test func spellingMarksEnglishProseOnly() throws {
        let text = "Helo `teh` wrld\nسلامم دنیاا\n#tagg [[Notte]]"
        view.string = text
        let ns = text as NSString
        func spelling(_ word: String) -> NSTextCheckingResult {
            NSTextCheckingResult.spellCheckingResult(range: ns.range(of: word))
        }
        let results = ["Helo", "teh", "wrld", "سلامم", "tagg", "Notte"].map(spelling)
        let kept = controller.textView(view, didCheckTextIn: NSRange(location: 0, length: ns.length), types: NSTextCheckingTypes(NSTextCheckingResult.CheckingType.spelling.rawValue),
            options: [:], results: results, orthography: NSOrthography.defaultOrthography(forLanguage: "en"), wordCount: 0)
        #expect(kept.map { ns.substring(with: $0.range) } == (EditorController.dictionaries.contains("fa") ? ["Helo", "wrld", "سلامم"] : ["Helo", "wrld"]))
        store.settings.spellCheck = false
        controller.followWritingModes()
        #expect(!view.isContinuousSpellCheckingEnabled)
        store.settings.spellCheck = true
        controller.followWritingModes()
        #expect(view.isContinuousSpellCheckingEnabled)
    }
}
