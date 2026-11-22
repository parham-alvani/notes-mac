import AppKit
import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// Where `EditorBarsTests.picture` writes the editor as pictures, when asked:
/// `DAFTAR_BARS_PICTURE=/tmp/bars swift test --filter EditorBarsTests/picture`
/// writes `/tmp/bars-slash-dark.png`, `/tmp/bars-card-light.png` and the
/// like. The views draw them, so it needs no screen and brings no window
/// to the front.
private let barsPicture = ProcessInfo.processInfo.environment["DAFTAR_BARS_PICTURE"]

/// The slash bar, focus mode and the link's card in the editor, on a
/// made-up vault in a temporary folder (docs/specs/look.md in notes-linux,
/// part 2).
@MainActor
@Suite(.serialized) struct EditorBarsTests {
    let root: URL
    let store: VaultStore
    let controller: EditorController
    let view: NoteTextView
    let window: NSWindow

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-bars-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Notes/Work"), withIntermediateDirectories: true)
        let plan = "---\ntags: [plan]\n---\n# Plan\n\nThe **plan** for the week, with a [[Other]] note.\n\n- [ ] Call the bank 📅 2026-11-20\n- [x] Send the form\n\n## Next\n\nWhat comes ==next==.\n\n## Later\n\nThe rest.\n"
        try plan.write(to: root.appending(path: "Notes/Work/Plan.md"), atomically: true, encoding: .utf8)
        try "".write(to: root.appending(path: "Notes/Empty.md"), atomically: true, encoding: .utf8)
        try "Other words.\n".write(to: root.appending(path: "Notes/Other.md"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50]).write(to: root.appending(path: "Notes/Shot.png"))
        let settings = AppSettings(url: root.appending(path: "config/config.toml"))
        store = VaultStore(settings: settings, openVault: false)
        store.openSynchronously(root)
        controller = EditorController(store: store)
        let scroll = NoteTextView.scrollableNoteView()
        view = scroll.documentView as! NoteTextView
        view.controller = controller
        controller.view = view
        // Off every screen: the view is laid out, and nothing is shown.
        window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 760, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
    }

    var text: NSString { view.string as NSString }

    func open(_ note: String) throws {
        try note.write(to: root.appending(path: "Notes/Bars.md"), atomically: true, encoding: .utf8)
        store.openSynchronously(root)
        controller.load("Notes/Bars.md")
    }

    func at(_ word: String) -> Int { text.range(of: word).location }

    func caret(in word: String, plus: Int = 0) {
        view.setSelectedRange(NSRange(location: at(word) + plus, length: 0))
    }

    /// [typed], a key at a time, as the keyboard sends it.
    func type(_ typed: String) {
        for letter in typed { view.insertText(String(letter), replacementRange: NSRange(location: NSNotFound, length: 0)) }
    }

    func key(_ selector: Selector) { view.doCommand(by: selector) }

    /// The editor as a picture, in the appearance named.
    func snapshot(_ name: String) throws {
        let scroll = try #require(view.enclosingScrollView)
        scroll.layoutSubtreeIfNeeded()
        scroll.displayIfNeeded()
        let bitmap = try #require(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
        scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(filePath: "\(barsPicture ?? "")-\(name).png"))
    }

    // MARK: The slash bar

    static let down = #selector(NSResponder.moveDown(_:))
    static let up = #selector(NSResponder.moveUp(_:))
    static let enter = #selector(NSResponder.insertNewline(_:))
    static let tab = #selector(NSResponder.insertTab(_:))
    static let escape = #selector(NSResponder.cancelOperation(_:))

    /// The caret at the end of the note, and the bar and its list as they are.
    func end() { view.setSelectedRange(NSRange(location: text.length, length: 0)) }
    var bar: SlashBar? { view.extras.slash }
    var list: SlashList? { view.extras.slashList.flatMap { $0.isHidden ? nil : $0 } }

    @Test func aTypedSlashOpensTheListUnderItAndTheKeysStayInTheText() throws {
        try open("Top\n\n")
        window.makeFirstResponder(view)
        end()
        type("/")
        let list = try #require(list)
        // Every item, Heading 1 chosen, under the `/`, 280 wide, at most 8 rows high.
        #expect(bar?.rows.count == 36 && bar?.choice?.id == "h1")
        #expect(list.frame.width == 280 && list.frame.height <= 8 * 32 + 8)
        let slash = try #require(view.letterCaret(at: at("/")))
        #expect(abs(list.frame.minX - slash.minX) < 0.5 && abs(list.frame.minY - (slash.maxY + 4)) < 0.5)
        #expect(list.lines.first == .header("Text") && list.lines.count == 36 + 6)
        // The list never has the keys.
        #expect(window.firstResponder === view && !list.acceptsFirstResponder)
        // Letters go into the text and filter; with a query there are no headers.
        type("tab")
        #expect(view.string == "Top\n\n/tab")
        #expect(bar?.choice?.id == "table" && self.list?.lines.contains { if case .header = $0 { true } else { false } } == false)
        // Down and Up choose and stop at the ends; the text and the caret stay.
        let rows = try #require(bar?.rows.count)
        for _ in 0..<(rows + 3) { key(Self.down) }
        #expect(bar?.chosen == rows - 1)
        for _ in 0..<(rows + 3) { key(Self.up) }
        #expect(bar?.chosen == 0)
        #expect(view.string == "Top\n\n/tab" && view.selectedRange() == NSRange(location: text.length, length: 0))
        // Return inserts the row in place of the `/` and the query: a formatted table, the caret in its first header cell.
        key(Self.enter)
        #expect(view.string == "Top\n\n| Column | Column |\n| ------ | ------ |\n|        |        |")
        #expect(view.selectedRange() == NSRange(location: at("Column"), length: 0))
        #expect(bar == nil && self.list == nil)
        // One step to undo gives the typed text back.
        view.undoManager?.undo()
        #expect(!view.string.contains("| Column"))
    }

    @Test func enterTabEscapeSpaceAndBackspace() throws {
        try open("Top\n\n")
        end()
        // Tab inserts as Return does. A callout's caret is in its title.
        type("/warn")
        key(Self.tab)
        #expect(view.string == "Top\n\n> [!warning] \n> ")
        #expect(view.selectedRange().location == at("> [!warning] ") + 13)
        // Escape closes the list: the `/` and what was typed stay, and more letters open nothing.
        try open("Top\n\n")
        end()
        type("/ta")
        key(Self.escape)
        #expect(bar == nil && list == nil && view.string == "Top\n\n/ta")
        type("b")
        #expect(bar == nil && view.string == "Top\n\n/tab")
        // Now Return is an ordinary key.
        key(Self.enter)
        #expect(view.string == "Top\n\n/tab\n")
        // A space goes into the text and closes the list.
        type("/h1")
        #expect(bar?.choice?.id == "h1")
        type(" ")
        #expect(bar == nil && view.string.hasSuffix("/h1 "))
        // Nothing matches: the list hides and still listens; a Backspace brings it back; Return is ordinary meanwhile.
        try open("Top\n\n")
        end()
        type("/hz")
        #expect(bar != nil && list == nil)
        view.deleteBackward(nil)
        #expect(list != nil && bar?.query == "h")
        // Backspace over the `/` closes it.
        view.deleteBackward(nil)
        #expect(bar?.query == "")
        view.deleteBackward(nil)
        #expect(bar == nil && list == nil && view.string == "Top\n\n")
        // Left out of the place between the `/` and the query's end closes it; so does a click elsewhere.
        type("/co")
        view.setSelectedRange(NSRange(location: at("/") + 2, length: 0))
        #expect(bar?.query == "c")
        view.setSelectedRange(NSRange(location: at("/"), length: 0))
        #expect(bar == nil)
        end()
        type(" /co")
        view.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(bar == nil && list == nil)
    }

    @Test func theBarOpensOnlyWhereTheSpecLetsIt() async throws {
        func opens(_ note: String, _ typed: String = "/") throws -> Bool {
            try open(note)
            end()
            type(typed)
            defer { view.closeSlashBar() }
            return bar != nil
        }
        #expect(try opens("") && opens("a ") && opens("a\n"))
        // A path, a web address and a fraction never open it.
        #expect(try !opens("a") && !opens("https:") && !opens("10"))
        // Not in a code block, inline code, the front matter, math or a comment.
        #expect(try !opens("```\ncode\n") && !opens("---\ntitle: x\n") && !opens("$$\n") && !opens("%%\nhidden\n"))
        try open("a `b ` c")
        view.setSelectedRange(NSRange(location: 5, length: 0))
        type("/")
        #expect(bar == nil)
        // After the block is closed it opens again.
        #expect(try opens("```\ncode\n```\n"))
        // A pasted `/` does not open it.
        try open("a ")
        end()
        // As Paste reads it, from a pasteboard of the test's own: never the person's.
        let board = NSPasteboard(name: NSPasteboard.Name("daftar-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("/", forType: .string)
        #expect(view.readSelection(from: board))
        #expect(view.string == "a /" && bar == nil)
        // Off by the setting: a `/` is only a `/`.
        store.settings.slashMenu = false
        #expect(try !opens("a "))
        #expect(view.string == "a /")
        store.settings.slashMenu = true
        // Not with many cursors.
        try open("one\ntwo\n")
        view.setCursors([NSRange(location: 0, length: 0), NSRange(location: 4, length: 0)])
        type("/")
        #expect(bar == nil && view.string == "/one\n/two\n")
        // Not in a read-only vault.
        let git = Git(root: root)
        try await git.run(["init", "-q", "-b", "main"])
        try await git.run(["config", "--local", "daftar.readonly", "true"])
        try open("a ")
        #expect(store.readOnly)
        end()
        type("/")
        #expect(bar == nil)
    }

    @Test func aClickOnARowInsertsItAndABlockStartsItsOwnLine() throws {
        try open("text ")
        window.makeFirstResponder(view)
        end()
        type("/code")
        let list = try #require(list)
        let frame = try #require(list.frames().first { $0.line == .row(0) }?.frame)
        #expect(list.row(at: NSPoint(x: frame.midX, y: frame.midY + 1)) == 0)
        view.insertSlash(try #require(bar?.rows.first))
        #expect(view.string == "text \n```\n\n```")
        #expect(view.selectedRange().location == 10)
        #expect(window.firstResponder === view)
        // The list is over the `/` when there is no room under it, and inside the editor by 8 px.
        try open(String(repeating: "line\n", count: 60))
        end()
        view.scrollRangeToVisible(view.selectedRange())
        type("/")
        let low = try #require(self.list)
        let slash = try #require(view.letterCaret(at: text.length - 1))
        #expect(low.frame.maxY <= slash.minY - 3.5)
        #expect(low.frame.minX >= view.visibleRect.minX + 8 && low.frame.maxX <= view.visibleRect.maxX - 8)
    }

    // MARK: Focus mode

    static let focusNote = "First paragraph\nstill first\n\nSecond one\n\n- [ ] A task 📅 2026-11-20\n- [x] Done\n\n> [!tip] A callout\n> Its body.\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\nLast words.\n"

    @Test func focusKeepsTheCaretsParagraphBrightAndChangesNoText() throws {
        try open(Self.focusNote)
        let before = NSAttributedString(attributedString: try #require(view.textStorage))
        store.settings.focusMode = true
        defer { store.settings.focusMode = false }
        caret(in: "still")
        #expect(view.extras.focused?.ranges == [NSRange(location: 0, length: at("\n\nSecond") + 1)])
        // The text, its styles and its layout's own attributes are as they were.
        #expect(view.textStorage?.isEqual(to: before) == true)
        let layout = try #require(view.textLayoutManager)
        var painted = 0
        layout.enumerateRenderingAttributes(from: layout.documentRange.location, reverse: false) { _, attributes, _ in
            if attributes[.foregroundColor] != nil { painted += 1 }
            return true
        }
        #expect(painted == 0)
        // The bright band is the paragraph's two lines, as wide as the view.
        let bands = view.brightBands()
        #expect(bands.count == 1)
        let first = try #require(view.lineRect(at: 0)), second = try #require(view.lineRect(at: at("still")))
        let other = try #require(view.lineRect(at: at("Second")))
        #expect(bands[0].minY <= first.minY && bands[0].maxY >= second.maxY && bands[0].maxY <= other.minY + 1)
        #expect(bands[0].width == view.bounds.width)
        // A selection keeps every paragraph it touches bright.
        view.setSelectedRange(NSRange(location: at("still"), length: at("Second") + 2 - at("still")))
        #expect(view.extras.focused?.ranges == [NSRange(location: 0, length: at("\n\n- [ ]") + 1)])
        // A list, a callout and a table are each one paragraph.
        caret(in: "Done")
        #expect(view.extras.focused.map { text.substring(with: $0.ranges[0]) } == "- [ ] A task 📅 2026-11-20\n- [x] Done\n")
        caret(in: "Its body")
        #expect(view.extras.focused.map { text.substring(with: $0.ranges[0]) } == "> [!tip] A callout\n> Its body.\n")
        caret(in: "| 1", plus: 2)
        #expect(view.extras.focused.map { text.substring(with: $0.ranges[0]) } == "| A | B |\n| --- | --- |\n| 1 | 2 |\n")
        // Many cursors: each cursor's paragraph.
        view.setCursors([NSRange(location: 2, length: 0), NSRange(location: at("Last"), length: 0)])
        controller.followCursor()
        #expect(view.extras.focused?.ranges.count == 2)
        #expect(view.brightBands().count == 2)
        // Typing in the paragraph keeps it, grown by the letter.
        caret(in: "Second", plus: 6)
        type("!")
        #expect(view.extras.focused.map { text.substring(with: $0.ranges[0]) } == "Second! one\n")
        // Off: nothing is kept, and nothing is dimmed.
        store.settings.focusMode = false
        controller.followWritingModes()
        #expect(view.extras.focused == nil && view.brightBands().isEmpty && view.extras.dim == nil)
        #expect(!view.subviews.contains { $0 is FocusDim })
    }

    /// The colour of the picture's point at [point] of the view, as red, green and blue from 0 to 1.
    func colour(at point: NSPoint) throws -> [CGFloat] {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
        let colour = try #require(bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB))
        return [colour.redComponent, colour.greenComponent, colour.blueComponent]
    }

    /// The dim is over the text and what is drawn behind it: a code block's
    /// panel in a dimmed paragraph is at 45% of what it is in a bright one.
    @Test func aDimmedPanelIsAt45PercentOverTheBackground() throws {
        try open("Top words\n\n```\ncode\n```\n\nEnd\n")
        window.appearance = NSAppearance(named: .darkAqua)
        caret(in: "End")
        let line = try #require(view.lineRect(at: at("code")))
        // A point of the panel with no letter on it.
        let point = NSPoint(x: view.bounds.width / 2, y: line.midY)
        let bright = try colour(at: point)
        store.settings.focusMode = true
        defer { store.settings.focusMode = false }
        controller.followWritingModes()
        let dimmed = try colour(at: point)
        let background = try colour(at: NSPoint(x: 4, y: line.midY))
        for index in 0..<3 {
            let expected = background[index] + (bright[index] - background[index]) * 0.45
            #expect(abs(dimmed[index] - expected) < 0.02, "channel \(index): \(dimmed[index]) for \(expected), bright \(bright[index])")
        }
        #expect(bright != background)
        // With the caret in the block, the panel is as bright as without focus mode.
        view.setSelectedRange(NSRange(location: at("```"), length: 0))
        let shown = try #require(view.lineRect(at: at("code")))
        #expect(try colour(at: NSPoint(x: point.x, y: shown.midY)).enumerated().allSatisfy { abs($0.element - bright[$0.offset]) < 0.02 })
    }

    // MARK: The link's card

    static let linkNote = "Top words.\n\nSee [[Plan]] and [[Plan#Next|what is next]], then ![[Plan]] or [[Shot.png]].\n\nA [[Nowhere]] link, an [[Empty]] one and [[#Here]].\n\n`[[Plan]]` in code.\n\n## Here\n\nUnder here.\n"

    /// A point on the letters of [word], in the view.
    func point(on word: String, plus: Int = 1) throws -> NSPoint {
        let box = try #require(view.letterBox(NSRange(location: at(word) + plus, length: 1)))
        return NSPoint(x: box.midX, y: box.midY)
    }

    /// The pointer rests on [word] long enough: the card that shows, if one does.
    func rest(on word: String, plus: Int = 1) throws -> LinkCardView? {
        view.hoverLink(at: try point(on: word, plus: plus))
        view.showLinkCard()
        return view.extras.linkHover?.view
    }

    @Test func theLinkUnderThePointerIsFoundDrawnOrRaw() throws {
        try open(Self.linkNote)
        // Drawn, with its marks hidden: the pointer is on the name.
        let plan = try #require(view.link(at: try point(on: "Plan]]")))
        #expect(text.substring(with: plan.range) == "[[Plan]]" && plan.link.target == "Plan")
        let next = try #require(view.link(at: try point(on: "what is next")))
        #expect(next.link.target == "Plan" && next.link.anchor == "Next")
        // Raw, with the caret in it.
        caret(in: "Plan]]")
        #expect(view.link(at: try point(on: "[[Plan]]", plus: 0))?.link.target == "Plan")
        // An embed, a link in code and plain words have none.
        #expect(view.link(at: try point(on: "![[Plan]]", plus: 4)) == nil)
        #expect(view.link(at: try point(on: "`[[Plan]]`", plus: 4)) == nil)
        #expect(view.link(at: try point(on: "Top words")) == nil)
        #expect(view.link(at: NSPoint(x: 5, y: 5)) == nil)
    }

    @Test func theCardShowsTheNotesTitleAndItsFirstLines() throws {
        try open(Self.linkNote)
        let card = try #require(try rest(on: "Plan]]"))
        #expect(card.card.title == "Plan" && card.card.heading == nil && card.card.folder == "Notes › Work" && card.card.path == "Notes/Work/Plan.md")
        // The first lines, without the front matter and the heading that is the title.
        let body = try #require(card.bodyText)
        #expect(body.string.hasPrefix("The **plan** for the week, with a [[Other]] note.\n\n- [ ] Call the bank"))
        // Drawn with the editor's styles at 0.9 em, the marks hidden: nothing shows raw, also on the first line.
        let stars = (body.string as NSString).range(of: "**")
        #expect((body.attribute(.foregroundColor, at: stars.location, effectiveRange: nil) as? NSColor) == .clear)
        let word = (body.string as NSString).range(of: "week")
        #expect(abs(((body.attribute(.font, at: word.location, effectiveRange: nil) as? NSFont)?.pointSize ?? 0) - CGFloat(store.settings.textSize) * 0.9) < 0.01)
        let box = (body.string as NSString).range(of: "- [ ]")
        #expect((body.attribute(NoteTextView.part, at: box.location, effectiveRange: nil) as? String).flatMap(DrawnPart.init) == .box(" "))
        // 360 wide, at most 240 high, under the link by 6 px with its start edge on the link's, inside the view by 8 px.
        #expect(card.frame.width == 360 && card.frame.height <= 240)
        let link = try #require(view.letterBox(text.range(of: "[[Plan]]")))
        #expect(abs(card.frame.minY - (link.maxY + 6)) < 0.5 && abs(card.frame.minX - link.minX) < 0.5)
        #expect(card.frame.maxX <= view.visibleRect.maxX - 8)
        // In a short pane the card is as high as the room it has, and inside the view.
        view.closeLinkCard()
        window.setContentSize(NSSize(width: 760, height: 260))
        let short = try #require(try rest(on: "Plan]]"))
        #expect(short.frame.maxY <= view.visibleRect.maxY - 8 + 0.5 && short.frame.height < card.frame.height)
        #expect(short.frame.minY >= link.maxY + 5.5)
        window.setContentSize(NSSize(width: 760, height: 620))
        // The card never has the keys, and the text is as it was.
        #expect(!card.acceptsFirstResponder && view.string == Self.linkNote)
        // A link to a heading: the section without its heading, and the heading in the head.
        let section = try #require(try rest(on: "what is next"))
        #expect(section.card.heading == "Next" && section.bodyText?.string == "What comes ==next==.")
        // One card at a time: the first went when the second came.
        #expect(card.superview == nil && view.subviews.filter { $0 is LinkCardView }.count == 1)
        // The pointer on the card is not on the links under it.
        view.hoverLink(at: try point(on: "#Here"))
        #expect(view.extras.linkHover?.view === section)
        view.closeLinkCard()
        // A link into this note shows it as it is typed.
        let here = try #require(try rest(on: "#Here"))
        #expect(here.card.title == "Bars" && here.card.heading == "Here" && here.bodyText?.string == "Under here.")
        // No such note, and an empty note.
        view.closeLinkCard()
        let none = try #require(try rest(on: "Nowhere"))
        #expect(none.card.title == "Nowhere" && none.card.body == .missing && none.bodyWords == "No note yet." && none.bodyText?.length == 0)
        view.closeLinkCard()
        let empty = try #require(try rest(on: "Empty"))
        #expect(empty.card.title == "Empty" && empty.bodyWords == "The note is empty.")
        // Each body's editor is let go by the store.
        view.closeLinkCard()
        #expect(view.subviews.filter { $0 is LinkCardView }.isEmpty)
        #expect(store.flushers.count == 1 && store.followers.count == 1)
    }

    @Test func whereNoCardShows() throws {
        try open(Self.linkNote)
        // An embed and a file that is no note.
        #expect(try rest(on: "![[Plan]]", plus: 4) == nil)
        #expect(try rest(on: "Shot.png") == nil)
        #expect(view.extras.linkHover == nil)
        // A key pressed since the pointer last moved: typing under a still pointer opens nothing.
        view.hoverLink(at: try point(on: "Plan]]"))
        #expect(view.extras.linkHover != nil)
        end()
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        view.keyDown(with: key)
        #expect(view.extras.linkHover == nil && view.extras.keySincePointer)
        view.showLinkCard()
        #expect(view.extras.linkHover == nil)
        // The pointer moves again: a card may open.
        #expect(try rest(on: "Plan]]") != nil)
        // A key closes a card that shows, at once.
        view.keyDown(with: key)
        #expect(view.extras.linkHover == nil && !view.subviews.contains { $0 is LinkCardView })
        // With the setting off.
        store.settings.linkPreview = false
        #expect(try rest(on: "Plan]]") == nil)
        store.settings.linkPreview = true
    }

    @Test func theCardClosesAtOnceAndItsHeadOpensTheNote() throws {
        try open(Self.linkNote)
        var opened: [String] = []
        controller.onOpen = { opened.append($0) }
        // A change of the note.
        #expect(try rest(on: "Plan]]") != nil)
        view.insertText("!", replacementRange: NSRange(location: 0, length: 0))
        #expect(view.extras.linkHover == nil)
        // A scroll of the note.
        #expect(try rest(on: "Plan]]") != nil)
        let clip = try #require(view.enclosingScrollView?.contentView)
        clip.setBoundsOrigin(NSPoint(x: 0, y: 4))
        #expect(view.extras.linkHover == nil)
        clip.setBoundsOrigin(.zero)
        // The window loses the focus.
        #expect(try rest(on: "Plan]]") != nil)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(view.extras.linkHover == nil)
        // Another note.
        #expect(try rest(on: "Plan]]") != nil)
        controller.load("Notes/Other.md")
        #expect(view.extras.linkHover == nil && !view.subviews.contains { $0 is LinkCardView })
        try open(Self.linkNote)
        // The head is the card's top; a click there opens the note, a click in the body does nothing.
        let card = try #require(try rest(on: "Plan]]"))
        #expect(card.isHead(NSPoint(x: 20, y: 10)) && !card.isHead(NSPoint(x: 20, y: 60)))
        #expect(card.hitTest(NSPoint(x: card.frame.midX, y: card.frame.maxY - 5)) === card)
        view.openLinkCard()
        #expect(opened == ["Notes/Work/Plan.md"] && view.extras.linkHover == nil)
        // A link to no note opens nothing.
        #expect(try rest(on: "Nowhere") != nil)
        view.openLinkCard()
        #expect(opened.count == 1)
        view.closeLinkCard()
    }

    @Test func theCardWaitsForThePointerToRestAndGoesAfterItLeft() async throws {
        try open(Self.linkNote)
        view.hoverLink(at: try point(on: "Plan]]"))
        #expect(view.extras.linkHover != nil && view.extras.linkHover?.view == nil)
        // Not yet at 150 ms; there after 350.
        try await Task.sleep(for: .milliseconds(150))
        #expect(view.extras.linkHover?.view == nil)
        try await Task.sleep(for: .milliseconds(350))
        let card = try #require(view.extras.linkHover?.view)
        // The pointer on the card keeps it; off both, it goes 250 ms later.
        view.hoverLink(at: try point(on: "Top words"))
        view.hoverLink(at: NSPoint(x: card.frame.midX, y: card.frame.midY))
        try await Task.sleep(for: .milliseconds(400))
        #expect(view.extras.linkHover?.view === card)
        view.hoverLink(at: nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(view.extras.linkHover?.view === card)
        try await Task.sleep(for: .milliseconds(300))
        #expect(view.extras.linkHover == nil && card.superview == nil)
        // The pointer that goes off the link before the rest is over shows nothing.
        view.hoverLink(at: try point(on: "Plan]]"))
        view.hoverLink(at: try point(on: "Top words"))
        try await Task.sleep(for: .milliseconds(450))
        #expect(view.extras.linkHover == nil)
    }

    // MARK: Pictures

    /// The editor with the slash bar, focus mode and a link's card, as pictures, to look at.
    @Test(.enabled(if: barsPicture != nil)) func picture() throws {
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            window.appearance = NSAppearance(named: appearance)
            try open("# Focus\n\n" + Self.focusNote + "\n```swift\nlet a = 1\n```\n\nSee ==this== and **that**.\n")
            store.settings.focusMode = true
            caret(in: "A task")
            try snapshot("focus-\(name)")
            store.settings.focusMode = false
            controller.followWritingModes()
            try open("# Slash\n\nSome words before the list.\n\n")
            end()
            type("/")
            key(Self.down)
            try snapshot("slash-\(name)")
            type("ca")
            try snapshot("slash-query-\(name)")
            view.closeSlashBar()
            try open(Self.linkNote)
            _ = try rest(on: "Plan]]")
            try snapshot("card-\(name)")
            _ = try rest(on: "what is next")
            try snapshot("card-heading-\(name)")
            view.closeLinkCard()
            _ = try rest(on: "Nowhere")
            try snapshot("card-missing-\(name)")
            view.closeLinkCard()
        }
    }
}
