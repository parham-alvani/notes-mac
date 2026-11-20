import Foundation
import Testing

@testable import DaftarCore

/// `docs/specs/several-vaults.md` in notes-linux, section 4: the pure rule
/// over the text of `config.toml`.
@Suite struct VaultsTests {
    let home = "/home/p"
    func vaults(_ text: String) -> Vaults { Vaults(config: text, home: home) }

    @Test func theVaultInUseIsOneOfTheList() {
        // A file with a `vault` and no `vaults`, as every one is today, is a list of that one.
        let one = vaults("vault = \"~/org\"\n")
        #expect(one.folders == ["~/org"] && one.inUse == "~/org")
        // The vault in use is always in the list.
        let two = vaults("vault = \"~/b\"\nvaults = [\"~/a\"]\n")
        #expect(two.folders == ["~/a", "~/b"] && two.inUse == "~/b")
        // No `vault` and no `vaults` is an empty list and no vault in use.
        for text in ["", "[appearance]\ntheme = \"dark\"\n", "vault = \"\"\nvaults = []\n", ConfigFile.template] {
            #expect(vaults(text).folders.isEmpty && vaults(text).inUse == nil)
        }
        // The list never holds one folder twice, in whatever spelling, and keeps the first.
        let twice = vaults("vault = \"/home/p/org/\"\nvaults = [\"~/org\", \"~/x/../org\", \"~/notes\"]\n")
        #expect(twice.folders == ["~/org", "~/notes"] && twice.inUse == "~/org")
        #expect(twice.isInUse("/home/p/org") && !twice.isInUse("~/notes") && twice.contains("/home/p/notes/"))
        // An older Daftar reads the file as before: `vault` stays the one in use.
        #expect(ConfigFile(text: two.applied(to: ConfigFile(text: "vault = \"~/b\"\nvaults = [\"~/a\"]\n")).text).string("vault") == "~/b")
    }

    @Test func openingAVaultAddsItOnce() throws {
        let text = "# mine\nvault = \"~/org\"\n\n[appearance]\ntheme = \"dark\"\n"
        var list = vaults(text)
        // The same folder by any spelling adds nothing and keeps the text it has.
        for spelling in ["/home/p/org", "~/org", "~/org/", "~/x/../org", "/home/p/./org"] {
            let added1 = list.open(spelling)
            #expect(!added1, "\(spelling)")
            #expect(list.folders == ["~/org"] && list.inUse == "~/org", "\(spelling)")
        }
        // The file names that one vault already: nothing is written.
        #expect(list.applied(to: ConfigFile(text: text)).text == text)
        // A new one is added at the end, once, and is the vault in use.
        let added2 = list.open("/home/p/notes")
            #expect(added2)
        #expect(list.folders == ["~/org", "~/notes"] && list.inUse == "~/notes")
        let added3 = list.open("~/notes/")
            #expect(!added3)
        let written = list.applied(to: ConfigFile(text: text)).text
        #expect(written == "# mine\nvault = \"~/notes\"\nvaults = [\"~/org\", \"~/notes\"]\n\n[appearance]\ntheme = \"dark\"\n")
        #expect(vaults(written) == list)
        // A change of vault moves nothing in the list.
        let added4 = list.open("~/org")
            #expect(!added4)
        #expect(list.folders == ["~/org", "~/notes"] && list.inUse == "~/org")
        // Forgetting takes the entry out; the vault in use is refused.
        try list.forget("/home/p/notes")
        #expect(list.folders == ["~/org"])
        #expect(throws: Vaults.Failure.inUse("org")) { try list.forget("~/org/") }
        #expect(list.folders == ["~/org"] && list.inUse == "~/org")
        #expect(list.applied(to: ConfigFile(text: written)).text == "# mine\nvault = \"~/org\"\nvaults = [\"~/org\"]\n\n[appearance]\ntheme = \"dark\"\n")
        // A folder outside the home folder is written as it is.
        let added5 = list.open("/Volumes/disk/notes/")
            #expect(added5)
        #expect(list.folders == ["~/org", "/Volumes/disk/notes"])
    }

    @Test func twoVaultsOfOneNameShowTheirParents() throws {
        let list = vaults("vault = \"~/org\"\nvaults = [\"~/org\", \"~/work/org\", \"~/notes\"]\n")
        #expect(list.name(of: "~/org") == "org — ~")
        #expect(list.name(of: "~/work/org") == "org — ~/work")
        #expect(list.name(of: "~/notes") == "notes")
        // A name that two vaults have is refused, and names both.
        #expect(throws: Vaults.Failure.ambiguous("org", ["org — ~", "org — ~/work"])) { try list.folder(named: "org") }
        #expect(Vaults.Failure.ambiguous("org", ["org — ~", "org — ~/work"]).errorDescription?.contains("org — ~/work") == true)
        // A name one vault has opens it; a folder is a folder, as before.
        #expect(try list.folder(named: "notes") == "~/notes")
        #expect(try list.folder(named: "~/work/org") == "~/work/org")
        #expect(try list.folder(named: "/tmp/elsewhere") == "/tmp/elsewhere")
        #expect(throws: Vaults.Failure.unknown("diary")) { try list.folder(named: "diary") }
    }

    @Test func theVaultCannotNameVaults() {
        let computer = "vault = \"~/org\"\nvaults = [\"~/org\", \"~/notes\"]\n"
        let settings = ResolvedSettings.resolved(vault: "vaults = [\"/tmp/x\"]\n\n[appearance]\ntheme = \"dark\"\n", computer: computer)
        #expect(settings.refused == ["vaults"])
        #expect(settings["vaults"] == .strings(["~/org", "~/notes"]))
        #expect(settings.source(of: "vaults") == .computer)
        #expect(settings.fromVault == ["appearance.theme"])
        // The list is the computer's file alone.
        #expect(Vaults(config: computer, home: home).folders == ["~/org", "~/notes"])
    }
}
