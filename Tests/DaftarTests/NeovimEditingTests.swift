import AppKit
import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// Everyday Neovim use through the editor view, against a real `nvim --clean`:
/// each step checked against the view, the file Neovim writes, and the cursor.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: hasNeovim)) struct NeovimEditingTests {
    let root: URL
    let store: VaultStore
    let controller: EditorController
    let view: NoteTextView
    let window: NSWindow

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-vim-editing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settings = AppSettings(url: root.appending(path: "config/config.toml"))
        settings.vimMode = true
        settings.nvimConfig = "clean"
        store = VaultStore(settings: settings, openVault: false)
        store.openSynchronously(root)
        controller = EditorController(store: store)
        let scroll = NoteTextView.scrollableNoteView()
        view = scroll.documentView as! NoteTextView
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = EditorContainer(scroll: scroll)
        view.controller = controller
        controller.view = view
    }

    func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    func press(_ characters: String, _ flags: NSEvent.ModifierFlags = [], ignoring: String? = nil) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: ignoring ?? characters, isARepeat: false, keyCode: 0)!
        view.keyDown(with: event)
    }

    func keys(_ text: String) { for character in text { press(String(character)) } }

    func open(_ text: String) async throws -> NeovimSession {
        try text.write(to: root.appending(path: "N.md"), atomically: true, encoding: .utf8)
        controller.load("N.md")
        let session = try #require(controller.session)
        #expect(await eventually { session.state == .running })
        return session
    }

    func file() -> String { (try? String(contentsOf: root.appending(path: "N.md"), encoding: .utf8)) ?? "" }

    /// The view and the file both say [text], once Neovim is back in normal mode.
    func settle(_ session: NeovimSession, _ text: String, _ comment: Comment) async {
        let view = await eventually { self.view.string == text }
        #expect(view, "view: \(comment) -> \(self.view.string.debugDescription)")
        let saved = await eventually { self.file() == text }
        #expect(saved, "file: \(comment) -> \(self.file().debugDescription)")
    }

    func cursor(_ offset: Int, _ comment: Comment) async {
        let ok = await eventually { view.selectedRange().location == offset }
        #expect(ok, "cursor: \(comment) -> \(view.selectedRange())")
    }

    @Test func keysTypedBeforeNeovimRunsAreKept() async throws {
        try "one\n".write(to: root.appending(path: "N.md"), atomically: true, encoding: .utf8)
        controller.load("N.md")
        let session = try #require(controller.session)
        keys("Atwo\u{1B}")
        #expect(await eventually { session.state == .running })
        await settle(session, "onetwo\n", "typed while starting")
        await session.stop()
    }

    @Test func fastTypingLosesNothing() async throws {
        let session = try await open("x\n")
        let text = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 6)
        press("A")
        keys(text)
        press("\u{1B}")
        await settle(session, "x" + text + "\n", "fast typing")
        await session.stop()
    }

    @Test func undoRedoAndRepeat() async throws {
        let session = try await open("abcdef\n")
        keys("xxx")
        await settle(session, "def\n", "xxx")
        keys("uu")
        await settle(session, "bcdef\n", "uu")
        press("r", .control, ignoring: "r")
        await settle(session, "cdef\n", "ctrl-r")
        keys("x.")
        await settle(session, "ef\n", "x.")
        await session.stop()
    }

    @Test func linesDeletePutAndIndent() async throws {
        let session = try await open("a\nb\nc\n")
        keys("ddp")
        await settle(session, "b\na\nc\n", "ddp")
        await cursor(2, "on a")
        keys(">>")
        // The runtime's markdown settings: four spaces.
        await settle(session, "b\n    a\nc\n", ">>")
        keys("Vjd")
        await settle(session, "b\n", "Vjd")
        await session.stop()
    }

    @Test func emojiAndPersianKeepTheCursorInStep() async throws {
        let session = try await open("a😀b سلام c\n")
        keys("0l")
        await cursor(1, "on the emoji")
        keys("l")
        await cursor(3, "after the emoji, two UTF-16 units")
        keys("x")
        await settle(session, "a😀 سلام c\n", "x after emoji")
        keys("$")
        await cursor(("a😀 سلام c" as NSString).length - 1, "$")
        keys("0fس")
        await cursor(("a😀 " as NSString).length, "f to a Persian letter")
        keys("iخ\u{1B}")
        await settle(session, "a😀 خسلام c\n", "insert Persian")
        await session.stop()
    }

    @Test func commandLineAndSearch() async throws {
        let session = try await open("red green red\nblue red\n")
        keys(":%s/red/RED/g\r")
        await settle(session, "RED green RED\nblue RED\n", ":%s")
        keys("gg/blue\r")
        await cursor(("RED green RED\n" as NSString).length, "search")
        keys("ciwBLUE\u{1B}")
        await settle(session, "RED green RED\nBLUE RED\n", "ciw")
        await session.stop()
    }

    @Test func aChangeOnDiskIsReadAgain() async throws {
        let session = try await open("old\n")
        try "new from outside\n".write(to: root.appending(path: "N.md"), atomically: true, encoding: .utf8)
        session.checkDisk()
        #expect(await eventually { view.string == "new from outside\n" }, "view: \(view.string.debugDescription)")
        // Neovim stopped sending the lines when it read the file again: the
        // view listens anew, and what is typed next still shows.
        keys("A!\u{1B}")
        await settle(session, "new from outside!\n", "typed after the reload")
        await session.stop()
    }

    @Test func pasteInNormalModeGoesInAsText() async throws {
        let session = try await open("ab\n")
        session.paste("X<Esc>Y")
        await settle(session, "aX<Esc>Yb\n", "paste is literal")
        await session.stop()
    }

    @Test func blockInsertWithCtrlV() async throws {
        let session = try await open("a\nb\nc\n")
        press("v", .control, ignoring: "v")
        keys("jjI- \u{1B}")
        await settle(session, "- a\n- b\n- c\n", "block insert")
        await session.stop()
    }

    @Test func ctrlAIncrements() async throws {
        let session = try await open("item 9\n")
        press("a", .control, ignoring: "a")
        await settle(session, "item 10\n", "ctrl-a")
        await session.stop()
    }
}
