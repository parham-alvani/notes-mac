import AppKit
import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// `[[` and `#` completion and Copy Block Link in the editor, on a made-up
/// vault in a temporary folder with its own settings file and pasteboard.
@MainActor
@Suite(.serialized) struct CompletionTests {
    let root: URL
    let store: VaultStore
    let controller: EditorController
    let view: NoteTextView
    let window: NSWindow

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-completion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Notes"), withIntermediateDirectories: true)
        try "# Plan\n\nA first step.\n\n## Later\n- [ ] first #project/daftar\n".write(to: root.appending(path: "Notes/Plan.md"), atomically: true, encoding: .utf8)
        try "---\naliases: [k8s]\n---\n# Kubernetes\n\n## Pods\n\nA pod runs containers.\n\nServices find pods ^svc\n"
            .write(to: root.appending(path: "Notes/Kubernetes.md"), atomically: true, encoding: .utf8)
        try "#project and #home\n".write(to: root.appending(path: "Notes/Tags.md"), atomically: true, encoding: .utf8)
        let settings = AppSettings(url: root.appending(path: "config/config.toml"))
        store = VaultStore(settings: settings, openVault: false)
        store.openSynchronously(root)
        VaultStore.linkPasteboard = NSPasteboard(name: NSPasteboard.Name("daftar-test-\(UUID().uuidString)"))
        controller = EditorController(store: store)
        let scroll = NoteTextView.scrollableNoteView()
        view = scroll.documentView as! NoteTextView
        view.controller = controller
        controller.view = view
        controller.load("Notes/Plan.md")
        // A window, off screen, gives the view its undo manager.
        window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
    }

    /// [text] typed at the end; a link's `]]` is put after the cursor, as `[[` does.
    func type(_ text: String) {
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertText(text, replacementRange: view.selectedRange())
        if text.contains("[[") {
            view.insertText("]]", replacementRange: view.selectedRange())
            view.setSelectedRange(NSRange(location: (view.string as NSString).length - 2, length: 0))
        }
    }

    func rows() -> (range: NSRange, labels: [String]) {
        let range = view.rangeForUserCompletion
        return (range, controller.textView(view, completions: [], forPartialWordRange: range, indexOfSelectedItem: nil))
    }

    func choose(_ label: String, in range: NSRange) {
        view.insertCompletion(label, forPartialWordRange: range, movement: NSTextMovement.return.rawValue, isFinal: true)
    }

    @Test func aHeadingOfAnotherNote() {
        type("[[Kubernetes#")
        let (range, labels) = rows()
        #expect(labels == ["Kubernetes", "  Pods"])
        choose("  Pods", in: range)
        #expect(view.string.hasSuffix("[[Kubernetes#Pods]]"))
        #expect(view.selectedRange().location == (view.string as NSString).length)
    }

    @Test func theHeadingsOfThisNoteAsTyped() {
        type("\n### New\n[[#")
        let (range, labels) = rows()
        #expect(labels == ["Plan", "  Later", "    New"])
        choose("  Later", in: range)
        #expect(view.string.hasSuffix("[[#Later]]"))
    }

    @Test func anAliasWritesTheNoteAndTheAlias() {
        type("[[k8s")
        let (range, labels) = rows()
        #expect(labels.first == "k8s → Kubernetes")
        choose("k8s → Kubernetes", in: range)
        #expect(view.string.hasSuffix("[[Kubernetes|k8s]]"))
    }

    @Test func aBlockWithAnIdIsLinkedAsItIs() {
        type("[[Kubernetes#^")
        let (range, labels) = rows()
        #expect(labels == ["A pod runs containers.", "Services find pods  ^svc"])
        choose("Services find pods  ^svc", in: range)
        #expect(view.string.hasSuffix("[[Kubernetes#^svc]]"))
    }

    @Test func aBlockWithoutAnIdGetsOneInItsFile() async throws {
        type("[[Kubernetes^pod run")
        let (range, labels) = rows()
        #expect(labels == ["A pod runs containers."])
        choose("A pod runs containers.", in: range)
        let link = try #require(view.string.firstMatch(of: /\[\[Kubernetes#\^([a-z0-9]{6})\]\]/))
        let file = root.appending(path: "Notes/Kubernetes.md")
        for _ in 0..<100 where !((try? String(contentsOf: file, encoding: .utf8)) ?? "").contains("^" + link.1) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try String(contentsOf: file, encoding: .utf8).contains("A pod runs containers. ^\(link.1)\n"))
    }

    @Test func aTagAtAWordsStart() {
        type("Some #proj")
        let (range, labels) = rows()
        #expect((view.string as NSString).substring(with: range) == "proj")
        #expect(labels.first == "#project  1")
        #expect(labels.contains("#project/daftar  1"))
        choose("#project/daftar  1", in: range)
        #expect(view.string.hasSuffix("Some #project/daftar"))
    }

    @Test func copyBlockLinkGivesTheParagraphAnId() throws {
        view.setSelectedRange(NSRange(location: ("# Plan\n\nA fir" as NSString).length, length: 0))
        controller.copyBlockLink()
        let id = try #require(view.string.firstMatch(of: /A first step\. \^([a-z0-9]{6})\n/)?.1)
        #expect(VaultStore.linkPasteboard.string(forType: .string) == "[[Plan#^\(id)]]")
        // The cursor stays where it was, and a second time adds nothing.
        #expect(view.selectedRange().location == ("# Plan\n\nA fir" as NSString).length)
        controller.copyBlockLink()
        #expect(view.string.components(separatedBy: "^").count == 2)
        #expect(VaultStore.linkPasteboard.string(forType: .string) == "[[Plan#^\(id)]]")
        // On a heading, the heading's link.
        view.setSelectedRange(NSRange(location: 2, length: 0))
        controller.copyBlockLink()
        #expect(VaultStore.linkPasteboard.string(forType: .string) == "[[Plan#Plan]]")
    }

    @Test func copyBlockLinkInTheReaderWritesTheFile() async throws {
        store.copyBlockLink("Notes/Kubernetes.md", line: 7)
        let text = try String(contentsOf: root.appending(path: "Notes/Kubernetes.md"), encoding: .utf8)
        let id = try #require(text.firstMatch(of: /A pod runs containers\. \^([a-z0-9]{6})\n/)?.1)
        #expect(VaultStore.linkPasteboard.string(forType: .string) == "[[Kubernetes#^\(id)]]")
    }
}
