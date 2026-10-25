import AppKit
@testable import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// The parts that use the system's newer features, without the system.
@MainActor
@Suite struct ModernTests {
    @Test func escapeKeepsOnlyADaftarWindowInFullScreen() {
        FullScreenEscape.install()
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        #expect(!FullScreenEscape.keeps(window))
        window.tabbingIdentifier = "daftar.main"
        // Not in full screen: Escape does what AppKit does, and nothing breaks.
        #expect(!FullScreenEscape.keeps(window))
        window.cancelOperation(nil)
    }

    @Test func theAssistantSaysWhenTheNoteIsCut() {
        let short = NoteAssistant.prompt(.summary, title: "Plan", text: "Short.")
        #expect(short.contains("“Plan”") && short.hasSuffix("Short.") && !short.contains("first part"))
        let long = NoteAssistant.prompt(.tasks, title: "Log", text: String(repeating: "a", count: NoteAssistant.limit + 10))
        #expect(long.contains("Only the first part of the note is given."))
        #expect(long.contains("- [ ] "))
        #expect(NoteAssistant.prompt(.question("Who pays?"), title: "T", text: "x").contains("Who pays?"))
    }

    @Test func aSpotlightItemIsTheNote() {
        let text = "---\naliases: [Kick]\ntags: [work]\n---\n# Kickoff\n\nWe met."
        let note = NoteEntry(path: "Projects/Kickoff.md", modified: Date(timeIntervalSince1970: 1), parsed: NoteParser.parse(text))
        let item = Spotlight.item(note, domain: "/vault")
        #expect(item.uniqueIdentifier == "Projects/Kickoff.md")
        #expect(item.domainIdentifier == "/vault")
        #expect(item.attributeSet.title == "Kickoff")
        #expect(item.attributeSet.keywords?.contains("work") == true)
        #expect(item.attributeSet.alternateNames == ["Kick"])
        #expect(item.attributeSet.containerTitle == "Projects")
    }

    @Test func translationLeavesThePropertiesOut() {
        #expect(WindowModel.withoutProperties("---\ntags: [a]\n---\n# Title\nBody") == "# Title\nBody")
        #expect(WindowModel.withoutProperties("# No properties") == "# No properties")
    }

    @Test func theNeovimConfigCanBeAFile() {
        #expect(NeovimSession.arguments(config: "user") == ["--cmd", "let g:daftar = 1"])
        #expect(NeovimSession.arguments(config: "clean") == ["--cmd", "let g:daftar = 1", "--clean"])
        #expect(NeovimSession.arguments(config: "~/.config/daftar/init.lua") == ["--cmd", "let g:daftar = 1", "-u", NSHomeDirectory() + "/.config/daftar/init.lua"])
    }

    @Test func readingAgainOpensWhereTheEditorWas() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "daftar-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "a\nb\nc\n".write(to: root.appending(path: "N.md"), atomically: true, encoding: .utf8)
        let store = VaultStore(settings: AppSettings(url: root.appending(path: "c/config.toml")), openVault: false)
        store.openSynchronously(root)
        let model = WindowModel()
        model.open("N.md", store: store)
        #expect(model.cursorLine == nil)
        model.editing = true
        model.cursorLine = 2
        let before = try #require(model.request)
        model.editing = false
        #expect(model.request?.line == 2)
        #expect(model.request?.generation == before.generation + 1)
        // Another note opens at its top, not at this one's line.
        model.open("N.md", line: nil, store: store)
        #expect(model.cursorLine == nil)
    }
}
