import Darwin
import Foundation

/// `daftar-cli`, run off the main thread: Export as PDF, the Problems
/// panel's audit and fixes, format on save, search by meaning and its index,
/// and the weekly review all go through here.
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
        /// The run was cancelled (or the app quit) and the command ended.
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
        /// No `daftar-cli` on this Mac.
        case notInstalled
        /// The command could not be started.
        case notRun(String)

        /// What a notice says.
        var message: String {
            switch self {
            case .notInstalled: DaftarCLI.notInstalled
            case .notRun(let why): "daftar-cli could not run: \(why)"
            }
        }
    }

    /// The notice when there is no `daftar-cli` at all, for a feature that
    /// has no words of its own for it (search by meaning, the weekly review).
    static let notInstalled = "daftar-cli is not installed: brew install parham-alvani/tap/daftar-cli"

    /// What [error], thrown by `run`, says in a notice.
    static func describe(_ error: Error) -> String {
        (error as? Failure)?.message ?? error.localizedDescription
    }

    /// Runs [cli] with [arguments] and gives what it wrote. Never on the
    /// main thread: both pipes are read as they fill (a full pipe would stop
    /// the command), [input] goes to its stdin, and [line] hears each line
    /// of its stderr as it comes (an index build's progress; a line may end
    /// in `\r`), on no particular thread. It runs in [directory] when given
    /// (the vault's folder: a note's path is read from there too), with
    /// [environment] in place of the app's when given, at [quality]: a check
    /// of the whole vault runs as `.utility`, so it never takes the cores
    /// from typing. A cancelled task ends the command (SIGTERM, then SIGKILL
    /// a second later), and so does quitting the app (`endAll`): no
    /// `daftar-cli` outlives Daftar. A nil [cli] throws `notInstalled`; a
    /// task cancelled before the start throws `CancellationError`.
    static func run(
        _ cli: String?,
        _ arguments: [String],
        input: Data? = nil,
        in directory: URL? = nil,
        environment: [String: String]? = nil,
        quality: QualityOfService = .userInitiated,
        line: (@Sendable (String) -> Void)? = nil
    ) async throws -> Output {
        guard let cli else { throw Failure.notInstalled }
        let process = Process()
        process.executableURL = URL(filePath: cli)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        if let environment { process.environment = environment }
        process.qualityOfService = quality
        let out = Pipe(), errors = Pipe()
        process.standardOutput = out
        process.standardError = errors
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        let running = Running(process)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
                let collected = Collected()
                errors.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else {
                        handle.readabilityHandler = nil
                        collected.finishErrors(line)
                        return
                    }
                    collected.addErrors(data, line)
                }
                out.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else {
                        handle.readabilityHandler = nil
                        collected.finishOut()
                        return
                    }
                    collected.addOut(data)
                }
                process.terminationHandler = { process in
                    Registry.shared.remove(running)
                    // The pipes are read to their end before the answer.
                    collected.whenDrained {
                        continuation.resume(returning: Output(
                            status: process.terminationStatus, stdout: collected.out,
                            stderr: collected.errorText, cancelled: running.cancelled))
                    }
                    // A command ended while its own child (a `git`) still
                    // holds the pipes: what came by now is all there is.
                    guard running.cancelled else { return }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        out.fileHandleForReading.readabilityHandler = nil
                        errors.fileHandleForReading.readabilityHandler = nil
                        collected.finishOut()
                        collected.finishErrors(nil)
                    }
                }
                do {
                    try running.start()
                } catch {
                    out.fileHandleForReading.readabilityHandler = nil
                    errors.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error is CancellationError ? error : Failure.notRun(error.localizedDescription))
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
            }
        } onCancel: {
            running.cancel()
        }
    }

    /// Ends every `daftar-cli` still running, when the app quits: SIGTERM,
    /// up to [grace] seconds for them to go, then SIGKILL. A semantic index
    /// build or an audit would otherwise go on with no app to answer. A
    /// test ends only its own, by their [arguments].
    static func endAll(grace: TimeInterval = 0.5, matching: ([String]) -> Bool = { _ in true }) {
        let all = Registry.shared.all.filter { matching($0.arguments) }
        guard !all.isEmpty else { return }
        for running in all { running.cancel(escalate: false) }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, all.contains(where: \.isRunning) { usleep(10_000) }
        for running in all { running.kill() }
    }

    /// The arguments of each command running now.
    static var running: [[String]] { Registry.shared.all.map(\.arguments) }

    /// The process and whether it was cancelled, shared by the task that
    /// runs it, its cancel handler and `endAll`.
    private final class Running: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private var started = false
        private var wasCancelled = false

        init(_ process: Process) { self.process = process }

        var arguments: [String] { process.arguments ?? [] }
        var cancelled: Bool { lock.withLock { wasCancelled } }
        var isRunning: Bool { lock.withLock { started } && process.isRunning }

        /// Starts the command, unless it was cancelled first. It is
        /// registered before the start, so a quit at that moment ends it too.
        func start() throws {
            try lock.withLock {
                guard !wasCancelled else { throw CancellationError() }
                Registry.shared.add(self)
                do {
                    try process.run()
                } catch {
                    Registry.shared.remove(self)
                    throw error
                }
                started = true
            }
        }

        func cancel(escalate: Bool = true) {
            let pid: pid_t? = lock.withLock {
                wasCancelled = true
                return started && process.isRunning ? process.processIdentifier : nil
            }
            guard let pid else { return }
            Darwin.kill(pid, SIGTERM)
            guard escalate else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in kill() }
        }

        /// SIGKILL, when it is still running.
        func kill() {
            lock.withLock {
                if started, process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    /// The commands running now, for `endAll`.
    private final class Registry: @unchecked Sendable {
        static let shared = Registry()
        private let lock = NSLock()
        private var running: [ObjectIdentifier: Running] = [:]

        var all: [Running] { lock.withLock { Array(running.values) } }
        func add(_ item: Running) { lock.withLock { running[ObjectIdentifier(item)] = item } }
        func remove(_ item: Running) { _ = lock.withLock { running.removeValue(forKey: ObjectIdentifier(item)) } }
    }

    /// What the pipes gave, gathered from their handlers' threads.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var outData = Data()
        private var errors = Data()
        private var pending = Data()
        private var outDone = false
        private var errorsDone = false
        private var drained: (() -> Void)?

        var out: Data { lock.withLock { outData } }
        var errorText: String { lock.withLock { String(decoding: errors, as: UTF8.self) } }

        func addOut(_ data: Data) { lock.withLock { outData.append(data) } }

        func addErrors(_ data: Data, _ line: (@Sendable (String) -> Void)?) {
            let lines: [String] = lock.withLock {
                errors.append(data)
                guard line != nil else { return [] }
                pending.append(data)
                var found: [String] = []
                while let end = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                    found.append(String(decoding: pending[pending.startIndex..<end], as: UTF8.self))
                    pending = Data(pending[pending.index(after: end)...])
                }
                return found
            }
            for text in lines where !text.isEmpty { line?(text) }
        }

        func finishErrors(_ line: (@Sendable (String) -> Void)?) {
            let rest: String = lock.withLock {
                defer { pending = Data() }
                return String(decoding: pending, as: UTF8.self)
            }
            if !rest.isEmpty { line?(rest) }
            done { errorsDone = true }
        }

        func finishOut() { done { outDone = true } }

        func whenDrained(_ then: @escaping () -> Void) {
            let now: Bool = lock.withLock {
                if outDone && errorsDone { return true }
                drained = then
                return false
            }
            if now { then() }
        }

        private func done(_ mark: () -> Void) {
            let then: (() -> Void)? = lock.withLock {
                mark()
                guard outDone && errorsDone, let drained else { return nil }
                self.drained = nil
                return drained
            }
            then?()
        }
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
