import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// A read-only vault and the vault's own settings, through the store, on
/// made-up clones in a temporary folder (`docs/specs/read-only-vault.md`
/// and `vault-config.md` in notes-linux).
@MainActor
@Suite(.serialized) struct ReadOnlyStoreTests {
    let base: URL
    let first: Git
    let second: Git

    init() async throws {
        base = FileManager.default.temporaryDirectory.appending(path: "daftar-store-readonly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        first = Git(root: base.appending(path: "first"))
        second = Git(root: base.appending(path: "second"))
        try await Git(root: base).run(["init", "-q", "--bare", "-b", "main", "remote.git"])
        try await Git(root: base).run(["clone", "-q", "remote.git", "first"])
        try await setUp(first)
        try write("# Note\ntext\n", to: "Note.md", in: first)
        try write("# Tasks\n- [ ] Call Sara #work\n- [x] Done ✅ 2026-11-01\n", to: "Tasks.md", in: first)
        try write("# Other\n[[Note]]\n", to: "Folder/Other.md", in: first)
        try await first.run(["add", "-A"])
        try await first.run(["commit", "-qm", "first"])
        try await first.run(["push", "-q", "-u", "origin", "main"])
        try await Git(root: base).run(["clone", "-q", "remote.git", "second"])
        try await setUp(second)
    }

    func setUp(_ git: Git) async throws {
        try await git.run(["config", "user.email", "test@example.com"])
        try await git.run(["config", "user.name", "Test"])
        try await git.run(["config", "commit.gpgsign", "false"])
    }

    func write(_ text: String, to path: String, in git: Git) throws {
        let file = git.root.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    func store(_ git: Git, config: String? = nil) throws -> VaultStore {
        let url = base.appending(path: "config-\(git.root.lastPathComponent)/config.toml")
        if let config {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try config.write(to: url, atomically: true, encoding: .utf8)
        }
        let store = VaultStore(settings: AppSettings(url: url), openVault: false)
        store.openSynchronously(git.root)
        return store
    }

    /// Every file of the vault, but git's own, with its bytes.
    func files(_ git: Git) -> [String: Data] {
        var found: [String: Data] = [:]
        let base = git.root.resolvingSymlinksInPath().path + "/"
        for case let url as URL in FileManager.default.enumerator(at: git.root, includingPropertiesForKeys: nil) ?? .init() {
            let path = String(url.resolvingSymlinksInPath().path.dropFirst(base.count))
            guard !path.hasPrefix(".git/"), path != ".git", let data = try? Data(contentsOf: url) else { continue }
            found[path] = data
        }
        return found
    }

    @Test func aReadOnlyVaultRefusesEveryWrite() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try await second.setReadOnly(true)
        let store = try store(second)
        #expect(store.readOnly)
        let before = files(second)
        #expect(before.count == 3)
        func refused(_ work: () async throws -> Void, _ what: Comment) async {
            do {
                try await work()
                Issue.record("written: \(what)")
            } catch {
                #expect(error as? VaultEdits.Failure == .readOnly, what)
            }
        }
        func noticed(_ what: Comment) {
            #expect(store.notice == VaultStore.readOnlyNotice, what)
            store.notice = nil
        }
        // A write, as the editor's save is.
        await refused({ try store.write("# Note\nedited\n", to: "Note.md") }, "a write")
        await refused({ try await store.restore("# Note\nolder\n", to: "Note.md") }, "a restored revision")
        // A task tick, and a status.
        store.toggleTask(path: "Tasks.md", line: 1, status: " ")
        noticed("a tick")
        let task = try #require(store.index.notes["Tasks.md"]?.parsed.tasks.first)
        #expect(!store.setTaskStatus(VaultTask(path: "Tasks.md", task: task), to: "x"))
        noticed("a status")
        var fields = TaskFields()
        fields.text = "New"
        #expect(!store.addTask(fields, to: "Tasks.md", headingLine: nil))
        noticed("a new task")
        #expect(!store.sortTasks("Tasks.md"))
        noticed("sort tasks")
        // A capture, and the scratchpad.
        await refused({ try await store.capture("- [ ] Captured") }, "a capture")
        await refused({ try await store.addToScratchpad("a line") }, "the scratchpad")
        await refused({ _ = try store.scratchpad() }, "the scratchpad's note")
        // A new note, the daily note, a folder.
        await refused({ _ = try store.createNote(named: "New", in: "") }, "a new note")
        await refused({ _ = try store.periodicNote() }, "the daily note")
        await refused({ _ = try store.createFolder(named: "Made", in: "") }, "a new folder")
        // A move, a rename and a delete.
        await refused({ _ = try await store.move("Note.md", to: "Folder/Note.md") }, "a move")
        await refused({ _ = try await store.move("Note.md", to: "Renamed.md") }, "a rename")
        await refused({ try await store.delete("Note.md") }, "a delete")
        // The rest of what writes.
        #expect(await store.renameTag("work", to: "job") == 0)
        noticed("a tag rename")
        #expect(!store.addBlockId("abc123", to: "Note.md", line: 1, text: "text"))
        noticed("a block id")
        store.toggleBookmark("Note.md")
        noticed("a bookmark")
        store.setIcon("Note.md", icon: "lucide-star", color: nil)
        noticed("an icon")
        store.checks.fixAll()
        noticed("Fix All")
        store.checks.formatNote("Note.md")
        noticed("Format Note")
        // Every file has the bytes it had, and git sees no change.
        #expect(files(second) == before)
        #expect(try await second.run(["status", "--porcelain"]).isEmpty)
        // What is not in the vault is still written: the reading place.
        store.places.markRead("Note.md")
        #expect(store.places.lastRead("Note.md") != nil)
        // Off again, only the one key changed and a write goes through.
        await store.setReadOnly(false)
        #expect(!store.readOnly)
        try store.write("# Note\nedited\n", to: "Note.md")
        #expect(try String(contentsOf: second.root.appending(path: "Note.md"), encoding: .utf8) == "# Note\nedited\n")
    }

    /// `git config daftar.readonly true` in a shell holds for the app's
    /// next write, before the store has looked again.
    @Test func theSwitchInAShellHoldsForTheNextWrite() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try store(second)
        #expect(!store.readOnly)
        try store.write("# Note\none\n", to: "Note.md")
        try await second.run(["config", "--local", "daftar.readonly", "true"])
        #expect(throws: VaultEdits.Failure.readOnly) { try store.write("# Note\ntwo\n", to: "Note.md") }
        #expect(store.readOnly)
        #expect(try String(contentsOf: second.root.appending(path: "Note.md"), encoding: .utf8) == "# Note\none\n")
        try await second.run(["config", "--local", "--unset", "daftar.readonly"])
        store.refreshReadOnly()
        #expect(!store.readOnly)
    }

