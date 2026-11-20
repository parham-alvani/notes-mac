import Foundation

/// What one clone is, in its own git config (`.git/config`), never
/// committed: read-only or not, its address, its author and its `ssh`. The
/// app, `daftar-cli`, the hooks and a shell all read the same values. The
/// rules are `docs/specs/read-only-vault.md` in notes-linux.
extension Git {
    /// The author of a commit, each part on its own.
    public struct Author: Sendable, Equatable {
        public var name: String?
        public var email: String?

        public init(name: String? = nil, email: String? = nil) {
            self.name = name
            self.email = email
        }
    }

    /// Why a sync stopped, where the person has a choice to make.
    public enum SyncFailure: Error, Equatable, CustomStringConvertible {
        /// A read-only clone's pull cannot fast-forward: the clone has
        /// commits or changes of its own, made by another tool, in [files].
        /// Nothing was stashed, reset or rebased.
        case readOnlyDiverged(files: [String])
        /// The remote refused the push because this clone's key cannot
        /// write. The commits already made stay.
        case pushRefusedReadOnly

        public var description: String {
            switch self {
            case .readOnlyDiverged(let files):
                let named = files.prefix(5).joined(separator: ", ") + (files.count > 5 ? " and \(files.count - 5) more" : "")
                return "This read-only vault has changes of its own, so the pull cannot go on"
                    + (files.isEmpty ? "." : ": \(named).") + " Mend it with git in a shell; Daftar changes nothing here."
            case .pushRefusedReadOnly:
                return "The remote refused the push: this computer's key cannot write to the vault. Your commits are kept."
            }
        }
    }

    /// A setting of the clone that was refused before git was asked.
    public enum SettingFailure: Error, Equatable, LocalizedError {
        case emptyAddress

        public var errorDescription: String? { "The vault's address cannot be empty." }
    }

    // MARK: Read-only

    public static let readOnlyKey = "daftar.readonly"

    /// What `git config --local --type=bool --get daftar.readonly` says:
    /// exit 0 with `true`, exit 1 for a key that is not set, and anything
    /// else (a value that is no boolean) reads as read-only, since when in
    /// doubt the app does not write.
    static func readOnly(status: Int32, output: String) -> Bool {
        switch status {
        case 0: output == "true"
        case 1: false
        default: true
        }
    }

    /// Whether this clone is read-only, asked of git now, on the caller's
    /// thread. Only the clone's own config is read, never the global or the
    /// system one; a folder that is no repository is never read-only.
    public func readsReadOnly() -> Bool {
        guard ask(["rev-parse", "--is-inside-work-tree"]).output == "true" else { return false }
        let answer = ask(["config", "--local", "--type=bool", "--get", Self.readOnlyKey])
        return Self.readOnly(status: answer.status, output: answer.output)
    }

    /// Whether this clone is read-only (`daftar.readonly` in its own config).
    public func isReadOnly() async -> Bool {
        guard await isRepository() else { return false }
        do {
            return Self.readOnly(status: 0, output: try await run(["config", "--local", "--type=bool", "--get", Self.readOnlyKey]))
        } catch let failure as Failure {
            return Self.readOnly(status: failure.status, output: failure.output)
        } catch {
            return true
        }
    }

    /// Turns read-only on, or off by taking the key away. Nothing else changes.
    public func setReadOnly(_ on: Bool) async throws {
        try await setLocalConfig(Self.readOnlyKey, on ? "true" : nil)
    }

    // MARK: The clone's own config

    /// [key] in the clone's own config, or nil when it is not set there or is empty.
    public func localConfig(_ key: String) async -> String? {
        guard let value = try? await run(["config", "--local", "--get", key]), !value.isEmpty else { return nil }
        return value
    }

