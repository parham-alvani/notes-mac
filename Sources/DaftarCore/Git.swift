import Foundation

/// The vault's repository, through the system `git`. The person's own git
/// config, credential helper and SSH agent apply, as they do in a terminal;
/// the app holds no key and no token.
public struct Git: Sendable {
    public var root: URL
    /// Found once: `/usr/bin/git` is a shim that asks for the developer tools.
    public var executable: URL

    /// The seconds one git command may take. A pull over a connection
    /// that went away would wait for ever, and a sync that never ends
    /// keeps every later one from starting.
    public var limit: TimeInterval

    public init(root: URL, executable: URL? = nil, limit: TimeInterval = 300) {
        self.root = root
        self.executable = executable ?? Git.locate()
        self.limit = limit
    }

    /// The `ssh` git uses when the person set none: it never asks, gives
    /// up on a host that does not answer, and notices a connection that died.
    public static let ssh = "ssh -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=3"

    public struct Failure: Error, CustomStringConvertible {
        public var arguments: [String]
        public var status: Int32
        public var output: String
        /// The command was stopped at the limit (`Git.limit`).
        public var timedOut = false
        /// The hook of the repository that refused the commit, by its name.
        public var hook: String?
        public var description: String {
            if let hook { return "The \(hook) hook stopped the commit: \(output)" }
            return "git \(arguments.joined(separator: " ")): \(output)"
        }
    }

