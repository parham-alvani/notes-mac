import Foundation
import Testing

@testable import DaftarUI

@Suite struct CLIProcessTests {
    @Test func theOutputTheStatusAndEachLineOfStderr() async throws {
        let lines = Lines()
        let output = try await CLIProcess.run(cli: "/bin/sh", ["-c", "printf '[1]'; printf 'indexed 1/2\\rindexed 2/2\\nlast' >&2; exit 3"]) { lines.add($0) }
        #expect(output.status == 3)
        #expect(String(decoding: output.stdout, as: UTF8.self) == "[1]")
        #expect(output.stderr == "indexed 1/2\rindexed 2/2\nlast")
        #expect(lines.all == ["indexed 1/2", "indexed 2/2", "last"])
        #expect(!output.cancelled)
    }

    @Test func aCancelEndsTheCommand() async throws {
        let started = ContinuousClock.now
        let task = Task { try await CLIProcess.run(cli: "/bin/sleep", ["30"]) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let output = try await task.value
        #expect(output.cancelled)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func noCLIIsSaid() async {
        await #expect(throws: CLIProcess.Failure.notInstalled) { try await CLIProcess.run(cli: nil, []) }
        await #expect(throws: CLIProcess.Failure.self) { try await CLIProcess.run(cli: "/nonexistent/daftar-cli", []) }
    }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
