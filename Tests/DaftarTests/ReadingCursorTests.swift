import AppKit
import DaftarCore
import Foundation
import SwiftUI
import Testing
import WebKit

@testable import DaftarUI

/// The reader's cursor in a real web view, on a made-up note: a band on
/// the line being read in a long paragraph, the file line it tells the app,
/// and a scroll that brings the cursor to what is on screen.
@MainActor
@Suite(.serialized) struct ReadingCursorTests {
    let root: URL
    let store: VaultStore
    /// Each file line the reader told the app, in order.
    final class Lines { var all: [Int] = [] }
    let lines = Lines()

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-reading-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let words = (1...40).map { "word\($0)" }.joined(separator: " ")
        // Line 2 starts a paragraph of three file lines, each longer than the page is wide.
        let note = "# Long\n\n\(words) first\n\(words) second\n\(words) third\n\nShort one.\n\n"
            + (1...60).map { "Paragraph \($0)." }.joined(separator: "\n\n") + "\n"
        try note.write(to: root.appending(path: "Long.md"), atomically: true, encoding: .utf8)
        store = VaultStore(settings: AppSettings(url: root.appending(path: "config/config.toml")), openVault: false)
        store.openSynchronously(root)
    }

    func page() async throws -> (WKWebView, NSWindow) {
        var web: WKWebView?
        let lines = self.lines
        let reader = ReaderView(
            request: ReaderRequest(path: "Long.md"), store: store, onOpen: { _, _, _ in }, onTag: { _ in },
            onCursor: { lines.all.append($0) }, onView: { web = $0 })
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: reader.environment(store))
        window.orderBack(nil)
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(150))
            if let web, try await web.evaluateJavaScript("!!document.querySelector('#reading-cursor')") as? Bool == true { return (web, window) }
        }
        throw CancellationError()
    }

    func run(_ web: WKWebView, _ script: String) async throws -> String {
        "\(try await web.evaluateJavaScript(script) ?? "")"
    }

    func key(_ web: WKWebView, _ key: String) async throws {
        _ = try await run(web, "document.dispatchEvent(new KeyboardEvent('keydown', { key: '\(key)' })); 1")
        try await Task.sleep(for: .milliseconds(60))
    }

    /// Whether the band shows, and its top on the page.
    func band(_ web: WKWebView) async throws -> (on: Bool, top: Double) {
        let on = try await run(web, "document.querySelector('#reading-line').classList.contains('is-on')") == "1"
        let top = Double(try await run(web, "parseFloat(document.querySelector('#reading-line').style.top)")) ?? -1
        return (on, top)
    }

    @Test func aLongParagraphIsReadALineAtATime() async throws {
        let (web, window) = try await page()
        defer { window.orderOut(nil) }
        // The heading, then the long paragraph's first line.
        try await key(web, "g")
        try await key(web, "j")
        let first = try await band(web)
        #expect(first.on)
        #expect(lines.all.last == 2)
        // A line down: the band moves down, still in the paragraph.
        try await key(web, "j")
        let second = try await band(web)
        #expect(second.on && second.top > first.top)
        #expect(lines.all.last == 2)
        // On down to the second file line of the paragraph.
        var guard_ = 0
        while lines.all.last == 2, guard_ < 10 {
            try await key(web, "j")
            guard_ += 1
        }
        #expect(lines.all.last == 3)
        // Past its last line: the short paragraph, one line, with no band.
        while lines.all.last ?? 0 < 6, guard_ < 30 {
            try await key(web, "j")
            guard_ += 1
        }
        #expect(lines.all.last == 6)
        #expect(try await band(web).on == false)
        // Back up: the long paragraph's last line, of the third file line.
        try await key(web, "k")
        #expect(lines.all.last == 4)
        #expect(try await band(web).on)
    }

    @Test func aScrollBringsTheCursorToTheScreen() async throws {
        let (web, window) = try await page()
        defer { window.orderOut(nil) }
        try await key(web, "g")
        lines.all = []
        _ = try await run(web, "window.scrollTo(0, 1500); 1")
        for _ in 0..<20 where lines.all.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        // A paragraph far down: the editor opens there, not at the top.
        #expect((lines.all.last ?? 0) > 20)
        let top = Double(try await run(web, "parseFloat(document.querySelector('#reading-cursor').style.top) - window.scrollY")) ?? -1
        #expect(top >= 0 && top < 600)
    }

    @Test func noBandWhenTheSettingIsZero() async throws {
        store.settings.readingLine = 0
        let (web, window) = try await page()
        defer { window.orderOut(nil) }
        try await key(web, "g")
        try await key(web, "j")
        #expect(lines.all.last == 2)
        #expect(try await band(web).on == false)
        // A paragraph at a time.
        try await key(web, "j")
        #expect(lines.all.last == 6)
    }
}
