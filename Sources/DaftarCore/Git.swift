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
    public func run(_ arguments: [String]) async throws -> String {
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
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { continuation in
            let output = OutputBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                output.append(handle.availableData)
            }
            process.terminationHandler = { process in
                pipe.fileHandleForReading.readabilityHandler = nil
                output.append(pipe.fileHandleForReading.readDataToEndOfFile())
                let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Paths with changes not yet committed.
    public func changes() async throws -> [String] {
        try await run(["status", "--porcelain=v1", "-z"]).split(separator: "\0").map { String($0.dropFirst(3)) }
    }

    /// Commits everything, pulls with a rebase, and pushes: the vault's own
    /// workflow. Returns false when there was nothing to do.
    @discardableResult
    public func sync(message: String) async throws -> Bool {
        var changed = false
        if try await !changes().isEmpty {
            try await run(["add", "-A"])
            try await run(["commit", "-m", message])
            changed = true
        }
        let before = try await run(["rev-parse", "HEAD"])
        try await run(["pull", "--rebase", "--autostash"])
        let after = try await run(["rev-parse", "HEAD"])
        if try await !run(["rev-list", "@{upstream}..HEAD"]).isEmpty {
            try await run(["push"])
            changed = true
        }
        return changed || before != after
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
