import AppKit
import DaftarCore
import Foundation
import SwiftUI
import Testing
import WebKit

@testable import DaftarUI

/// The reader drawing a note again, in a real web view on a made-up vault:
/// a change on disk draws only the blocks that changed, and the addresses
/// and numbers the app finds after the note is on screen still become links.
@MainActor
@Suite(.serialized) struct ReaderRedrawTests {
    let root: URL
    let store: VaultStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-redraw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = VaultStore(settings: AppSettings(url: root.appending(path: "config/config.toml")), openVault: false)
    }

    /// A heading, sixty paragraphs (paragraph n on line 2n), a code block on
    /// lines 122 to 124 and a task on line 126.
    func note(top: String = "First paragraph.") -> String {
        "# Long\n\n\(top)\n\n" + (2...60).map { "Paragraph \($0)." }.joined(separator: "\n\n")
            + "\n\n```swift\nlet x = 1\n```\n\n- [ ] the task\n"
    }

    func page(_ path: String) async throws -> (WKWebView, NSWindow) {
        var web: WKWebView?
        let reader = ReaderView(
            request: ReaderRequest(path: path), store: store, revision: store.revision, onOpen: { _, _, _ in }, onTag: { _ in },
            onView: { web = $0 })
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Redraw(reader: reader, store: store).environment(store))
        window.orderBack(nil)
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(150))
            if let web, try await web.evaluateJavaScript("!!document.querySelector('#note h1') && window.innerHeight > 0") as? Bool == true {
                return (web, window)
            }
        }
        throw CancellationError()
    }

    /// The reader with the store's revision read where it is made, as `NotePane` has it.
    struct Redraw: View {
        var reader: ReaderView
        var store: VaultStore
        var body: some View {
            var reader = reader
            reader.revision = store.revision
            return reader
        }
    }

    func run(_ web: WKWebView, _ script: String) async throws -> String {
        "\(try await web.evaluateJavaScript(script) ?? "")"
    }

    @Test func aChangeOnDiskDrawsOnlyTheBlocksThatChanged() async throws {
        try note().write(to: root.appending(path: "Long.md"), atomically: true, encoding: .utf8)
        store.openSynchronously(root)
        let (web, window) = try await page("Long.md")
        defer { window.orderOut(nil) }
        // Each block below the change is marked, to tell it is the same element after.
        _ = try await run(web, """
            document.querySelector('#note > .code-block').kept = 'code';
            [...document.querySelectorAll('#note > p')].find((p) => p.textContent === 'Paragraph 40.').kept = 'p40';
            document.querySelector('#note > ul').kept = 'list';
            window.scrollTo(0, 900); 1
            """)
        try await Task.sleep(for: .milliseconds(200))
        let shown = "String(Math.round([...document.querySelectorAll('#note > *')].find((el) => el.getBoundingClientRect().bottom > 0).getBoundingClientRect().top))"
        let first = "[...document.querySelectorAll('#note > *')].find((el) => el.getBoundingClientRect().bottom > 0).textContent"
        let before = (try await run(web, first), try await run(web, shown), Double(try await run(web, "window.scrollY")) ?? 0)
        // Four lines in place of one, near the top: everything below is three lines down.
        try note(top: "First paragraph, changed\nover two lines.\n\nAnd one more.").write(to: root.appending(path: "Long.md"), atomically: true, encoding: .utf8)
        store.noteChanged("Long.md")
        for _ in 0..<40 where try await run(web, "String(document.querySelector('#note').textContent.includes('And one more.'))") != "true" {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(try await run(web, "document.querySelector('#note > .code-block').kept") == "code")
        #expect(try await run(web, "[...document.querySelectorAll('#note > p')].find((p) => p.textContent === 'Paragraph 40.').kept") == "p40")
        #expect(try await run(web, "document.querySelector('#note > ul').kept") == "list")
        // Their file lines moved with the text: a tick goes to the task's new line.
        #expect(try await run(web, "document.querySelector('#note > ul > li').dataset.line") == "129")
        #expect(try await run(web, "document.querySelector('#note input.task-list-item-checkbox').dataset.line") == "129")
        #expect(try await run(web, "[...document.querySelectorAll('#note > p')].find((p) => p.textContent === 'Paragraph 40.').dataset.line") == "83")
        // The text being read stays where it is: the page moved down by
        // what was added above it (WebKit has no scroll anchoring).
        #expect(try await run(web, first) == before.0)
        #expect(try await run(web, shown) == before.1)
        #expect((Double(try await run(web, "window.scrollY")) ?? 0) > before.2)
    }

    /// The numbers are found after the note is drawn, and linked then.
    @Test func aNumberFoundAfterTheNoteIsDrawnBecomesALink() async throws {
        try "# Call\n\nRing +34 612 345 678 today.\n".write(to: root.appending(path: "Call.md"), atomically: true, encoding: .utf8)
        store.openSynchronously(root)
        let (web, window) = try await page("Call.md")
        defer { window.orderOut(nil) }
        for _ in 0..<40 where try await run(web, "String(!!document.querySelector('#note a.detected-phone'))") != "true" {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(try await run(web, "document.querySelector('#note a.detected-phone').textContent") == "+34 612 345 678")
    }

    /// A page made ahead goes to the next reader of its store, loaded, and to no other store's.
    @Test func aReaderTakesAPageMadeAhead() async throws {
        store.openSynchronously(root)
        let pages = ReaderPages()
        pages.ahead = true
        _ = pages.take(store: store)
        let other = VaultStore(settings: AppSettings(url: root.appending(path: "other/config.toml")), openVault: false)
        // The spare is made two seconds after a take, then loads.
        try await Task.sleep(for: .seconds(3))
        #expect(!pages.take(store: other).spare)
        var taken = pages.take(store: store)
        for _ in 0..<40 where !taken.spare {
            try await Task.sleep(for: .milliseconds(250))
            taken = pages.take(store: store)
        }
        #expect(taken.spare && taken.bridge.ready)
        #expect(try await taken.view.evaluateJavaScript("typeof daftar") as? String == "object")
    }
}
