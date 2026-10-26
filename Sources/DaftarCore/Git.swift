import Foundation

/// The vault's repository, through the system `git`. The person's own git
/// config, credential helper and SSH agent apply, as they do in a terminal;
/// the app holds no key and no token.
public struct Git: Sendable {
    public var root: URL
    /// Found once: `/usr/bin/git` is a shim that asks for the developer tools.
    public var executable: URL

    public init(root: URL, executable: URL? = nil) {
        self.root = root
        self.executable = executable ?? Git.locate()
    }

    public struct Failure: Error, CustomStringConvertible {
        public var arguments: [String]
        public var status: Int32
        public var output: String
        public var description: String { "git \(arguments.joined(separator: " ")): \(output)" }
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
        environment["GIT_SSH_COMMAND"] = environment["GIT_SSH_COMMAND"] ?? "ssh -o BatchMode=yes"
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

        return try await withCheckedThrowingContinuation { continuation in
            let output = OutputBuffer()
            let ended = DispatchSemaphore(value: 0)
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
                if ended.wait(timeout: .now() + 2) == .timedOut { pipe.fileHandleForReading.readabilityHandler = nil }
                let text = trimmed ? output.text.trimmingCharacters(in: .whitespacesAndNewlines) : output.text
                if process.terminationStatus == 0 {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: Failure(arguments: arguments, status: process.terminationStatus, output: text))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    public func isRepository() async -> Bool {
        (try? await run(["rev-parse", "--is-inside-work-tree"])) == "true"
    }

    /// Pulls with a rebase, keeping local changes aside while it does. A
    /// rebase that stops on a conflict stays open and throws `Stopped`.
    public func pull() async throws {
        if try await rebaseInProgress() { throw Stopped(conflicts: try await conflicts()) }
        try await pullRebase()
    }

    private func pullRebase() async throws {
        do {
            try await run(["pull", "--rebase", "--autostash"])
        } catch {
            guard try await rebaseInProgress() else { throw error }
            throw Stopped(conflicts: try await conflicts())
        }
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
        try await run(["status", "--porcelain=v1", "-z"]).split(separator: "\0").map { String($0.dropFirst(3)) }
    }

    /// Commits everything, pulls with a rebase, and pushes: the vault's own
    /// workflow. Returns false when there was nothing to do.
    /// A rebase open on a conflict is never committed over: it throws
    /// `Stopped`, and the person resolves it first.
    @discardableResult
    public func sync(message: String) async throws -> Bool {
        if try await rebaseInProgress() { throw Stopped(conflicts: try await conflicts()) }
        var changed = false
        if try await !changes().isEmpty {
            try await run(["add", "-A"])
            try await run(["commit", "-m", message])
            changed = true
        }
        let before = try await run(["rev-parse", "HEAD"])
        try await pullRebase()
        let after = try await run(["rev-parse", "HEAD"])
        return try await pushIfAhead() || changed || before != after
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
        public init(conflicts: [Conflicted]) { self.conflicts = conflicts }
        public var description: String {
            conflicts.count == 1 ? "The pull stopped on a conflict in \(conflicts[0].path)." : "The pull stopped on conflicts in \(conflicts.count) files."
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

    /// Goes on with the rebase once every file is resolved. Returns the
    /// conflicts of the next commit it replays, if that one stops too, or
    /// none when the rebase is done. Git is never let to open an editor.
    public func continueRebase() async throws -> [Conflicted] {
        while try await rebaseInProgress() {
            let open = try await conflicts()
            if !open.isEmpty { return open }
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

    /// Ends the open rebase and puts the branch back as it was before the pull.
    public func abortRebase() async throws {
        try await run(["rebase", "--abort"])
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

    func append(_ chunk: Data) {
        lock.withLock { data.append(chunk) }
    }

    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
