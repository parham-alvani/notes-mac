import AppKit
import Foundation
import Testing

@testable import DaftarUI

/// The soft change between reading and editing
/// (`docs/specs/look.md` in notes-linux, "A soft change").
@MainActor
@Suite(.serialized) struct SoftChangeTests {
    func window() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        window.orderBack(nil)
        return window
    }

    @Test func theFadeIs120msAndNoneWithReduceMotion() {
        #expect(SoftChange.fade(reduced: false) == 0.12)
        #expect(SoftChange.fade(reduced: true) == nil)
        // A view that is not ready after 400 ms is shown at once.
        #expect(SoftChange.patience == 0.4)
    }

    @Test func theViewThatLeavesFadesAsAPictureThatTakesNoClick() async throws {
        let window = window()
        defer { window.orderOut(nil) }
        let host = try #require(window.contentView)
        let view = NSView(frame: CGRect(x: 40, y: 30, width: 300, height: 200))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.systemOrange.cgColor
        host.addSubview(view)
        let ghost = try #require(SoftChange.leave(view, reduced: false))
        // The picture is where the view is, over everything, and is not the view.
        #expect(ghost.superview === host && host.subviews.last === ghost)
        #expect(ghost.frame == view.frame)
        // A click goes through it, and it takes no keys.
        #expect(ghost.hitTest(CGPoint(x: 100, y: 100)) == nil)
        #expect(!ghost.acceptsFirstResponder)
        #expect(window.firstResponder !== ghost)
        // The view may go at once: the picture stays for the fade, then goes too.
        view.removeFromSuperview()
        #expect(ghost.superview === host)
        for _ in 0..<30 where ghost.superview != nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(ghost.superview == nil)
        #expect(host.subviews.isEmpty)
    }

    @Test func withReduceMotionTheChangeIsMadeAtOnce() throws {
        let window = window()
        defer { window.orderOut(nil) }
        let host = try #require(window.contentView)
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        host.addSubview(view)
        #expect(SoftChange.leave(view, reduced: true) == nil)
        #expect(host.subviews == [view])
        // A view in no window leaves no picture.
        #expect(SoftChange.leave(NSView(frame: CGRect(x: 0, y: 0, width: 10, height: 10)), reduced: false) == nil)
    }

    @Test func theEditorThatLeavesIsThePanesOwn() throws {
        let window = window()
        defer { window.orderOut(nil) }
        let host = try #require(window.contentView)
        // Two panes side by side, each a reader with an editor over it.
        let left = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 400)), right = NSView(frame: CGRect(x: 300, y: 0, width: 300, height: 400))
        let leftEditor = EditorContainer(scroll: NoteTextView.scrollableNoteView()), rightEditor = EditorContainer(scroll: NoteTextView.scrollableNoteView())
        leftEditor.frame = CGRect(x: 0, y: 0, width: 300, height: 370)
        rightEditor.frame = CGRect(x: 300, y: 0, width: 300, height: 370)
        let wrap = NSView(frame: host.bounds)
        wrap.addSubview(rightEditor)
        for view in [left, right, leftEditor, wrap] { host.addSubview(view) }
        #expect(SoftChange.editor(over: left) === leftEditor)
        #expect(SoftChange.editor(over: right) === rightEditor)
        // A hidden editor, and a pane with none, has none to fade.
        rightEditor.isHidden = true
        #expect(SoftChange.editor(over: right) == nil)
        #expect(SoftChange.editor(over: NSView()) == nil)
    }

    @Test func theReaderComesOnceItHasDrawn() {
        let pane = NotePane()
        pane.request = ReaderRequest(path: "Note.md")
        pane.editing = true
        #expect(!pane.readerShown)
        pane.editing = false
        // The editor stays over the page until the page has drawn.
        #expect(!pane.readerShown)
        pane.readerCame()
        #expect(pane.readerShown)
    }
}
