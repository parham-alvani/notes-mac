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

    func press(_ characters: String, _ flags: NSEvent.ModifierFlags = [], ignoring: String? = nil, keyCode: UInt16 = 0) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: ignoring ?? characters, isARepeat: false, keyCode: keyCode)!
        view.keyDown(with: event)
    }

    func keys(_ text: String) { for character in text { press(String(character)) } }

    func open(_ text: String) async throws -> NeovimSession {
        try text.write(to: root.appending(path: "N.md"), atomically: true, encoding: .utf8)
        // The index knows the note, so a save of the view's own is not refused.
        store.openSynchronously(root)
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

    @Test func quittingNeovimGoesBackToReading() async throws {
        var quit = 0
        controller.onQuit = { quit += 1 }
        let session = try await open("a\n")
        keys("Ab\u{1B}:wq\r")
        #expect(await eventually { quit == 1 })
        #expect(file() == "ab\n")
        #expect(controller.session == nil)
        _ = session
    }

    /// `:q!` throws the edits away: the view leaving the screen, which
    /// saves a plain editor, must not write them.
    @Test func quittingWithoutWritingWritesNothing() async throws {
        var quit = 0
        controller.onQuit = { quit += 1 }
        let session = try await open("a\n")
        keys("Ab\u{1B}")
        #expect(await eventually { self.view.string == "ab\n" })
        keys(":q!\r")
        #expect(await eventually { quit == 1 })
        #expect(view.string == "a\n")
        // What SwiftUI does as the editor goes: `dismantleNSView`.
        controller.saveNow()
        #expect(file() == "a\n")
        _ = session
    }

    /// After `:wq` the file is Neovim's: the view does not write it again.
    @Test func writeAndQuitWritesOnce() async throws {
        var quit = 0
        controller.onQuit = { quit += 1 }
        let session = try await open("a\n")
        keys("Ab\u{1B}:wq\r")
        #expect(await eventually { quit == 1 })
        let url = root.appending(path: "N.md")
        let written = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        try await Task.sleep(for: .milliseconds(20))
        controller.saveNow()
        #expect(file() == "ab\n")
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == written)
        _ = session
    }

    /// A Neovim that is killed wrote nothing: the typing the view shows is
    /// saved, and the note stays open in the plain editor.
    @Test func aKilledNeovimLosesNoTyping() async throws {
        var quit = 0
        controller.onQuit = { quit += 1 }
        let session = try await open("a\n")
        keys("Ab")
        #expect(await eventually { self.view.string == "ab\n" })
        kill(session.processIdentifier, SIGKILL)
        #expect(await eventually { self.controller.session == nil })
        #expect(file() == "ab\n")
        #expect(quit == 0)
        #expect(controller.owner == .plain)
    }

    /// A Neovim that never answers -- at a question, in a plugin -- does
    /// not leave the editor at "Starting Neovim…" for ever.
    @Test func aNeovimThatNeverAnswersGivesWayToThePlainEditor() async throws {
        let script = root.appending(path: "config/stuck")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexec sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        store.settings.nvimPath = script.path
        NeovimSession.startLimit = .milliseconds(300)
        defer { NeovimSession.startLimit = .seconds(15) }
        try "a\n".write(to: root.appending(path: "N.md"), atomically: true, encoding: .utf8)
        store.openSynchronously(root)
        controller.load("N.md")
        #expect(controller.owner == .neovimStarting)
        #expect(await eventually { self.controller.session == nil })
        #expect(controller.owner == .plain)
    }

    /// A save that is waited for (Sort Tasks, a property, quit) and a
    /// Neovim that does not write: it is ended, and the typing is saved
    /// from the view.
    @Test func aSaveNeovimDoesNotAnswerIsMadeByTheEditor() async throws {
        NeovimSession.saveLimit = .milliseconds(400)
        defer { NeovimSession.saveLimit = .seconds(5) }
        let session = try await open("a\n")
        keys("Ab\u{1B}")
        #expect(await eventually { self.view.string == "ab\n" })
        keys(":lua vim.uv.sleep(30000)\r")
        try await Task.sleep(for: .milliseconds(100))
        await controller.flush()
        #expect(file() == "ab\n")
        #expect(controller.session == nil)
        #expect(controller.owner == .plain)
        _ = session
    }

    /// The same as the editor leaves the note: the buffer is written by the store.
    @Test func aStopNeovimDoesNotAnswerStillWritesTheBuffer() async throws {
        NeovimSession.stopLimit = .milliseconds(400)
        defer { NeovimSession.stopLimit = .seconds(3) }
        let session = try await open("a\n")
        keys("Ab\u{1B}")
        #expect(await eventually { self.view.string == "ab\n" })
        keys(":lua vim.uv.sleep(30000)\r")
        try await Task.sleep(for: .milliseconds(100))
        controller.stopVim()
        #expect(await eventually { self.file() == "ab\n" })
        _ = session
    }

    /// A Neovim that does not start leaves the plain editor, which saves:
    /// before, the view took the typing and no save ever wrote it.
    @Test func typingAfterAFailedStartIsSaved() async throws {
        store.settings.nvimPath = "/usr/bin/false"
        try "a\n".write(to: root.appending(path: "N.md"), atomically: true, encoding: .utf8)
        store.openSynchronously(root)
        controller.load("N.md")
        #expect(controller.owner == .neovimStarting)
        #expect(await eventually { controller.session == nil })
        #expect(controller.owner == .plain)
        #expect(store.notice?.contains("Neovim did not start") == true)
        view.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        #expect(view.string == "xa\n")
        controller.saveNow()
        #expect(file() == "xa\n")
        // Not started again at each update of the view.
        controller.followVimSetting()
        #expect(controller.session == nil)
    }

    /// A Neovim that is being stopped still writes its file, and a
    /// formatter that runs at the write changes its buffer: that edit must
    /// not reach the view, which shows another text by then.
    @Test func aStoppedNeovimDoesNotEditTheView() async throws {
        let session = try await open("a\n")
        keys(":autocmd BufWritePre * call setline(1, 'formatted')\r")
        keys("Ax\u{1B}")
        #expect(await eventually { self.view.string == "ax\n" })
        // Neovim mode goes off: the plain editor shows the file as it is now.
        store.settings.vimMode = false
        controller.followVimSetting()
        #expect(controller.session == nil)
        let shown = view.string
        // The old Neovim writes, its formatter runs.
        #expect(await eventually { self.file() == "formatted\n" })
        try await Task.sleep(for: .milliseconds(200))
        #expect(view.string == shown)
        _ = session
    }

    /// ⌃A with the Persian layout on: the key reads `ش`, and Neovim gets `<C-a>`.
    @Test func controlChordsWorkWithThePersianLayoutOn() async throws {
        guard NeovimSession.latinCharacter(keycode: 0, shift: false) == "a" else { return }
        let session = try await open("item 9\n")
        press("\u{01}", .control, ignoring: "ش", keyCode: 0)
        await settle(session, "item 10\n", "ctrl-a on the Persian layout")
        await session.stop()
    }

    /// A Neovim that died with a changed buffer leaves its swap file, and
    /// the next Neovim asked what to do with it, of a person who could not
    /// answer: the keys wait until Neovim runs. Neovim runs without swap
    /// files (`-n`); Daftar saves a second after each change.
    @Test func aLeftoverSwapFileDoesNotStopNeovim() async throws {
        let state = root.appending(path: "state")
        setenv("XDG_STATE_HOME", state.path, 1)
        defer { unsetenv("XDG_STATE_HOME") }
        try "a\n".write(to: root.appending(path: "N.md"), atomically: true, encoding: .utf8)
        // A Neovim of another program, with swap files, killed in the middle of an edit.
        let other = NeovimClient(executable: try #require(NeovimClient.locate()), arguments: ["--clean"], directory: root)
        try other.start()
        try await other.request("nvim_ui_attach", [80, 24, [:]])
        try await other.request("nvim_command", ["edit N.md"])
        try await other.request("nvim_buf_set_lines", [0, 0, 0, false, ["changed"]])
        try await other.request("nvim_command", ["preserve"])
        kill(other.processIdentifier, SIGKILL)
        for _ in 0..<100 where other.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        let swaps = (try? FileManager.default.subpathsOfDirectory(atPath: state.path))?.filter { $0.hasSuffix(".swp") } ?? []
        try #require(!swaps.isEmpty, "the made-up crash left a swap file")

        store.openSynchronously(root)
        controller.load("N.md")
        let session = try #require(controller.session)
        #expect(await eventually { session.state == .running })
        keys("Ab\u{1B}")
        await settle(session, "ab\n", "typing with a swap file left over")
        await session.stop()
    }
}
