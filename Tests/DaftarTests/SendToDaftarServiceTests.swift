import AppKit
import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// The Services menu's "Add to Daftar Scratchpad" and "New Daftar Task",
/// on a made-up vault in a temporary folder.
@MainActor
@Suite(.serialized) struct SendToDaftarServiceTests {
    let root: URL
    let store: VaultStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-services-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: ".obsidian"), withIntermediateDirectories: true)
        try "## 2026-11-11\n\n- an older thought\n".write(to: root.appending(path: "Scratchpad.md"), atomically: true, encoding: .utf8)
        store = VaultStore(settings: AppSettings(url: root.appending(path: "config/config.toml")), openVault: false)
        store.openSynchronously(root)
    }

    func text(_ path: String) throws -> String { try String(contentsOf: root.appending(path: path), encoding: .utf8) }

    func pasteboard(text: String? = nil, url: String? = nil) -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        if let text { board.setString(text, forType: .string) }
        if let url { board.setString(url, forType: .URL) }
        return board
    }

    @Test func theSelectionGoesUnderTodayInTheScratchpad() async throws {
        #expect(try await store.addToScratchpad("- New", on: Day("2026-11-12")!) == "Scratchpad.md")
        try await store.addToScratchpad("- <https://example.com>", on: Day("2026-11-12")!)
        #expect(try text("Scratchpad.md") == "## 2026-11-11\n\n- an older thought\n\n## 2026-11-12\n- New\n- <https://example.com>\n")
        #expect(!store.isUpdatedSinceRead("Scratchpad.md"))
    }

    @Test func aScratchpadNotThereIsMade() async throws {
        store.settings.scratchpadNote = "Inbox/Later.md"
        #expect(try await store.addToScratchpad("- x", on: Day("2026-11-12")!) == "Inbox/Later.md")
        #expect(try text("Inbox/Later.md") == "## 2026-11-12\n- x\n")
    }

    @Test func theServiceReadsThePasteboard() async throws {
        let services = DaftarServices()
        services.store = { self.store }
        var error: NSString?
        services.addToScratchpad(pasteboard(text: "Read later", url: "https://example.com/a"), userData: nil, error: &error)
        #expect(error == nil)
        for _ in 0..<40 where !((try? text("Scratchpad.md")) ?? "").contains("Read later") { try await Task.sleep(for: .milliseconds(50)) }
        #expect(try text("Scratchpad.md").hasSuffix("## \(Day.today())\n- [Read later](https://example.com/a)\n"))
        // Nothing to add is said, and nothing is written.
        let before = try text("Scratchpad.md")
        services.addToScratchpad(pasteboard(text: "  "), userData: nil, error: &error)
        #expect(error != nil)
        #expect(try text("Scratchpad.md") == before)
    }

    @Test func newDaftarTaskFillsTheForm() async throws {
        let services = DaftarServices()
        services.store = { self.store }
        var delivered: [URL] = []
        services.deliver = { delivered.append($0) }
        var error: NSString?
        services.newTask(pasteboard(text: "Renew the passport\nbefore May"), userData: nil, error: &error)
        for _ in 0..<40 where delivered.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        let url = try #require(delivered.first)
        // The window's handler opens the form with the text, in the scratchpad when no note is open.
        let model = WindowModel()
        model.handle(url, store: store)
        #expect(model.taskNew?.text == "Renew the passport before May")
        #expect(model.taskNew?.path == "Scratchpad.md")
    }
}
