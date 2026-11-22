import Foundation
import Testing

@testable import DaftarCore

/// `docs/specs/vault-config.md` in notes-linux, section 5, by name.
@Suite struct VaultConfigTests {
    func resolved(vault: String, computer: String, root: URL? = nil) -> ResolvedSettings {
        ResolvedSettings.resolved(vault: vault, computer: computer, root: root)
    }

    @Test func theVaultsValueWins() {
        let computer = "[appearance]\ntext_size = 14\n"
        let both = resolved(vault: "[appearance]\ntext_size = 16\n", computer: computer)
        #expect(both.int("appearance.text_size") == 16)
        #expect(both.source(of: "appearance.text_size") == .vault)
        #expect(both.fromVault == ["appearance.text_size"])
        // With no vault key, the computer's.
        let alone = resolved(vault: "[reader]\nfolded = true\n", computer: computer)
        #expect(alone.int("appearance.text_size") == 14)
        #expect(alone.source(of: "appearance.text_size") == .computer)
        #expect(alone.fromVault.isEmpty)
        // With neither, the default.
        let neither = resolved(vault: "", computer: "")
        #expect(neither.int("appearance.text_size") == 16)
        #expect(neither.source(of: "appearance.text_size") == .standard)
        #expect(resolved(vault: "", computer: "[appearance]\ntext_size = 20\n").int("appearance.text_size") == 20)
        // The template has every key, and the vault still speaks over it.
        let full = resolved(vault: "[appearance]\ntheme = \"dark\"\n[git]\nsync_interval = 5\n", computer: ConfigFile.template)
        #expect(full.string("appearance.theme") == "dark")
        #expect(full.int("git.sync_interval") == 5)
        #expect(full.bool("git.pull_on_launch") == true)
        #expect(full.refused.isEmpty)
    }

    @Test func aComputerCanDecline() {
        let vault = "[appearance]\ntext_size = 16\ntheme = \"dark\"\n\n[reader]\nfolded = true\n"
        let none = resolved(vault: vault, computer: "vault_settings = false\n\n[appearance]\ntext_size = 14\n")
        #expect(none.int("appearance.text_size") == 14)
        #expect(none.string("appearance.theme") == "system")
        #expect(none.fromVault.isEmpty)
        let one = resolved(vault: vault, computer: "vault_settings = [\"appearance.text_size\"]\n\n[appearance]\ntext_size = 14\n")
        #expect(one.int("appearance.text_size") == 14)
        #expect(one.source(of: "appearance.text_size") == .computer)
        #expect(one.string("appearance.theme") == "dark")
        // Not set is true, and so is `true`.
        for computer in ["[appearance]\ntext_size = 14\n", "vault_settings = true\n[appearance]\ntext_size = 14\n"] {
            #expect(resolved(vault: vault, computer: computer).int("appearance.text_size") == 16)
        }
        // What the vault says about itself is not an app setting: it is read in both.
        #expect(VaultSettings(text: vault).folded)
    }

