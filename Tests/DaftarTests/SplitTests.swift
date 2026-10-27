import AppKit
import DaftarCore
import Foundation
import SwiftUI
import Testing
import WebKit

@testable import DaftarUI

/// Two notes side by side: the panes of one window, on a made-up vault.
@MainActor
@Suite(.serialized) struct SplitTests {
    let root: URL
    let store: VaultStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-split-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["A", "B", "C"] {
            try "# \(name)\n\nSee [[A]].\n".write(to: root.appending(path: "\(name).md"), atomically: true, encoding: .utf8)
        }
        store = VaultStore(settings: AppSettings(url: root.appending(path: "config/config.toml")), openVault: false)
        store.openSynchronously(root)
    }

    @Test func splitShowsTheSameNoteBesideItWithTheFocus() {
        let model = WindowModel()
        model.open("A.md", store: store)
        model.editing = true
        let first = model.focused
        model.toggleSplit()
        #expect(model.isSplit)
        #expect(model.focused !== first)
        #expect(model.path == "A.md" && !model.editing)
        // The new pane has a history of its own.
        #expect(!model.canGoBack)
        #expect(first.editing)
        model.toggleSplit()
        #expect(!model.isSplit)
    }

    @Test func homeShowsTheHomePageAndBackReturnsToTheNote() {
        let model = WindowModel()
        model.open("A.md", store: store)
        model.editing = true
        model.goHome()
        #expect(model.showsHome)
        #expect(model.path == nil && !model.editing)
        model.goBack()
        #expect(model.path == "A.md")
        // From a page, too: the home page replaces Today.
        model.showsToday = true
        #expect(!model.showsHome)
        model.goHome()
        #expect(model.showsHome && !model.showsToday)
    }

    @Test func aLinkOpensInTheOtherPaneAndTheFocusStays() {
        let model = WindowModel()
        model.open("A.md", store: store)
        let first = model.focused
        model.openInOtherPane("B.md", heading: "B", store: store)
        #expect(model.isSplit)
        #expect(model.focused === first && model.path == "A.md")
        let other = try! #require(model.other(than: first))
        #expect(other.path == "B.md" && other.request?.heading == "B")
        // Again: the same other pane, not a third one.
        model.openInOtherPane("C.md", store: store)
        #expect(model.panes.count == 2 && other.path == "C.md")
        other.goBack()
        #expect(other.path == "B.md")
        #expect(model.recent.prefix(2) == ["C.md", "B.md"])
    }

    @Test func theCommandsActOnTheFocusedPane() {
        let model = WindowModel()
        model.open("A.md", store: store)
        let first = model.focused
        let second = model.split()
        model.open("B.md", store: store)
        #expect(second.path == "B.md" && first.path == "A.md")
        model.editing = true
        #expect(second.editing && !first.editing)
        model.focus(first)
        #expect(model.path == "A.md" && !model.editing)
        model.open("C.md", store: store)
        model.goBack()
        #expect(first.path == "A.md" && second.path == "B.md")
        model.goForward()
        #expect(first.path == "C.md")
        // A pane that is not the window's is never focused.
        model.focus(NotePane())
        #expect(model.focused === first)
    }

    @Test func closingTheSplitKeepsTheFocusedNote() {
        let model = WindowModel()
        model.open("A.md", store: store)
        let second = model.split()
        model.open("B.md", store: store)
        model.closeSplit()
        #expect(model.panes.count == 1 && model.focused === second)
        #expect(model.path == "B.md")
        // With its own history: it opened on A, then went to B.
        model.goBack()
        #expect(model.path == "A.md")
        model.goForward()
        // The close button of one pane keeps the other one.
        model.open("C.md", store: store)
        let third = model.split()
        model.close(third)
        #expect(model.panes.map(\.path) == ["C.md"] && model.focused === second)
    }

    @Test func inNeovimModeOnlyOnePaneEdits() {
        let model = WindowModel()
        model.oneEditor = true
        model.open("A.md", store: store)
        model.editing = true
        let first = model.focused
        let second = model.split()
        model.editing = true
        #expect(second.editing && !first.editing)
        model.oneEditor = false
        model.focus(first)
        model.editing = true
        #expect(first.editing && second.editing)
    }

    @Test func bothPanesFollowAMoveAndADelete() {
        let model = WindowModel()
        model.open("A.md", store: store)
        let second = model.split()
        model.open("B.md", store: store)
        model.follow(["A.md": "Old/A.md"])
        #expect(model.panes.map(\.path) == ["Old/A.md", "B.md"])
        model.forget("B.md")
        #expect(second.path == nil)
        #expect(model.panes[0].path == "Old/A.md")
    }

    /// The same note in the editor of both panes: an edit saved in one is
    /// in the other when it gets the focus, and never over text typed there.
    @Test func twoEditorsOnOneNoteDoNotFight() throws {
        func editor() -> (EditorController, NoteTextView) {
            let controller = EditorController(store: store)
            let view = NoteTextView.scrollableNoteView().documentView as! NoteTextView
            view.controller = controller
            controller.view = view
            controller.load("A.md")
            return (controller, view)
        }
        let (left, leftView) = editor()
        let (right, rightView) = editor()
        func type(_ text: String, in view: NoteTextView) {
            view.insertText(text, replacementRange: NSRange(location: (view.string as NSString).length, length: 0))
        }
        // While the left one is typed in and saves, the right one, with
        // nothing unsaved, follows the file.
        type("left\n", in: leftView)
        left.saveNow()
        store.noteChanged("A.md")
        right.followDisk()
        #expect(rightView.string == leftView.string)
        // Typed on the left, and the focus goes right at once, before the
        // file watcher: leaving saves, arriving takes the file.
        type("more\n", in: leftView)
        _ = leftView.resignFirstResponder()
        #expect(try String(contentsOf: root.appending(path: "A.md"), encoding: .utf8).hasSuffix("left\nmore\n"))
        _ = rightView.becomeFirstResponder()
        #expect(rightView.string == leftView.string)
        type("right\n", in: rightView)
        _ = rightView.resignFirstResponder()
        _ = leftView.becomeFirstResponder()
        #expect(leftView.string.hasSuffix("left\nmore\nright\n"))
        #expect(leftView.string == rightView.string)
        // The left one's own save is no change for it, and nothing is lost.
        store.noteChanged("A.md")
        left.followDisk()
        right.followDisk()
        #expect(leftView.string == rightView.string && store.notice == nil)
    }

    /// The window drawn off screen with two panes: two readers side by
    /// side, and the accent line over the focused one only.
    @Test func aSplitWindowDrawsTwoPanes() async throws {
        let model = WindowModel()
        model.open("A.md", store: store)
        model.split()
        model.open("B.md", store: store)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: NotePanes(model: model).environment(store))
        window.contentView = host
        func webViews(_ view: NSView) -> [WKWebView] {
            (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
        }
        for _ in 0..<100 where webViews(host).count < 2 { try await Task.sleep(for: .milliseconds(50)) }
        let readers = webViews(host).sorted { $0.convert($0.bounds, to: host).minX < $1.convert($1.bounds, to: host).minX }
        #expect(readers.count == 2)
        let pageViews: [WKWebView] = model.panes.compactMap { $0.readerView }
        #expect(pageViews.count == 2)
        if readers.count == 2 {
            let left: NSRect = readers[0].convert(readers[0].bounds, to: host)
            let right: NSRect = readers[1].convert(readers[1].bounds, to: host)
            let apart: Bool = left.maxX <= right.minX + 1
            #expect(apart)
            let wide: Bool = left.width > 300 && right.width > 300
            #expect(wide)
        }
        try await Task.sleep(for: .milliseconds(300))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        // The top row: the accent over the right pane, none over the left.
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let leftTop = try #require(bitmap.colorAt(x: Int(200 * scale), y: 0)?.usingColorSpace(.sRGB))
        let rightTop = try #require(bitmap.colorAt(x: Int(700 * scale), y: 0)?.usingColorSpace(.sRGB))
        let rightTint: CGFloat = rightTop.redComponent - rightTop.blueComponent
        let leftTint: CGFloat = abs(leftTop.redComponent - leftTop.blueComponent)
        #expect(rightTint > 0.3)
        #expect(leftTint < 0.2)
    }
}
