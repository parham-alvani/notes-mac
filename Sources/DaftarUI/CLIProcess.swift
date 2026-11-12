import Foundation

/// One run of `daftar-cli` off the main thread: what it printed, how it
/// ended. A cancelled task ends the command (SIGTERM, then SIGKILL a second
/// later), so a search typed over or a download stopped leaves no process
/// behind. The command found is `PDFExport.cli`'s.
enum CLIProcess {
    struct Output: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: String
        /// Ended by a cancel, not by itself.
        var cancelled: Bool
    }

    enum Failure: Error, Equatable {
        /// No `daftar-cli` on this Mac.
        case notInstalled
        /// It could not be started.
        case couldNotRun(String)
    }

    static let notInstalled = "daftar-cli is not installed: brew install parham-alvani/tap/daftar-cli"

    /// Runs [cli] with [arguments] at [priority]; [line] hears each line of
    /// its stderr as it comes (an index build's progress), on no particular thread.
    static func run(
        cli: String? = PDFExport.cli(),
        _ arguments: [String],
        environment: [String: String]? = nil,
        priority: QualityOfService = .userInitiated,
        line: (@Sendable (String) -> Void)? = nil
    ) async throws -> Output {
        guard let cli else { throw Failure.notInstalled }
        let process = Process()
        process.executableURL = URL(filePath: cli)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.qualityOfService = priority
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let box = ProcessBox(process)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
                let collected = Collected()
                // stderr a line at a time; a progress line may end in `\r`.
                err.fileHandleForReading.readabilityHandler = { handle in
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
                    // The pipes are read to their end before the answer.
                    collected.whenDrained {
                        continuation.resume(returning: Output(
                            status: process.terminationStatus, stdout: collected.out,
                            stderr: collected.errorText, cancelled: box.cancelled))
                    }
                }
                do {
                    try process.run()
                } catch {
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: Failure.couldNotRun(error.localizedDescription))
                    return
                }
                if Task.isCancelled { box.cancel() }
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// The process, for the cancel handler, which runs on another thread.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var wasCancelled = false

    init(_ process: Process) { self.process = process }

    var cancelled: Bool { lock.withLock { wasCancelled } }

    func cancel() {
        lock.withLock { wasCancelled = true }
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// What the pipes gave, gathered from their handlers' threads.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var out = Data()
    private var errors = Data()
    private var pending = Data()
    private var outDone = false
    private var errorsDone = false
    private var drained: (() -> Void)?

    var errorText: String { lock.withLock { String(decoding: errors, as: UTF8.self) } }

    func addOut(_ data: Data) { lock.withLock { out.append(data) } }

    func addErrors(_ data: Data, _ line: (@Sendable (String) -> Void)?) {
        let lines: [String] = lock.withLock {
            errors.append(data)
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