    static func locate() -> URL {
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(filePath: path)
        }
        return URL(filePath: "/usr/bin/git")
    }

    /// Runs git and returns what it printed. Never asks on a terminal: a sync
    /// that needs a password fails and says so instead of waiting for ever.
    @discardableResult
    public func run(_ arguments: [String], trimmed: Bool = true, environment extra: [String: String] = [:]) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-C", root.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_SSH_COMMAND"] = environment["GIT_SSH_COMMAND"] ?? Self.ssh
        // Over HTTPS: under 1000 bytes a second for 30 seconds is a dead connection.
        environment["GIT_HTTP_LOW_SPEED_LIMIT"] = environment["GIT_HTTP_LOW_SPEED_LIMIT"] ?? "1000"
        environment["GIT_HTTP_LOW_SPEED_TIME"] = environment["GIT_HTTP_LOW_SPEED_TIME"] ?? "30"
        // An app started from Finder has a short PATH; git hooks and the
        // credential helper still have to be found.
        let path = environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + path
        environment.merge(extra) { $1 }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let limit = limit
        return try await withCheckedThrowingContinuation { continuation in
            let output = OutputBuffer()
            let ended = DispatchSemaphore(value: 0)
            // Past the limit git is told to end, and made to if it does not.
            nonisolated(unsafe) let running = process
            nonisolated(unsafe) let overdue = DispatchWorkItem {
                guard running.isRunning else { return }
                output.stopped = true
                running.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if running.isRunning { kill(running.processIdentifier, SIGKILL) }
                }
            }
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    ended.signal()
                } else {
                    output.append(chunk)
                }
            }
            process.terminationHandler = { process in
                // The text is complete at the end of the pipe, not when git
                // exits: the handler may still hold the last chunk. A helper
                // that git started and that stays, such as an SSH master
                // connection, can keep the pipe open, so not for ever.
                overdue.cancel()
                if ended.wait(timeout: .now() + 2) == .timedOut { pipe.fileHandleForReading.readabilityHandler = nil }
                let text = trimmed ? output.text.trimmingCharacters(in: .whitespacesAndNewlines) : output.text
                if output.stopped {
                    let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: Failure(
                        arguments: arguments, status: process.terminationStatus,
                        output: "it took longer than \(Int(limit)) seconds and was stopped" + (said.isEmpty ? "" : ": " + said), timedOut: true))
                } else if process.terminationStatus == 0 {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: Failure(arguments: arguments, status: process.terminationStatus, output: text))
                }
            }
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: overdue)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    public func isRepository() async -> Bool {
        (try? await run(["rev-parse", "--is-inside-work-tree"])) == "true"
    }

    /// Pulls with a rebase, keeping local changes aside while it does. A
    /// rebase that stops on a conflict stays open and throws `Stopped`, and
    /// so do local changes that do not fit on what the pull brought.
    public func pull() async throws {
        try await refuseOpenOperation()
        try await pullRebase()
    }

    /// Throws `Stopped` while a rebase is open or files are still marked
    /// as conflicted, and a `Failure` while a merge, a cherry-pick or a
    /// revert that git left open would be committed with its marks.
    private func refuseOpenOperation() async throws {
        if try await rebaseInProgress() { throw Stopped(conflicts: try await conflicts()) }
        if let operation = try await otherOperationInProgress() {
            throw Failure(arguments: ["sync"], status: -1, output: "a \(operation) is in progress: finish or abort it with git first")
        }
        let left = try await conflicts()
        if !left.isEmpty { throw Stopped(conflicts: left, unstashed: true) }
    }

    /// What waits for the person's choice.
    public enum Stop: Sendable, Equatable {
        /// A rebase stopped on a conflict and is open.
        case rebase
        /// No operation is open, but files are marked as conflicted: the
        /// changes a pull kept aside did not fit on what it brought.
        case unstash
    }

    public func openStop() async throws -> Stop? {
        if try await rebaseInProgress() { return .rebase }
        if try await otherOperationInProgress() != nil { return nil }
        return try await conflicts().isEmpty ? nil : .unstash
    }

    /// A merge, cherry-pick or revert that git left open, by its name.
    public func otherOperationInProgress() async throws -> String? {
        for (name, operation) in [("MERGE_HEAD", "merge"), ("CHERRY_PICK_HEAD", "cherry-pick"), ("REVERT_HEAD", "revert")] {
            let path = try await run(["rev-parse", "--path-format=absolute", "--git-path", name])
            if FileManager.default.fileExists(atPath: path) { return operation }
        }
        return nil
    }

    private func pullRebase() async throws {
        do {
            try await run(["pull", "--rebase", "--autostash"])
        } catch {
            guard try await rebaseInProgress() else { throw error }
            throw Stopped(conflicts: try await conflicts())
        }
        // `--autostash` puts the local changes back after the rebase, and
        // git says nothing went wrong (exit 0) when they do not fit: the
        // files have conflict marks, and the changes stay in the stash.
        let left = try await conflicts()
        if !left.isEmpty { throw Stopped(conflicts: left, unstashed: true) }
    }

    public struct Status: Sendable, Equatable {
        public var branch: String
        public var ahead: Int
        public var behind: Int
        public var changed: Int
    }

    /// The branch, how far it is from its upstream, and how many files changed.
    public func status() async throws -> Status {
        let lines = try await run(["status", "--porcelain=v2", "--branch"]).components(separatedBy: "\n")
        var status = Status(branch: "", ahead: 0, behind: 0, changed: 0)
        for line in lines {
            if line.hasPrefix("# branch.head ") {
                status.branch = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.ab ") {
                let parts = line.split(separator: " ")
                status.ahead = parts.count > 2 ? abs(Int(parts[2]) ?? 0) : 0
                status.behind = parts.count > 3 ? abs(Int(parts[3]) ?? 0) : 0
            } else if !line.hasPrefix("#"), !line.isEmpty {
                status.changed += 1
            }
        }
        return status
    }

    /// Paths with changes not yet committed.
    public func changes() async throws -> [String] {
        Git.changedPaths(try await run(["status", "--porcelain=v1", "-z"], trimmed: false))
    }

    /// The paths of `git status --porcelain=v1 -z`: `XY path` records, and
    /// after a rename or a copy the old path as a record of its own. Read
    /// untrimmed, by bytes: trimmed, the first record lost the space its
    /// code can start with, and with it its path's first letter.
    public static func changedPaths(_ output: String) -> [String] {
        var paths: [String] = []
        var records = output.utf8.split(separator: 0, omittingEmptySubsequences: false).makeIterator()
        while let record = records.next() {
            guard record.count > 3 else { continue }
            paths.append(String(decoding: record.dropFirst(3), as: UTF8.self))
            if record.prefix(2).contains(where: { $0 == UInt8(ascii: "R") || $0 == UInt8(ascii: "C") }) { _ = records.next() }
        }
        return paths
    }

    /// Commits everything, pulls with a rebase, and pushes: the vault's own
    /// workflow. Returns false when there was nothing to do.
    /// A rebase open on a conflict is never committed over: it throws
    /// `Stopped`, and the person resolves it first. Nor is a merge, a
    /// cherry-pick or a revert left open, or a file still in conflict.
    @discardableResult
    public func sync(message: String) async throws -> Bool {
        try await refuseOpenOperation()
        try await refuseNoBranch()
        var changed = false
        if try await !changes().isEmpty {
            try await run(["add", "-A"])
            do {
                try await run(["commit", "-m", message])
            } catch var failure as Failure {
                // A hook's refusal reads as its own words, a lint report
                // perhaps: say whose they are.
                failure.hook = await refusingHook()
                throw failure
            }
            changed = true
        }
        let before = try await run(["rev-parse", "HEAD"])
        try await pullRebase()
        let after = try await run(["rev-parse", "HEAD"])
        return try await pushIfAhead() || changed || before != after
    }

    /// Throws before anything is committed when the commit could not be
    /// pulled over or pushed: on a detached HEAD each sync would add a
    /// commit that is on no branch, and with no upstream the pull fails
    /// after the commit, every time.
    private func refuseNoBranch() async throws {
        guard let branch = try? await run(["symbolic-ref", "-q", "--short", "HEAD"]), !branch.isEmpty else {
            throw Failure(arguments: ["sync"], status: -1, output: "HEAD is detached: check out a branch first (git switch <branch>)")
        }
        guard (try? await run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])) != nil else {
            throw Failure(
                arguments: ["sync"], status: -1,
                output: "the branch \(branch) has no upstream to pull from and push to: set it once (git push -u origin \(branch))")
        }
    }

    /// The hook that can refuse a commit, when the repository has one:
    /// `pre-commit`, else `commit-msg`, in `core.hooksPath` when that is set.
    func refusingHook() async -> String? {
        for name in ["pre-commit", "commit-msg"] {
            guard let path = try? await run(["rev-parse", "--path-format=absolute", "--git-path", "hooks/" + name]) else { continue }
            if FileManager.default.isExecutableFile(atPath: path) { return name }
        }
        return nil
    }

    /// Pushes when the branch has commits its upstream has not.
    @discardableResult
    public func pushIfAhead() async throws -> Bool {
        guard try await !run(["rev-list", "@{upstream}..HEAD"]).isEmpty else { return false }
        try await run(["push"])
        return true
    }

    // MARK: Conflicts

    /// A pull whose rebase stopped on a conflict. The rebase stays open
    /// until the person resolves it or aborts it.
    public struct Stopped: Error, CustomStringConvertible {
        public var conflicts: [Conflicted]
        /// No rebase is open: the pull is done, and the changes it kept
        /// aside (not committed yet) did not fit on it.
        public var unstashed: Bool
        public init(conflicts: [Conflicted], unstashed: Bool = false) {
            self.conflicts = conflicts
            self.unstashed = unstashed
        }
        public var description: String {
            if unstashed {
                return conflicts.count == 1
                    ? "The pull changed \(conflicts[0].path), and so did you since the last commit."
                    : "The pull changed \(conflicts.count) files that you changed too since the last commit."
            }
            return conflicts.count == 1 ? "The pull stopped on a conflict in \(conflicts[0].path)." : "The pull stopped on conflicts in \(conflicts.count) files."
        }
    }

    /// What one side of a rebase did to a conflicted file.
    public enum Side: Sendable, Equatable {
        case changed, added, deleted
    }

    /// A file a rebase stopped on. During a rebase git's "ours" is the
    /// upstream and "theirs" is the person's commit being replayed; here
    /// they are `remote` and `mine`.
    public struct Conflicted: Sendable, Equatable, Identifiable {
        public var path: String
        public var remote: Side
        public var mine: Side
        public var id: String { path }

        public init(path: String, remote: Side, mine: Side) {
            self.path = path
            self.remote = remote
            self.mine = mine
        }

        public var isMarkdown: Bool { path.lowercased().hasSuffix(".md") }
        /// Both sides changed the text, so it has conflict marks to read.
        public var hasMarks: Bool { remote != .deleted && mine != .deleted }
    }

    /// The person's choice for a whole file.
    public enum Resolution: Sendable, Equatable {
        /// The text to keep, conflict marks taken out.
        case text(String)
        /// The upstream's file, or its deletion.
        case keepRemote
        /// The person's file, or their deletion.
        case keepMine
    }

    /// A rebase is open: `rebase-merge` or `rebase-apply` in the git folder.
    public func rebaseInProgress() async throws -> Bool {
        for name in ["rebase-merge", "rebase-apply"] {
            let path = try await run(["rev-parse", "--path-format=absolute", "--git-path", name])
            if FileManager.default.fileExists(atPath: path) { return true }
        }
        return false
    }

    /// The files with unresolved conflicts.
    public func conflicts() async throws -> [Conflicted] {
        Git.conflicted(try await run(["status", "--porcelain=v2", "-z"], trimmed: false))
    }

    /// The `u` records of `git status --porcelain=v2 -z`.
    public static func conflicted(_ output: String) -> [Conflicted] {
        output.split(separator: "\0").compactMap { record in
            guard record.hasPrefix("u ") else { return nil }
            // u XY sub m1 m2 m3 mW h1 h2 h3 path: the path may hold spaces.
            let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
            guard fields.count == 11, fields[1].count == 2 else { return nil }
            func side(_ letter: Character) -> Side { letter == "D" ? .deleted : letter == "A" ? .added : .changed }
            let code = Array(fields[1])
            return Conflicted(path: String(fields[10]), remote: side(code[0]), mine: side(code[1]))
        }
    }

    /// Resolves one file and stages it. A side that deleted the file
    /// deletes it when it is kept.
    public func resolve(_ file: Conflicted, _ resolution: Resolution) async throws {
        switch resolution {
        case let .text(text):
            try Data(text.utf8).write(to: root.appending(path: file.path), options: .atomic)
            try await run(["add", "--", file.path])
        case .keepRemote:
            try await keep(file, side: file.remote, flag: "--ours")
        case .keepMine:
            try await keep(file, side: file.mine, flag: "--theirs")
        }
    }

    private func keep(_ file: Conflicted, side: Side, flag: String) async throws {
        if side == .deleted {
            try await run(["rm", "-q", "--ignore-unmatch", "--", file.path])
        } else {
            // In a rebase `--ours` is the upstream and `--theirs` the replayed commit.
            try await run(["checkout", flag, "--", file.path])
            try await run(["add", "--", file.path])
        }
    }

    /// Goes on with the rebase once every file is resolved, with whatever
    /// else changed in the tree since it stopped. Returns the
    /// conflicts of the next commit it replays, if that one stops too, or
    /// none when the rebase is done. Git is never let to open an editor.
    public func continueRebase() async throws -> [Conflicted] {
        while try await rebaseInProgress() {
            let open = try await conflicts()
            if !open.isEmpty { return open }
            // `rebase --continue` refuses a tree with changes that are not
            // staged, and the person may have gone on working while the
            // conflict waited: what they wrote goes into the commit being
            // replayed, which is theirs.
            try await run(["add", "-A"])
            do {
                try await run(["rebase", "--continue"], environment: ["GIT_EDITOR": "true"])
            } catch {
                // A stop on the next commit's conflict is not a failure.
                guard try await rebaseInProgress(), try await !conflicts().isEmpty else { throw error }
            }
        }
        return []
    }

    /// Resolves [resolutions], goes on with the rebase and pushes when it is
    /// done. Returns the next commit's conflicts when the rebase stops again.
    public func finishRebase(_ resolutions: [(Conflicted, Resolution)]) async throws -> [Conflicted] {
        for (file, resolution) in resolutions { try await resolve(file, resolution) }
        let open = try await continueRebase()
        if open.isEmpty { try await pushIfAhead() }
        return open
    }

    /// Resolves [resolutions] where a pull's kept-aside changes did not
    /// fit (`Stop.unstash`). The sides are as in a rebase: the upstream is
    /// "ours" and the person's changes "theirs". With every file resolved
    /// the changes are unstaged again, as they were before the pull, and
    /// the stash the pull left them in is dropped. Returns what is open still.
    public func finishUnstash(_ resolutions: [(Conflicted, Resolution)]) async throws -> [Conflicted] {
        for (file, resolution) in resolutions { try await resolve(file, resolution) }
        let open = try await conflicts()
        guard open.isEmpty else { return open }
        try await run(["reset", "-q"])
        // Only the pull's own stash: another one is the person's.
        if try await run(["stash", "list", "-n", "1", "--format=%gs"]) == "autostash" {
            try await run(["stash", "drop", "-q", "stash@{0}"])
        }
        return []
    }

    /// Ends the open rebase and puts the branch back as it was before the pull.
    /// The abort resets the tree, so what the person wrote in other files
    /// while the rebase was open is read first and written back after it:
    /// a note edited, added or deleted during the stop stays so. A file
    /// still in conflict is not kept; its choice is made again at the next
    /// pull. Returns the copies made beside a file that the pull's own
    /// stash also changed, where neither text may go over the other.
    @discardableResult
    public func abortRebase() async throws -> [String] {
        let kept = try await editedDuringStop()
        try await run(["rebase", "--abort"])
        return try await putBack(kept)
    }

    /// A tracked file that differs from the rebase's commit and is not in
    /// conflict: its bytes, or nil when the person deleted it.
    struct Kept {
        var path: String
        var data: Data?
    }

    /// The codes of `git status` for a file with unresolved conflicts.
    private static let unmerged: Set<String> = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]

    func editedDuringStop() async throws -> [Kept] {
        let output = try await run(["status", "--porcelain=v1", "-z", "--no-renames"], trimmed: false)
        var kept: [Kept] = []
        for record in output.utf8.split(separator: 0, omittingEmptySubsequences: true) where record.count > 3 {
            let code = String(decoding: record.prefix(2), as: UTF8.self)
            // An untracked file stays through an abort by itself.
            guard code != "??", code != "!!", !Self.unmerged.contains(code) else { continue }
            let path = String(decoding: record.dropFirst(3), as: UTF8.self)
            let file = root.appending(path: path)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) {
                // A submodule or a folder in a file's place is not a note to keep.
                guard !isDirectory.boolValue, let data = try? Data(contentsOf: file) else { continue }
                kept.append(Kept(path: path, data: data))
            } else {
                kept.append(Kept(path: path, data: nil))
            }
        }
        return kept
    }

    func putBack(_ kept: [Kept]) async throws -> [String] {
        guard !kept.isEmpty else { return [] }
        // After the abort the tree is clean but for what the pull's own
        // stash put back: a file it changed has two texts now.
        let stashed = Set(try await changes())
        var copies: [String] = []
        var failure: (any Error)?
        for file in kept {
            let url = root.appending(path: file.path)
            do {
                guard let data = file.data else {
                    if !stashed.contains(file.path), FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                    continue
                }
                if (try? Data(contentsOf: url)) == data { continue }
                var target = url
                if stashed.contains(file.path) {
                    let name = url.deletingPathExtension().lastPathComponent + " (edited during the stopped sync)"
                    let ext = url.pathExtension
                    target = url.deletingLastPathComponent().appending(path: ext.isEmpty ? name : name + "." + ext)
                    let folder = (file.path as NSString).deletingLastPathComponent
                    copies.append((folder.isEmpty ? "" : folder + "/") + target.lastPathComponent)
                }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            } catch {
                failure = failure ?? error
            }
        }
        if let failure { throw failure }
        return copies
    }

    /// A commit that changed a note.
    public struct Revision: Sendable, Equatable, Identifiable {
        public var hash: String
        public var date: Date
        public var author: String
        public var subject: String
        /// The note's path in this commit, which a rename changes.
        public var path: String
        public var id: String { hash }
    }

    /// The commits that changed [path], newest first, across renames.
    public func history(of path: String, limit: Int = 300) async throws -> [Revision] {
        Git.revisions(try await run([
            "-c", "core.quotePath=false", "log", "--follow", "-n", String(limit),
            "--format=%x1e%H%x1f%aI%x1f%an%x1f%s", "--name-only", "--", path,
        ]))
    }

    /// What `git log --format=%x1e%H%x1f%aI%x1f%an%x1f%s --name-only` printed.
    public static func revisions(_ output: String) -> [Revision] {
        let dates = ISO8601DateFormatter()
        return output.split(separator: "\u{1e}").compactMap { record in
            let lines = record.split(separator: "\n", omittingEmptySubsequences: true)
            guard let head = lines.first else { return nil }
            let fields = head.split(separator: "\u{1f}", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, let date = dates.date(from: fields[1]) else { return nil }
            return Revision(hash: fields[0], date: date, author: fields[2], subject: fields[3], path: lines.dropFirst().last.map(String.init) ?? "")
        }
    }

    /// The text of [path] as commit [hash] has it, to the last byte.
    public func content(of path: String, at hash: String) async throws -> String {
        try await run(["show", "\(hash):\(path)"], trimmed: false)
    }

    /// The obsidian-git message this vault's history is written with:
    /// `update notes @ 2026-10-25 09:30:00 on host`.
    public static func message(at date: Date = Date(), host: String = ProcessInfo.processInfo.hostName) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let name = host.split(separator: ".").first.map(String.init) ?? host
        return "update notes @ \(format.string(from: date)) on \(name)"
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    private var wasStopped = false

    /// The command went past its limit and was ended.
    var stopped: Bool {
        get { lock.withLock { wasStopped } }
        set { lock.withLock { wasStopped = newValue } }
    }

    func append(_ chunk: Data) {
        lock.withLock { data.append(chunk) }
    }

    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
