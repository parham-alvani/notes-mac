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

    /// SwiftUI's hosting view leaves full screen through the window's own
    /// `exitFullScreenMode:` (an Escape the reader gives back), which is also
    /// the action of View > Exit Full Screen: a Daftar window in full screen
    /// ignores it for the Escape key only.
    @Test func escapeFromAViewKeepsADaftarWindowInFullScreen() throws {
        // The class whose `exitFullScreenMode:` the app changes; a SwiftUI that renamed it would let Escape out again.
        #expect(NSClassFromString(FullScreenEscape.swiftUIWindow) != nil)
        FullScreenEscape.guardWindows(ExitProbe.self)
        let window = ExitProbe(contentRect: NSRect(x: -30000, y: -30000, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        func key(_ code: UInt16, _ characters: String) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        let escape = try key(53, "\u{1b}")
        window.inFullScreen = true
        // Another window leaves full screen, Escape or not.
        #expect(!FullScreenEscape.stays(window, FullScreenEscape.exit, during: escape))
        window.tabbingIdentifier = "daftar.main"
        #expect(FullScreenEscape.stays(window, FullScreenEscape.exit, during: escape))
        #expect(FullScreenEscape.stays(window, FullScreenEscape.cancel, during: nil))
        // The menu, its key and a click leave full screen.
        #expect(!FullScreenEscape.stays(window, FullScreenEscape.exit, during: try key(3, "f")))
        #expect(!FullScreenEscape.stays(window, FullScreenEscape.exit, during: nil))
        window.perform(FullScreenEscape.exit, with: nil)
        #expect(window.exits == 1)
        // Not in full screen, nothing is kept.
        window.inFullScreen = false
        #expect(!FullScreenEscape.stays(window, FullScreenEscape.exit, during: escape))
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
        #expect(NeovimSession.arguments(config: "user") == ["--cmd", "let g:daftar = 1", "-n"])
        #expect(NeovimSession.arguments(config: "clean") == ["--cmd", "let g:daftar = 1", "-n", "--clean"])
        #expect(NeovimSession.arguments(config: "~/.config/daftar/init.lua") == ["--cmd", "let g:daftar = 1", "-n", "-u", NSHomeDirectory() + "/.config/daftar/init.lua"])
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
        // Opened again, the note is where it was being read.
        model.open("N.md", line: nil, store: store)
        #expect(model.cursorLine == 2)
    }

    @Test func everyIconInTheMapIsASymbolHere() {
        let missing = IconicImage.symbols.filter { NSImage(systemSymbolName: $0.value, accessibilityDescription: nil) == nil }
        #expect(missing.isEmpty, "\(missing.sorted { $0.key < $1.key })")
    }

    @Test func anIconSetHereGoesToIconicAndFollowsARename() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "daftar-icon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Cars"), withIntermediateDirectories: true)
        try "x".write(to: root.appending(path: "Cars/Fiat.md"), atomically: true, encoding: .utf8)
        let store = VaultStore(settings: AppSettings(url: root.appending(path: "c/config.toml")), openVault: false)
        store.openSynchronously(root)
        store.setIcon("Cars", icon: "lucide-car", color: "blue")
        store.setIcon("Cars/Fiat.md", icon: "🚗", color: nil)
        #expect(store.iconic.icon(for: "Cars", folder: true) == Iconic.Icon(name: "lucide-car", color: "blue"))
        _ = try await store.move("Cars", to: "Vehicles")
        let data = try Data(contentsOf: root.appending(path: ".obsidian/plugins/iconic/data.json"))
        #expect(Iconic.parse(data).icon(for: "Vehicles/Fiat.md", folder: false)?.name == "🚗")
        #expect(store.iconic.icon(for: "Vehicles", folder: true)?.color == "blue")
        #expect(store.iconic.icon(for: "Cars", folder: true) == nil)
    }

    @Test func aNoteOpensWhereItWasBeingRead() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "daftar-place-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["A.md", "B.md"] { try "x\ny\nz\n".write(to: root.appending(path: name), atomically: true, encoding: .utf8) }
        let store = VaultStore(settings: AppSettings(url: root.appending(path: "c/config.toml")), openVault: false)
        store.openSynchronously(root)
        let model = WindowModel()
        model.open("A.md", store: store)
        model.cursorLine = 2
        model.open("B.md", store: store)
        #expect(model.request?.line == nil)
        model.goBack()
        #expect(model.request?.path == "A.md" && model.request?.line == 2)
        model.open("A.md", store: store)
        #expect(model.request?.line == 2)
        // A link to a heading goes to the heading, not to the old place.
        model.open("A.md", heading: "Top", store: store)
        #expect(model.request?.line == nil && model.request?.heading == "Top")
    }
}

/// A window with its own `exitFullScreenMode:`, as SwiftUI's has, that only
/// counts, and that says it is in full screen when told to.
private final class ExitProbe: NSWindow {
    var inFullScreen = false
    var exits = 0

    override var styleMask: NSWindow.StyleMask {
        get { inFullScreen ? super.styleMask.union(.fullScreen) : super.styleMask }
        set { super.styleMask = newValue }
    }

    @objc(exitFullScreenMode:) func countExit(_ sender: Any?) { exits += 1 }
}
