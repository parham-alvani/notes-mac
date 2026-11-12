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

    /// A far jump puts the cursor's line where Neovim says, in the middle
    /// of the view, in a long note of code blocks and headings: TextKit
    /// guesses where lines it has not laid out are, and the guess was
    /// hundreds of points off, so `G`, `n` and a search left the cursor
    /// off the screen. In a window on screen, which lays out its viewport.
    @Test func farJumpsKeepTheCursorOnScreen() async throws {
        let sections = (1...80).map {
            "## Section \($0)\n\nParagraph \($0) is a long line of prose that wraps on the screen more than once, so the layout has work to do.\n\n```python\ndef f\($0)(x):\n    return x * 2\n```\n"
        }
        let text = sections.joined(separator: "\n") as NSString
        try (text as String).write(to: root.appending(path: "Long.md"), atomically: true, encoding: .utf8)
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        controller.load("Long.md")
        let session = try #require(controller.session)
        #expect(await eventually { session.state == .running })
        let clip = try #require(view.enclosingScrollView?.contentView)
        func jump(_ keys: [String], to target: Int, middle: Bool) async throws {
            for key in keys { press(key) }
            #expect(await eventually { view.selectedRange().location == target }, "\(keys)")
            // The glide, and the layout under it.
            try await Task.sleep(for: .milliseconds(400))
            let line = try #require(view.lineRect(at: target))
            #expect(line.minY >= clip.bounds.minY && line.maxY <= clip.bounds.maxY, "\(keys): line \(line.minY) not in \(clip.bounds.minY)...\(clip.bounds.maxY)")
            if middle { #expect(abs(line.midY - clip.bounds.midY) < clip.bounds.height / 4, "\(keys): not in the middle") }
            // The block is on the letter, not where the guess had the line.
            let block = try #require(view.blockRect())
            let drawn = try #require(view.extras.neovimCursor?.frame)
            #expect(abs(drawn.minY - block.minY) < 1, "\(keys): block at \(drawn.minY), letter at \(block.minY)")
        }
        try await jump(["/", "d", "e", "f", " ", "f", "7", "\r"], to: text.range(of: "def f7(").location, middle: false)
        try await jump(["n"], to: text.range(of: "def f70(").location, middle: true)
        try await jump(["G"], to: text.range(of: "```", options: .backwards).location, middle: false)
        try await jump(["g", "g"], to: 0, middle: false)
        try await jump(["/", "f", "4", "0", "(", "\r"], to: text.range(of: "f40(").location, middle: true)
        try await jump(["z", "t"], to: text.range(of: "f40(").location, middle: false)
        let top = try #require(view.lineRect(at: text.range(of: "f40(").location))
        #expect(top.minY - clip.bounds.minY < clip.bounds.height / 4)
        await session.stop()
    }

    /// A long note of every kind of block (KVM over IP's shape: tables,
    /// callouts, code and long paragraphs) in a small window: TextKit's
    /// guess of a far line was a screen or more off, and the block stayed
    /// where the guess had it, lines above its letter, or the line was put
    /// below the view's guessed height and the view could not reach it.
    @Test func farJumpsInAMixedNoteKeepTheBlockOnItsLetter() async throws {
        let sections = (1...140).map { i -> String in
            var section = "## Heading \(i)\n\n" + String(repeating: "Words of prose that wrap on the screen. ", count: 3 + (i * 7) % 19) + "mark\(i) ends it.\n\n"
            if i % 3 == 0 { section += "| Model | Port | Notes |\n| --- | --- | --- |\n" + (1...(4 + i % 5)).map { "| V\($0) | USB \($0) | a cell long enough to wrap in a narrow window |" }.joined(separator: "\n") + "\n\n" }
            if i % 4 == 0 { section += "> [!note]\n>\n> " + String(repeating: "A callout line that wraps. ", count: 2 + i % 6) + "\n\n" }
            section += "```bash\n" + (0..<(2 + i % 9)).map { "echo step \($0) of section \(i)" }.joined(separator: "\n") + "\n```\n\n"
            section += (1...(2 + i % 4)).map { "- [Link \($0)](https://example.com/\(i)/\($0)) to a page" }.joined(separator: "\n") + "\n"
            return section
        }
        let text = sections.joined(separator: "\n") as NSString
        try (text as String).write(to: root.appending(path: "Mixed.md"), atomically: true, encoding: .utf8)
        window.setContentSize(NSSize(width: 520, height: 400))
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        controller.load("Mixed.md")
        let session = try #require(controller.session)
        #expect(await eventually { session.state == .running })
        let clip = try #require(view.enclosingScrollView?.contentView)
        func jump(_ keys: [String], to target: Int) async throws {
            for key in keys { press(key) }
            #expect(await eventually { view.selectedRange().location == target }, "\(keys)")
            try await Task.sleep(for: .milliseconds(700))
            let line = try #require(view.lineRect(at: target))
            #expect(line.minY >= clip.bounds.minY && line.maxY <= clip.bounds.maxY, "\(keys): line \(line.minY) not in \(clip.bounds.minY)...\(clip.bounds.maxY)")
            let block = try #require(view.blockRect())
            let drawn = try #require(view.extras.neovimCursor?.frame)
            #expect(abs(drawn.minY - block.minY) < 1, "\(keys): block at \(drawn.minY), letter at \(block.minY)")
        }
        func search(_ word: String) -> [String] { ["/"] + word.map(String.init) + ["\r"] }
        let last = text.lineRange(for: NSRange(location: text.length - 1, length: 0)).location
        try await jump(search("mark120 "), to: text.range(of: "mark120 ").location)
        try await jump(["g", "g", "0"], to: 0)
        try await jump(search("mark40 "), to: text.range(of: "mark40 ").location)
        try await jump(["G", "0"], to: last)
        try await jump(search("mark7 "), to: text.range(of: "mark7 ").location)
        try await jump(search("section 133"), to: text.range(of: "section 133").location)
        try await jump(["N"], to: text.range(of: "section 133", options: .backwards).location)
        try await jump(search("mark2 "), to: text.range(of: "mark2 ").location)
        try await jump(["G", "0"], to: last)
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

    /// `[[` and `#` in Neovim offer the vault's notes, headings and tags,
    /// as the plain editor does; Neovim asks Daftar for the rows.
    @Test func linksAndTagsCompleteInNeovim() async throws {
        try "# Alpha\n\n## Roots\n\n## Leaves\n".write(to: root.appending(path: "Alpha.md"), atomically: true, encoding: .utf8)
        try "Beta grows. #garden\n".write(to: root.appending(path: "Beta.md"), atomically: true, encoding: .utf8)
        store.openSynchronously(root)
        controller.load("Note.md")
        let session = try #require(controller.session)
        #expect(await eventually { session.state == .running })
        func type(_ keys: String) { for key in keys { press(String(key)) } }
        // As the person's config has it: nothing chosen until <C-n>.
        type(":set completeopt=menu,menuone,noselect\r")
        type("Go[[Al")
        #expect(await eventually { view.extras.menu?.items.first?.word == "Alpha" })
        press("n", .control)
        #expect(await eventually { view.string.hasSuffix("\n[[Alpha]]\n") })
        // A heading of the note, after its #, in by its level as in the plain editor.
        type("\u{1B}o[[Alpha#Ro")
        #expect(await eventually { view.extras.menu?.items.contains { $0.word.trimmingCharacters(in: .whitespaces) == "Roots" } == true })
        press("n", .control)
        #expect(await eventually { view.string.hasSuffix("\n[[Alpha#Roots]]\n") })
        // A tag, at the start of a word.
        type("\u{1B}o#gar")
        #expect(await eventually { view.extras.menu?.items.first?.word.contains("garden") == true })
        press("n", .control)
        #expect(await eventually { view.string.hasSuffix("\n#garden\n") })
        type("\u{1B}")
        await session.stop()
    }

    /// Enter, o and O go on with a list, a numbered list, a task list and a
    /// quote; Enter on an empty item ends the list.
    @Test func listsGoOnInNeovim() async throws {
        try "- [x] done\n".write(to: root.appending(path: "Lists.md"), atomically: true, encoding: .utf8)
        controller.load("Lists.md")
        let session = try #require(controller.session)
        #expect(await eventually { session.state == .running })
        func type(_ keys: String) { for key in keys { press(String(key)) } }
        // A task goes on open, whatever the one above is.
        type("A\rnext\u{1B}")
        #expect(await eventually { view.string == "- [x] done\n- [ ] next\n" })
        // Numbers count on; text after the cursor goes to the new item.
        type("o\u{1B}S3. ab\u{1B}i\r\u{1B}")
        #expect(await eventually { view.string == "- [x] done\n- [ ] next\n3. a\n4. b\n" })
        // o below, O above, in the list of the line.
        type("ok\u{1B}")
        #expect(await eventually { view.string == "- [x] done\n- [ ] next\n3. a\n4. b\n5. k\n" })
        type("ggOz\u{1B}")
        #expect(await eventually { view.string == "- [ ] z\n- [x] done\n- [ ] next\n3. a\n4. b\n5. k\n" })
        // Enter on an empty item ends the list on that line; a quote goes on too.
        type("GA\r\r> q\rr\u{1B}")
        #expect(await eventually { view.string.hasSuffix("5. k\n> q\n> r\n") })
        await session.stop()
    }

    /// Sort Tasks sorts the file once Neovim has written what was typed.
    @Test func sortTasksWaitsForNeovimsWrite() async throws {
        try "# Plan\n- [ ] Open\n".write(to: root.appending(path: "Sort.md"), atomically: true, encoding: .utf8)
        store.openSynchronously(root)
        controller.load("Sort.md")
        let session = try #require(controller.session)
        #expect(await eventually { session.state == .running })
        for key in "GA\rDone\u{1B}03lrx" { press(String(key)) }
        #expect(await eventually { view.string == "# Plan\n- [ ] Open\n- [x] Done\n" })
        controller.sortTasks()
        #expect(await eventually {
            (try? String(contentsOf: root.appending(path: "Sort.md"), encoding: .utf8)) == "# Plan\n- [x] Done\n- [ ] Open\n"
        })
        await session.stop()
    }

    /// Format Note in Neovim mode: the buffer takes the lines that changed,
    /// as one step of Neovim's undo, and Neovim writes the file.
    @Test func formatNotePutsTheFormattedLinesInTheBuffer() async throws {
        let cli = try FakeCLI()
        try "# Plan\n*  item\nend\n".write(to: root.appending(path: "Format.md"), atomically: true, encoding: .utf8)
        store.openSynchronously(root)
        store.checks.opened(root)
        store.checks.locate = { cli.path }
        controller.load("Format.md")
        let session = try #require(controller.session)
        #expect(await eventually { session.state == .running })
        controller.formatNote()
        #expect(await eventually { view.string == "# Plan\n- item\nend\n" })
        #expect(await eventually {
            (try? String(contentsOf: root.appending(path: "Format.md"), encoding: .utf8)) == "# Plan\n- item\nend\n"
        })
        press("u")
        #expect(await eventually { view.string == "# Plan\n*  item\nend\n" })
        await session.stop(writing: false)
    }

    /// Format on save in Neovim mode: leaving the note lets Neovim write
    /// what was typed, and the file is formatted after that write, never
    /// before it.
    @Test func leavingANoteFormatsItOnceNeovimHasWrittenIt() async throws {
        let cli = try FakeCLI()
        try "# Plan\n".write(to: root.appending(path: "Leave.md"), atomically: true, encoding: .utf8)
        store.openSynchronously(root)
        store.checks.opened(root)
        store.checks.locate = { cli.path }
        controller.load("Leave.md")
        let session = try #require(controller.session)
        #expect(await eventually { session.state == .running })
        for key in "GA\r*  item\u{1B}" { press(String(key)) }
        #expect(await eventually { view.string == "# Plan\n*  item\n" })
        let left = controller.leaving
        controller.saveNow()
        controller.load("Note.md")
        controller.formatOnLeave(left, at: .otherNote)
        #expect(await eventually {
            (try? String(contentsOf: root.appending(path: "Leave.md"), encoding: .utf8)) == "# Plan\n- item\n"
        })
        controller.stopVim(writing: false)
    }

    /// The editor opens on the line the reader was at, and tells the pane
    /// that line, so the reader comes back to it: never the note's top.
    @Test func theEditorOpensAtTheReadersLine() async throws {
        var reported: [Int] = []
        controller.onCursor = { reported.append($0) }
        controller.load("Note.md")
        controller.go(toLine: 1)
        let session = try #require(controller.session)
        #expect(await eventually { session.state == .running })
        #expect(await eventually { view.selectedRange().location == 11 })
        #expect(await eventually { reported.last == 1 })
        controller.stopVim()
    }

    /// The cursor is a block over the letter in normal mode, a bar at the
    /// letters' height while typing, and none over a visual selection.
    @Test func theCursorIsABlockABarOrNone() async throws {
        controller.load("Note.md")
        let session = try #require(controller.session)
        #expect(await eventually { session.state == .running })
        press("w")
        #expect(await eventually { view.selectedRange().location == 6 })
        #expect(await eventually { view.extras.neovimCursor?.frame == view.blockRect() })
        let block = try #require(view.extras.neovimCursor?.frame)
        // As wide as its letter, an `l` here: more than the bar.
        #expect(block.width > 2)
        press("i")
        #expect(await eventually { view.extras.neovimCursor?.frame.width == 2 })
        #expect(view.extras.neovimCursor?.frame.minX == view.letterCaret(at: 6)?.minX)
        press("\u{1B}")
        press("v")
        #expect(await eventually { view.extras.neovimCursor == nil })
        press("\u{1B}")
        #expect(await eventually { view.extras.neovimCursor != nil })
        controller.stopVim()
        #expect(view.extras.neovimCursor == nil)
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

    /// ⌥ is Meta only with `option_as_meta` set: unmapped in Insert mode,
    /// Neovim takes `<M-x>` as Escape and `x`, which deletes a letter.
    @Test func optionIsMetaWhenTheSettingSaysSo() async throws {
        store.settings.optionAsMeta = .both
        controller.load("Note.md")
        let session = try #require(controller.session)
        #expect(await eventually { session.state == .running })
        press("i")
        #expect(await eventually { !session.isNormal })
        press("x", .option)
        #expect(await eventually { view.string == "irst line\nسلام دنیا\n" })
        // Off, ⌥ types its letter: here the made-up event's own `x`.
        store.settings.optionAsMeta = .none
        press("i")
        #expect(await eventually { !session.isNormal })
        press("x", .option)
        #expect(await eventually { view.string == "xirst line\nسلام دنیا\n" })
        await session.stop()
    }

    /// The menu and the command line blur the note behind them, or not.
    @Test func panelsBlurTheNoteBehindThem() async throws {
        let menu = NeovimMenu()
        menu.setFrameSize(NSSize(width: 200, height: 100))
        let blur = try #require(menu.subviews.first as? NSVisualEffectView)
        #expect(blur.frame == menu.bounds && blur.blendingMode == .withinWindow)
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        #expect(blur.isHidden == reduced)
        #expect(menu.fill.alphaComponent < 1 || reduced)
        menu.blurred = false
        #expect(blur.isHidden && menu.fill.alphaComponent == 1)
        // The setting reaches the menu Neovim shows.
        store.settings.blurPanels = false
        view.vim = nil
        view.showNeovimMenu([NeovimMenu.Item(word: "a", detail: "")], selected: -1, forCommandLine: false)
        #expect(view.extras.menu?.blurred == false)
        view.hideNeovimMenu()
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
