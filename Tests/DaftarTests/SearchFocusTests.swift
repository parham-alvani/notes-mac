import AppKit
import DaftarCore
import Foundation
import SwiftUI
import Testing

@testable import DaftarUI

/// Search in Vault (⇧⌘F) puts the cursor in the sidebar's search field.
@MainActor
@Suite(.serialized) struct SearchFocusTests {
    @Test func searchInVaultFocusesTheField() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "daftar-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# Note\n\nText.\n".write(to: root.appending(path: "Note.md"), atomically: true, encoding: .utf8)
        let store = VaultStore(settings: AppSettings(url: root.appending(path: "config/config.toml")), openVault: false)
        store.openSynchronously(root)
        let model = WindowModel()
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 1000, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingIdentifier = "daftar.main"
        window.contentView = NSHostingView(rootView: NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            Text("Detail")
        }.environment(store))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(800))
        model.searchRequests += 1
        try await Task.sleep(for: .milliseconds(300))
        // The field edits in a text view of its own, inside the field.
        let responder = window.firstResponder as? NSView
        #expect(responder.map { sequence(first: $0, next: \.superview).contains { $0 is NSSearchField } } == true)
    }
}