    @Test func aReadOnlyVaultsSyncSaysPulledOrUpToDate() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try await second.setReadOnly(true)
        let store = try store(second)
        await store.sync()
        #expect(store.notice == "Up to date")
        #expect(store.syncError == nil && store.lastSync != nil)
        try write("# Note\nfrom the first\n", to: "Note.md", in: first)
        try await first.sync(message: "from the first")
        try write("by hand\n", to: "Hand.md", in: second)
        await store.sync()
        #expect(store.notice == "Pulled")
        #expect(try String(contentsOf: second.root.appending(path: "Note.md"), encoding: .utf8) == "# Note\nfrom the first\n")
        #expect(try await second.run(["rev-list", "@{u}..HEAD"]).isEmpty)
        #expect(try await second.changes() == ["Hand.md"])
        // The timer's sync and the pull say nothing new when asked quietly.
        store.notice = nil
        await store.sync(quiet: true)
        #expect(store.notice == nil)
        await store.pull()
        #expect(store.notice == "Up to date")
        // A clone that diverged is named, and nothing is mended.
        try write("# Note\nmine\n", to: "Note.md", in: second)
        try write("# Note\ntheirs\n", to: "Note.md", in: first)
        try await first.sync(message: "theirs")
        await store.sync()
        #expect(store.syncError?.contains("Note.md") == true)
        #expect(store.notice?.contains("Note.md") == true)
        #expect(!store.rebasing)
        #expect(try String(contentsOf: second.root.appending(path: "Note.md"), encoding: .utf8) == "# Note\nmine\n")
    }

    @Test func aRefusedPushOffersToMakeTheVaultReadOnly() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let hook = base.appending(path: "remote.git/hooks/pre-receive")
        try "#!/bin/sh\necho 'ERROR: The key you are authenticating with has been marked as read only.' >&2\nexit 1\n"
            .write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let store = try store(second)
        try write("# Note\nmine\n", to: "Note.md", in: second)
        await store.sync()
        #expect(store.pushRefused)
        #expect(store.noticeOffer == .makeReadOnly)
        #expect(store.notice?.contains("cannot write") == true)
        // The commit already made stays.
        #expect(try await second.run(["rev-list", "--count", "@{u}..HEAD"]) == "1")
        await store.setReadOnly(true)
        #expect(store.readOnly && !store.pushRefused)
        #expect(await second.localConfig("daftar.readonly") == "true")
        store.notice = nil
        #expect(store.noticeOffer == nil)
        // From now on the sync is a pull, and the commit is still there.
        await store.sync()
        #expect(store.syncError == nil)
        #expect(try await second.run(["rev-list", "--count", "@{u}..HEAD"]) == "1")
    }

    @Test func theClonesSettingsAreItsGitConfig() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try store(second)
        var clone = try #require(await store.cloneSettings())
        // Git keeps the address as it resolved it (`/private/var/…`).
        #expect(clone.address.hasSuffix("/\(base.lastPathComponent)/remote.git"))
        clone.address = ""
        #expect(clone == VaultStore.CloneSettings(readOnly: false, address: "", name: "Test", email: "test@example.com", ssh: ""))
        #expect(await store.setCloneConfig("user.name", "Sara") == nil)
        #expect(await store.setCloneConfig("user.email", "") == nil)
        #expect(await store.setCloneConfig("core.sshCommand", SSHKey.command(key: "/tmp/key file")) == nil)
        #expect(await store.setAddress("   ") == "The vault's address cannot be empty.")
        #expect(await store.setAddress(" git@example.org:notes.git ") == nil)
        await store.setReadOnly(true)
        clone = try #require(await store.cloneSettings())
        #expect(clone == VaultStore.CloneSettings(readOnly: true, address: "git@example.org:notes.git", name: "Sara", email: "", ssh: "ssh -i '/tmp/key file' -o IdentitiesOnly=yes"))
        #expect(try await second.run(["config", "--local", "--get", "remote.origin.url"]) == "git@example.org:notes.git")
        #expect(await second.localConfig("user.email") == nil)
        // A folder that is no repository has none of them.
        let plain = base.appending(path: "plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let other = VaultStore(settings: AppSettings(url: base.appending(path: "config-plain/config.toml")), openVault: false)
        other.openSynchronously(plain)
        #expect(await other.cloneSettings() == nil)
        #expect(!other.readOnly)
    }

    @Test func aSettingChangedInTheAppGoesToTheComputer() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let vault = "[appearance]\ntext_size = 16\ntheme = \"dark\"\n\n[terminal]\nshell = \"/tmp/x\"\n\n[reader]\nfolded = true\n"
        try write(vault, to: ".daftar.toml", in: second)
        let store = try store(second, config: "[appearance]\ntext_size = 14\n\n[terminal]\nshell = \"/bin/zsh\"\n")
        let settings = store.settings
        // The vault's value wins, and the control says where it is from.
        #expect(settings.textSize == 16)
        #expect(settings.appearance == .dark)
        #expect(settings.isFromVault("appearance.text_size") && settings.isFromVault("appearance.theme"))
        #expect(!settings.isFromVault("terminal.shell"))
        #expect(settings.shell == "/bin/zsh")
        #expect(settings.refusedByVault == ["terminal.shell"])
        #expect(store.foldsSections)
        // Opening the vault wrote nothing of the vault's values into the computer's file.
        let config = try String(contentsOf: settings.url, encoding: .utf8)
        #expect(config.contains("text_size = 14") && !config.contains("dark"))
        // A change in the app writes config.toml, and leaves .daftar.toml byte for byte.
        let bytes = try Data(contentsOf: second.root.appending(path: ".daftar.toml"))
        settings.textSize = 18
        #expect(try String(contentsOf: settings.url, encoding: .utf8).contains("text_size = 18"))
        #expect(try Data(contentsOf: second.root.appending(path: ".daftar.toml")) == bytes)
        #expect(try await second.run(["status", "--porcelain"]) == "?? .daftar.toml")
        // The vault's file changed: read again, as after a pull.
        try write("[appearance]\ntext_size = 20\n", to: ".daftar.toml", in: second)
        store.changed([FileWatcher.vault])
        #expect(settings.textSize == 20)
        #expect(settings.appearance == .system)
        #expect(!store.foldsSections)
        // A computer can decline: one key, or all of them.
        settings.followsVault = false
        #expect(try String(contentsOf: settings.url, encoding: .utf8).contains("vault_settings = false"))
        #expect(settings.textSize == 18)
        #expect(settings.fromVault.isEmpty)
        settings.followsVault = true
        #expect(settings.textSize == 20)
    }

    @Test func theVaultsAuthorSignsACloneWithNone() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try write("[git]\nname = \"Vault Notes\"\nemail = \"vault@example.org\"\n", to: ".daftar.toml", in: second)
        try await second.run(["config", "--local", "--unset", "user.name"])
        let store = try store(second)
        #expect(store.settings.vaultAuthor == Git.Author(name: "Vault Notes", email: "vault@example.org"))
        await store.sync()
        #expect(store.syncError == nil)
        // The name is the vault's; the email is the clone's own.
        #expect(try await second.run(["log", "-1", "--format=%an <%ae>"]) == "Vault Notes <test@example.com>")
    }

    @Test func aReadOnlyCloneCanRefuseAgents() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try write("[agents]\nread_only_clones = false\n", to: ".daftar.toml", in: second)
        let store = try store(second)
        // A clone that is not read-only is never touched by the key.
        #expect(!store.refusesAgents)
        await store.setReadOnly(true)
        #expect(store.refusesAgents)
        let assistant = NoteAssistant()
        assistant.refuse(VaultStore.agentsRefused)
        #expect(assistant.failure == VaultStore.agentsRefused && !assistant.working)
        // Without the key a read-only clone is still read.
        try write("[reader]\nfolded = true\n", to: ".daftar.toml", in: second)
        store.changed([FileWatcher.vault])
        #expect(!store.refusesAgents)
    }
}

