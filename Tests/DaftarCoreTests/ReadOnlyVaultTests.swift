import Foundation
import Testing

@testable import DaftarCore

/// Clones of made-up repositories in a temporary folder, with a global
/// config of their own: no test reads or writes the person's git config.
struct TestClones {
    let base: URL
    let environment: [String: String]

    init(author: String = "Test", email: String = "test@example.com") throws {
        base = FileManager.default.temporaryDirectory.appending(path: "daftar-clones-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let global = base.appending(path: "global.gitconfig")
        try "[user]\n\tname = \(author)\n\temail = \(email)\n[init]\n\tdefaultBranch = main\n[commit]\n\tgpgsign = false\n"
            .write(to: global, atomically: true, encoding: .utf8)
        environment = ["GIT_CONFIG_GLOBAL": global.path, "GIT_CONFIG_NOSYSTEM": "1"]
    }

    func remove() { try? FileManager.default.removeItem(at: base) }

    func url(_ name: String) -> URL { base.appending(path: name) }
    func git(_ name: String) -> Git { Git(root: url(name), environment: environment) }

    /// A bare repository named [name].
    @discardableResult
    func bare(_ name: String) async throws -> URL {
        try await Git(root: base, environment: environment).run(["init", "-q", "--bare", "-b", "main", url(name).path])
        return url(name)
    }

    /// A clone of [remote] named [name].
    @discardableResult
    func clone(_ remote: String, as name: String) async throws -> Git {
        try await Git(root: base, environment: environment).run(["clone", "-q", url(remote).path, url(name).path])
        return git(name)
    }

    func write(_ text: String, to path: String, in name: String) throws {
        let file = url(name).appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    func read(_ path: String, in name: String) -> String? { try? String(contentsOf: url(name).appending(path: path), encoding: .utf8) }

    /// A bare `remote`, and a clone `first` that pushed one commit to it.
    func seeded() async throws -> Git {
        try await bare("remote")
        let first = try await clone("remote", as: "first")
        try write("# Note\n", to: "Note.md", in: "first")
        try await first.run(["add", "-A"])
        try await first.run(["commit", "-q", "-m", "first"])
        try await first.run(["push", "-q", "-u", "origin", "main"])
        return first
    }

    /// Commits [text] in [path] of the clone [name].
    func commit(_ text: String, to path: String, in name: String, message: String = "change") async throws {
        try write(text, to: path, in: name)
        try await git(name).run(["add", "-A"])
        try await git(name).run(["commit", "-q", "-m", message])
    }
}

/// `docs/specs/read-only-vault.md` in notes-linux, section 6, by name.
@Suite struct ReadOnlyVaultTests {
    @Test func theSshCommandKeepsTheClonesKey() {
        let options = " -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=3"
        // No config, no environment: `ssh` and the app's options.
        #expect(Git.sshCommand(configured: nil, environment: nil) == "ssh" + options)
        #expect(Git.ssh == "ssh" + options)
        // The clone's key stays, and the app's options come after it.
        let keyed = "ssh -i ~/.ssh/notes_ro -o IdentitiesOnly=yes"
        #expect(Git.sshCommand(configured: keyed, environment: nil) == keyed + options)
        // An option the command names already, in any case, is not added again.
        #expect(
            Git.sshCommand(configured: "ssh -o batchmode=no", environment: nil)
                == "ssh -o batchmode=no -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=3")
        // The person's own variable is used as it is, whatever the clone says.
        #expect(Git.sshCommand(configured: keyed, environment: "ssh -v") == "ssh -v")
        #expect(Git.sshCommand(configured: nil, environment: "ssh -v") == "ssh -v")
        // Empty or blank is as not set.
        for blank in ["", "  ", "\n\t"] {
            #expect(Git.sshCommand(configured: blank, environment: blank) == "ssh" + options)
            #expect(Git.sshCommand(configured: keyed, environment: blank) == keyed + options)
            #expect(Git.sshCommand(configured: blank, environment: "ssh -v") == "ssh -v")
        }
    }

    /// The variable git gets is the rule's answer for the clone's config.
    @Test func gitRunsWithTheClonesSshCommand() async throws {
        let clones = try TestClones()
        defer { clones.remove() }
        let first = try await clones.seeded()
        // The hook of a fetch is `ssh` itself: a script that writes what it was run as.
        let seen = clones.url("seen.txt")
        let script = clones.url("ssh.sh")
        try "#!/bin/sh\necho \"$GIT_SSH_COMMAND\" > '\(seen.path)'\nexit 1\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try await first.run(["config", "--local", "core.sshCommand", "\(script.path) -i /tmp/key"])
        try await first.run(["remote", "set-url", "origin", "git@example.invalid:vault.git"])
        _ = try? await first.run(["fetch", "origin"])
        let said = try String(contentsOf: seen, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(said == "\(script.path) -i /tmp/key -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=3")
        #expect(Git.reachesRemote(["-c", "user.name=x", "pull", "--rebase"]))
        #expect(!Git.reachesRemote(["status", "--porcelain=v2"]))
        #expect(!Git.reachesRemote(["-c", "core.quotePath=false", "log", "push"]))
    }

    @Test func aCloneIsReadOnlyByItsOwnConfig() async throws {
        let clones = try TestClones()
        defer { clones.remove() }
        let git = try await clones.seeded()
        let root = clones.url("first")
        func both() async -> Bool {
            let asked = await git.isReadOnly()
            #expect(git.readsReadOnly() == asked)
            #expect(VaultEdits.isReadOnly(root) == asked)
            return asked
        }
        // Not set is not read-only.
        #expect(await !both())
        for on in ["true", "yes", "on", "1"] {
            try await git.run(["config", "--local", "daftar.readonly", on])
            #expect(await both(), "\(on)")
        }
        for off in ["false", "no", "off", "0"] {
            try await git.run(["config", "--local", "daftar.readonly", off])
            #expect(await !both(), "\(off)")
        }
        // When in doubt the app does not write.
        try await git.run(["config", "--local", "daftar.readonly", "perhaps"])
        #expect(await both())
        // The global config is not read: a computer cannot make every vault read-only by accident.
        try await git.run(["config", "--local", "--unset", "daftar.readonly"])
        try await git.run(["config", "--global", "daftar.readonly", "true"])
        #expect(try await git.run(["config", "--get", "daftar.readonly"]) == "true")
        #expect(await !both())
        // The app's own switch writes and takes away the one key.
        try await git.setReadOnly(true)
        #expect(await git.localConfig("daftar.readonly") == "true")
        #expect(await both())
        try await git.setReadOnly(false)
        #expect(await git.localConfig("daftar.readonly") == nil)
        try await git.setReadOnly(false)
        #expect(await !both())
        // A folder that is no repository is never read-only.
        let plain = clones.url("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let none = clones.git("plain")
        #expect(await !none.isReadOnly())
        #expect(!none.readsReadOnly())
        #expect(!VaultEdits.isReadOnly(plain))
    }

    /// The core's own writers refuse before they read; the app's whole
    /// write path is `StoreReadOnlyTests.aReadOnlyVaultRefusesEveryWrite`.
    @Test func theCoresWritersRefuseAReadOnlyVault() async throws {
        let clones = try TestClones()
        defer { clones.remove() }
        let git = try await clones.seeded()
        let root = clones.url("first")
        try clones.write("- [ ] Task\n", to: "Tasks.md", in: "first")
        try await git.setReadOnly(true)
        // Not even an unreadable file is looked at first.
        #expect(throws: VaultEdits.Failure.readOnly) { try VaultEdits.apply("Missing.md", in: root) { $0 + "x" } }
        #expect(throws: VaultEdits.Failure.readOnly) { try VaultEdits.apply("Tasks.md", in: root) { $0 + "x" } }
        let many = VaultEdits.apply(["Tasks.md", "Note.md"], in: root) { $0 + "x" }
        #expect(many.count == 2)
        for outcome in many {
            guard case .failure(let error) = outcome else { Issue.record("written"); continue }
            #expect(error as? VaultEdits.Failure == .readOnly)
        }
        let index = Vault.index(root)
        #expect(throws: VaultEdits.Failure.readOnly) { try VaultMoves.perform("Note.md", to: "Moved.md", index: index, root: root) }
        var bookmarks = Bookmarks()
        bookmarks.toggle("Note.md")
        #expect(throws: VaultEdits.Failure.readOnly) { try bookmarks.save(root) }
        #expect(clones.read("Tasks.md", in: "first") == "- [ ] Task\n")
        #expect(clones.read("Note.md", in: "first") == "# Note\n")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".obsidian").path))
        // Off again, the same edit is written.
        try await git.setReadOnly(false)
        try VaultEdits.apply("Tasks.md", in: root) { $0 + "x" }
        #expect(clones.read("Tasks.md", in: "first") == "- [ ] Task\nx")
    }

    @Test func aReadOnlySyncOnlyPulls() async throws {
        let clones = try TestClones()
        defer { clones.remove() }
        let first = try await clones.seeded()
        let second = try await clones.clone("remote", as: "second")
        try await second.setReadOnly(true)
        // Up to date: nothing to bring.
        #expect(try await !second.sync(message: "never"))
        // A commit pushed from the first reaches the second by its sync.
        try clones.write("# Note\nfrom the first\n", to: "Note.md", in: "first")
        #expect(try await first.sync(message: "from the first"))
        let pushed = try await first.run(["rev-parse", "HEAD"])
        // A file changed by hand in the second, by another tool.
        try clones.write("by hand\n", to: "Hand.md", in: "second")
        #expect(try await second.sync(message: "never"))
        #expect(clones.read("Note.md", in: "second") == "# Note\nfrom the first\n")
        #expect(try await second.run(["rev-parse", "HEAD"]) == pushed)
        // Nothing of the second's own: no commit, no push.
        #expect(try await second.run(["rev-list", "@{u}..HEAD"]).isEmpty)
        #expect(try await Git(root: clones.url("remote"), environment: clones.environment).run(["rev-parse", "main"]) == pushed)
        #expect(try await second.run(["log", "--format=%s"]) == "from the first\nfirst")
        // The file changed by hand is not committed, and is still changed.
        #expect(try await second.changes() == ["Hand.md"])
        #expect(clones.read("Hand.md", in: "second") == "by hand\n")
        #expect(try await second.run(["stash", "list"]).isEmpty)
        // Pull is the same pull.
        try clones.write("# Note\nagain\n", to: "Note.md", in: "first")
        try await first.sync(message: "again")
        try await second.pull()
        #expect(clones.read("Note.md", in: "second") == "# Note\nagain\n")
        #expect(try await second.changes() == ["Hand.md"])
    }

    @Test func aReadOnlySyncDoesNotMendADivergedClone() async throws {
        let clones = try TestClones()
        defer { clones.remove() }
        let first = try await clones.seeded()
        let second = try await clones.clone("remote", as: "second")
        // The second has a commit of its own, and the remote another.
        try await clones.commit("# Mine\n", to: "Mine.md", in: "second", message: "mine")
        try clones.write("# Note\ntheirs\n", to: "Note.md", in: "first")
        try await first.sync(message: "theirs")
        try clones.write("not committed\n", to: "Loose.md", in: "second")
        try await second.setReadOnly(true)
        let head = try await second.run(["rev-parse", "HEAD"])
        let branch = try await second.run(["symbolic-ref", "--short", "HEAD"])
        let status = try await second.run(["status", "--porcelain"])
        do {
            try await second.sync(message: "never")
            Issue.record("the sync went on")
        } catch let failure as Git.SyncFailure {
            #expect(failure == .readOnlyDiverged(files: ["Mine.md", "Loose.md"]))
            #expect(failure.description.contains("Mine.md"))
        }
        // The commit, the branch and the working tree are as they were.
        #expect(try await second.run(["rev-parse", "HEAD"]) == head)
        #expect(try await second.run(["symbolic-ref", "--short", "HEAD"]) == branch)
        #expect(try await second.run(["status", "--porcelain"]) == status)
        #expect(clones.read("Note.md", in: "second") == "# Note\n")
        #expect(clones.read("Loose.md", in: "second") == "not committed\n")
        #expect(try await !second.rebaseInProgress())
        #expect(try await second.run(["stash", "list"]).isEmpty)
        // A change not committed that the pull would write over stops it too, and stays.
        let third = try await clones.clone("remote", as: "third")
        try clones.write("# Note\ntheirs again\n", to: "Note.md", in: "first")
        try await first.sync(message: "theirs again")
        try clones.write("# Note\nmy edit\n", to: "Note.md", in: "third")
        try await third.setReadOnly(true)
        await #expect(throws: Git.SyncFailure.readOnlyDiverged(files: ["Note.md"])) { try await third.sync(message: "never") }
        #expect(clones.read("Note.md", in: "third") == "# Note\nmy edit\n")
        // A remote that does not answer is not a divergence.
        try await third.run(["checkout", "-q", "--", "Note.md"])
        try await third.run(["remote", "set-url", "origin", clones.url("gone").path])
        do {
            try await third.sync(message: "never")
            Issue.record("the sync went on")
        } catch {
            #expect(error is Git.Failure)
        }
    }

    @Test func aRefusedPushIsNamed() {
        #expect(Git.refusedPush("ERROR: The key you are authenticating with has been marked as read only.\nfatal: Could not read from remote repository.") == .pushRefusedReadOnly)
        #expect(Git.refusedPush("ERROR: Write access to repository not granted.\nfatal: Could not read from remote repository.") == .pushRefusedReadOnly)
        #expect(Git.refusedPush("git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.") == nil)
        #expect(Git.refusedPush("") == nil)
    }

    /// The remote's refusal comes out of a real push as the named failure,
    /// and the commit stays.
    @Test func aRefusedPushKeepsTheCommit() async throws {
        let clones = try TestClones()
        defer { clones.remove() }
        let first = try await clones.seeded()
        let hook = clones.url("remote").appending(path: "hooks/pre-receive")
        try "#!/bin/sh\necho 'ERROR: The key you are authenticating with has been marked as read only.' >&2\nexit 1\n"
            .write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try clones.write("# Note\nmine\n", to: "Note.md", in: "first")
        await #expect(throws: Git.SyncFailure.pushRefusedReadOnly) { try await first.sync(message: "mine") }
        #expect(try await first.run(["log", "-1", "--format=%s"]) == "mine")
        #expect(try await first.run(["rev-list", "--count", "@{u}..HEAD"]) == "1")
    }

    @Test func theAddressIsTheUpstreamsRemote() async throws {
        let clones = try TestClones()
        defer { clones.remove() }
        let first = try await clones.seeded()
        let second = try await clones.clone("remote", as: "second")
        // The address read is the remote's.
        #expect(await second.remoteName() == "origin")
        #expect(await second.address() == clones.url("remote").path)
        // A second bare remote with the same history, and one commit more.
        try await clones.bare("mirror")
        try await first.run(["push", "-q", clones.url("mirror").path, "main"])
        try await second.setAddress("  \(clones.url("mirror").path)\n")
        #expect(try await second.run(["config", "--local", "--get", "remote.origin.url"]) == clones.url("mirror").path)
        #expect(await second.address() == clones.url("mirror").path)
        try await clones.commit("# Note\non the mirror\n", to: "Note.md", in: "first", message: "on the mirror")
        try await first.run(["push", "-q", clones.url("mirror").path, "main"])
        #expect(try await second.sync(message: "sync"))
        #expect(clones.read("Note.md", in: "second") == "# Note\non the mirror\n")
        // With the upstream on a remote named `backup`, that one is read and written.
        try await clones.bare("backup")
        try await first.run(["push", "-q", clones.url("backup").path, "main"])
        try await second.run(["remote", "add", "backup", clones.url("backup").path])
        try await second.run(["fetch", "-q", "backup"])
        try await second.run(["branch", "-q", "--set-upstream-to=backup/main"])
        #expect(await second.remoteName() == "backup")
        #expect(await second.address() == clones.url("backup").path)
        try await second.setAddress(clones.url("remote").path)
        #expect(try await second.run(["config", "--local", "--get", "remote.backup.url"]) == clones.url("remote").path)
        #expect(try await second.run(["config", "--local", "--get", "remote.origin.url"]) == clones.url("mirror").path)
        // An empty or blank address is refused, and the old one stays.
        for blank in ["", "   ", "\n\t"] {
            await #expect(throws: Git.SettingFailure.emptyAddress) { try await second.setAddress(blank) }
        }
        #expect(await second.address() == clones.url("remote").path)
        #expect(try await second.run(["config", "--local", "--get", "remote.origin.url"]) == clones.url("mirror").path)
    }

    /// With no remote yet, the address adds `origin`, and the next pull
    /// gives the branch its upstream.
    @Test func anAddressGivenToACloneWithNoRemote() async throws {
        let clones = try TestClones()
        defer { clones.remove() }
        _ = try await clones.seeded()
        let alone = clones.git("alone")
        try await Git(root: clones.base, environment: clones.environment).run(["init", "-q", "-b", "main", clones.url("alone").path])
        #expect(await alone.address() == nil)
        try await alone.setAddress(clones.url("remote").path)
        #expect(try await alone.run(["config", "--local", "--get", "remote.origin.url"]) == clones.url("remote").path)
        // Nothing is fetched until the next sync.
        #expect((try? await alone.run(["rev-parse", "--verify", "-q", "refs/remotes/origin/main"])) == nil)
        try await alone.setReadOnly(true)
        try await alone.sync(message: "never")
        #expect(clones.read("Note.md", in: "alone") == "# Note\n")
        #expect(try await alone.run(["rev-parse", "--abbrev-ref", "@{upstream}"]) == "origin/main")
    }

    @Test func aReadOnlyCloneCanRefuseAgents() {
        let refuses = VaultSettings(text: "[agents]\nread_only_clones = false\n")
        #expect(!refuses.agentsInReadOnlyClones)
        #expect(refuses.refusesAgents(readOnly: true))
        // A clone that is not read-only is never touched by the key.
        #expect(!refuses.refusesAgents(readOnly: false))
        for text in ["", "[reader]\nfolded = true\n", "[agents]\nread_only_clones = true\n", "[check]\nread_only_clones = false\n", "read_only_clones = false\n"] {
            let settings = VaultSettings(text: text)
            #expect(settings.agentsInReadOnlyClones, "\(text)")
            #expect(!settings.refusesAgents(readOnly: true), "\(text)")
        }
        // The other sections of the file are read as before.
        #expect(VaultSettings(text: "[reader]\nfolded = true\n\n[agents]\nread_only_clones = false\n").folded)
    }

    @Test func theKeyFieldWritesAndReadsItsOwnCommand() throws {
        #expect(SSHKey.command(key: "/Users/sara/.ssh/notes_ro") == "ssh -i /Users/sara/.ssh/notes_ro -o IdentitiesOnly=yes")
        #expect(SSHKey.command(key: "/Users/sara/My Keys/it's") == #"ssh -i '/Users/sara/My Keys/it'\''s' -o IdentitiesOnly=yes"#)
        for path in ["/Users/sara/.ssh/notes_ro", "/Users/sara/My Keys/it's", "/tmp/a b", "/tmp/$HOME;x", "/tmp/کلید"] {
            #expect(SSHKey.key(in: SSHKey.command(key: path)) == path)
        }
        #expect(SSHKey.key(in: "ssh -i ~/.ssh/notes_ro -o IdentitiesOnly=yes") == "~/.ssh/notes_ro")
        // A command the app did not write is shown as text, never read as a key.
        for other in ["ssh -v", "ssh -i /a -i /b -o IdentitiesOnly=yes", "ssh -i /a b -o IdentitiesOnly=yes", "ssh -i 'a'b' -o IdentitiesOnly=yes",
            "ssh -i  -o IdentitiesOnly=yes", "ssh -i /a -o IdentitiesOnly=yes -p 2222", "", "ssh -i /a;rm -o IdentitiesOnly=yes"] {
            #expect(SSHKey.key(in: other) == nil, "\(other)")
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "daftar-keys-\(UUID().uuidString)/.ssh")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        #expect(SSHKey.file(vault: "My Notes", directory: folder).lastPathComponent == "daftar_My_Notes_ed25519")
        #expect(SSHKey.comment(vault: "org", host: "mac.local") == "daftar org on mac")
        let made = try SSHKey.generate(vault: "org", host: "mac.local", directory: folder)
        #expect(made.file.lastPathComponent == "daftar_org_ed25519")
        #expect(made.publicKey.hasPrefix("ssh-ed25519 ") && made.publicKey.hasSuffix(" daftar org on mac"))
        let key = try Data(contentsOf: made.file)
        // Never over a file that is there.
        #expect(throws: SSHKey.Failure.exists((made.file.path as NSString).abbreviatingWithTildeInPath)) {
            try SSHKey.generate(vault: "org", host: "mac.local", directory: folder)
        }
        #expect(try Data(contentsOf: made.file) == key)
    }
}
