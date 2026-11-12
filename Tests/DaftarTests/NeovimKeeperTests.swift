import AppKit
import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// One Neovim for a pane: kept while the pane reads, and taken again by the
/// editor's next open; the same one for another note in the editor. Each
/// note's undo stays in its buffer. Against a real `nvim --clean`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: hasNeovim)) struct NeovimKeeperTests {
    let root: URL
    let store: VaultStore
    let keeper = NeovimKeeper()
    let window: NSWindow
    var controller: EditorController
    var view: NoteTextView

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-vim-keeper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "first line\nسلام دنیا\n".write(to: root.appending(path: "Note.md"), atomically: true, encoding: .utf8)
        try "other\n".write(to: root.appending(path: "Other.md"), atomically: true, encoding: .utf8)
        let settings = AppSettings(url: root.appending(path: "config/config.toml"))
        settings.vimMode = true
        settings.nvimConfig = "clean"
        store = VaultStore(settings: settings, openVault: false)
        store.openSynchronously(root)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        (controller, view) = (EditorController(store: store), NoteTextView())
        newEditor()
    }

    /// A new editor in the window, as ⌘E makes one, with the pane's keeper.
    mutating func newEditor() {
        controller = EditorController(store: store)
        controller.keeper = keeper
        let scroll = NoteTextView.scrollableNoteView()
        view = scroll.documentView as! NoteTextView
        window.contentView = EditorContainer(scroll: scroll)
        view.controller = controller
        controller.view = view
    }

    /// The editor goes as the reader comes back: what `dismantleNSView` does.
    func leave() async {
        controller.saveNow()
        controller.parkVim()
        await controller.stopping?.value
    }

    func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    func keys(_ text: String) {
        for character in text {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: String(character), charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: 0)!
            view.keyDown(with: event)
        }
    }

    func file(_ name: String) -> String? { try? String(contentsOf: root.appending(path: name), encoding: .utf8) }

    func running() async throws -> NeovimSession {
        let session = try #require(controller.session)
        #expect(await eventually { session.state == .running })
        return session
    }

    @Test mutating func theReaderKeepsNeovimForTheNextEditWithItsUndo() async throws {
        controller.load("Note.md")
        let first = try await running()
        keys("Ax\u{1B}")
        #expect(await eventually { file("Note.md") == "first linex\nسلام دنیا\n" })
        await leave()
        #expect(keeper.session === first)
        #expect(first.state == .running)

        newEditor()
        controller.load("Note.md")
        controller.go(toLine: 1)
        let again = try await running()
        #expect(again === first)
        #expect(again.processIdentifier == first.processIdentifier)
        // At the reader's line, as a new Neovim opens.
        #expect(await eventually { view.selectedRange().location == 12 })
        // The typing before the reader is undone, with the same Neovim's undo.
        keys("u")
        #expect(await eventually { view.string == "first line\nسلام دنیا\n" })
        #expect(await eventually { file("Note.md") == "first line\nسلام دنیا\n" })
        keys("ggAy\u{1B}")
        #expect(await eventually { file("Note.md") == "first liney\nسلام دنیا\n" })
        controller.stopVim()
        await controller.stopping?.value
    }

    @Test func anotherNoteInTheEditorIsTheSameNeovim() async throws {
        controller.load("Note.md")
        let session = try await running()
        keys("Ax\u{1B}")
        #expect(await eventually { view.string == "first linex\nسلام دنیا\n" })
        controller.load("Other.md")
        #expect(controller.session === session)
        #expect(view.string == "other\n")
        #expect(await eventually { session.state == .running })
        // The note left was written before the other opened.
        #expect(file("Note.md") == "first linex\nسلام دنیا\n")
        keys("Ay\u{1B}")
        #expect(await eventually { file("Other.md") == "othery\n" })
        controller.load("Note.md")
        #expect(await eventually { session.state == .running && view.string == "first linex\nسلام دنیا\n" })
        // Each note's own undo.
        keys("u")
        #expect(await eventually { file("Note.md") == "first line\nسلام دنیا\n" })
        #expect(file("Other.md") == "othery\n")
        // `:q` ends Neovim with the other note hidden in it: nothing unsaved.
        var quit = false
        controller.onQuit = { quit = true }
        keys(":q\r")
        #expect(await eventually { quit })
    }

    @Test mutating func aNoteChangedWhileKeptIsReadAgain() async throws {
        controller.load("Note.md")
        _ = try await running()
        await leave()
        try "changed elsewhere\n".write(to: root.appending(path: "Note.md"), atomically: true, encoding: .utf8)
        store.openSynchronously(root)
        newEditor()
        controller.load("Note.md")
        let session = try await running()
        #expect(await eventually { view.string == "changed elsewhere\n" })
        keys("Az\u{1B}")
        #expect(await eventually { file("Note.md") == "changed elsewherez\n" })
        await session.stop()
    }

    @Test func aKeptNeovimEndsWhenItsNoteIsDeleted() async throws {
        controller.load("Note.md")
        let session = try await running()
        await leave()
        try await store.delete("Note.md")
        #expect(keeper.session == nil)
        #expect(await eventually { session.state == .ended })
        try await Task.sleep(for: .milliseconds(300))
        #expect(file("Note.md") == nil)
    }

    @Test mutating func aKeptNeovimOfOtherSettingsIsNotTaken() async throws {
        controller.load("Note.md")
        let first = try await running()
        await leave()
        let config = root.appending(path: "init.lua")
        try "vim.o.tabstop = 3\n".write(to: config, atomically: true, encoding: .utf8)
        store.settings.nvimConfig = config.path
        newEditor()
        controller.load("Note.md")
        let second = try await running()
        #expect(second !== first)
        #expect(await eventually { first.state == .ended })
        #expect(keeper.session == nil)
        await second.stop()
    }

    @Test func aKeptNeovimEndsWhenIdle() async throws {
        let limit = NeovimKeeper.idleLimit
        NeovimKeeper.idleLimit = .milliseconds(200)
        defer { NeovimKeeper.idleLimit = limit }
        controller.load("Note.md")
        let session = try await running()
        await leave()
        #expect(keeper.session === session)
        #expect(await eventually { keeper.session == nil && session.state == .ended })
    }
}