    @Test func theVaultStartsNoProgram() {
        let computer = """
            vault = "~/notes"
            vault_settings = ["appearance.font"]

            [terminal]
            shell = "/bin/zsh"

            [editor]
            nvim = "/opt/homebrew/bin/nvim"
            nvim_config = "user"
            vim_mode = false
            neovide = false

            [wakatime]
            enabled = false

            """
        let cases: [(vault: String, key: String, kept: ConfigFile.Value)] = [
            ("[terminal]\nshell = \"/tmp/x\"\n", "terminal.shell", .string("/bin/zsh")),
            ("[editor]\nnvim = \"/tmp/x\"\n", "editor.nvim", .string("/opt/homebrew/bin/nvim")),
            ("[editor]\nnvim_config = \"x.lua\"\n", "editor.nvim_config", .string("user")),
            ("[editor]\nvim_mode = true\n", "editor.vim_mode", .bool(false)),
            ("[editor]\nneovide = true\n", "editor.neovide", .bool(false)),
            ("[wakatime]\nenabled = true\n", "wakatime.enabled", .bool(false)),
            ("vault = \"/tmp\"\n", "vault", .string("~/notes")),
            ("vault_settings = true\n", "vault_settings", .strings(["appearance.font"])),
        ]
        for (vault, key, kept) in cases {
            let settings = resolved(vault: vault, computer: computer)
            #expect(settings[key] == kept, "\(key)")
            #expect(settings.refused == [key], "\(key)")
            #expect(settings.fromVault.isEmpty, "\(key)")
            #expect(settings.source(of: key) == .computer, "\(key)")
        }
        // All at once, and beside keys a vault may set and sections that are not the app's.
        let all = resolved(vault: cases.reversed().map(\.vault).joined(separator: "\n") + "\n[appearance]\ntheme = \"light\"\n[check]\nmemory = true\n[agents]\nread_only_clones = false\n[notifications]\nlater = 1\n", computer: computer)
        #expect(Set(all.refused) == Set(cases.map(\.key)))
        #expect(all.refused.count == cases.count)
        #expect(all.fromVault == ["appearance.theme"])
        // A key of the app's that is not on the list is refused too.
        #expect(resolved(vault: "[wakatime]\ncli = \"/tmp/x\"\n[editor]\ntypewriter = true\n[meaning]\nsearch = false\n", computer: "").refused == ["wakatime.cli", "editor.typewriter", "meaning.search"])
    }

    @Test func theVaultOnlyTurnsWebPicturesOff() {
        let on = "[appearance]\nremote_images = true\n", off = "[appearance]\nremote_images = false\n"
        #expect(resolved(vault: off, computer: on).bool("appearance.remote_images") == false)
        #expect(resolved(vault: on, computer: off).bool("appearance.remote_images") == false)
        #expect(resolved(vault: on, computer: off).fromVault.isEmpty)
        #expect(resolved(vault: on, computer: on).bool("appearance.remote_images") == true)
        #expect(resolved(vault: off, computer: off).bool("appearance.remote_images") == false)
    }