    /// Writes [key] with `git config --local`; an empty or nil value unsets it.
    public func setLocalConfig(_ key: String, _ value: String?) async throws {
        if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            try await run(["config", "--local", key, value])
            return
        }
        do {
            try await run(["config", "--local", "--unset-all", key])
        } catch let failure as Failure where failure.status == 5 {
            // The key was not there to unset.
        }
    }

    /// The arguments that give a commit the vault's author, for each of the
    /// name and the email the clone's own config does not set. With
    /// neither, git finds the author as it always did.
    func identity() async -> [String] {
        var arguments: [String] = []
        for (key, value) in [("user.name", author.name), ("user.email", author.email)] {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, await localConfig(key) == nil else { continue }
            arguments += ["-c", "\(key)=\(value)"]
        }
        return arguments
    }

    // MARK: The address

    /// The remote this clone pulls from and pushes to: the one of the
    /// branch's upstream, else `origin`.
    public func remoteName() async -> String {
        if let branch = try? await run(["symbolic-ref", "-q", "--short", "HEAD"]), !branch.isEmpty,
            let remote = try? await run(["config", "--get", "branch.\(branch).remote"]), !remote.isEmpty, remote != "."
        {
            return remote
        }
        return "origin"
    }

    /// The vault's address, `remote.<name>.url`; nil with no remote yet.
    public func address() async -> String? {
        await localConfig("remote.\(await remoteName()).url")
    }

    /// Sets the vault's address: `git remote set-url`, or `git remote add`
    /// when the clone has no remote yet, with the branch's upstream on it,
    /// which the next pull fetches. Trimmed; an empty one is refused and the old
    /// one stays. Nothing is fetched until the next sync.
    public func setAddress(_ address: String) async throws {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { throw SettingFailure.emptyAddress }
        let name = await remoteName()
        if await localConfig("remote.\(name).url") != nil {
            try await run(["remote", "set-url", name, address])
        } else {
            try await run(["remote", "add", name, address])
            // The branch's upstream, as config, which a branch with no
            // commit yet takes too: the next pull fetches it and follows it.
            if let branch = try? await run(["symbolic-ref", "-q", "--short", "HEAD"]), !branch.isEmpty, await localConfig("branch.\(branch).merge") == nil {
                try await run(["config", "--local", "branch.\(branch).remote", name])
                try await run(["config", "--local", "branch.\(branch).merge", "refs/heads/\(branch)"])
            }
        }
    }

    // MARK: A read-only clone's sync

    /// A read-only clone's sync: `git pull --ff-only`, with no commit before
    /// it and no push after. Nothing is stashed, reset or rebased. A pull
    /// that cannot fast-forward throws `SyncFailure.readOnlyDiverged` with
    /// the files, and the clone is as it was. True when the pull brought
    /// commits, false when the clone was up to date.
    @discardableResult
    public func pullOnly() async throws -> Bool {
        let before = try? await run(["rev-parse", "HEAD"])
        do {
            try await run(["pull", "--no-rebase", "--ff-only", "--no-autostash"])
        } catch let failure as Failure {
            if let files = await divergedFiles() { throw SyncFailure.readOnlyDiverged(files: files) }
            throw failure
        }
        return (try? await run(["rev-parse", "HEAD"])) != before
    }

    /// After a pull that failed: the files that keep it from going on, or
    /// nil when the clone did not diverge (the remote did not answer). The
    /// pull's fetch came first, so the upstream is what the remote has now.
    private func divergedFiles() async -> [String]? {
        func count(_ range: String) async -> Int { Int((try? await run(["rev-list", "--count", range])) ?? "") ?? 0 }
        func names(_ arguments: [String]) async -> [String] {
            ((try? await run(["-c", "core.quotePath=false", "diff", "--name-only"] + arguments)) ?? "")
                .split(separator: "\n").map(String.init)
        }
        let behind = await count("HEAD..@{upstream}")
        guard behind > 0 else { return nil }
        let changed = (try? await changes()) ?? []
        if await count("@{upstream}..HEAD") > 0 {
            // Commits of its own: what they changed, and what is not committed.
            let own = await names(["@{upstream}...HEAD"])
            return own + changed.filter { !own.contains($0) }
        }
        // No commit of its own: the changes not committed that the pull would write over.
        let incoming = Set(await names(["HEAD", "@{upstream}"]))
        let blocked = changed.filter(incoming.contains)
        return blocked.isEmpty ? nil : blocked
    }

    /// What a failed push's output says about this clone's key: GitHub's
    /// deploy key message, or the one for an account that may not write.
    public static func refusedPush(_ output: String) -> SyncFailure? {
        let said = output.lowercased()
        return said.contains("marked as read only") || said.contains("write access to repository not granted") ? .pushRefusedReadOnly : nil
    }
}

