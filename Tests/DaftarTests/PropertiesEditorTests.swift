import AppKit
import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// The editor under the properties form, on a made-up vault in a temporary
/// folder with its own settings file.
@MainActor
@Suite(.serialized) struct PropertiesEditorTests {
    let root: URL
    let store: VaultStore
    let controller: EditorController
    let view: NoteTextView
    static let front = "---\ntitle: Plan\ntags: [a, b]\n---\n"

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-properties-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Notes"), withIntermediateDirectories: true)
        try (Self.front + "# Plan\nBody\n").write(to: root.appending(path: "Notes/Plan.md"), atomically: true, encoding: .utf8)
        try "---\ntitle: x # a comment\n---\nBody\n".write(to: root.appending(path: "Notes/Raw.md"), atomically: true, encoding: .utf8)
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

    @Test func theFrontMatterIsHiddenAndOutOfReach() throws {
        let length = (Self.front as NSString).length
        #expect(controller.hiddenFront == length)
        #expect(view.selectedRange().location == length)
        let font = try #require(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize < 1)
        // A key at the start of the body never reaches the closing fence.
        view.deleteBackward(nil)
        #expect(view.string == Self.front + "# Plan\nBody\n")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(view.selectedRange().location == length)
        view.insertText("Intro ", replacementRange: view.selectedRange())
        #expect(view.string == Self.front + "Intro # Plan\nBody\n")
    }

    @Test func theSettingAndYAMLTheFormCannotShowKeepTheText() {
        controller.load("Notes/Raw.md")
        #expect(controller.hiddenFront == 0)
        controller.load("Notes/Plan.md")
        #expect(controller.hiddenFront > 0)
        store.settings.propertiesForm = false
        controller.applyTextSize()
        #expect(controller.hiddenFront == 0)
        store.settings.vimMode = false
        store.settings.propertiesForm = true
        controller.applyTextSize()
        #expect(controller.hiddenFront > 0)
    }
}

extension PropertiesEditorTests {
    @Test func aFormEditSavesTheEditorAndWritesOnlyTheFrontMatter() async throws {
        // Typing the form has not seen yet is saved first, and kept.
        view.insertText("Typed ", replacementRange: view.selectedRange())
        let shown = try #require(PropertySheet.read(Self.front + "# Plan\nBody\n").sheet)
        let now = await store.editProperties("Notes/Plan.md", shown: shown) { $0.set("tags", .list(["a", "b", "c"])) }
        #expect(now?.sheet?.value("tags") == .list(["a", "b", "c"]))
        #expect(store.text(of: "Notes/Plan.md") == "---\ntitle: Plan\ntags: [a, b, c]\n---\nTyped # Plan\nBody\n")
        // The editor takes the new front matter at once and keeps it hidden.
        controller.followDisk()
        #expect(view.string == "---\ntitle: Plan\ntags: [a, b, c]\n---\nTyped # Plan\nBody\n")
        #expect(controller.hiddenFront == ("---\ntitle: Plan\ntags: [a, b, c]\n---\n" as NSString).length)
        // The form showed an older front matter: nothing is written.
        let stale = await store.editProperties("Notes/Plan.md", shown: shown) { $0.remove("title") }
        #expect(stale == nil)
        #expect(store.notice?.contains("changed on disk") == true)
        #expect(store.text(of: "Notes/Plan.md")?.hasPrefix("---\ntitle: Plan\n") == true)
    }
}
