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
        // Another Daftar window, opened first and so found first by a search of the app's windows:
        // the field focused must be the one of the window whose model was asked.
        let other = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.tabbingIdentifier = "daftar.main"
        other.contentView = NSHostingView(rootView: Text("Another window"))
        other.orderBack(nil)
        defer { other.orderOut(nil) }
        // The sidebar is in the window when its search field is: with every suite running at once
        // that takes seconds, and a request made before the sidebar is there is heard by no one.
        func hasField(_ view: NSView) -> Bool { view is NSSearchField || view.subviews.contains(where: hasField) }
        for _ in 0..<200 where !(window.contentView?.superview.map(hasField) ?? false) { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(200))
        model.searchRequests += 1
        // The field edits in a text view of its own, inside the field. With every suite running at
        // once the window gets its search field late: the request waits for it, and so does the test.
        func focused() -> Bool {
            (window.firstResponder as? NSView).map { sequence(first: $0, next: \.superview).contains { $0 is NSSearchField } } == true
        }
        for _ in 0..<60 where !focused() { try await Task.sleep(for: .milliseconds(50)) }
        #expect(focused())
        #expect((other.firstResponder as? NSView) == nil)
    }
}
