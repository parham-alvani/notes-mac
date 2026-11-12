import Foundation
import Testing

@testable import DaftarUI

/// The one runner of `daftar-cli`, tried on the system's own commands.
@Suite struct DaftarCLITests {
    @Test func theRunnerFeedsStdinAndReadsBothPipes() async throws {
        let output = try await DaftarCLI.run("/bin/sh", ["-c", "cat; echo said >&2; exit 3"], input: Data("note text\n".utf8))
        #expect(output.text == "note text\n")
        #expect(output.stderr == "said\n")
        #expect(output.status == 3)
        // More than a pipe holds, both ways, does not stop the command.
        let big = String(repeating: "line of a long note\n", count: 20_000)
        let echoed = try await DaftarCLI.run("/bin/cat", [], input: Data(big.utf8))
        #expect(echoed.text == big)
    }

    @Test func theOutputTheStatusAndEachLineOfStderr() async throws {
        let lines = Lines()
        let output = try await DaftarCLI.run("/bin/sh", ["-c", "printf '[1]'; printf 'indexed 1/2\\rindexed 2/2\\nlast' >&2; exit 3"]) { lines.add($0) }
        #expect(output.status == 3)
        #expect(output.text == "[1]")
        #expect(output.stderr == "indexed 1/2\rindexed 2/2\nlast")
        #expect(lines.all == ["indexed 1/2", "indexed 2/2", "last"])
        #expect(!output.cancelled)
    }

    @Test func itRunsInTheFolderGivenWithTheEnvironmentGiven() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "daftar-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = try await DaftarCLI.run("/bin/sh", ["-c", "pwd -P; echo \"$DAFTAR_TEST\""], in: folder, environment: ["DAFTAR_TEST": "given"])
        // `/var` is `/private/var` to `pwd -P`.
        #expect(output.text.hasSuffix("/" + folder.lastPathComponent + "\ngiven\n"))
    }

    @Test func aCancelledRunEndsTheCommand() async throws {
        let started = ContinuousClock.now
        let task = Task { try await DaftarCLI.run("/bin/sleep", ["30"]) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let output = try? await task.value
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(output?.cancelled ?? true)
    }

    /// Quitting the app ends every command still running: an index build
    /// must not go on with no app to answer.
    @Test func quittingEndsEveryCommandStillRunning() async throws {
        let marker = UUID().uuidString
        let mine: ([String]) -> Bool = { $0.last == marker }
        let started = ContinuousClock.now
        let tasks = (0..<2).map { _ in Task { try await DaftarCLI.run("/bin/sh", ["-c", "sleep 30", marker]) } }
        for _ in 0..<100 where DaftarCLI.running.filter(mine).count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(DaftarCLI.running.filter(mine).count == 2)
        DaftarCLI.endAll(matching: mine)
        for task in tasks {
            let output = try await task.value
            #expect(output.cancelled)
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(DaftarCLI.running.filter(mine).isEmpty)
    }

    @Test func noCLIIsSaid() async {
        await #expect(throws: DaftarCLI.Failure.notInstalled) { try await DaftarCLI.run(nil, []) }
        await #expect(throws: DaftarCLI.Failure.self) { try await DaftarCLI.run("/nonexistent/daftar-cli", []) }
        #expect(DaftarCLI.describe(DaftarCLI.Failure.notInstalled) == DaftarCLI.notInstalled)
    }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
