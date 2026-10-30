import AppKit
import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// The editor in Neovim mode, against a real `nvim --clean` (never the
/// person's config) on a made-up vault. Skipped where there is no Neovim.
/// Off the main actor: a `@MainActor` suite's `.enabled(if:)` runs its
/// condition there, while the main actor waits for the runner, and the whole
/// test run hangs before it starts.
let hasNeovim = NeovimClient.locate() != nil

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: hasNeovim)) struct NeovimModeTests {
    let root: URL
    let store: VaultStore
    let controller: EditorController
    let view: NoteTextView
    let window: NSWindow

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-vim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "first line\nسلام دنیا\n".write(to: root.appending(path: "Note.md"), atomically: true, encoding: .utf8)
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

    /// Waits for [condition], up to five seconds.
    func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    func press(_ characters: String, _ flags: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)!
        view.keyDown(with: event)
    }

    @Test func typingGoesThroughNeovimAndNeovimWritesTheFile() async throws {
        controller.load("Note.md")
        let session = try #require(controller.session)
        #expect(await eventually { session.state == .running })
        for key in ["A", " ", "x", "\u{1B}"] { press(key) }
        #expect(await eventually { view.string == "first line x\nسلام دنیا\n" })
        #expect(await eventually { session.isNormal })
        // A change the view makes on its own is refused.
        #expect(!view.shouldChangeText(in: NSRange(location: 0, length: 0), replacementString: "zzz"))
        #expect(await eventually {
            (try? String(contentsOf: root.appending(path: "Note.md"), encoding: .utf8)) == "first line x\nسلام دنیا\n"
        })
        await session.stop()
    }

    @Test func aMovedNoteIsSavedAtItsNewPathOnly() async throws {
        controller.load("Note.md")
        let session = try #require(controller.session)
        #expect(await eventually { session.state == .running })
        _ = try await store.move("Note.md", to: "Moved.md")
        #expect(controller.path == "Moved.md")
        let old = root.appending(path: "Note.md").path
        // What is typed after the move goes to the new file, never the old one.
        try await Task.sleep(for: .milliseconds(300))
        for key in ["A", " ", "y", "\u{1B}"] { press(key) }
        #expect(await eventually {
            (try? String(contentsOf: root.appending(path: "Moved.md"), encoding: .utf8)) == "first line y\nسلام دنیا\n"
        })
        await session.stop()
        #expect(!FileManager.default.fileExists(atPath: old))
    }

    @Test func aDeletedNoteStaysDeleted() async throws {
        controller.load("Note.md")
        let session = try #require(controller.session)
        #expect(await eventually { session.state == .running })
        for key in ["A", " ", "z", "\u{1B}"] { press(key) }
        #expect(await eventually { session.isNormal })
        try await store.delete("Note.md")
        let file = root.appending(path: "Note.md").path
        // Neovim's buffer outlived the file: nothing may write it back.
        try await Task.sleep(for: .seconds(2))
        #expect(!FileManager.default.fileExists(atPath: file))
        controller.stopVim()
        try await Task.sleep(for: .milliseconds(500))
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    @Test func theViewScrollsWithNeovimsWindow() async throws {
        let long = (1...400).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try long.write(to: root.appending(path: "Long.md"), atomically: true, encoding: .utf8)
        controller.load("Long.md")
        let session = try #require(controller.session)
        #expect(await eventually { session.state == .running })
        let clip = try #require(view.enclosingScrollView?.contentView)
        for key in ["3", "0", "0", "G", "z", "z"] { press(key) }
        let line = (view.string as NSString).range(of: "line 300\n").location
        #expect(await eventually { view.selectedRange().location == line })
        // `zz` puts the line in the middle of the view, more or less.
        #expect(await eventually {
            guard let rect = view.lineRect(at: line) else { return false }
            let middle = clip.bounds.midY
            return abs(rect.midY - middle) < clip.bounds.height / 4
        })
        await session.stop()
    }

    /// An edit and its undo keep the view where it is, with the cursor in
    /// sight. On screen the view jumped after them -- to Neovim's window, or
    /// where TextKit's layout scrolled it; a window off screen does neither,
    /// so this holds what stays still, and the jump itself is checked in the app.
    @Test func anEditAndItsUndoKeepTheViewWhereItIs() async throws {
        let sections = (1...40).map {
            "## Section \($0)\n\nParagraph \($0) is a long line of prose that wraps on the screen more than once, so the layout has work to do.\n\n```python\ndef f\($0)(x):\n    return x * 2\n```\n"
        }
        let text = sections.joined(separator: "\n")
        try text.write(to: root.appending(path: "Code.md"), atomically: true, encoding: .utf8)
        // In a window on screen, far off it: TextKit lays out the viewport
        // only for a window that shows.
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        controller.load("Code.md")
        let session = try #require(controller.session)
        #expect(await eventually { session.state == .running })
        let clip = try #require(view.enclosingScrollView?.contentView)
        let target = (text as NSString).range(of: "    return x * 2", options: [], range: NSRange(location: (text as NSString).range(of: "def f20(").location, length: 200)).location + 4
        for key in ["/", "f", "2", "0", "(", "\r", "j", "z", "z"] { press(key) }
        #expect(await eventually { view.selectedRange().location == target })
        try await Task.sleep(for: .milliseconds(600))
        let before = clip.bounds.origin.y
        for key in ["o", "x", "y", "\u{1B}"] { press(key) }
        #expect(await eventually { view.string.contains("    xy\n```") })
        try await Task.sleep(for: .milliseconds(400))
        #expect(abs(clip.bounds.origin.y - before) < 2)
        press("u")
        #expect(await eventually { view.string == text })
        try await Task.sleep(for: .milliseconds(600))
        #expect(abs(clip.bounds.origin.y - before) < 2)
        // The cursor is on screen.
        let cursor = try #require(view.lineRect(at: view.selectedRange().location))
        #expect(cursor.minY >= clip.bounds.minY && cursor.maxY <= clip.bounds.maxY)
        await session.stop()
    }

    /// Neovim's completion menu shows under the word, follows `<C-n>`, and
    /// goes with Esc; Neovim puts the word in.
    @Test func neovimsCompletionMenuShowsUnderTheWord() async throws {
        try "carrot cardamom caraway\n\n".write(to: root.appending(path: "Menu.md"), atomically: true, encoding: .utf8)
        controller.load("Menu.md")
        let session = try #require(controller.session)
        #expect(await eventually { session.state == .running })
        for key in ["G", "i", "c", "a", "r"] { press(key) }
        press("n", .control)
        #expect(await eventually { view.extras.menu?.items.count == 3 })
        let menu = try #require(view.extras.menu)
        #expect(Set(menu.items.map(\.word)) == ["carrot", "cardamom", "caraway"])
        // `noselect`: nothing is chosen until the next <C-n>.
        let line = try #require(view.lineRect(at: view.selectedRange().location))
        #expect(menu.frame.minY >= line.maxY)
        press("n", .control)
        #expect(await eventually { menu.selected == 0 })
        #expect(await eventually { view.string.hasSuffix("\n" + menu.items[0].word + "\n") || view.string.hasSuffix("\n" + menu.items[0].word) })
        press("\u{1B}")
        #expect(await eventually { view.extras.menu == nil })
        await session.stop()
    }

    /// The command line floats over the editor while it is open, with what
    /// is typed and its cursor; the status bar keeps the message after it.
    @Test func theCommandLineFloatsOverTheEditor() async throws {
        let container = try #require(window.contentView as? EditorContainer)
        controller.container = container
        controller.load("Note.md")
        let session = try #require(controller.session)
        #expect(await eventually { session.state == .running })
        for key in [":", "e", "c", "h", "o", " ", "'", "س", "ل", "ا", "م", "'"] { press(key) }
        #expect(await eventually { container.commandPanel?.line.text == "echo 'سلام'" })
        #expect(container.commandPanel?.line.prefix == ":")
        // At the end: the bytes of the line, Persian letters two each.
        #expect(container.commandPanel?.line.position == "echo 'سلام'".utf8.count)
        press("\r")
        #expect(await eventually { container.commandPanel == nil })
        #expect(await eventually { session.status == "سلام" })
        press("/")
        #expect(await eventually { container.commandPanel?.line.prefix == "/" })
        press("\u{1B}")
        #expect(await eventually { container.commandPanel == nil })
        await session.stop()
    }

    @Test func aCommandLineCursorIsCountedInLetters() {
        #expect(CommandLinePanel.offset(of: 0, in: "سلام") == 0)
        #expect(CommandLinePanel.offset(of: 4, in: "سلام") == 2)
        #expect(CommandLinePanel.offset(of: 6, in: "ab😀") == 4)
        #expect(CommandLinePanel.offset(of: 99, in: "ab") == 2)
    }

    @Test func visualBlockSelectsAColumnOnEachRow() async throws {
        controller.load("Note.md")
        let session = try #require(controller.session)
        #expect(await eventually { session.state == .running })
        try "abcd\nefgh\nijkl\n".write(to: root.appending(path: "Block.md"), atomically: true, encoding: .utf8)
        controller.load("Block.md")
        let block = try #require(controller.session)
        #expect(await eventually { block.state == .running && view.string == "abcd\nefgh\nijkl\n" })
        press("l")
        press("v", .control)
        press("j")
        press("l")
        #expect(await eventually { view.selectedRanges.count == 2 })
        #expect(view.selectedRanges.map(\.rangeValue) == [NSRange(location: 1, length: 2), NSRange(location: 6, length: 2)])
        await block.stop()
        await session.stop()
    }

    @Test func theCursorFollowsNeovimInPersianText() async throws {
        controller.load("Note.md")
        let session = try #require(controller.session)
        #expect(await eventually { session.state == .running })
        for key in ["j", "0", "w"] { press(key) }
        // "سلام " is 5 characters: `w` lands on the second word.
        #expect(await eventually { view.selectedRange() == NSRange(location: ("first line\n" as NSString).length + 5, length: 0) })
        await session.stop()
    }

    @Test func controlKeysAndVisualSelection() async throws {
        controller.load("Note.md")
        let session = try #require(controller.session)
        #expect(await eventually { session.state == .running })
        press("v")
        press("e")
        #expect(await eventually { view.selectedRange() == NSRange(location: 0, length: 5) })
        #expect(await eventually { session.modeName == "VISUAL" })
        press("\u{1B}")
        press("d", .control)
        #expect(await eventually { session.isNormal })
        await session.stop()
    }
}
