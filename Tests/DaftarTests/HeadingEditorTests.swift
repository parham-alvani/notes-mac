import AppKit
import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// Sections and headings in the editor, on a made-up vault in a temporary folder.
@MainActor
@Suite(.serialized) struct HeadingEditorTests {
    let root: URL
    let store: VaultStore
    let controller: EditorController
    let view: NoteTextView

    static let plan = "# Plan\nintro\n## Old Name\nold\n\n## Next\nnext\n"

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-headings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Notes"), withIntermediateDirectories: true)
        try Self.plan.write(to: root.appending(path: "Notes/Plan.md"), atomically: true, encoding: .utf8)
        try "See [[Plan#Old Name]] and [x](Plan.md#Old%20Name), not [[Plan#Next]].\n"
            .write(to: root.appending(path: "Notes/Other.md"), atomically: true, encoding: .utf8)
        let settings = AppSettings(url: root.appending(path: "config/config.toml"))
        store = VaultStore(settings: settings, openVault: false)
        store.openSynchronously(root)
        controller = EditorController(store: store)
        let scroll = NoteTextView.scrollableNoteView()
        view = scroll.documentView as! NoteTextView
        view.controller = controller
        controller.view = view
        controller.load("Notes/Plan.md")
    }

    @Test func aSectionMovesAsOneStepToUndo() throws {
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        view.setSelectedRange(NSRange(location: (Self.plan as NSString).range(of: "old\n").location, length: 0))
        view.moveSectionDown(nil)
        #expect(view.string == "# Plan\nintro\n## Next\nnext\n\n## Old Name\nold\n")
        #expect((view.string as NSString).substring(from: view.selectedRange().location).hasPrefix("old"))
        // At the end already: nothing changes.
        view.moveSectionDown(nil)
        #expect(view.string == "# Plan\nintro\n## Next\nnext\n\n## Old Name\nold\n")
        try #require(view.undoManager).undo()
        #expect(view.string == Self.plan)
    }

    @Test func leavingARenamedHeadingOffersItsLinks() async throws {
        var offered: HeadingRename.Change?
        controller.onHeadingsRenamed = { offered = $0 }
        let heading = (Self.plan as NSString).range(of: "Old Name")
        view.setSelectedRange(NSRange(location: NSMaxRange(heading), length: 0))
        view.replace(heading, with: "New Name", select: NSRange(location: NSMaxRange(heading), length: 0))
        // Typing on the line offers nothing yet.
        try await Task.sleep(for: .milliseconds(50))
        #expect(offered == nil)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(50))
        let change = try #require(offered)
        #expect(change.renames == [1: "New Name"])
        // The note was saved before the links are looked for.
        #expect(store.text(of: "Notes/Plan.md")?.contains("## New Name") == true)
        let edits = await store.headingEdits(change)
        #expect(edits.map(\.path) == ["Notes/Other.md"])
        #expect(edits.first?.edits.map(\.links) == [2])
        let done = store.applyHeadingEdits(edits)
        #expect(done.notes == 1 && done.replacements == 2 && done.refused.isEmpty)
        #expect(store.text(of: "Notes/Other.md") == "See [[Plan#New Name]] and [x](Plan.md#New%20Name), not [[Plan#Next]].\n")
        // A second look finds nothing new.
        offered = nil
        controller.checkHeadings()
        try await Task.sleep(for: .milliseconds(50))
        #expect(offered == nil)
    }

    @Test func renameHeadingWritesTheHeadingAndItsLinks() async throws {
        let headings = Sections.headings(in: Self.plan)
        let change = HeadingRename.Change(path: "Notes/Plan.md", headings: headings, renames: [1: "Renamed"])
        let edits = await store.headingEdits(change, retitle: true)
        #expect(edits.map(\.path) == ["Notes/Other.md", "Notes/Plan.md"])
        _ = store.applyHeadingEdits(edits)
        #expect(store.text(of: "Notes/Plan.md") == "# Plan\nintro\n## Renamed\nold\n\n## Next\nnext\n")
        #expect(store.text(of: "Notes/Other.md")?.hasPrefix("See [[Plan#Renamed]]") == true)
        // A preview older than the file is refused.
        #expect(store.applyHeadingEdits(edits).refused == ["Notes/Other.md", "Notes/Plan.md"])
    }

    @Test func theOutlineMovesTheCursor() {
        controller.jump(EditorJump(line: 5))
        #expect(view.selectedRange().location == (Self.plan as NSString).range(of: "## Next").location)
    }

    @Test func aSectionMovesInTheFile() {
        #expect(store.moveSection("Notes/Plan.md", heading: 2, to: 0))
        #expect(store.text(of: "Notes/Plan.md") == "# Plan\nintro\n## Next\nnext\n\n## Old Name\nold\n")
        #expect(!store.moveSection("Notes/Plan.md", heading: 0, to: 1))
    }
}
