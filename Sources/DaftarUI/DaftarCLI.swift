import Darwin
import Foundation

/// `daftar-cli`, run off the main thread: Export as PDF, the Problems
/// panel's audit and fixes, and format on save all go through here.
enum DaftarCLI {
    /// The `daftar-cli` to run: the one beside the app's own binary, else
    /// the first on `$PATH`, else Homebrew's or Cargo's, which an app opened
    /// from the Finder does not have on its `$PATH`.
    static func locate(
        beside executable: URL? = Bundle.main.executableURL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let folders = [executable?.deletingLastPathComponent().path].compactMap { $0 } + path
            + ["/opt/homebrew/bin", "/usr/local/bin", home + "/.cargo/bin", home + "/.local/bin"]
        return folders.map { ($0 as NSString).appendingPathComponent("daftar-cli") }.first(where: isExecutable)
    }

    /// What a run gave back.
    struct Output: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: String
        /// The run was cancelled and the command ended.
        var cancelled = false

        var text: String { String(decoding: stdout, as: UTF8.self) }
        /// A usage error: clap exits 2 with an `error:` line.
        var usageError: String? {
            guard status == 2 else { return nil }
            return stderr.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("error: ") }
        }
    }

    enum Failure: Error, Equatable {
        /// The command could not be started.
        case notRun(String)
    }

    /// Runs [cli] with [arguments], with [input] on its stdin, and gives
    /// what it wrote. Never on the main thread: the process is waited for on
    /// a queue of its own, its two pipes are read at once (a full pipe would
    /// stop it), and a cancelled task ends it. It runs in [directory] when
    /// given. [quality] is the process's
    /// own: a check of the whole vault runs as `.utility`, so it never takes
    /// the cores from typing.
    static func run(
        _ cli: String, _ arguments: [String], input: Data? = nil, in directory: URL? = nil, quality: QualityOfService = .userInitiated
    ) async throws -> Output {
        let process = Process()
        process.executableURL = URL(filePath: cli)
        process.arguments = arguments
        // In the vault's folder: a note's path is read from where the
        // command runs, as well as from `--vault`.
        if let directory { process.currentDirectoryURL = directory }
        process.qualityOfService = quality
        let out = Pipe(), errors = Pipe()
        process.standardOutput = out
        process.standardError = errors
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        let running = Running(process)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
                DispatchQueue.global(qos: quality == .utility ? .utility : .userInitiated).async {
                    do {
                        try running.start()
                    } catch is CancellationError {
                        continuation.resume(throwing: CancellationError())
                        return
                    } catch {
                        continuation.resume(throwing: Failure.notRun(error.localizedDescription))
                        return
                    }
                    if let stdin, let input {
                        // A command that ends before it reads all of stdin
                        // must not end the app with SIGPIPE.
                        let handle = stdin.fileHandleForWriting
                        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
                        DispatchQueue.global(qos: .utility).async {
                            try? handle.write(contentsOf: input)
                            try? handle.close()
                        }
                    }
                    let said = Collected()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        said.errors = errors.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    let stdout = out.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    process.waitUntilExit()
                    continuation.resume(
                        returning: Output(
                            status: process.terminationStatus, stdout: stdout,
                            stderr: String(decoding: said.errors, as: UTF8.self), cancelled: running.cancelled))
                }
            }
        } onCancel: {
            running.cancel()
        }
    }

    /// The process and whether it was cancelled, shared by the queue that
    /// runs it and the task that may cancel it.
    private final class Running: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private var started = false
        private(set) var cancelled = false

        init(_ process: Process) { self.process = process }

        func start() throws {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { throw CancellationError() }
            try process.run()
            started = true
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            cancelled = true
            if started, process.isRunning { process.terminate() }
        }
    }

    private final class Collected: @unchecked Sendable {
        var errors = Data()
    }

    /// What a failed run says: the last line of its stderr, without the
    /// command's name; a usage error says its `error:` line.
    static func failure(_ errors: String) -> String {
        let lines = errors.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let usage = lines.first(where: { $0.hasPrefix("error: ") }) {
            return "daftar-cli: " + usage.dropFirst("error: ".count)
        }
        guard let line = lines.last else { return "daftar-cli failed." }
        return line.hasPrefix("daftar-cli: ") ? String(line.dropFirst("daftar-cli: ".count)) : line
    }

    /// The flags the Problems panel and format on save need, which a
    /// `daftar-cli` before 0.23.0 does not know.
    static let newFlags = ["--json", "--stdin", "--path"]

    /// The notice for a `daftar-cli` too old for the Problems panel and
    /// format on save.
    static let upgrade = "Problems and Format Note need daftar-cli 0.23.0 or later: brew upgrade parham-alvani/tap/daftar-cli."

    /// The notice when there is no `daftar-cli` at all.
    static let missing = "Problems and Format Note run daftar-cli, which is neither beside Daftar nor on $PATH: brew install parham-alvani/tap/daftar-cli."

    /// Whether [output] is a `daftar-cli` that does not know one of
    /// [newFlags]: clap's "unexpected argument '--json'".
    static func tooOld(_ output: Output) -> Bool {
        guard let usage = output.usageError else { return false }
        return newFlags.contains { usage.hasPrefix("error: unexpected argument '\($0)'") }
    }
}
