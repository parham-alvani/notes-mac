import AppKit
import SwiftUI
import Testing

@testable import DaftarUI

/// One at a time: a window that takes a `TabbedWindow` sets the app's window
/// in front (`ActiveWindow.shared`), which the first test reads.
@MainActor
@Suite(.serialized) struct WindowTests {
    @Test func everyWindowIsATabOfOneGroup() async throws {
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let model = WindowModel()
        ActiveWindow.shared.model = nil
        window.contentView = NSHostingView(rootView: Color.clear.background(TabbedWindow(model: model)))
        try await until { window.tabbingIdentifier == "daftar.main" }
        #expect(window.tabbingMode == .preferred)
        #expect(window.tabbingIdentifier == "daftar.main")
        // With no other window, this one is the menus' target.
        #expect(ActiveWindow.shared.model === model)
        // Another window that comes to the front takes over.
        let other = WindowModel()
        let second = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        second.contentView = NSHostingView(rootView: Color.clear.background(TabbedWindow(model: other)))
        try await until { second.tabbingIdentifier == "daftar.main" }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: second)
        #expect(ActiveWindow.shared.model === other)
    }

    /// A new tab fills its sidebar and toolbar when the window is where it
    /// stays: the view is told so once, after the window took it.
    @Test func aWindowSaysOnceThatItSettled() async throws {
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        var settled = 0
        window.contentView = NSHostingView(rootView: Color.clear.background(TabbedWindow(model: WindowModel()) { settled += 1 }))
        try await until { settled > 0 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(settled == 1)
    }

    /// In full screen each window with a sidebar follows every move of the
    /// pointer to show the sidebar at the screen's edge. A tab that is not
    /// seen has that off, and gets it back when it is seen; what AppKit had
    /// off stays off.
    @Test func aWindowNotSeenDoesNotFollowThePointer() throws {
        let key = "revealsOnEdgeHoverInFullscreen"
        let split = NSSplitViewController()
        let sidebar = NSSplitViewItem(sidebarWithViewController: NSViewController())
        let content = NSSplitViewItem(viewController: NSViewController())
        for item in [sidebar, content] { item.viewController.view = NSView() }
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(content)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = split
        try #require(sidebar.responds(to: Selector(("setRevealsOnEdgeHoverInFullscreen:"))))
        sidebar.setValue(true, forKey: key)
        content.setValue(false, forKey: key)

        EdgeHover.set(false, in: window)
        #expect(sidebar.value(forKey: key) as? Bool == false)
        #expect(content.value(forKey: key) as? Bool == false)
        EdgeHover.set(true, in: window)
        #expect(sidebar.value(forKey: key) as? Bool == true)
        #expect(content.value(forKey: key) as? Bool == false)
    }

    /// Waits for the window to take its view, which a slow machine does late.
    private func until(_ done: () -> Bool) async throws {
        for _ in 0..<100 where !done() { try await Task.sleep(for: .milliseconds(50)) }
    }

    /// A page hides the inspector, and SwiftUI writes that back: the
    /// person's choice is kept for when a note is shown again.
    @Test func aPageDoesNotCloseTheInspector() {
        let model = WindowModel()
        #expect(model.inspectorShown)
        model.page = .jobs
        #expect(!model.inspectorShown)
        model.inspectorShown = false
        model.page = nil
        #expect(model.inspectorShown)
        model.inspectorShown = false
        #expect(!model.inspector)
    }

    @Test func eachTabRequestIsNew() throws {
        // The same note can be open in two tabs: two requests are never equal.
        #expect(TabRequest(path: "A.md") != TabRequest(path: "A.md"))
        let request = TabRequest(path: "Notes/A.md")
        let again = try JSONDecoder().decode(TabRequest.self, from: JSONEncoder().encode(request))
        #expect(again == request)
    }
}