/// An OKF concept through the store: Mark as Verified, and the deprecated
/// concept after the others in quick open.
@MainActor
@Suite(.serialized) struct ConceptStoreTests {
    let root: URL
    let store: VaultStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-concept-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Metrics"), withIntermediateDirectories: true)
        try "---\ntype: Metric\nowner: data\nverified: { by: \"process:nightly\", at: \"2026-06-25T03:00:00Z\" }\n---\n# Revenue\n".write(
            to: root.appending(path: "Metrics/Revenue.md"), atomically: true, encoding: .utf8)
        try "---\ntype: Metric\nstatus: deprecated\nsuperseded_by: Revenue.md\n---\n# Revenue old\n".write(
            to: root.appending(path: "Metrics/Revenue old.md"), atomically: true, encoding: .utf8)
        try "---\ntype: Metric\nstale_after: 2020-01-01\n---\n# Revenue net\n".write(to: root.appending(path: "Metrics/Revenue net.md"), atomically: true, encoding: .utf8)
        try "# Plain\n".write(to: root.appending(path: "Plain.md"), atomically: true, encoding: .utf8)
        store = VaultStore(settings: AppSettings(url: root.appending(path: "config/config.toml")), openVault: false)
        store.openSynchronously(root)
    }

    func text(_ path: String) throws -> String { try String(contentsOf: root.appending(path: path), encoding: .utf8) }

    @Test func markAsVerifiedWritesOneEventThroughTheStore() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        // Nobody to sign as: the command says to set it, and writes nothing.
        let before = try text("Metrics/Revenue.md")
        #expect(await !store.markVerified("Metrics/Revenue.md"))
        #expect(store.notice?.contains("okf.actor") == true)
        #expect(try text("Metrics/Revenue.md") == before)
        store.settings.okfActor = "parham"
        #expect(try String(contentsOf: store.settings.url, encoding: .utf8).contains("actor = \"parham\""))
        let now = ISO8601DateFormatter().date(from: "2026-06-30T14:00:05Z")!
        #expect(await store.markVerified("Metrics/Revenue.md", at: now))
        #expect(try text("Metrics/Revenue.md")
            == "---\ntype: Metric\nowner: data\nverified:\n  - { by: \"process:nightly\", at: \"2026-06-25T03:00:00Z\" }\n  - { by: \"human:parham\", at: \"2026-06-30T14:00:05Z\" }\n---\n# Revenue\n")
        #expect(await store.markVerified("Metrics/Revenue.md", at: now.addingTimeInterval(60)))
        #expect(OKF.concept(note: try text("Metrics/Revenue.md"))?.verified.map(\.by) == ["process:nightly", "human:parham"])
        // Offered on a concept only.
        #expect(await !store.markVerified("Plain.md"))
        #expect(try text("Plain.md") == "# Plain\n")
        // The lists know the concepts: the deprecated one is dimmed and comes after its like.
        #expect(store.isDeprecated("Metrics/Revenue old.md") && !store.isDeprecated("Metrics/Revenue.md") && !store.isDeprecated("Plain.md"))
        #expect(store.index.superseding("Metrics/Revenue old.md") == "Metrics/Revenue.md")
        #expect(ConceptLine.text(store.index.concept(of: "Metrics/Revenue old.md")!) == "Deprecated.")
        #expect(ConceptLine.text(store.index.concept(of: "Metrics/Revenue net.md")!) == "Stale since 2020-01-01: check it again.")
        #expect(ConceptLine.text(OKF.concept(frontMatter: "type: Metric")!) == nil)
        let found = store.quickOpen("revenue", recent: [])
        #expect(found.last == "Metrics/Revenue old.md" && found.count == 3)
        let alike = [
            QuickSwitcher.Candidate(path: "A/Old plan.md", title: "Old plan", deprecated: true),
            QuickSwitcher.Candidate(path: "B/Old plan.md", title: "Old plan"),
        ]
        #expect(QuickSwitcher.rank("old plan", in: alike) == ["B/Old plan.md", "A/Old plan.md"])
    }
}
