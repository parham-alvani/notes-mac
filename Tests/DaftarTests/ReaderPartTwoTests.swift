import AppKit
import DaftarCore
import Foundation
import Observation
import SwiftUI
import Testing
import WebKit

@testable import DaftarUI

/// The reader's parts of the look's part 2, in a real web view on a made-up
/// vault: the section bar, a table's header that stays and its sort, the
/// footnote's card, a link's card and the change between two notes
/// (`docs/specs/look.md` in notes-linux).
@MainActor
@Suite(.serialized) struct ReaderPartTwoTests {
    let root: URL
    let store: VaultStore

    /// `# A`, `## B`, `### C` and `## D`, each with paragraphs enough to scroll.
    static let sections: String = {
        let body = { (name: String) in (1...14).map { "\(name) paragraph \($0)." }.joined(separator: "\n\n") }
        return "# A\n\n\(body("A"))\n\n## B\n\n\(body("B"))\n\n### C\n\n\(body("C"))\n\n## D\n\n\(body("D"))\n"
    }()

    /// A table of forty rows between two long runs of paragraphs, and a small one after it.
    static let tables: String = {
        let rows = (1...40).map { "| item \($0) | \(($0 * 37) % 41) |" }.joined(separator: "\n")
        let tail = (1...30).map { "After \($0)." }.joined(separator: "\n\n")
        return "Before.\n\n| Name | Count |\n| --- | --- |\n\(rows)\n\n\(tail)\n\n| Word | Size |\n| --- | --- |\n| b | 10 |\n| A | 9 |\n| c | 100 |\n"
    }()

