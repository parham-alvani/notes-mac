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

    /// One inbox note with a section for each day: the heading holds the
    /// day, the day's first capture makes its section at the note's end,
    /// and the next ones go under it.
    @Test func aDatedHeadingGivesEachDayItsSection() async throws {
        try "## 2026-11-06\n\n- an older thought\n".write(to: root.appending(path: "Scratchpad.md"), atomically: true, encoding: .utf8)
        store.openSynchronously(root)
        store.settings.captureTarget = "Scratchpad.md"
        store.settings.captureHeading = "## {{date:YYYY-MM-DD}}"
        let day = Day(year: 2026, month: 11, day: 7)
        #expect(store.captureHeading(on: day) == "## 2026-11-07")
        #expect(QuickCaptureController.describeTarget(store) == "Scratchpad.md › \(Day.today().description)")
        #expect(try await store.capture("- first", on: day) == "Scratchpad.md")
        try await store.capture("- second", on: day)
        try await store.capture("- back to the day before", on: Day(year: 2026, month: 11, day: 6))
        #expect(try text("Scratchpad.md") == "## 2026-11-06\n\n- an older thought\n- back to the day before\n\n## 2026-11-07\n- first\n- second\n")
        // Another format, and a heading with no day in it, as before.
        store.settings.captureHeading = "{{date:dddd D MMMM}}"
        #expect(store.captureHeading(on: day) == "Saturday 7 November")
        store.settings.captureHeading = " Inbox "
        #expect(store.captureHeading(on: day) == "Inbox")
        #expect(ConfigFile.template.contains("\"## {{date:YYYY-MM-DD}}\""))
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

    /// ⌥⌘S: the scratchpad is one note, `Scratchpad.md`, found when it is
    /// there and made empty when it is not; never a folder of dated notes.
    @Test func theScratchpadIsOneNote() throws {
        #expect(store.settings.scratchpadNote == "Scratchpad.md")
        let path = try store.scratchpad()
        #expect(path == "Scratchpad.md")
        #expect(try text(path) == "")
        try "## 2026-11-07\n\n- first thought\n".write(to: root.appending(path: path), atomically: true, encoding: .utf8)
        #expect(try store.scratchpad() == path)
        #expect(try text(path) == "## 2026-11-07\n\n- first thought\n")
        var isDirectory: ObjCBool = false
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Scratchpad").path, isDirectory: &isDirectory))
        #expect(!store.index.files.contains { $0.hasPrefix("Scratchpad/") })
        // Another note, with or without `.md`, in a folder made for it; a name in another case is the same note.
        store.settings.scratchpadNote = "/Notes/Inbox"
        #expect(try store.scratchpad() == "Notes/Inbox.md")
        store.settings.scratchpadNote = "notes/inbox.md"
        #expect(try store.scratchpad() == "Notes/Inbox.md")
        store.settings.scratchpadNote = ""
        #expect(try store.scratchpad() == "Scratchpad.md")
        store.settings.scratchpadNote = "../outside"
        #expect(throws: (any Error).self) { try store.scratchpad() }
        #expect(ConfigFile(text: ConfigFile.template).string("scratchpad.note") == "Scratchpad.md")
        #expect(ConfigFile(text: ConfigFile.template).string("scratchpad.folder") == nil)
    }

    /// A settings file from before, with `scratchpad.folder`: the key is
    /// not read and not written, and the scratchpad is the one note.
    @Test func anOldScratchpadFolderIsLeftAlone() throws {
        let url = root.appending(path: "old/config.toml")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let written = "[scratchpad]\nfolder = \"Daily\"\n"
        try written.write(to: url, atomically: true, encoding: .utf8)
        let old = VaultStore(settings: AppSettings(url: url), openVault: false)
        old.openSynchronously(root)
        #expect(old.settings.scratchpadNote == "Scratchpad.md")
        #expect(try old.scratchpad() == "Scratchpad.md")
        #expect(try String(contentsOf: url, encoding: .utf8) == written)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Daily").path))
    }

    /// The command opens the note in the editor, at its end, and writes nothing.
    @Test func theCommandOpensTheScratchpadAtItsEnd() throws {
        try "## 2026-11-07\n\n- first thought\n".write(to: root.appending(path: "Scratchpad.md"), atomically: true, encoding: .utf8)
        store.openSynchronously(root)
        let model = WindowModel()
        model.openScratchpad(store: store)
        #expect(model.path == "Scratchpad.md")
        #expect(model.editing)
        #expect(model.focused.cursorLine == 3)
        #expect(try text("Scratchpad.md") == "## 2026-11-07\n\n- first thought\n")
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