    @Test func aPathFromTheVaultStaysInIt() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "daftar-vaultconfig-\(UUID().uuidString)")
        let root = base.appending(path: "vault")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: root.appending(path: "uploads"), withIntermediateDirectories: true)
        try Data("picture".utf8).write(to: root.appending(path: "uploads/home.webp"))
        try Data("outside".utf8).write(to: base.appending(path: "x.png"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "uploads/link.png"), withDestinationURL: base.appending(path: "x.png"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "out"), withDestinationURL: base)
        let computer = "[home]\nimage = \"~/Pictures/mine.png\"\n\n[export]\nlogo = \"\"\n\n[scratchpad]\nnote = \"Scratchpad.md\"\n\n[capture]\ntarget = \"daily\"\n"
        func image(_ path: String) -> ResolvedSettings { resolved(vault: "[home]\nimage = \"\(path)\"\n", computer: computer, root: root) }
        // A path in the vault is that file in the vault.
        let inside = image("uploads/home.webp")
        #expect(inside.string("home.image") == "uploads/home.webp")
        #expect(inside.source(of: "home.image") == .vault)
        #expect(Vault.file("uploads/home.webp", in: root)?.resolvingSymlinksInPath().path == root.appending(path: "uploads/home.webp").resolvingSymlinksInPath().path)
        // Outside it, by any spelling, the computer's value is used.
        for path in ["/etc/passwd", "~/x.png", "../x.png", "uploads/../../x.png", "uploads/link.png", "out/x.png", "./uploads/home.webp", "uploads//home.webp"] {
            let settings = image(path)
            #expect(settings.string("home.image") == "~/Pictures/mine.png", "\(path)")
            #expect(settings.source(of: "home.image") == .computer, "\(path)")
        }
        // The text alone refuses what leaves, when no folder is given.
        for path in ["/etc/passwd", "~/x.png", "../x.png", "uploads/../../x.png"] {
            #expect(resolved(vault: "[home]\nimage = \"\(path)\"\n", computer: computer).string("home.image") == "~/Pictures/mine.png", "\(path)")
        }
        // The same rule for the other paths a vault may set.
        let others = resolved(
            vault: "[export]\nlogo = \"/etc/logo.svg\"\n\n[scratchpad]\nnote = \"../Inbox.md\"\n\n[capture]\ntarget = \"~/Inbox.md\"\n", computer: computer, root: root)
        #expect(others.string("export.logo") == "")
        #expect(others.string("scratchpad.note") == "Scratchpad.md")
        #expect(others.string("capture.target") == "daily")
        let good = resolved(vault: "[export]\nlogo = \"uploads/logo.svg\"\n\n[scratchpad]\nnote = \"Inbox/Scratch.md\"\n\n[capture]\ntarget = \"Inbox.md\"\n", computer: computer, root: root)
        #expect(good.string("export.logo") == "uploads/logo.svg")
        #expect(good.string("scratchpad.note") == "Inbox/Scratch.md")
        #expect(good.string("capture.target") == "Inbox.md")
    }

    @Test func aWrongValueIsAsNotThere() {
        let computer = "[appearance]\ntext_size = 14\ntheme = \"light\"\n\n[notifications]\ndigest_time = \"08:30\"\n\n[git]\nsync_interval = 5\n"
        for wrong in ["\"big\"", "-3", "0", "400", "true", "[\"16\"]", "16.5"] {
            let settings = resolved(vault: "[appearance]\ntext_size = \(wrong)\n", computer: computer)
            #expect(settings.int("appearance.text_size") == 14, "\(wrong)")
            #expect(settings.source(of: "appearance.text_size") == .computer, "\(wrong)")
            #expect(settings.refused.isEmpty)
        }
        #expect(resolved(vault: "[appearance]\ntheme = \"neon\"\n", computer: computer).string("appearance.theme") == "light")
        #expect(resolved(vault: "[appearance]\ntheme = 3\n", computer: computer).string("appearance.theme") == "light")
        #expect(resolved(vault: "[notifications]\ndigest_time = \"25:00\"\n", computer: computer).string("notifications.digest_time") == "08:30")
        #expect(resolved(vault: "[git]\nsync_interval = -1\n", computer: computer).int("git.sync_interval") == 5)
        #expect(resolved(vault: "[git]\nname = \"\"\nemail = 3\n", computer: computer).author == Git.Author())
        // With no computer value either, the default.
        #expect(resolved(vault: "[appearance]\ntext_size = \"big\"\n", computer: "").int("appearance.text_size") == 16)
        // A key the app does not know is left alone.
        #expect(resolved(vault: "[capture]\nlater = \"x\"\n\n[plugin]\nshell = \"/tmp/x\"\n\nmemory = true\n", computer: computer).refused.isEmpty)
    }

    @Test func theAuthorIsTheClonesThenTheVaults() async throws {
        let clones = try TestClones(author: "Work", email: "work@example.com")
        defer { clones.remove() }
        var git = try await clones.seeded()
        func author() async throws -> String { try await git.run(["log", "-1", "--format=%an <%ae> %cn <%ce>"]) }
        // With nothing else, the commit is the global config's.
        try clones.write("one\n", to: "Note.md", in: "first")
        try await git.sync(message: "one")
        #expect(try await author() == "Work <work@example.com> Work <work@example.com>")
        // With the vault's name and email, it is the vault's.
        git.author = ResolvedSettings.resolved(vault: "[git]\nname = \"Sara Notes\"\nemail = \"sara@example.org\"\n", computer: "").author
        #expect(git.author == Git.Author(name: "Sara Notes", email: "sara@example.org"))
        try clones.write("two\n", to: "Note.md", in: "first")
        try await git.sync(message: "two")
        #expect(try await author() == "Sara Notes <sara@example.org> Sara Notes <sara@example.org>")
        // With the clone's email set too, the email is the clone's and the name the vault's.
        try await git.setLocalConfig("user.email", "clone@example.net")
        try clones.write("three\n", to: "Note.md", in: "first")
        try await git.sync(message: "three")
        #expect(try await author() == "Sara Notes <clone@example.net> Sara Notes <clone@example.net>")
        // The clone's own name wins as well, and an emptied field unsets its key.
        try await git.setLocalConfig("user.name", "Clone")
        try clones.write("four\n", to: "Note.md", in: "first")
        try await git.sync(message: "four")
        #expect(try await author() == "Clone <clone@example.net> Clone <clone@example.net>")
        try await git.setLocalConfig("user.name", "  ")
        try await git.setLocalConfig("user.email", nil)
        #expect(await git.localConfig("user.name") == nil)
        try clones.write("five\n", to: "Note.md", in: "first")
        try await git.sync(message: "five")
        #expect(try await author() == "Sara Notes <sara@example.org> Sara Notes <sara@example.org>")
        // A computer that declines the vault's settings keeps its own author.
        git.author = ResolvedSettings.resolved(vault: "[git]\nname = \"Sara Notes\"\n", computer: "vault_settings = false\n").author
        try clones.write("six\n", to: "Note.md", in: "first")
        try await git.sync(message: "six")
        #expect(try await author() == "Work <work@example.com> Work <work@example.com>")
    }

    @Test func aPlatformReadsItsOwnTable() {
        let vault = "[appearance]\ntext_size = 14\n[macos.appearance]\ntext_size = 15\n[android.appearance]\ntext_size = 16\n"
        func size(_ platform: String) -> Int? {
            ResolvedSettings.resolved(vault: vault, computer: "[appearance]\ntext_size = 12\n", platform: platform).int("appearance.text_size")
        }
        #expect(size("macos") == 15)
        #expect(size("android") == 16)
        #expect(size("linux") == 14)
        let mac = resolved(vault: vault, computer: "")
        #expect(mac.source(of: "appearance.text_size") == .vault && mac.inPlatformTable == ["appearance.text_size"])
        #expect(mac.refused.isEmpty)
        // The allow-list, the ranges and the path rules hold in a platform table as in a shared section.
        let shell = resolved(vault: "[macos.terminal]\nshell = \"/tmp/x\"\nfont_size = 15\n", computer: "[terminal]\nshell = \"/bin/zsh\"\n")
        #expect(shell.refused == ["macos.terminal.shell"])
        #expect(shell.string("terminal.shell") == "/bin/zsh" && shell.int("terminal.font_size") == 15)
        #expect(resolved(vault: "[macos.appearance]\ntext_size = 99\n[appearance]\ntext_size = 16\n", computer: "").int("appearance.text_size") == 16)
        #expect(resolved(vault: "[macos.home]\nimage = \"/etc/passwd\"\n", computer: "[home]\nimage = \"mine.png\"\n").string("home.image") == "mine.png")
        #expect(resolved(vault: "[macos.appearance]\nremote_images = true\n", computer: "[appearance]\nremote_images = false\n").bool("appearance.remote_images") == false)
        // What only the Mac has lives in its table, and nowhere else.
        let own = resolved(vault: "[macos.appearance]\ndock_badge = false\n[macos.editor]\ncursor_effect = \"ripple\"\ntypewriter = true\n", computer: "")
        #expect(own.bool("appearance.dock_badge") == false && own.string("editor.cursor_effect") == "ripple" && own.bool("editor.typewriter") == true)
        #expect(own.refused.isEmpty)
        #expect(resolved(vault: "[appearance]\ndock_badge = false\n", computer: "").refused == ["appearance.dock_badge"])
        #expect(resolved(vault: "[macos.editor]\ncursor_effect = \"fireworks\"\n", computer: "").string("editor.cursor_effect") == "none")
        // A computer that declines a key declines it in the platform's table too.
        #expect(resolved(vault: vault, computer: "vault_settings = [\"appearance.text_size\"]\n[appearance]\ntext_size = 12\n").int("appearance.text_size") == 12)
    }

    /// Where a change is written: the pure rule of section 5.
    @Test func whereAChangeIsWritten() {
        let settings = resolved(vault: "[appearance]\ntheme = \"dark\"\n[macos.appearance]\ntext_size = 15\n", computer: "")
        func where_(_ key: String, _ value: ConfigFile.Value, in settings: ResolvedSettings, writable: Bool = true) -> ResolvedSettings.Destination {
            settings.destination(of: key, value: value, writable: writable)
        }
        // The shared section, for a key every platform reads the same.
        #expect(where_("appearance.theme", .string("light"), in: settings) == .shared)
        #expect(where_("notifications.digest", .bool(false), in: settings) == .shared)
        // The platform's table: a key that is there already, a font, and what only the Mac has.
        #expect(where_("appearance.text_size", .int(17), in: settings) == .platform)
        #expect(where_("appearance.font", .string("SF Pro"), in: settings) == .platform)
        #expect(where_("appearance.code_font", .string("SF Mono"), in: settings) == .platform)
        #expect(where_("terminal.font_size", .int(13), in: settings) == .platform)
        #expect(where_("capture.hotkey", .string("ctrl+opt+n"), in: settings) == .platform)
        #expect(where_("capture.target", .string("daily"), in: settings) == .shared)
        #expect(where_("appearance.dock_badge", .bool(false), in: settings) == .platform)
        #expect(where_("editor.cursor_effect", .string("ripple"), in: settings) == .platform)
        #expect(ResolvedSettings.written("appearance.font", at: .platform) == "macos.appearance.font")
        #expect(ResolvedSettings.written("appearance.theme", at: .shared) == "appearance.theme")
        // The device: what a vault may never hold, by key or by value.
        for (key, value) in [
            ("terminal.shell", ConfigFile.Value.string("/bin/zsh")), ("editor.vim_mode", .bool(true)), ("editor.nvim", .string("/x")),
            ("wakatime.enabled", .bool(true)), ("okf.actor", .string("parham")), ("vault", .string("~/org")), ("vaults", .strings([])),
            ("vault_settings", .bool(true)), ("appearance.remote_images", .bool(true)), ("home.image", .string("/Users/p/x.png")),
            ("home.image", .string("~/x.png")), ("appearance.text_size", .int(99)),
        ] {
            #expect(where_(key, value, in: settings) == .device, "\(key)")
        }
        #expect(where_("appearance.remote_images", .bool(false), in: settings) == .shared)
        #expect(where_("home.image", .string("uploads/home.webp"), in: settings) == .shared)
        // A vault that cannot be written, and a computer that declines.
        #expect(where_("appearance.theme", .string("light"), in: settings, writable: false) == .device)
        #expect(where_("appearance.theme", .string("light"), in: resolved(vault: "", computer: "vault_settings = false\n")) == .device)
        let declined = resolved(vault: "", computer: "vault_settings = [\"appearance.theme\"]\n")
        #expect(where_("appearance.theme", .string("light"), in: declined) == .device)
        #expect(where_("appearance.text_size", .int(16), in: declined) == .shared)
        #expect(declined.declines("appearance.theme") && !declined.declines("appearance.text_size"))
    }

    /// Only the line of the key changes; a new key goes at the end of its
    /// section, a new section at the end of the file after one blank line.
    @Test func theVaultsFileIsWrittenALineAtATime() {
        var file = ConfigFile(text: "# mine\n[appearance]\ntheme = \"dark\" # night\n")
        file.set("appearance.text_size", .int(16))
        #expect(file.text == "# mine\n[appearance]\ntheme = \"dark\" # night\ntext_size = 16\n")
        file.set("appearance.theme", .string("light"))
        #expect(file.text == "# mine\n[appearance]\ntheme = \"light\" # night\ntext_size = 16\n")
        file.set("notifications.digest", .bool(false))
        #expect(file.text == "# mine\n[appearance]\ntheme = \"light\" # night\ntext_size = 16\n\n[notifications]\ndigest = false\n")
        file.set("macos.appearance.font", .string("SF Pro"))
        #expect(file.text.hasSuffix("\n[notifications]\ndigest = false\n\n[macos.appearance]\nfont = \"SF Pro\"\n"))
        // A file that was empty gets no blank line at its top.
        var empty = ConfigFile(text: "")
        empty.set("appearance.theme", .string("dark"))
        #expect(empty.text == "[appearance]\ntheme = \"dark\"\n")
    }
}
