import AppKit
import DaftarCore
import Foundation
import SwiftUI
import Testing
import WebKit

@testable import DaftarUI

/// What the reader's page may do, in a real web view on a made-up vault:
/// where it may go, what it may ask the app for, and what a file of the
/// vault shown in it may run.
@MainActor
@Suite(.serialized) struct ReaderPageTests {
    let root: URL
    let store: VaultStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-page-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Tasks"), withIntermediateDirectories: true)
        try "# Page\n\nSome text.\n\n- [ ] here\n".write(to: root.appending(path: "Page.md"), atomically: true, encoding: .utf8)
        try "# Other\n\n- [ ] elsewhere\n".write(to: root.appending(path: "Tasks/Other.md"), atomically: true, encoding: .utf8)
        try "# Query\n\n```tasks\nnot done\npath includes Other\n```\n".write(to: root.appending(path: "Query.md"), atomically: true, encoding: .utf8)
        store = VaultStore(settings: AppSettings(url: root.appending(path: "config/config.toml")), openVault: false)
        store.openSynchronously(root)
    }

    func page(_ path: String = "Page.md") async throws -> (WKWebView, NSWindow) {
        var web: WKWebView?
        let reader = ReaderView(request: ReaderRequest(path: path), store: store, onOpen: { _, _, _ in }, onTag: { _ in }, onView: { web = $0 })
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: reader.environment(store))
        window.orderBack(nil)
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(150))
            if let web, try await web.evaluateJavaScript("!!document.querySelector('#note h1')") as? Bool == true { return (web, window) }
        }
        throw CancellationError()
    }

    func run(_ web: WKWebView, _ script: String) async throws -> String {
        "\(try await web.evaluateJavaScript(script) ?? "")"
    }

    /// The main frame is the reader's page and stays it: a note that got a
    /// `<meta http-equiv=refresh>` or a form past the renderer cannot leave
    /// the pane with a page that has no reader in it.
    @Test func thePageGoesNowhere() async throws {
        let (web, window) = try await page()
        defer { window.orderOut(nil) }
        for script in [
            "location.href = 'daftar://reader/reader.css'; 1",
            "location.href = 'daftar://reader/index.html'; 1",
            "location.href = 'https://example.org/'; 1",
            "location.reload(); 1",
            "(() => { const meta = document.createElement('meta'); meta.httpEquiv = 'refresh'; meta.content = '0;url=daftar://reader/reader.css'; document.getElementById('note').appendChild(meta); return 1 })()",
            "(() => { const form = document.createElement('form'); form.action = 'daftar://reader/reader.css'; document.body.appendChild(form); form.submit(); return 1 })()",
        ] {
            _ = try await run(web, "window.stayed = true; 1")
            _ = try await run(web, script)
            try await Task.sleep(for: .milliseconds(400))
            #expect(try await run(web, "location.href") == "daftar://reader/index.html", "\(script)")
            // The same document, not the page loaded again.
            #expect(try await run(web, "String(window.stayed === true && !!document.querySelector('#note h1'))") == "true", "\(script)")
        }
    }

    /// A `<base>` would send the page's own lazy loads (`mermaid.js`) to another site.
    @Test func aBaseElementChangesNoAddress() async throws {
        let (web, window) = try await page()
        defer { window.orderOut(nil) }
        _ = try await run(web, "(() => { const base = document.createElement('base'); base.href = 'https://example.org/'; document.head.appendChild(base); return 1 })()")
        #expect(try await run(web, "document.baseURI") == "daftar://reader/index.html")
    }

    private func other() throws -> String { try String(contentsOf: root.appending(path: "Tasks/Other.md"), encoding: .utf8) }

    /// A message from the page that names a task of another note is taken
    /// only when a query of this show listed that task: a note cannot tick
    /// a line of a file it does not show.
    @Test func thePageTicksAnotherNotesTaskOnlyFromAQueryResult() async throws {
        let (web, window) = try await page()
        defer { window.orderOut(nil) }
        let tick = "webkit.messageHandlers.daftar.postMessage({ kind: 'toggleTask', line: 2, status: ' ', path: 'Tasks/Other.md' }); 1"
        _ = try await run(web, tick)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try other().contains("- [ ] elsewhere"))
        // Its own task is its to tick.
        _ = try await run(web, "webkit.messageHandlers.daftar.postMessage({ kind: 'toggleTask', line: 4, status: ' ', path: '' }); 1")
        try await Task.sleep(for: .milliseconds(300))
        #expect(try String(contentsOf: root.appending(path: "Page.md"), encoding: .utf8).contains("- [x] here"))
        window.orderOut(nil)

        let (query, second) = try await page("Query.md")
        defer { second.orderOut(nil) }
        for _ in 0..<20 where try await run(query, "String(!!document.querySelector('.query-list input'))") != "true" {
            try await Task.sleep(for: .milliseconds(100))
        }
        // A line the query did not list is still refused.
        _ = try await run(query, "webkit.messageHandlers.daftar.postMessage({ kind: 'toggleTask', line: 0, status: ' ', path: 'Tasks/Other.md' }); 1")
        _ = try await run(query, "document.querySelector('.query-list input').click(); 1")
        try await Task.sleep(for: .milliseconds(300))
        #expect(try other().contains("- [x] elsewhere"))
    }

    @Test func thePageNamesOnlyWhatTheAppGaveIt() {
        var trust = PageTrust()
        #expect(trust.mayName(task: "A.md", line: 3, shown: "A.md"))
        #expect(!trust.mayName(task: "B.md", line: 3, shown: "A.md"))
        trust.tasks.insert(PageTrust.Task(path: "B.md", line: 3))
        #expect(trust.mayName(task: "B.md", line: 3, shown: "A.md"))
        #expect(!trust.mayName(task: "B.md", line: 4, shown: "A.md"))
        #expect(!trust.detected.contains(PageTrust.Found(kind: "phone", value: "+19005550100")))
    }

    /// A phone number is called only when the app found it in the note on screen.
    @Test func aNumberTheNoteDoesNotHoldIsNotCalled() async throws {
        try "# Call\n\nRing +34 612 345 678 today.\n".write(to: root.appending(path: "Call.md"), atomically: true, encoding: .utf8)
        store.openSynchronously(root)
        var coordinator: ReaderView.Coordinator?
        let reader = ReaderView(request: ReaderRequest(path: "Call.md"), store: store, onOpen: { _, _, _ in }, onTag: { _ in }, onView: { coordinator = $0.navigationDelegate as? ReaderView.Coordinator })
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: reader.environment(store))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<40 where coordinator?.trust.detected.isEmpty != false { try await Task.sleep(for: .milliseconds(150)) }
        let found = try #require(coordinator?.trust.detected)
        #expect(found.contains { $0.kind == "phone" })
        #expect(!found.contains(PageTrust.Found(kind: "phone", value: "+19005550100")))
    }
}