    init() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "daftar-part2-\(UUID().uuidString)")
        self.root = root
        try FileManager.default.createDirectory(at: root.appending(path: "Work"), withIntermediateDirectories: true)
        let write = { (name: String, text: String) in try text.write(to: root.appending(path: name), atomically: true, encoding: .utf8) }
        try write("Sections.md", Self.sections)
        try write("Tables.md", Self.tables)
        try write("Notes.md", "Text with a note[^1] and one more[^two].\n\nSee [[Plan]], [[Plan#Next]], [[Nowhere]] and [[Empty]].\n\n[^1]: The note.\n[^two]: The second, with [[Plan]].\n")
        try write("Work/Plan.md", "---\ntags: [a]\n---\n# Plan\n\n" + (1...20).map { "l\($0)" }.joined(separator: "\n\n") + "\n\n## Next\n\nThe next step.\n\n## Later\n\nNot yet.\n")
        try write("Empty.md", "---\ntags: [a]\n---\n")
        // Two parents that fit the bar by themselves, and leave no room for the last heading.
        let long = { (name: String) in "\(name) heading with a longer name" }
        try write("Deep.md", "# \(long("First"))\n\n## \(long("Second"))\n\n### The place that is being read\n\n" + (1...40).map { "Deep \($0)." }.joined(separator: "\n\n") + "\n")
        try write("One.md", "- [ ] one\n\n" + (1...30).map { "One \($0)." }.joined(separator: "\n\n") + "\n")
        try write("Two.md", "- [ ] two\n\nTwo.\n")
        store = VaultStore(settings: AppSettings(url: root.appending(path: "config/config.toml")), openVault: false)
        store.openSynchronously(root)
    }

    /// The note the page shows, changed by a test as a pane changes it.
    @Observable final class Shown {
        var request: ReaderRequest
        init(_ path: String) { request = ReaderRequest(path: path) }
    }

    struct Pane: View {
        var shown: Shown
        var store: VaultStore
        var onView: (WKWebView) -> Void
        var body: some View {
            ReaderView(request: shown.request, store: store, revision: store.revision, onOpen: { _, _, _ in }, onTag: { _ in }, onView: onView)
        }
    }

    func page(_ path: String) async throws -> (WKWebView, NSWindow, Shown) {
        var web: WKWebView?
        let shown = Shown(path)
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Pane(shown: shown, store: store, onView: { web = $0 }).environment(store))
        window.orderBack(nil)
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(150))
            if let web, try await web.evaluateJavaScript("!!document.querySelector('#note .inline-title') && window.innerHeight > 0") as? Bool == true {
                return (web, window, shown)
            }
        }
        throw CancellationError()
    }

    func run(_ web: WKWebView, _ script: String) async throws -> String {
        "\(try await web.evaluateJavaScript(script) ?? "")"
    }

    /// Waits until [script] is "true", for at most four seconds.
    func until(_ web: WKWebView, _ script: String) async throws -> Bool {
        for _ in 0..<40 {
            if try await run(web, "String(\(script))") == "true" { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Scrolls so the element [selector] finds has its top at [top] in the view.
    func scroll(_ web: WKWebView, _ selector: String, top: Int = 40) async throws {
        _ = try await run(web, "window.scrollTo(0, \(selector).getBoundingClientRect().top + window.scrollY - \(top)); 1")
        try await Task.sleep(for: .milliseconds(250))
    }

    static let barOn = "!!document.querySelector('#section-bar.is-on')"
    static let path = "[...document.querySelectorAll('#section-bar .section-crumb')].filter((c) => !c.hidden).map((c) => c.textContent).join(' › ')"
    static let heading = { (text: String) in "[...document.querySelectorAll('#note > [data-heading]')].find((h) => h.dataset.heading === '\(text)')" }

    @Test func theSectionBarIsTheHeadingPath() async throws {
        let (web, window, _) = try await page("Sections.md")
        defer { window.orderOut(nil) }
        // At the top of the note there is no bar.
        #expect(try await run(web, "String(\(Self.barOn))") == "false")
        // Under C, with C gone from the view: A › B › C.
        try await scroll(web, Self.heading("C"), top: -200)
        #expect(try await until(web, Self.barOn))
        #expect(try await run(web, Self.path) == "A › B › C")
        // The reading progress line is at the bar's bottom edge.
        #expect(try await run(web, "String(Math.round(document.getElementById('progress').getBoundingClientRect().bottom))") == "28")
        #expect(try await run(web, "String(Math.round(document.getElementById('section-bar').getBoundingClientRect().height))") == "28")
        // Under D: A › D.
        try await scroll(web, Self.heading("D"), top: -200)
        #expect(try await until(web, "\(Self.path) === 'A › D'"))
        // A heading that is still in the view has no bar over it.
        try await scroll(web, Self.heading("D"), top: 50)
        #expect(try await until(web, "!\(Self.barOn)"))
        // A click on a parent goes to it, and the reading cursor with it; the bar takes no focus.
        try await scroll(web, Self.heading("C"), top: -200)
        #expect(try await until(web, "\(Self.path) === 'A › B › C'"))
        _ = try await run(web, "document.querySelectorAll('#section-bar .section-crumb')[1].click(); 1")
        #expect(try await until(web, "Math.abs(\(Self.heading("B")).getBoundingClientRect().top - 36) < 2"))
        #expect(try await run(web, "String(document.activeElement === document.body || document.activeElement === null)") == "true")
        #expect(try await until(web, "!\(Self.barOn)"))
    }

    @Test func aPathTooWideLeavesParentsOutAndKeepsTheLastHeading() async throws {
        let (web, window, _) = try await page("Deep.md")
        defer { window.orderOut(nil) }
        try await scroll(web, Self.heading("The place that is being read"), top: -200)
        #expect(try await until(web, Self.barOn))
        // The last heading shows whole; parents are left out from the start, with `…` there.
        let last = "document.querySelector('#section-bar .section-crumb.is-last')"
        #expect(try await run(web, "\(last).textContent") == "The place that is being read")
        #expect(try await run(web, "String(!\(last).hidden && \(last).scrollWidth <= \(last).clientWidth + 1 && \(last).clientWidth > 40)") == "true")
        #expect(try await run(web, "String(document.querySelector('#section-bar .section-crumb').hidden)") == "true")
        #expect(try await run(web, "String(document.querySelector('#section-bar .section-dots').hidden)") == "false")
        #expect(try await run(web, Self.path) == "Second heading with a longer name › The place that is being read")
        // Nothing of the path is outside the bar's line.
        #expect(try await run(web, "String((() => { const line = document.querySelector('#section-bar .section-path'); return line.scrollWidth <= line.clientWidth + 1; })())") == "true")
    }

    @Test func aFoldedSectionAndTheSettingLeaveTheBarOut() async throws {
        let (web, window, _) = try await page("Sections.md")
        defer { window.orderOut(nil) }
        // B folded: C is folded away, so under D the place is A › D, and C is in no path.
        _ = try await run(web, "\(Self.heading("B")).querySelector('.fold-toggle').click(); 1")
        try await scroll(web, Self.heading("D"), top: -200)
        #expect(try await until(web, "\(Self.path) === 'A › D'"))
        // `appearance.section_bar = false`: no bar anywhere.
        store.settings.sectionBar = false
        store.noteChanged("Sections.md")
        #expect(try await until(web, "!\(Self.barOn)"))
        try await scroll(web, Self.heading("D"), top: -300)
        #expect(try await run(web, "String(\(Self.barOn))") == "false")
    }

    static let firstTable = "document.querySelector('#note table:not(.properties)')"
    static let lastTable = "[...document.querySelectorAll('#note table:not(.properties)')].at(-1)"
    static let words = "[...\(lastTable).tBodies[0].rows].map((r) => r.cells[0].textContent).join(',')"

    @Test func aColumnSortsByNumbersOrByText() async throws {
        let (web, window, _) = try await page("Tables.md")
        defer { window.orderOut(nil) }
        let before = try String(contentsOf: root.appending(path: "Tables.md"), encoding: .utf8)
        let click = { (column: Int) in "\(Self.lastTable).tHead.rows[0].cells[\(column)].click(); 1" }
        #expect(try await run(web, Self.words) == "b,A,c")
        // By text, capital and small letters as the same; the mark is after the header's text.
        _ = try await run(web, click(0))
        #expect(try await run(web, Self.words) == "A,b,c")
        #expect(try await run(web, "\(Self.lastTable).tHead.rows[0].cells[0].querySelector('.sort-mark').textContent") == "↑")
        #expect(try await run(web, "\(Self.lastTable).tHead.rows[0].cells[0].getAttribute('aria-sort')") == "ascending")
        // Another column starts at the first: by the number.
        _ = try await run(web, click(1))
        #expect(try await run(web, Self.words) == "A,b,c")
        #expect(try await run(web, "String(\(Self.lastTable).querySelectorAll('.sort-mark').length)") == "1")
        _ = try await run(web, click(1))
        #expect(try await run(web, Self.words) == "c,b,A")
        #expect(try await run(web, "\(Self.lastTable).tHead.rows[0].cells[1].querySelector('.sort-mark').textContent") == "↓")
        // The sort lasts through a redraw of the same note, while the header texts are the same.
        try (before + "\nOne more line.\n").write(to: root.appending(path: "Tables.md"), atomically: true, encoding: .utf8)
        store.noteChanged("Tables.md")
        #expect(try await until(web, "document.querySelector('#note').textContent.includes('One more line.')"))
        #expect(try await run(web, Self.words) == "c,b,A")
        // A row changed in the file draws the table again: the sort is put back on it.
        try (before.replacingOccurrences(of: "| A | 9 |", with: "| A | 900 |")).write(to: root.appending(path: "Tables.md"), atomically: true, encoding: .utf8)
        store.noteChanged("Tables.md")
        #expect(try await until(web, "document.querySelector('#note').textContent.includes('900')"))
        #expect(try await run(web, Self.words) == "A,c,b")
        // The third click gives the file's order, with no mark.
        _ = try await run(web, click(1))
        #expect(try await run(web, Self.words) == "b,A,c")
        #expect(try await run(web, "String(\(Self.lastTable).querySelectorAll('.sort-mark').length)") == "0")
        // A view only: nothing was written by a sort.
        #expect(try String(contentsOf: root.appending(path: "Tables.md"), encoding: .utf8) == before.replacingOccurrences(of: "| A | 9 |", with: "| A | 900 |"))
    }

    static let headOn = "!!document.querySelector('#table-head.is-on')"

    @Test func aTablesHeaderStaysWhileItsRowsAreRead() async throws {
        let (web, window, _) = try await page("Tables.md")
        defer { window.orderOut(nil) }
        #expect(try await run(web, "String(\(Self.headOn))") == "false")
        // Row 20 at the top of the view: the header row is drawn there, with the header's words.
        try await scroll(web, "\(Self.firstTable).tBodies[0].rows[19]", top: 60)
        #expect(try await until(web, Self.headOn))
        #expect(try await run(web, "[...document.querySelectorAll('#table-head th')].map((c) => c.textContent).join(',')") == "Name,Count")
        #expect(try await run(web, "String(Math.round(document.getElementById('table-head').getBoundingClientRect().top))") == "0")
        // Each copied cell is as wide as the cell it stands for, and stands over it.
        #expect(try await run(web, "String([...document.querySelectorAll('#table-head th')].every((c, i) => { const o = \(Self.firstTable).tHead.rows[0].cells[i].getBoundingClientRect(), r = c.getBoundingClientRect(); return Math.abs(o.width - r.width) < 1 && Math.abs(o.left - r.left) < 1.5; }))") == "true")
        // A click on the header that stays sorts the table.
        _ = try await run(web, "document.querySelectorAll('#table-head th')[1].click(); 1")
        #expect(try await run(web, "\(Self.firstTable).tBodies[0].rows[0].textContent.replace(/\\s+/g, ' ').trim()") == "item 10 1")
        #expect(try await until(web, "document.querySelector('#table-head .sort-mark')?.textContent === '↑'"))
        // It leaves with the table's last row.
        try await scroll(web, "\(Self.firstTable).tBodies[0].rows[39]", top: -80)
        #expect(try await until(web, "!\(Self.headOn)"))
        // Back above the table there is none.
        _ = try await run(web, "window.scrollTo(0, 0); 1")
        #expect(try await until(web, "!\(Self.headOn)"))
    }

    static let cardOpen = "!!document.querySelector('.preview.is-open')"
    static let cardHead = "document.querySelector('.preview .preview-head').textContent"
    static let cardBody = "document.querySelector('.preview .preview-body').textContent.trim()"
    static let reference = { (at: Int) in "document.querySelectorAll('#note sup.footnote-ref a')[\(at)]" }

    @Test func aFootnoteShowsWhereItsReferenceIs() async throws {
        let (web, window, _) = try await page("Notes.md")
        defer { window.orderOut(nil) }
        // A click opens the card at once, and the page does not go to the footnote.
        _ = try await run(web, "\(Self.reference(0)).click(); 1")
        #expect(try await run(web, "String(\(Self.cardOpen))") == "true")
        #expect(try await run(web, Self.cardHead) == "Footnote 1")
        #expect(try await run(web, Self.cardBody) == "The note.")
        #expect(try await run(web, "String(window.scrollY)") == "0")
        #expect(try await run(web, "String(document.querySelector('.preview .footnote-backref') === null)") == "true")
        // The card takes no focus, and nothing in it is a Tab stop.
        #expect(try await run(web, "String(!document.querySelector('.preview').contains(document.activeElement))") == "true")
        // A second click on the reference closes it.
        _ = try await run(web, "\(Self.reference(0)).dispatchEvent(new MouseEvent('mousedown', { bubbles: true })); \(Self.reference(0)).click(); 1")
        #expect(try await run(web, "String(\(Self.cardOpen))") == "false")
        // Escape closes it too, and a key that is not Escape leaves a card a click opened.
        _ = try await run(web, "\(Self.reference(1)).click(); 1")
        #expect(try await run(web, Self.cardHead) == "Footnote 2")
        #expect(try await run(web, "String(document.querySelector('.preview .preview-body a.internal-link').getAttribute('tabindex'))") == "-1")
        _ = try await run(web, "document.dispatchEvent(new KeyboardEvent('keydown', { key: 'j', bubbles: true })); 1")
        #expect(try await run(web, "String(\(Self.cardOpen))") == "true")
        _ = try await run(web, "document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); 1")
        #expect(try await run(web, "String(\(Self.cardOpen))") == "false")
        // A click outside closes it.
        _ = try await run(web, "\(Self.reference(0)).click(); 1")
        _ = try await run(web, "document.querySelector('#note p').dispatchEvent(new MouseEvent('mousedown', { bubbles: true })); 1")
        #expect(try await run(web, "String(\(Self.cardOpen))") == "false")
        // Resting the pointer on the reference opens it after a moment, with the link preview off as well.
        store.settings.linkPreview = false
        store.noteChanged("Notes.md")
        try await Task.sleep(for: .milliseconds(400))
        _ = try await run(web, "\(Self.reference(0)).dispatchEvent(new MouseEvent('mouseover', { bubbles: true })); 1")
        #expect(try await run(web, "String(\(Self.cardOpen))") == "false")
        #expect(try await until(web, Self.cardOpen))
        #expect(try await run(web, Self.cardHead) == "Footnote 1")
        // A reference with no footnote opens nothing.
        _ = try await run(web, "document.dispatchEvent(new KeyboardEvent('keydown', { key: 'a', bubbles: true })); 1")
        _ = try await run(web, "(() => { const a = document.createElement('a'); a.href = '#fn99'; a.textContent = '[9]'; const sup = document.createElement('sup'); sup.className = 'footnote-ref'; sup.append(a); document.querySelector('#note p').append(sup); a.click(); return 1 })()")
        #expect(try await run(web, "String(\(Self.cardOpen))") == "false")
    }

    static let link = { (at: Int) in "document.querySelectorAll('#note a.internal-link')[\(at)]" }
    static let rest = { (at: Int) in "\(link(at)).dispatchEvent(new MouseEvent('mouseover', { bubbles: true })); 1" }
    static let anyKey = "document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Shift', bubbles: true })); 1"

    @Test func aLinksCardShowsTheNotesFirstLines() async throws {
        let (web, window, _) = try await page("Notes.md")
        defer { window.orderOut(nil) }
        // Resting on `[[Plan]]`: the title, the folder, and the first twelve lines with `…`.
        _ = try await run(web, Self.rest(0))
        #expect(try await run(web, "String(\(Self.cardOpen))") == "false")
        #expect(try await until(web, Self.cardOpen))
        #expect(try await run(web, "document.querySelector('.preview .preview-title').textContent") == "Plan")
        #expect(try await run(web, "document.querySelector('.preview .preview-path').textContent") == "Work")
        let body = try await run(web, "[...document.querySelectorAll('.preview .preview-body > *')].map((p) => p.textContent).join('|')")
        #expect(body == "l1|l2|l3|l4|l5|l6|…")
        // The card is 360 px wide, at most 240 px high, under the link and 6 px from it.
        #expect(try await run(web, "String(Math.round(document.querySelector('.preview').getBoundingClientRect().width))") == "360")
        #expect(try await run(web, "String(document.querySelector('.preview').getBoundingClientRect().height <= 240)") == "true")
        #expect(try await run(web, "String(Math.round(document.querySelector('.preview').getBoundingClientRect().top - \(Self.link(0)).getBoundingClientRect().bottom))") == "6")
        // Any key closes it at once.
        _ = try await run(web, Self.anyKey)
        #expect(try await run(web, "String(\(Self.cardOpen))") == "false")
        // `[[Plan#Next]]`: that section's lines, without its heading.
        _ = try await run(web, Self.rest(1))
        #expect(try await until(web, Self.cardOpen))
        #expect(try await run(web, "document.querySelector('.preview .preview-anchor').textContent") == "› Next")
        #expect(try await run(web, Self.cardBody) == "The next step.")
        _ = try await run(web, Self.anyKey)
        // A link to no note, and a note with no text.
        _ = try await run(web, Self.rest(2))
        #expect(try await until(web, Self.cardOpen))
        #expect(try await run(web, "document.querySelector('.preview .preview-title.is-missing').textContent") == "Nowhere")
        #expect(try await run(web, Self.cardBody) == "No note yet.")
        _ = try await run(web, Self.anyKey)
        _ = try await run(web, Self.rest(3))
        #expect(try await until(web, Self.cardOpen))
        #expect(try await run(web, Self.cardBody) == "The note is empty.")
        // A scroll of the note closes it.
        _ = try await run(web, "window.dispatchEvent(new Event('scroll')); 1")
        #expect(try await run(web, "String(\(Self.cardOpen))") == "false")
        // Not while a mouse button is down.
        _ = try await run(web, "\(Self.link(0)).dispatchEvent(new MouseEvent('mouseover', { bubbles: true, buttons: 1 })); 1")
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await run(web, "String(\(Self.cardOpen))") == "false")
        // `appearance.link_preview = false`: no card.
        store.settings.linkPreview = false
        store.noteChanged("Notes.md")
        try await Task.sleep(for: .milliseconds(400))
        _ = try await run(web, Self.rest(0))
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await run(web, "String(\(Self.cardOpen))") == "false")
    }

    @Test func theAppGivesACardOnlyANotesFirstLines() throws {
        let card = try #require(ReaderView.Coordinator.preview(of: "Work/Plan.md", anchor: "", in: store))
        #expect(card["title"] as? String == "Plan")
        #expect(card["text"] as? String == (1...6).map { "l\($0)" }.joined(separator: "\n\n") + "\n\n…")
        #expect(ReaderView.Coordinator.preview(of: "Work/Plan.md", anchor: "Later", in: store)?["text"] as? String == "Not yet.")
        // The links of those lines come with them.
        let notes = try #require(ReaderView.Coordinator.preview(of: "Notes.md", anchor: "", in: store))
        #expect((notes["links"] as? [String: String])?["Plan"] == "Work/Plan.md")
        // A file that is not in the vault, or is no note, has no card.
        #expect(ReaderView.Coordinator.preview(of: "Gone.md", anchor: "", in: store) == nil)
        #expect(ReaderView.Coordinator.preview(of: "../outside.md", anchor: "", in: store) == nil)
        #expect(ReaderView.Coordinator.preview(of: ".daftar.toml", anchor: "", in: store) == nil)
    }

    @Test func anotherNoteIsDrawnAtItsPlaceAndTheKeysAreNotLost() async throws {
        let (web, window, shown) = try await page("Sections.md")
        defer { window.orderOut(nil) }
        try await scroll(web, Self.heading("C"), top: -200)
        #expect(try await until(web, Self.barOn))
        // Another note: it is drawn from its top, with nothing of the note before.
        shown.request = ReaderRequest(path: "Tables.md")
        #expect(try await until(web, "document.querySelector('#note .inline-title')?.textContent === 'Tables'"))
        #expect(try await run(web, "String(window.scrollY)") == "0")
        #expect(try await until(web, "!\(Self.barOn)"))
        // A key right after the change moves the new note's reading cursor.
        _ = try await run(web, "document.dispatchEvent(new KeyboardEvent('keydown', { key: 'j', bubbles: true })); 1")
        #expect(try await until(web, "document.querySelector('#reading-cursor.is-on') !== null"))
        // Two changes one after the other end on the last note.
        shown.request = ReaderRequest(path: "Sections.md")
        shown.request = ReaderRequest(path: "Notes.md")
        #expect(try await until(web, "document.querySelector('#note .inline-title')?.textContent === 'Notes'"))
        try await Task.sleep(for: .milliseconds(600))
        #expect(try await run(web, "document.querySelector('#note .inline-title').textContent") == "Notes")
        #expect(try await run(web, "String(document.querySelectorAll('#note .inline-title').length)") == "1")
    }
}
