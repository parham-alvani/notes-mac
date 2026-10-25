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
