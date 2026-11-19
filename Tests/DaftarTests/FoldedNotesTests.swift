import AppKit
import DaftarCore
import Foundation
import SwiftUI
import Testing
import WebKit

@testable import DaftarUI

/// Notes that open folded, in a real web view on a made-up vault: a note the
/// person has not folded opens with every section shut and each heading
/// saying what it holds; a note they folded or opened opens as they left it
/// (`docs/specs/folded-sections.md` in notes-linux).
@MainActor
@Suite(.serialized) struct FoldedNotesTests {
    let root: URL
    let store: VaultStore

    static let note = """
        # Trip

        The plan of the week.

        ## Flights

        We fly on Monday morning from Barcelona and come back on Friday night.

        ### Seats

        Two by the window.

        ## Hotel

        One room.

        ## Empty

        """

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-folded-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.note.write(to: root.appending(path: "Trip.md"), atomically: true, encoding: .utf8)
        try "[reader]\nfolded = true\n".write(to: root.appending(path: ".daftar.toml"), atomically: true, encoding: .utf8)
        store = VaultStore(settings: AppSettings(url: root.appending(path: "config/config.toml")), openVault: false)
        store.openSynchronously(root)
    }

    func page() async throws -> (WKWebView, NSWindow) {
        var web: WKWebView?
        let reader = ReaderView(request: ReaderRequest(path: "Trip.md"), store: store, onOpen: { _, _, _ in }, onTag: { _ in }, onView: { web = $0 })
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: reader.environment(store))
        window.orderBack(nil)
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(150))
            if let web, try await web.evaluateJavaScript("!!document.querySelector('#note h2')") as? Bool == true { return (web, window) }
        }
        throw CancellationError()
    }

    func run(_ web: WKWebView, _ script: String) async throws -> String {
        "\(try await web.evaluateJavaScript(script) ?? "")"
    }

    /// The headings that are shut, by their text.
    static let shut = "[...document.querySelectorAll('#note > .is-folded')].map(h => h.dataset.heading).join('|')"

    @Test func theVaultSaysNotesOpenFoldedAndTheAppCanSayOtherwise() {
        #expect(store.vaultFolds)
        #expect(store.foldsSections)
        store.settings.foldSections = .never
        #expect(!store.foldsSections)
        store.settings.foldSections = .always
        #expect(store.foldsSections)
        store.settings.foldSections = .vault
        #expect(store.foldsSections)
    }

    @Test func aNoteNotFoldedByThePersonOpensWithEverySectionShut() async throws {
        let (web, window) = try await page()
        defer { window.orderOut(nil) }
        // Every heading that holds something; "Empty" holds nothing and has no fold.
        #expect(try await run(web, Self.shut) == "Trip|Flights|Seats|Hotel")
        // Under the first heading everything is away: only the note's own heading is on the page.
        #expect(try await run(web, "[...document.querySelectorAll('#note > [data-heading]:not(.folded-away)')].map(h => h.dataset.heading).join('|')") == "Trip")
        // The heading says how its text begins, how much is under it, and how many headings.
        #expect(try await run(web, "document.querySelector('#note > h1[data-heading] > .fold-hint').textContent") == "The plan of the week. · 24 words · 4 sections")
        // The hint is not the heading's name: a link to the heading is still to "Trip".
        #expect(try await run(web, "document.querySelector('#note > h1[data-heading]').dataset.heading") == "Trip")
    }

    @Test func openingASectionShowsTheNextLevelFoldedAndIsKept() async throws {
        let (web, window) = try await page()
        defer { window.orderOut(nil) }
        _ = try await run(web, "document.querySelector('#note > h1[data-heading] > .fold-toggle').click(); 1")
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await run(web, Self.shut) == "Flights|Seats|Hotel")
        #expect(try await run(web, "String(document.querySelector('#note > h1[data-heading] > .fold-hint') === null)") == "true")
        #expect(try await run(web, "[...document.querySelectorAll('#note > h2:not(.folded-away) > .fold-hint')].map(h => h.textContent).join('|')")
            == "We fly on Monday morning from Barcelona and come back on Friday… · 17 words · 1 section|One room.")
        // What the person did is kept for the note.
        for _ in 0..<20 where store.places.keptFolds("Trip.md") == nil { try await Task.sleep(for: .milliseconds(100)) }
        #expect(store.places.keptFolds("Trip.md").map(Set.init) == ["2:Flights", "3:Seats", "2:Hotel"])
    }

    @Test func aNoteThePersonOpenedWholeStaysOpen() async throws {
        store.places.setFolds("Trip.md", [], explicit: true)
        let (web, window) = try await page()
        defer { window.orderOut(nil) }
        #expect(try await run(web, Self.shut).isEmpty)
        #expect(try await run(web, "String(document.querySelectorAll('.fold-hint').length)") == "0")
    }

    @Test func whereNotesOpenUnfoldedNothingIsShut() async throws {
        store.settings.foldSections = .never
        let (web, window) = try await page()
        defer { window.orderOut(nil) }
        #expect(try await run(web, Self.shut).isEmpty)
    }
}
