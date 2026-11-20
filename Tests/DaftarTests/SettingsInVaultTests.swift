import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// A setting changed in the app goes to the vault's `.daftar.toml`
/// (`docs/specs/vault-config.md` in notes-linux, section 5 and tests 9 to
/// 13), through the store, on a made-up vault in a temporary folder.
@MainActor
@Suite(.serialized) struct SettingsInVaultTests {
    let base: URL
    let root: URL
    let config: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "daftar-settings-in-vault-\(UUID().uuidString)")
        root = base.appending(path: "vault")
        config = base.appending(path: "config/config.toml")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Note\n".write(to: root.appending(path: "Note.md"), atomically: true, encoding: .utf8)
    }

    var vaultFile: URL { root.appending(path: ".daftar.toml") }
    func vault() -> String { (try? String(contentsOf: vaultFile, encoding: .utf8)) ?? "<none>" }
    func device() -> String { (try? String(contentsOf: config, encoding: .utf8)) ?? "<none>" }

    /// The store on the vault with [vault] as its `.daftar.toml` and [computer] as `config.toml`.
    func store(vault text: String?, computer: String = "") throws -> VaultStore {
        if let text { try text.write(to: vaultFile, atomically: true, encoding: .utf8) }
        try computer.write(to: config, atomically: true, encoding: .utf8)
        let store = VaultStore(settings: AppSettings(url: config), openVault: false)
        store.openSynchronously(root)
        return store
    }

    @Test func aSettingChangedInTheAppGoesToTheVault() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try store(vault: "# mine\n[appearance]\ntheme = \"dark\" # night\n", computer: "# my Mac\n[appearance]\ntext_size = 14\n")
        let settings = store.settings
        #expect(settings.vaultWritable)
        let before = device()
        // A key that is not there is added at the end of its section.
        settings.textSize = 16
        #expect(vault() == "# mine\n[appearance]\ntheme = \"dark\" # night\ntext_size = 16\n")
        #expect(device() == before)
        #expect(settings.textSize == 16 && settings.isFromVault("appearance.text_size"))
        // Only the line of the key changes, and its comment stays.
        settings.appearance = .light
        #expect(vault() == "# mine\n[appearance]\ntheme = \"light\" # night\ntext_size = 16\n")
        // A section that is not there is added at the end of the file.
        settings.taskDigest = false
        #expect(vault() == "# mine\n[appearance]\ntheme = \"light\" # night\ntext_size = 16\n\n[notifications]\ndigest = false\n")
        #expect(device() == before)
        // The settings read again right after the app's own write are the ones it set: nothing goes back.
        store.changed([FileWatcher.vault])
        #expect(settings.textSize == 16 && settings.appearance == .light && !settings.taskDigest)
        #expect(vault().hasSuffix("[notifications]\ndigest = false\n"))
        // A field that is only left, with the value in use, writes nothing.
        let written = vault()
        settings.textSize = 16
        settings.hiddenNames = settings.hiddenNames
        settings.livePreview = settings.livePreview
        #expect(vault() == written && device() == before)
        // A value equal to the default is still written: the vault says it on purpose.
        settings.textSize = 14
        #expect(vault().contains("text_size = 14\n"))
        // The zoom and the export panel's choices are changes like any other.
        settings.textSize += 1
        settings.exportContents = true
        #expect(vault().contains("text_size = 15\n") && vault().hasSuffix("\n[export]\ncontents = true\n"))
        #expect(device() == before)
        // Another edit of the file, made since the app read it, is kept: the write is on top of what is there.
        try (vault() + "\n[check]\nmemory = true\n").write(to: vaultFile, atomically: true, encoding: .utf8)
        settings.persianCalendar = true
        #expect(vault().contains("[check]\nmemory = true\n") && vault().contains("persian_calendar = true\n"))
    }

    /// A vault with no `.daftar.toml` gets one only when it is a repository.
    @Test func aVaultWithoutTheFileGetsItOnlyInARepository() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        var store = try store(vault: nil)
        #expect(!store.settings.vaultWritable)
        store.settings.textSize = 17
        #expect(vault() == "<none>" && device().contains("text_size = 17"))
        try await Git(root: root).run(["init", "-q", "-b", "main"])
        store = try self.store(vault: nil)
        #expect(store.settings.vaultWritable)
        store.settings.textSize = 18
        #expect(vault() == "[appearance]\ntext_size = 18\n")
        #expect(try await Git(root: root).changes().contains(".daftar.toml"))
    }

    @Test func aFontIsWrittenToThePlatformsTable() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try store(vault: "[appearance]\ntext_size = 14\n\n[macos.appearance]\ntext_size = 15\n", computer: "[appearance]\nfont = \"New York\"\n")
        let settings = store.settings
        #expect(settings.textSize == 15)
        let before = device()
        // A font differs by platform by nature: the platform's table, and no shared `font`.
        settings.font = "SF Pro"
        #expect(vault() == "[appearance]\ntext_size = 14\n\n[macos.appearance]\ntext_size = 15\nfont = \"SF Pro\"\n")
        // A key the platform's table has already changes there, not in the shared section.
        settings.textSize = 17
        #expect(vault() == "[appearance]\ntext_size = 14\n\n[macos.appearance]\ntext_size = 17\nfont = \"SF Pro\"\n")
        // What only the Mac has goes to its table too.
        settings.dockBadge = false
        settings.cursorEffect = .ripple
        settings.terminalFontSize = 15
        #expect(vault().hasSuffix("\n[macos.editor]\ncursor_effect = \"ripple\"\n\n[macos.terminal]\nfont_size = 15\n"))
        // The capture shortcut is the Mac's own key of the list.
        settings.captureHotkey = "ctrl+opt+m"
        #expect(vault().hasSuffix("\n[macos.capture]\nhotkey = \"ctrl+opt+m\"\n"))
        #expect(vault().contains("[macos.appearance]\ntext_size = 17\nfont = \"SF Pro\"\ndock_badge = false\n"))
        #expect(device() == before)
        #expect(settings.isFromVault("appearance.dock_badge") && settings.isFromVault("editor.cursor_effect"))
        #expect(settings.refusedByVault.isEmpty)
    }

    @Test func whatAVaultMayNotHoldGoesToTheDevice() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let text = "[appearance]\nremote_images = false\ntext_size = 16\n"
        var store = try store(vault: text)
        var settings = store.settings
        // A program, pictures from the web turned on, and a picture outside the vault.
        settings.shell = "/bin/bash"
        settings.vimMode = true
        settings.wakatime = true
        settings.okfActor = "parham"
        settings.remoteImages = true
        settings.homeImage = "/Users/Shared/home.png"
        #expect(vault() == text)
        for line in ["shell = \"/bin/bash\"", "vim_mode = true", "enabled = true", "actor = \"parham\"", "remote_images = true", "image = \"/Users/Shared/home.png\""] {
            #expect(device().contains(line), "\(line)")
        }
        // A picture in the vault is the vault's to hold.
        settings.homeImage = "uploads/home.webp"
        #expect(vault().hasSuffix("\n[home]\nimage = \"uploads/home.webp\"\n"))
        try text.write(to: vaultFile, atomically: true, encoding: .utf8)

        // With `vault_settings = false` every change goes to the device.
        store = try self.store(vault: text, computer: "vault_settings = false\n")
        settings = store.settings
        settings.textSize = 19
        settings.appearance = .dark
        settings.dockBadge = false
        #expect(vault() == text)
        #expect(device().contains("text_size = 19") && device().contains("theme = \"dark\"") && device().contains("dock_badge = false"))

        // And so does every change in a read-only clone.
        let git = Git(root: root)
        try await git.run(["init", "-q", "-b", "main"])
        try await git.setReadOnly(true)
        store = try self.store(vault: text)
        settings = store.settings
        #expect(store.readOnly && !settings.vaultWritable)
        #expect(settings.textSize == 16)
        settings.textSize = 20
        settings.appearance = .light
        settings.font = "New York"
        settings.cursorEffect = .ripple
        #expect(vault() == text)
        #expect(try Data(contentsOf: vaultFile) == Data(text.utf8))
        #expect(device().contains("text_size = 20") && device().contains("theme = \"light\"") && device().contains("font = \"New York\"") && device().contains("cursor_effect = \"ripple\""))
        #expect(store.writeVaultSetting("appearance.theme", .string("dark")) == nil)
        #expect(vault() == text)
    }

    @Test func keepOnThisDeviceDeclinesTheKey() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let text = "[appearance]\ntheme = \"dark\"\ntext_size = 16\n"
        let store = try store(vault: text, computer: "# my Mac\n")
        let settings = store.settings
        #expect(settings.appearance == .dark && !settings.keepsOnDevice("appearance.theme"))
        // The key joins the declined list, its value now goes to the device, and the vault's line stays.
        settings.keepOnDevice("appearance.theme")
        #expect(ConfigFile(text: device())["vault_settings"] == .strings(["appearance.theme"]))
        #expect(ConfigFile(text: device()).string("appearance.theme") == "dark")
        #expect(vault() == text)
        #expect(settings.appearance == .dark && !settings.isFromVault("appearance.theme") && settings.keepsOnDevice("appearance.theme"))
        // A later change of the key writes the device.
        settings.appearance = .light
        #expect(ConfigFile(text: device()).string("appearance.theme") == "light")
        #expect(vault() == text)
        // The other keys still go to the vault.
        settings.textSize = 17
        #expect(vault() == "[appearance]\ntheme = \"dark\"\ntext_size = 17\n")
        // Follow the Vault takes the key off the list, and the vault's value is used again.
        settings.followVault("appearance.theme")
        #expect(ConfigFile(text: device())["vault_settings"] == .strings([]))
        #expect(device().contains("vault_settings = []") && settings.followsVault && settings.declinedKeys.isEmpty)
        #expect(settings.appearance == .dark && settings.isFromVault("appearance.theme") && !settings.keepsOnDevice("appearance.theme"))
        // A second key is kept beside the first, and one leaves alone.
        settings.keepOnDevice("appearance.theme")
        settings.keepOnDevice("appearance.text_size")
        #expect(ConfigFile(text: device())["vault_settings"] == .strings(["appearance.theme", "appearance.text_size"]))
        settings.followVault("appearance.theme")
        #expect(ConfigFile(text: device())["vault_settings"] == .strings(["appearance.text_size"]))
        // A key a vault may never hold has nothing to keep.
        settings.keepOnDevice("terminal.shell")
        #expect(ConfigFile(text: device())["vault_settings"] == .strings(["appearance.text_size"]))
        #expect(vault() == "[appearance]\ntheme = \"dark\"\ntext_size = 17\n")
        // With `vault_settings = false`, Keep on This Device changes nothing.
        settings.followsVault = false
        let none = device()
        settings.keepOnDevice("appearance.theme")
        #expect(device() == none && vault() == "[appearance]\ntheme = \"dark\"\ntext_size = 17\n")
    }
}
