import AppKit
import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// Where `EditorPartsTests.picture` writes the editor as a picture, when asked:
/// `DAFTAR_PARTS_PICTURE=/tmp/parts swift test --filter EditorPartsTests`
/// writes `/tmp/parts-dark.png` and `/tmp/parts-light.png`. The views draw
/// it, so it needs no screen and brings no window to the front.
private let picturePath = ProcessInfo.processInfo.environment["DAFTAR_PARTS_PICTURE"]

/// The parts the editor draws in place of their text -- a task's box, the
/// date chips, a callout and a code block -- on a made-up vault in a
/// temporary folder (docs/specs/look.md in notes-linux, part 2).
@MainActor
@Suite(.serialized) struct EditorPartsTests {
    let root: URL
    let store: VaultStore
    let controller: EditorController
    let view: NoteTextView
    let window: NSWindow

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-parts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Notes"), withIntermediateDirectories: true)
        try "# Plan\n".write(to: root.appending(path: "Notes/Plan.md"), atomically: true, encoding: .utf8)
        let settings = AppSettings(url: root.appending(path: "config/config.toml"))
        store = VaultStore(settings: settings, openVault: false)
        store.openSynchronously(root)
        controller = EditorController(store: store)
        let scroll = NoteTextView.scrollableNoteView()
        view = scroll.documentView as! NoteTextView
        view.controller = controller
        controller.view = view
        // Off every screen: the view is laid out, and nothing is shown.
        window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 700, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
    }

    var text: NSString { view.string as NSString }

    func open(_ note: String) throws {
        try note.write(to: root.appending(path: "Notes/Parts.md"), atomically: true, encoding: .utf8)
        store.openSynchronously(root)
        controller.load("Notes/Parts.md")
    }

    func caret(in word: String, plus: Int = 0) {
        view.setSelectedRange(NSRange(location: text.range(of: word).location + plus, length: 0))
    }

    /// The part drawn at the start of [word], as the styling wrote it.
    func part(at word: String) -> DrawnPart? {
        let range = text.range(of: word)
        guard range.location != NSNotFound else { return nil }
        return (view.textStorage?.attribute(NoteTextView.part, at: range.location, effectiveRange: nil) as? String).flatMap(DrawnPart.init)
    }

    func attribute<T>(_ key: NSAttributedString.Key, at word: String, plus: Int = 0) -> T? {
        view.textStorage?.attribute(key, at: text.range(of: word).location + plus, effectiveRange: nil) as? T
    }

    func hidden(_ word: String) -> Bool {
        (attribute(.foregroundColor, at: word) as NSColor?) == .clear
    }

    @Test func aBoxIsDrawnAwayFromTheCursorAndRawUnderIt() throws {
        try open("Top\n\n- [ ] Buy milk\n1. [x] Sent\n- [ ]\n")
        // The cursor is on the first line: the marks go, and the box is in their place.
        #expect(part(at: "- [ ]") == .box(" "))
        #expect(hidden("- [ ]"))
        // The five marks take the box's width: no size of their own, and the box's after the last.
        let size = CGFloat(store.settings.textSize)
        #expect((attribute(.font, at: "- [ ]") as NSFont?)?.pointSize ?? 1 < 0.1)
        #expect((attribute(.kern, at: "- [ ]", plus: 4) as CGFloat?) == size * 1.1)
        #expect((attribute(.kern, at: "- [ ]", plus: 3) as CGFloat?) == nil)
        // After a number the box takes the place of the brackets alone.
        #expect(part(at: "[x]") == .box("x"))
        #expect(part(at: "1.") == nil && !hidden("1."))
        // A mark that is not complete is text.
        #expect(view.textStorage?.attribute(NoteTextView.part, at: text.length - 2, effectiveRange: nil) == nil)
        // In the marks they are raw; at the start of the text the box is back.
        for offset in [0, 3, 5] {
            caret(in: "- [ ]", plus: offset)
            #expect(part(at: "- [ ]") == nil && !hidden("- [ ]"), "\(offset)")
        }
        caret(in: "- [ ]", plus: 6)
        #expect(part(at: "- [ ]") == .box(" "))
        // A selection that reaches into the marks shows them.
        view.setSelectedRange(NSRange(location: text.range(of: "- [ ]").location + 4, length: 4))
        #expect(part(at: "- [ ]") == nil)
        // Live preview off: no drawn part.
        store.settings.livePreview = false
        controller.restyle(all: true)
        #expect(part(at: "- [ ]") == nil && part(at: "[x]") == nil)
        store.settings.livePreview = true
    }

    @Test func aDateOnATaskIsAChipAndRawUnderTheCursor() throws {
        try open("Top\n\n- [ ] Pay 📅 2001-02-03 ⏳ 2999-01-01 🔁 every week\n- [x] Paid ✅ 2001-02-04\nMeeting 📅 2001-02-03\n- [ ] Bad 📅 2001-02-30\n")
        let size = CGFloat(store.settings.textSize)
        // A due date in the past on an open task is late: the red, and heavier.
        #expect(part(at: "📅 2001-02-03") == .chip(colour: "red", closed: false))
        #expect(part(at: "⏳") == .chip(colour: "blue", closed: false))
        #expect(part(at: "🔁") == .chip(colour: "pink", closed: false))
        #expect((attribute(.font, at: "2001-02-03") as NSFont?)?.pointSize == size * 0.92)
        // Room for the pill's sides: after the space before a chip, more between two, and after the space behind one.
        #expect((attribute(.kern, at: " 📅") as CGFloat?) == size * 0.5)
        #expect((attribute(.kern, at: " ⏳") as CGFloat?) == size * 1.05)
        #expect((attribute(.kern, at: "2001-02-03", plus: 9) as CGFloat?) == nil)
        // On a closed task the chip is drawn weaker, and never struck through.
        #expect(part(at: "✅") == .chip(colour: "green", closed: true))
        #expect((attribute(.strikethroughStyle, at: "✅") as Int?) == nil)
        #expect((attribute(.strikethroughStyle, at: "Paid") as Int?) == NSUnderlineStyle.single.rawValue)
        // No task, no chip; and a day that is not real stays as written.
        #expect(part(at: "📅 2001-02-03\n- [ ] Bad") == nil)
        #expect(part(at: "📅 2001-02-30") == nil)
        // The cursor in the chip shows it raw, at the full size; the others stay.
        caret(in: "2001-02-03", plus: 4)
        #expect(part(at: "📅 2001-02-03") == nil)
        #expect((attribute(.font, at: "2001-02-03") as NSFont?)?.pointSize == size)
        #expect(part(at: "⏳") == .chip(colour: "blue", closed: false))
        #expect(part(at: "- [ ]") == .box(" "))
        // Just after its last digit it is raw too; in the task's text it is drawn.
        caret(in: "2001-02-03", plus: 10)
        #expect(part(at: "📅 2001-02-03") == nil)
        caret(in: "Pay", plus: 1)
        #expect(part(at: "📅 2001-02-03") == .chip(colour: "red", closed: false))
    }

    @Test func aClickOnTheBoxTicksTheTaskInOneUndoStep() throws {
        try open("Top line\n\n- [ ] Call ➕ 2026-11-20\nAfter\n")
        let today = Day.today().description
        let undo = try #require(view.undoManager)
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        caret(in: "After", plus: 2)
        // A click in the box, as the mouse makes it.
        let box = try #require(view.boxRect(for: text.range(of: "- [ ]")))
        let hit = try #require(view.taskBox(at: NSPoint(x: box.midX, y: box.midY)))
        #expect(hit.cover == text.range(of: "- [ ]"))
        #expect(view.taskBox(at: NSPoint(x: box.maxX + 30, y: box.midY)) == nil)
        let click = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: view.convert(NSPoint(x: box.midX, y: box.midY), to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        undo.beginUndoGrouping()
        view.mouseDown(with: click)
        undo.endUndoGrouping()
        #expect(view.string == "Top line\n\n- [x] Call ➕ 2026-11-20 ✅ \(today)\nAfter\n")
        // The cursor is on the text it was on, and the box is still a box.
        #expect(view.selectedRange() == NSRange(location: text.range(of: "After").location + 2, length: 0))
        #expect(part(at: "- [x]") == .box("x"))
        // One step back, and the task is as it was.
        undo.undo()
        #expect(view.string == "Top line\n\n- [ ] Call ➕ 2026-11-20\nAfter\n")
        undo.groupsByEvent = true
        // A second click on a ticked task opens it again.
        view.toggleTaskBox(at: text.range(of: "- [ ]").location)
        view.toggleTaskBox(at: text.range(of: "- [x]").location)
        #expect(view.string == "Top line\n\n- [ ] Call ➕ 2026-11-20\nAfter\n")
        // With the cursor in the task's text, it keeps its place in the line.
        caret(in: "Call", plus: 2)
        let place = view.selectedRange()
        view.toggleTaskBox(at: text.range(of: "- [ ]").location)
        #expect(view.selectedRange() == place)
        // A click with Shift is a click in the text: nothing is ticked.
        let before = view.string
        let shifted = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: view.convert(NSPoint(x: box.midX, y: box.midY), to: nil), modifierFlags: [.shift], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(!view.boxClick(shifted))
        #expect(view.string == before)
        // Saving is the editor's own: the file has the tick once the editor saves.
        controller.saveNow()
        #expect(try String(contentsOf: root.appending(path: "Notes/Parts.md"), encoding: .utf8) == before)
    }

    @Test func aRepeatingTaskLeavesItsNextOneAboveAndTheCursorOnItsText() throws {
        try open("- [ ] Water 🔁 every week 📅 2026-11-20\nAfter\n")
        caret(in: "After", plus: 1)
        view.toggleTaskBox(at: 0)
        #expect(view.string.hasPrefix("- [ ] Water 🔁 every week 📅 "))
        #expect(view.string.contains("\n- [x] Water 🔁 every week 📅 2026-11-20 ✅ "))
        #expect(view.selectedRange().location == text.range(of: "After").location + 1)
    }

    /// In a read-only vault everything is drawn, and a click changes nothing.
    @Test func aClickInAReadOnlyVaultDoesNothing() async throws {
        let git = Git(root: root)
        try await git.run(["init", "-q", "-b", "main"])
        try await git.run(["config", "--local", "daftar.readonly", "true"])
        try open("Top\n\n- [ ] Call\n")
        #expect(store.readOnly)
        #expect(part(at: "- [ ]") == .box(" "))
        view.toggleTaskBox(at: text.range(of: "- [ ]").location)
        #expect(view.string == "Top\n\n- [ ] Call\n")
    }

    @Test func aCalloutHasItsIconAndItsMarksGoAwayFromTheCursor() throws {
        try open("Top\n\n> [!warning] Mind\n> the gap\n\n> [!tip]\n> body\n>\n\n> plain\n")
        let size = CGFloat(store.settings.textSize)
        // The marks of a callout are drawn at no width; the icon stands for `[!kind]`.
        #expect(hidden("> [!warning]") && hidden("[!warning]"))
        #expect(part(at: "[!warning]") == .icon(kind: "warning", name: ""))
        #expect((attribute(.kern, at: "[!warning]", plus: 9) as CGFloat?) == size * 1.25)
        #expect(hidden("> the gap"))
        // With no title the kind's name is drawn, and never written.
        #expect(part(at: "[!tip]") == .icon(kind: "tip", name: "Tip"))
        #expect(view.string.contains("> [!tip]\n"))
        // An em of room at each side of the panel.
        #expect((attribute(.paragraphStyle, at: "the gap") as NSParagraphStyle?)?.headIndent == size)
        #expect((attribute(.paragraphStyle, at: "the gap") as NSParagraphStyle?)?.tailIndent == -size)
        // A quote keeps its `>`: it has a bar, no panel.
        #expect(!hidden("> plain"))
        #expect((attribute(NoteTextView.calloutPanel, at: "> plain") as String?) == nil)
        // On the cursor's line the marks show.
        caret(in: "Mind")
        #expect(!hidden("> [!warning]") && !hidden("[!warning]") && part(at: "[!warning]") == nil)
        #expect(hidden("> the gap"))
    }

    @Test func aKindTypedInAHeadColoursTheLinesUnderIt() throws {
        try open("Top\n\n> [!note] Title\n> one\n> two\n\nEnd\n")
        #expect((attribute(NoteTextView.calloutPanel, at: "> two") as String?) == "blue")
        let kind = text.range(of: "note")
        view.setSelectedRange(kind)
        view.insertText("bug", replacementRange: kind)
        #expect((attribute(NoteTextView.calloutPanel, at: "> one") as String?) == "red")
        #expect((attribute(NoteTextView.calloutPanel, at: "> two") as String?) == "red")
        // The head taken away, the lines under it are a quote.
        let head = text.lineRange(for: text.range(of: "[!bug]"))
        view.setSelectedRange(head)
        view.insertText("", replacementRange: head)
        #expect((attribute(NoteTextView.calloutPanel, at: "> two") as String?) == nil)
        #expect((attribute(NoteTextView.quoteBar, at: "> two") as String?) == "quote")
    }

    @Test func aCodeBlockHasItsWordAndItsFencesGoAwayFromTheCursor() throws {
        try open("Top\n\n```Rust\nlet x = 1;\n```\n\n~~~\nplain\n~~~\n")
        let size = CGFloat(store.settings.textSize)
        // The opening fence: its marks at no width, the word drawn in small letters.
        #expect(hidden("```Rust"))
        #expect(part(at: "```Rust") == .word("rust"))
        // The closing fence is 0.4 em high.
        let closing = text.range(of: "```\n\n~~~")
        let paragraph = view.textStorage?.attribute(.paragraphStyle, at: closing.location, effectiveRange: nil) as? NSParagraphStyle
        #expect(paragraph?.maximumLineHeight == size * 0.4)
        #expect((view.textStorage?.attribute(.foregroundColor, at: closing.location, effectiveRange: nil) as? NSColor) == .clear)
        // With no language there is no word.
        #expect(hidden("~~~") && part(at: "~~~") == nil)
        // The body: the code font at 0.85 em, with room where the lines start and end.
        #expect((attribute(.font, at: "let x") as NSFont?)?.pointSize == size * 0.85)
        #expect((attribute(.paragraphStyle, at: "let x") as NSParagraphStyle?)?.headIndent == size * 1.1)
        // On the cursor's line a fence is as written, at its full height.
        caret(in: "Rust")
        #expect(!hidden("```Rust") && part(at: "```Rust") == nil)
        #expect((attribute(.paragraphStyle, at: "```Rust") as NSParagraphStyle?)?.maximumLineHeight == 0)
        // The body never changes with the cursor.
        #expect((attribute(.font, at: "let x") as NSFont?)?.pointSize == size * 0.85)
    }

    /// Every icon the core's tables name is in the reader's build, and is drawn.
    @Test func everyIconOfABoxAndACalloutIsDrawn() throws {
        for name in TaskBox.icons.union(Callout.icons).sorted() {
            #expect(EditorIcons.svgs[name] != nil, "\(name)")
            let image = try #require(EditorIcons.image(name, colour: NSPalette.accent, side: 18, scale: 2), "\(name)")
            let bitmap = try #require(image.representations.first as? NSBitmapImageRep)
            #expect(bitmap.pixelsWide == 36)
            var inked = 0
            for x in 0..<bitmap.pixelsWide { for y in 0..<bitmap.pixelsHigh where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { inked += 1 } }
            // A drawing of lines: some of the square, never all of it.
            #expect(inked > 20 && inked < 36 * 36 * 3 / 4, "\(name): \(inked)")
        }
    }

    /// The editor with every drawn part in it, as a picture, to look at.
    @Test(.enabled(if: picturePath != nil)) func picture() throws {
        let note = """
            # Parts

            Some text before, with **bold** and a [[Link]].

            - [ ] Open task with dates 📅 2999-11-30 ⏳ 2999-11-25 ➕ 2026-11-01
            - [ ] Late task 📅 2001-11-01 🔁 every week
            - [/] In progress 🛫 2026-11-20
            - [x] Done task ✅ 2026-11-21 ➕ 2026-11-01
            - [-] Cancelled [reason:: no budget] ❌ 2026-11-02
            - [>] Forwarded
            - [!] Important
            - [?] Question
            - [~] A status the vault does not have
            1. [ ] Numbered task
            2. [x] Numbered done
                - [ ] Nested task
            - [ ] کار فارسی 📅 2001-10-30 ⏳ 2999-12-01
            - [ ] Raw under the cursor 📅 2999-01-01

            > [!warning] Mind the gap
            > A callout's body, long enough to go around the measure of the editor, so the room at each side of the panel shows.
            > - [ ] a task in a callout 📅 2999-12-01

            > [!tip]
            > A tip with no title.

            > [!note]- Folded title
            > Body.

            > A plain quote
            > with two lines.

            ```Rust
            fn main() {
                println!("hello");
            }
            ```

            ```
            no language
            ```

            After.

            """
        try open(note)
        window.setContentSize(NSSize(width: 820, height: 1500))
        // The cursor in a task's marks, so one line shows raw.
        caret(in: "- [ ] Raw", plus: 2)
        let scroll = try #require(view.enclosingScrollView)
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            window.appearance = NSAppearance(named: appearance)
            controller.restyle(all: true)
            scroll.layoutSubtreeIfNeeded()
            scroll.displayIfNeeded()
            let bitmap = try #require(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
            scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(filePath: "\(picturePath ?? "")-\(name).png"))
        }
    }

    /// The pointer over a box grows it; the styling's value reads back as written.
    @Test func aPartReadsBackAsItWasWritten() {
        let parts: [DrawnPart] = [.box(" "), .box("x"), .chip(colour: "red", closed: false), .chip(colour: "green", closed: true),
            .icon(kind: "tip", name: "Tip"), .icon(kind: "warning", name: ""), .word("rust")]
        for part in parts { #expect(DrawnPart(part.value) == part) }
        #expect(DrawnPart("nothing") == nil)
    }
}
