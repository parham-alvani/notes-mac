import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// The settings file is the person's: a file the app could not read is never
/// replaced, a change that could not be written is said, and the vault's path
/// keeps the spelling it was written with.
@MainActor
@Suite(.serialized) struct SettingsFileTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "daftar-settings-\(UUID().uuidString)")
    var url: URL { folder.appending(path: "config.toml") }

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @Test func aFileThatCouldNotBeReadIsNeverReplaced() throws {
        // One byte that is not UTF-8, in a comment.
        var bytes = Data("vault = \"~/notes\"\n\n[appearance]\ntext_size = 17 # ".utf8)
        bytes.append(0xFF)
        bytes.append(contentsOf: Data("\n".utf8))
        try bytes.write(to: url)
        let settings = AppSettings(url: url)
        #expect(settings.problem?.contains("could not be read") == true)
        // The defaults, since nothing was read.
        #expect(settings.textSize == 14)
        settings.textSize = 20
        settings.remoteImages = false
        #expect(try Data(contentsOf: url) == bytes)
        #expect(settings.problem?.contains("not kept") == true)
    }

    @Test func aChangeThatCouldNotBeWrittenIsSaid() throws {
        try Data("[appearance]\ntext_size = 15\n".utf8).write(to: url)
        let settings = AppSettings(url: url)
        #expect(settings.problem == nil)
        // The folder takes no new file, and the file is written by putting a new one in its place.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        settings.textSize = 20
        #expect(settings.problem?.contains("was not saved") == true)
        #expect(try String(contentsOf: url, encoding: .utf8) == "[appearance]\ntext_size = 15\n")
        // Writable again: the next change is kept and the problem is gone.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        settings.textSize = 21
        #expect(settings.problem == nil)
        #expect(ConfigFile(text: try String(contentsOf: url, encoding: .utf8)).int("appearance.text_size") == 21)
    }

    @Test func theVaultKeepsItsTilde() throws {
        let home = NSHomeDirectory()
        try Data("vault = \"~/made-up-notes\" # mine\n".utf8).write(to: url)
        let settings = AppSettings(url: url)
        #expect(settings.vaultPath == home + "/made-up-notes")
        // The same folder, set again as the app knows it: the file is not touched.
        settings.vaultPath = home + "/made-up-notes"
        #expect(try String(contentsOf: url, encoding: .utf8) == "vault = \"~/made-up-notes\" # mine\n")
        // Another folder under home is written with `~`; one outside it as it is.
        settings.vaultPath = home + "/other-notes"
        #expect(try String(contentsOf: url, encoding: .utf8) == "vault = \"~/other-notes\" # mine\n")
        settings.vaultPath = "/Volumes/Made Up/notes"
        #expect(ConfigFile(text: try String(contentsOf: url, encoding: .utf8)).string("vault") == "/Volumes/Made Up/notes")
        #expect(AppSettings(url: url).vaultPath == "/Volumes/Made Up/notes")
    }
}
