import AppKit
import SwiftUI
import Testing

@testable import DaftarUI

@MainActor
@Suite struct WindowTests {
    @Test func everyWindowIsATabOfOneGroup() async throws {
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Color.clear.background(TabbedWindow()))
        try await Task.sleep(for: .milliseconds(200))
        #expect(window.tabbingMode == .preferred)
        #expect(window.tabbingIdentifier == "daftar.main")
    }

    @Test func eachTabRequestIsNew() throws {
        // The same note can be open in two tabs: two requests are never equal.
        #expect(TabRequest(path: "A.md") != TabRequest(path: "A.md"))
        let request = TabRequest(path: "Notes/A.md")
        let again = try JSONDecoder().decode(TabRequest.self, from: JSONEncoder().encode(request))
        #expect(again == request)
    }
}