/// The clone's own `ssh`: `core.sshCommand` as the app writes it for a key,
/// and a new key made for a vault.
public enum SSHKey {
    public enum Failure: Error, Equatable, LocalizedError {
        /// A file is there already: a key is never written over.
        case exists(String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .exists(let path): "\(path) is there already, and a key is never written over. Choose it, or move it away first."
            case .failed(let said): "ssh-keygen could not make the key: \(said)"
            }
        }
    }

    /// `ssh -i <path> -o IdentitiesOnly=yes`, the path quoted for a shell.
    public static func command(key path: String) -> String {
        "ssh -i \(quoted(path)) -o IdentitiesOnly=yes"
    }

    /// The key of a command written by `command(key:)`, or nil for any
    /// other command, which the app shows as text and never changes.
    public static func key(in command: String) -> String? {
        // By scalars: a combining mark after a quote or a space is the path's, not the quote's.
        let command = Array(command.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars)
        let prefix = Array("ssh -i ".unicodeScalars), suffix = Array(" -o IdentitiesOnly=yes".unicodeScalars)
        guard command.count > prefix.count + suffix.count, command.starts(with: prefix), command.suffix(suffix.count).elementsEqual(suffix) else { return nil }
        var rest = command[prefix.count..<(command.count - suffix.count)]
        var path = String.UnicodeScalarView()
        guard rest.first == "'" else {
            return rest.allSatisfy { safe.contains($0) || $0 == "~" } ? String(String.UnicodeScalarView(rest)) : nil
        }
        // One word in single quotes, a quote in it written as `'\''`.
        rest = rest.dropFirst()
        while true {
            guard let end = rest.firstIndex(of: "'") else { return nil }
            path.append(contentsOf: rest[..<end])
            rest = rest[(end + 1)...]
            if rest.isEmpty { return String(path) }
            guard rest.starts(with: Array("\\''".unicodeScalars)) else { return nil }
            path.append("'")
            rest = rest.dropFirst(3)
        }
    }

    /// The characters a shell reads as themselves.
    private static let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")

    static func quoted(_ text: String) -> String {
        if !text.isEmpty, text.unicodeScalars.allSatisfy(safe.contains) { return text }
        var out = String.UnicodeScalarView()
        out.append("'")
        for scalar in text.unicodeScalars {
            if scalar == "'" { out.append(contentsOf: "'\\''".unicodeScalars) } else { out.append(scalar) }
        }
        out.append("'")
        return String(out)
    }

    /// `daftar_<vault>_ed25519` in [directory] (`~/.ssh`): the vault's name
    /// with everything but letters, digits, `-` and `.` as `_`.
    public static func file(vault: String, directory: URL) -> URL {
        let name = String(vault.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "." ? Character(scalar) : "_"
        })
        return directory.appending(path: "daftar_\(name.isEmpty ? "vault" : name)_ed25519")
    }

    public static func comment(vault: String, host: String) -> String {
        "daftar \(vault) on \(host.split(separator: ".").first.map(String.init) ?? host)"
    }

    public static var directory: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh") }

    /// A new key for [vault], with no passphrase: `ssh-keygen -t ed25519 -N
    /// "" -C "daftar <vault> on <host>"` into `daftar_<vault>_ed25519` of
    /// [directory], never over a file that is there. The key's file and its
    /// public key's text.
    public static func generate(vault: String, host: String = ProcessInfo.processInfo.hostName, directory: URL = SSHKey.directory) throws -> (file: URL, publicKey: String) {
        let file = file(vault: vault, directory: directory)
        let manager = FileManager.default
        for taken in [file.path, file.path + ".pub"] where manager.fileExists(atPath: taken) {
            throw Failure.exists((taken as NSString).abbreviatingWithTildeInPath)
        }
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ssh-keygen")
        process.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", comment(vault: vault, host: host), "-f", file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        do { try process.run() } catch { throw Failure.failed(error.localizedDescription) }
        let said = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        ended.wait()
        guard process.terminationStatus == 0, let text = publicKey(of: file) else { throw Failure.failed(said) }
        return (file, text)
    }

    /// The text of [key]'s public key, from the `.pub` file beside it.
    public static func publicKey(of key: URL) -> String? {
        (try? String(contentsOfFile: key.path + ".pub", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
