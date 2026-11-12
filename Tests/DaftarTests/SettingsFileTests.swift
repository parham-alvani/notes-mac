import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// The settings file is the person's too: an edit made outside the app is
/// never written over by the next change made in it.
@MainActor
@Suite struct SettingsFileTests {
    @Test func aChangeGoesOntoAnEditSavedInPlace() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "daftar-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "config.toml")
        let settings = AppSettings(url: url)
        let before = try String(contentsOf: url, encoding: .utf8)
        // Saved in place, as `>>` or nano does: the same file, longer.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n# mine\n".utf8))
        try handle.close()
        settings.textSize = settings.textSize + 1
        let after = try String(contentsOf: url, encoding: .utf8)
        #expect(after.contains("# mine"))
        #expect(after != before)
        #expect(ConfigFile(text: after).int("appearance.text_size") == settings.textSize)
    }
}
