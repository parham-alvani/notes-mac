import AppKit
import Carbon.HIToolbox
import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// Quick capture on a made-up vault in a temporary folder.
@MainActor
@Suite(.serialized) struct CaptureTests {
    let root: URL
    let store: VaultStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: ".obsidian"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "Templates"), withIntermediateDirectories: true)
        try #"{"format":"YYYY-MM-DD","folder":"Journal","template":"Templates/Day"}"#.write(to: root.appending(path: ".obsidian/daily-notes.json"), atomically: true, encoding: .utf8)
        try "# {{title}}\n## Inbox\n\n## Log\n".write(to: root.appending(path: "Templates/Day.md"), atomically: true, encoding: .utf8)
        try "# Inbox\n- [ ] Old\n".write(to: root.appending(path: "Inbox.md"), atomically: true, encoding: .utf8)
        store = VaultStore(settings: AppSettings(url: root.appending(path: "config/config.toml")), openVault: false)
        store.openSynchronously(root)
    }

    func text(_ path: String) throws -> String { try String(contentsOf: root.appending(path: path), encoding: .utf8) }

    @Test func goesToTodaysNoteMadeFromItsTemplate() async throws {
        store.settings.captureHeading = "Inbox"
        let path = try await store.capture("- [ ] Call Sara")
        #expect(path == "Journal/\(Day.today().description).md")
        #expect(try text(path) == "# \(Day.today().description)\n## Inbox\n- [ ] Call Sara\n\n## Log\n")
        // The file is read again: a change made on disk meanwhile stays.
        try "# Today\n## Inbox\n- [ ] Call Sara\n- [ ] Written elsewhere\n".write(to: root.appending(path: path), atomically: true, encoding: .utf8)
        try await store.capture("Idea")
        #expect(try text(path) == "# Today\n## Inbox\n- [ ] Call Sara\n- [ ] Written elsewhere\n\nIdea\n")
        // The app's own edit is not news.
        #expect(!store.isUpdatedSinceRead(path))
    }

    @Test func goesToANamedNote() async throws {
        store.settings.captureTarget = "inbox"
        #expect(try await store.capture("- [ ] New") == "Inbox.md")
        #expect(try text("Inbox.md") == "# Inbox\n- [ ] Old\n- [ ] New\n")
        // A note not there yet is made.
        store.settings.captureTarget = "Notes/Later.md"
        store.settings.captureHeading = "Ideas"
        #expect(try await store.capture("x") == "Notes/Later.md")
        #expect(try text("Notes/Later.md") == "## Ideas\nx\n")
        // Never outside the vault.
        store.settings.captureTarget = "../escaped"
        await #expect(throws: (any Error).self) { try await self.store.capture("x") }
        #expect(!FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appending(path: "escaped.md").path))
    }

    @Test func theSettingsAreInTheFile() throws {
        let settings = store.settings
        #expect(settings.captureHotkey == "ctrl+opt+n")
        #expect(settings.captureTarget == "daily")
        settings.captureHotkey = ""
        settings.captureHeading = "Inbox"
        let file = ConfigFile(text: try String(contentsOf: settings.url, encoding: .utf8))
        #expect(file.string("capture.hotkey") == "")
        #expect(file.string("capture.heading") == "Inbox")
        #expect(HotKeySpec.parse(ConfigFile(text: ConfigFile.template).string("capture.hotkey") ?? "") != nil)
    }

    /// The core's key codes are Carbon's.
    @Test func theKeyCodesAreTheMacs() {
        let expected: [String: Int] = [
            "a": kVK_ANSI_A, "n": kVK_ANSI_N, "z": kVK_ANSI_Z, "q": kVK_ANSI_Q, "m": kVK_ANSI_M, "0": kVK_ANSI_0, "5": kVK_ANSI_5,
            "9": kVK_ANSI_9, "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
            ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
            "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave, "space": kVK_Space, "return": kVK_Return, "tab": kVK_Tab,
            "escape": kVK_Escape, "delete": kVK_Delete, "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow,
            "down": kVK_DownArrow, "f1": kVK_F1, "f5": kVK_F5, "f12": kVK_F12, "f13": kVK_F13, "f17": kVK_F17, "f20": kVK_F20,
        ]
        for (key, code) in expected {
            #expect(HotKeySpec.parse("ctrl+" + key)?.keyCode == UInt32(code), "\(key)")
        }
        let letters = "abcdefghijklmnopqrstuvwxyz".map { HotKeySpec.parse("ctrl+\($0)")!.keyCode }
        #expect(Set(letters).count == 26)
    }
}
