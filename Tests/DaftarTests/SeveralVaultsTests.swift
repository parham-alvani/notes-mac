import AppKit
import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// A change of vault in the running app, through the store's own path, on
/// made-up vaults in a temporary folder (`docs/specs/several-vaults.md` in
/// notes-linux, section 4).
@MainActor
@Suite(.serialized) struct SeveralVaultsTests {
    let base: URL
    let a: URL
    let b: URL
    let store: VaultStore
    let config: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "daftar-vaults-\(UUID().uuidString)").standardizedFileURL
        a = base.appending(path: "A")
        b = base.appending(path: "B")
        config = base.appending(path: "config/config.toml")
        for folder in [a, b, base.appending(path: "config")] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try "# Alpha\n\nalphaword\n\n- [r] In review\n".write(to: a.appending(path: "Alpha.md"), atomically: true, encoding: .utf8)
        try "# A2\n\nsecond\n".write(to: a.appending(path: "A2.md"), atomically: true, encoding: .utf8)
        try "# Beta\n\nbetaword\n".write(to: b.appending(path: "Beta.md"), atomically: true, encoding: .utf8)
        try "[appearance]\ntext_size = 14\n\n[editor]\nformat_on_save = false\n\n[git]\npull_on_launch = false\n\n[files]\nhidden = [\"CLAUDE.md\"]\n".write(to: config, atomically: true, encoding: .utf8)
        store = VaultStore(settings: AppSettings(url: config), openVault: false)
    }

    func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    func loaded() async -> Bool {
        for _ in 0..<200 {
            if !store.loading, store.root != nil { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    /// The first vault, as at a start; the rest change by the store's one path.
    func start(_ vault: URL) async {
        store.open(vault)
        #expect(await loaded())
    }

    func change(_ vault: URL) async -> Bool {
        let changed = await store.change(to: vault)
        if changed { #expect(await loaded()) }
        return changed
    }

    @Test func aChangeLeavesNothingOfTheVaultBefore() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        // `A` has a status, settings, a hidden name of its own, and is read-only.
        let plugin = a.appending(path: ".obsidian/plugins/obsidian-tasks-plugin")
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        try #"{"statusSettings":{"coreStatuses":[{"symbol":" ","name":"Todo","nextStatusSymbol":"x","type":"TODO"},{"symbol":"x","name":"Done","nextStatusSymbol":" ","type":"DONE"}],"customStatuses":[{"symbol":"r","name":"In Review","nextStatusSymbol":"x","type":"IN_PROGRESS"}]}}"#
            .write(to: plugin.appending(path: "data.json"), atomically: true, encoding: .utf8)
        try "[appearance]\ntext_size = 20\n\n[files]\nhidden = [\"Private.md\"]\n".write(to: a.appending(path: ".daftar.toml"), atomically: true, encoding: .utf8)
        try "# Private\n".write(to: a.appending(path: "Private.md"), atomically: true, encoding: .utf8)
        let git = Git(root: a)
        try await git.run(["init", "-q", "-b", "main"])
        try await git.setReadOnly(true)

        func isA(_ comment: Comment) {
            #expect(store.root?.path == a.path, comment)
            #expect(store.quickOpen("alpha", recent: []) == ["Alpha.md"], comment)
            #expect(store.quickOpen("beta", recent: []).isEmpty, comment)
            #expect(store.search.search("alphaword", limit: 10).map(\.path) == ["Alpha.md"], comment)
            #expect(store.search.search("betaword", limit: 10).isEmpty, comment)
            #expect(store.index.statuses.type("r") == .inProgress, comment)
            #expect(store.settings.textSize == 20 && store.settings.isFromVault("appearance.text_size"), comment)
            #expect(store.settings.hiddenNames == ["Private.md"], comment)
            #expect(store.hidden.contains("Private.md") && !store.quickOpen("private", recent: []).contains("Private.md"), comment)
            #expect(store.readOnly, comment)
            #expect(throws: VaultEdits.Failure.readOnly, comment) { try store.write("# Alpha\nedited\n", to: "Alpha.md") }
            #expect(Vaults(config: text(config)).inUse.map { Vaults(config: "").path(of: $0) } == a.path, comment)
            #expect(store.index.files.contains("Alpha.md") && !store.index.files.contains("Beta.md"), comment)
        }
        await start(a)
        isA("at the start")
        let alpha = text(a.appending(path: "Alpha.md"))

        // From `A` to `B`: nothing of `A` is left.
        #expect(await change(b))
        #expect(store.root?.path == b.path)
        #expect(store.quickOpen("beta", recent: []) == ["Beta.md"])
        #expect(store.quickOpen("alpha", recent: []).isEmpty)
        #expect(store.quickOpen("private", recent: []).isEmpty)
        #expect(store.search.search("betaword", limit: 10).map(\.path) == ["Beta.md"])
        #expect(store.search.search("alphaword", limit: 10).isEmpty)
        #expect(store.index.files == ["Beta.md"])
        #expect(store.index.tasksInOrder.isEmpty)
        #expect(store.index.backlinks.isEmpty && store.index.notes.keys.sorted() == ["Beta.md"])
        // The statuses are the defaults.
        #expect(store.index.statuses == TaskStatuses.defaults)
        #expect(store.index.statuses.type("r") != .inProgress)
        // The settings are the computer's.
        #expect(store.settings.textSize == 14)
        #expect(store.settings.fromVault.isEmpty)
        #expect(store.settings.hiddenNames == ["CLAUDE.md"])
        #expect(!store.hidden.contains("Private.md"))
        // Not read-only, not a repository, and a write succeeds.
        #expect(!store.readOnly && !store.isRepository && store.gitStatus == nil && store.syncError == nil)
        try store.write("# Beta\n\nbetaword\nwritten\n", to: "Beta.md")
        #expect(text(b.appending(path: "Beta.md")) == "# Beta\n\nbetaword\nwritten\n")
        // No finding of `A` in the Problems panel.
        #expect(store.checks.problems.isEmpty && !store.checks.any)
        // `vault` is `B`, and the list has both, `A` first.
        let list = Vaults(config: text(config))
        #expect(list.inUse.map(list.path(of:)) == b.path)
        #expect(list.folders.map(list.path(of:)) == [a.path, b.path])
        #expect(store.listedVaults.map(\.inUse) == [false, true])
        // The alerts follow the vault in use: none of `A`'s meetings is planned from `B`.
        #expect(Notifier.plan(store: store).allSatisfy { !$0.id.contains("Alpha") })

        // Back to `A`: each is `A`'s again, and the write is refused.
        #expect(await change(a))
        isA("after the change back")
        #expect(text(a.appending(path: "Alpha.md")) == alpha)
        #expect(Vaults(config: text(config)).folders.count == 2)
    }

    @Test func eachVaultKeepsItsTabs() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let tabs = WindowTabs()
        tabs.adopt = { [store] tab in tab.places = store.places }
        store.windows = { [tabs] }
        await start(a)
        // `A` shows Alpha and A2 in two tabs, Alpha in front, each read to a line.
        tabs.current.open("Alpha.md", store: store)
        tabs.add { $0.open("A2.md", store: self.store) }
        tabs.current.focused.cursorLine = 2
        tabs.select(tabs.tabs[0])
        tabs.current.focused.cursorLine = 4
        #expect(tabs.tabs.map(\.path) == ["Alpha.md", "A2.md"] && tabs.current.path == "Alpha.md")
        let alphaTab = tabs.current

        // `B`, opened for the first time, shows the home page.
        #expect(await change(b))
        #expect(tabs.tabs.count == 1 && tabs.current.path == nil && tabs.current.showsHome)
        #expect(alphaTab.tabs == nil)
        tabs.current.open("Beta.md", store: store)

        // Back in `A`: its two tabs, the same one in front, each at its reading place.
        #expect(await change(a))
        #expect(tabs.tabs.map(\.path) == ["Alpha.md", "A2.md"])
        #expect(tabs.current.path == "Alpha.md" && tabs.chrome === tabs.current)
        #expect(tabs.tabs.map { $0.request?.line } == [4, 2])

        // And `B`, opened again, shows Beta.
        #expect(await change(b))
        #expect(tabs.tabs.map(\.path) == ["Beta.md"])
        // Kept by the vault's folder, in the app's state, never in a vault.
        #expect(FileManager.default.fileExists(atPath: VaultTabs.file(of: a, in: store.settings.stateDirectory).path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: a.path).sorted() == ["A2.md", "Alpha.md"])
        // A note that went since does not come back as a tab.
        try FileManager.default.removeItem(at: a.appending(path: "A2.md"))
        #expect(await change(a))
        #expect(tabs.tabs.map(\.path) == ["Alpha.md"])
    }

    @Test func aMissingVaultIsListedAndNotOpened() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let gone = base.appending(path: "Gone")
        try "vault = \"\(a.path)\"\nvaults = [\"\(a.path)\", \"\(gone.path)\"]\n\n[git]\npull_on_launch = false\n".write(to: config, atomically: true, encoding: .utf8)
        let store = VaultStore(settings: AppSettings(url: config), openVault: true)
        for _ in 0..<200 where store.loading { try? await Task.sleep(for: .milliseconds(25)) }
        // It is in the list, as missing.
        #expect(store.listedVaults.map(\.name) == ["A", "Gone"])
        #expect(store.listedVaults.map(\.missing) == [false, true])
        #expect(store.listedVaults.map(\.inUse) == [true, false])
        // A change to it is refused with a notice, and the vault in use stays.
        #expect(await !store.change(to: gone))
        #expect(store.notice?.contains("Gone is not there") == true)
        #expect(store.root?.path == a.path && store.index.files.contains("Alpha.md"))
        #expect(Vaults(config: text(config)).inUse == a.path)
        // It is still in the list afterwards, until it is forgotten.
        #expect(store.listedVaults.map(\.name) == ["A", "Gone"])
        // The vault in use cannot be forgotten.
        store.forgetVault(a.path)
        #expect(store.notice?.contains("cannot be forgotten") == true)
        #expect(store.listedVaults.count == 2)
        store.forgetVault(gone.path)
        #expect(store.listedVaults.map(\.name) == ["A"])
        #expect(Vaults(config: text(config)).folders == [a.path])
    }

    @Test func anUnsavedEditorStopsTheChange() async throws {
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: a.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: a.appending(path: "Alpha.md").path)
            try? FileManager.default.removeItem(at: base)
        }
        await start(a)
        let controller = EditorController(store: store)
        let scroll = NoteTextView.scrollableNoteView()
        let view = scroll.documentView as! NoteTextView
        view.controller = controller
        controller.view = view
        controller.load("Alpha.md")
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertText("typed and not saved", replacementRange: view.selectedRange())
        let typed = view.string
        let disk = text(a.appending(path: "Alpha.md"))
        #expect(typed.hasSuffix("typed and not saved") && typed != disk)
        // The save fails: the folder takes no new file, and the note none in its place.
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: a.appending(path: "Alpha.md").path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: a.path)
        #expect(await !store.change(to: b))
        // The change is refused, the vault stays and the editor's text is kept.
        #expect(store.root?.path == a.path)
        #expect(store.notice?.contains("vault was not changed") == true)
        #expect(view.string == typed && controller.hasUnsaved)
        #expect(text(a.appending(path: "Alpha.md")) == disk)
        #expect(Vaults(config: text(config)).inUse.map { Vaults(config: "").path(of: $0) } == a.path)
        #expect(store.index.files.contains("Alpha.md"))
        // Once the save goes through, the change does.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: a.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: a.appending(path: "Alpha.md").path)
        #expect(view.string == typed && controller.hasUnsaved, "before the second try")
        #expect(await change(b))
        #expect(store.root?.path == b.path)
        #expect(text(a.appending(path: "Alpha.md")) == typed)
    }
}
