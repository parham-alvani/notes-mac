import AppKit
import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// `just bench-editor`: the plain editor's main-thread time per key, from
/// the key to the frame drawn (the key, its styling, the layout and the
/// drawing of the window), on a long made-up note in a real window. Off in
/// a plain `just test`.
@MainActor
@Suite(.serialized, .enabled(if: benchmarking)) struct EditorBenchmarkTests {
    /// A long note of the kinds a vault has: headings, prose, a paragraph
    /// of 4,000 letters, lists, tables, code, callouts, Persian, pictures.
    static func note(sections: Int = 60) -> String {
        var random = SyntheticVault.Seeded(state: 7)
        let words = SyntheticVault.words, persian = SyntheticVault.persian
        func word() -> String { words.randomElement(using: &random)! }
        func sentence(_ count: Int = 14) -> String {
            var parts: [String] = []
            for index in 0..<count {
                switch Int.random(in: 0..<40, using: &random) {
                case 0: parts.append("**\(word())**")
                case 1: parts.append("[[\(word().capitalized)]]")
                case 2: parts.append("`\(word())`")
                case 3: parts.append("*\(word())*")
                case 4: parts.append("==\(word())==")
                default: parts.append(index == 0 ? word().capitalized : word())
                }
            }
            return parts.joined(separator: " ") + "."
        }
        var text = "---\ntitle: Bench\ntags: [one, two]\n---\n\n# Bench\n\n"
        for section in 0..<sections {
            text += "## \(word().capitalized) \(section)\n\n"
            text += (0..<4).map { _ in sentence() }.joined(separator: " ") + "\n\n"
            switch section % 6 {
            case 0:
                text += (0..<8).map { _ in "- \(sentence(8))" }.joined(separator: "\n") + "\n    - " + sentence(6) + "\n\n"
            case 1:
                text += "| Name | Kind | Note |\n| --- | --- | --- |\n"
                text += (0..<12).map { _ in "| \(word()) | \(word()) | \(sentence(5)) |" }.joined(separator: "\n") + "\n\n"
            case 2:
                text += "```swift\n" + (0..<10).map { "let \(word())\($0) = \"\(word())\" // \(word())" }.joined(separator: "\n") + "\n```\n\n"
            case 3:
                text += (0..<5).map { _ in (0..<12).map { _ in persian.randomElement(using: &random)! }.joined(separator: " ") + "." }.joined(separator: " ") + "\n\n"
            case 4:
                text += "> [!note] A note\n>\n> " + sentence(20) + "\n\n- [ ] " + sentence(6) + " ➕ 2026-11-01 ⏳ 2026-11-04\n- [x] " + sentence(6) + "\n\n"
            default:
                text += "![[picture-\(section % 3).png]]\n\n" + sentence() + "\n\n"
            }
            if section == sections / 2 {
                // The long paragraph: about 4,000 letters, on one line.
                var long = ""
                while long.count < 4_000 { long += sentence() + " " }
                text += long + "\n\n"
            }
        }
        return text
    }

    let root: URL
    let store: VaultStore
    let controller: EditorController
    let view: NoteTextView
    let window: NSWindow

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-editor-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Notes"), withIntermediateDirectories: true)
        try Self.note().write(to: root.appending(path: "Notes/Long.md"), atomically: true, encoding: .utf8)
        // Three pictures, 800 by 500.
        for index in 0..<3 {
            let image = NSImage(size: NSSize(width: 800, height: 500), flipped: false) { rect in
                NSColor(hue: CGFloat(index) / 3, saturation: 0.6, brightness: 0.8, alpha: 1).setFill()
                rect.fill()
                return true
            }
            let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            try png.write(to: root.appending(path: "picture-\(index).png"))
        }
        let settings = AppSettings(url: root.appending(path: "config/config.toml"))
        store = VaultStore(settings: settings, openVault: false)
        store.openSynchronously(root)
        controller = EditorController(store: store)
        let container = EditorContainer(scroll: NoteTextView.scrollableNoteView())
        view = container.scroll.documentView as! NoteTextView
        view.controller = controller
        controller.view = view
        controller.container = container
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = container
        window.orderFrontRegardless()
        window.makeKey()
        controller.load("Notes/Long.md")
        settle()
        window.makeFirstResponder(view)
    }

    func end() {
        window.orderOut(nil)
        window.contentView = nil
        try? FileManager.default.removeItem(at: root)
    }

    var text: NSString { view.string as NSString }

    /// The run loop for a while: the progressive styling, the debounced counts.
    func settle(_ seconds: Double = 0.6) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        window.displayIfNeeded()
    }

    /// The main thread's own time, not the wall's: the other processes on
    /// the Mac do not count.
    static func cpu() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

    /// The main thread's time for [work] and the frame after it, in milliseconds.
    func frame(_ work: () -> Void) -> Double {
        let start = Self.cpu()
        work()
        // What AppKit does before a frame: the layout and the drawing.
        window.layoutIfNeeded()
        window.displayIfNeeded()
        // What the key queued for the run loop's turn.
        RunLoop.main.run(mode: .default, before: Date())
        window.displayIfNeeded()
        return Double(Self.cpu() - start) / 1e6
    }

    func key(_ characters: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code)!
    }

    /// Typing [count] letters at [offset]: the median and the worst, in ms.
    func typing(at offset: Int, count: Int = 60, letters: String = "abcdefghij") -> (Double, Double) {
        view.setSelectedRange(NSRange(location: offset, length: 0))
        view.scrollRangeToVisible(NSRange(location: offset, length: 0))
        settle(0.3)
        var times: [Double] = []
        let keys = Array(letters)
        // Five keys first, not timed: the first key at a place lays out what is around it.
        for index in 0..<5 { _ = frame { view.keyDown(with: key(String(keys[index % keys.count]))) } }
        for index in 0..<count {
            let letter = String(keys[index % keys.count])
            times.append(frame { view.keyDown(with: key(letter)) })
        }
        settle(0.3)
        return stats(times)
    }

    func stats(_ times: [Double]) -> (Double, Double) {
        let sorted = times.sorted()
        return (sorted[sorted.count / 2], sorted.last!)
    }

    func report(_ name: String, _ value: (Double, Double)) {
        print(String(format: "EDITOR-BENCH %-44@ median %7.2f ms   worst %7.2f ms", name as NSString, value.0, value.1))
    }

    func offset(after needle: String) -> Int {
        let found = text.range(of: needle)
        return found.location == NSNotFound ? 0 : NSMaxRange(found)
    }

    /// The end of the line that holds [location].
    func lineEnd(_ location: Int) -> Int {
        var end = 0
        text.getLineStart(nil, end: nil, contentsEnd: &end, for: NSRange(location: location, length: 0))
        return end
    }

    /// The end of the longest line.
    func longLineEnd() -> Int {
        var best = (0, 0)
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            if line.length > best.1 { best = (NSMaxRange(line), line.length) }
        }
        return best.0
    }

    @Test func typing() throws {
        defer { end() }
        print("EDITOR-BENCH note: \(text.length) characters")
        report("type, end of a 4,000-letter paragraph", typing(at: longLineEnd()))
        report("type, short paragraph mid-note", typing(at: lineEnd(offset(after: "## ") + 300)))
        report("type, table row", typing(at: lineEnd(offset(after: "| --- | --- | --- |\n") + 3) - 2))
        report("type, list item", typing(at: lineEnd(offset(after: "\n- "))))
        let persian = text.range(of: "سلام").location
        report("type, Persian paragraph", typing(at: lineEnd(persian), letters: "سلامدنیا"))
        report("type, below a picture", typing(at: lineEnd(offset(after: "![[picture-2.png]]\n\n"))))
        report("type, end of the note", typing(at: text.length))
        // Return and Backspace at the end of the long paragraph.
        let long = longLineEnd()
        view.setSelectedRange(NSRange(location: long, length: 0))
        var times: [Double] = []
        for _ in 0..<10 {
            times.append(frame { view.keyDown(with: key("\r", code: 36)) })
            times.append(frame { view.keyDown(with: key("\u{7f}", code: 51)) })
        }
        report("return + backspace, long paragraph", stats(times))
    }

    @Test func movingAndScrolling() throws {
        defer { end() }
        view.setSelectedRange(NSRange(location: offset(after: "## ") + 10, length: 0))
        settle(0.3)
        var times: [Double] = []
        for _ in 0..<60 { times.append(frame { view.keyDown(with: key(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125)) }) }
        report("arrow down, 60 lines", stats(times))
        times = []
        for _ in 0..<60 { times.append(frame { view.keyDown(with: key(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125, flags: [.shift, .numericPad, .function])) }) }
        report("shift-arrow down, selection of 60 lines", stats(times))
        let clip = view.enclosingScrollView!.contentView
        clip.setBoundsOrigin(.zero)
        settle(0.3)
        times = []
        let pages = Int(view.frame.height / 300)
        for page in 1..<min(pages, 120) {
            times.append(frame {
                clip.setBoundsOrigin(NSPoint(x: 0, y: CGFloat(page) * 300))
                view.enclosingScrollView!.reflectScrolledClipView(clip)
            })
        }
        report("scroll 300 pt, whole note", stats(times))
        // Problems in the margin: a dot every 10 lines.
        var marks: [Int: [Problem]] = [:]
        let lines = text.components(separatedBy: "\n").count
        for line in stride(from: 0, to: lines, by: 10) {
            marks[line] = [Problem(tool: .check, level: .warning, path: "Notes/Long.md", line: line + 1, code: "x", message: "m")]
        }
        view.show(problems: marks)
        clip.setBoundsOrigin(.zero)
        settle(0.3)
        times = []
        for page in 1..<min(pages, 120) {
            times.append(frame {
                clip.setBoundsOrigin(NSPoint(x: 0, y: CGFloat(page) * 300))
                view.enclosingScrollView!.reflectScrolledClipView(clip)
            })
        }
        report("scroll 300 pt, with problem dots", stats(times))
        report("type, end of note, with problem dots", typing(at: text.length))
    }

    @Test func opening() throws {
        defer { end() }
        var times: [Double] = []
        for _ in 0..<5 {
            times.append(frame { controller.load("Notes/Long.md") })
            settle(0.5)
        }
        report("open the note (first frame)", stats(times))
        times = []
        for _ in 0..<5 {
            times.append(frame { controller.load("Notes/Long.md"); controller.go(toLine: 900) })
            settle(0.5)
        }
        report("open the note at line 900 (first frame)", stats(times))
    }

    @Test func bigEdits() throws {
        defer { end() }
        let block = (0..<40).map { _ in Self.note(sections: 1) }.joined()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(block, forType: .string)
        var times: [Double] = []
        for _ in 0..<4 {
            view.setSelectedRange(NSRange(location: text.length / 2, length: 0))
            settle(0.2)
            times.append(frame { view.pasteAsPlainText(nil) })
            settle(0.4)
        }
        report("paste \(block.count) characters", stats(times))
        times = []
        for _ in 0..<4 {
            controller.load("Notes/Long.md")
            settle(0.6)
            times.append(frame {
                view.selectAll(nil)
                view.keyDown(with: key("\u{7f}", code: 51))
            })
            settle(0.2)
        }
        report("select all + delete", stats(times))
        // A fence typed near the top: each letter of its language changes
        // the note's structure, so the lines under it are styled again.
        controller.load("Notes/Long.md")
        settle(0.6)
        view.setSelectedRange(NSRange(location: offset(after: "# Bench\n"), length: 0))
        times = []
        for letter in "\n```swift" {
            times.append(frame { view.keyDown(with: key(letter == "\n" ? "\r" : String(letter), code: letter == "\n" ? 36 : 0)) })
        }
        report("type a fence near the top, each key", stats(times))
    }

    @Test func manyCursors() throws {
        defer { end() }
        view.setSelectedRange(NSRange(location: offset(after: "## ") + 1, length: 0))
        let word = "plan"
        view.setSelectedRange(text.range(of: " \(word) "))
        view.setSelectedRange(NSRange(location: view.selectedRange().location + 1, length: 4))
        var times: [Double] = []
        times.append(frame { view.selectAllOccurrences(nil) })
        report("select all occurrences (\(view.cursorRanges.count))", stats(times))
        times = []
        for letter in "abcdefghij" { times.append(frame { view.keyDown(with: key(String(letter))) }) }
        report("type at \(view.cursorRanges.count) cursors", stats(times))
    }

    @Test func modes() throws {
        defer { end() }
        store.settings.focusMode = true
        controller.followWritingModes()
        report("focus: type, end of the note", typing(at: text.length))
        report("focus: type, long paragraph", typing(at: longLineEnd()))
        view.setSelectedRange(NSRange(location: offset(after: "## ") + 10, length: 0))
        var times: [Double] = []
        for _ in 0..<40 { times.append(frame { view.keyDown(with: key(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125)) }) }
        report("focus: arrow down", stats(times))
        store.settings.focusMode = false
        controller.followWritingModes()
        store.settings.typewriter = true
        report("typewriter: type, mid-note", typing(at: lineEnd(text.length / 2)))
        times = []
        for _ in 0..<40 { times.append(frame { view.keyDown(with: key(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125)) }) }
        report("typewriter: arrow down", stats(times))
        store.settings.typewriter = false
        controller.followWritingModes()
        store.settings.spellCheck = true
        controller.followWritingModes()
        report("spelling: type, end of a long paragraph", typing(at: longLineEnd()))
        store.settings.spellCheck = false
        controller.followWritingModes()
    }

    @Test func finding() throws {
        defer { end() }
        let board = NSPasteboard(name: .find)
        board.clearContents()
        board.setString("plan", forType: .string)
        var times: [Double] = []
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.nextMatch.rawValue
        for _ in 0..<10 { times.append(frame { view.performTextFinderAction(item) }) }
        report("find next (plan)", stats(times))
    }

    /// `DAFTAR_PROFILE=long`: typing at the end of the long paragraph for
    /// a while, for `sample` to read; the time of each part of a key.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DAFTAR_PROFILE"] != nil)) func profile() throws {
        defer { end() }
        let scenario = ProcessInfo.processInfo.environment["DAFTAR_PROFILE"] ?? ""
        let at = switch scenario {
        case "persian": lineEnd(text.range(of: "سلام").location)
        case "end", "focus": text.length
        case "arrows", "cursors", "paste": offset(after: "## ") + 10
        default: longLineEnd()
        }
        view.setSelectedRange(NSRange(location: at, length: 0))
        view.scrollRangeToVisible(NSRange(location: at, length: 0))
        settle(0.3)
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!), up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        if scenario == "focus" {
            store.settings.focusMode = true
            controller.followWritingModes()
        }
        if scenario == "cursors" {
            view.setSelectedRange(NSRange(location: text.range(of: " plan ").location + 1, length: 4))
            view.selectAllOccurrences(nil)
        }
        if scenario == "paste" {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString((0..<10).map { _ in Self.note(sections: 1) }.joined(), forType: .string)
        }
        var parts = [0.0, 0.0, 0.0, 0.0]
        let until = Date().addingTimeInterval(Double(ProcessInfo.processInfo.environment["DAFTAR_PROFILE_SECONDS"] ?? "4") ?? 4)
        var keys = 0
        while Date() < until {
            let letter = keys % 20 == 19 ? "\u{7f}" : "a"
            var t = Self.cpu()
            func lap(_ index: Int) {
                let now = Self.cpu()
                parts[index] += Double(now - t) / 1e6
                t = now
            }
            switch scenario {
            case "arrows":
                let goingDown = (keys / 80) % 2 == 0
                view.keyDown(with: key(goingDown ? down : up, code: goingDown ? 125 : 126))
            case "paste":
                if keys % 2 == 0 { view.pasteAsPlainText(nil) } else { view.undoManager?.undo() }
            case "open":
                controller.load("Notes/Long.md")
                controller.go(toLine: 900)
            case "delete":
                if keys % 2 == 0 {
                    view.selectAll(nil)
                    view.keyDown(with: key("\u{7f}", code: 51))
                } else {
                    view.undoManager?.undo()
                }
            default:
                view.keyDown(with: key(letter, code: letter == "a" ? 0 : 51))
            }
            lap(0)
            window.layoutIfNeeded()
            lap(1)
            window.displayIfNeeded()
            lap(2)
            RunLoop.main.run(mode: .default, before: Date())
            window.displayIfNeeded()
            lap(3)
            keys += 1
        }
        print(String(format: "EDITOR-BENCH profile %@: %d keys; key %.2f, layout %.2f, display %.2f, run loop %.2f ms a key",
            scenario, keys, parts[0] / Double(keys), parts[1] / Double(keys), parts[2] / Double(keys), parts[3] / Double(keys)))
    }
}
