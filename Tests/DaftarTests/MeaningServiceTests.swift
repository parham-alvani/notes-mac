import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// Search by meaning against a made-up `daftar-cli`: a shell script that
/// counts its runs and answers as the real one would.
@MainActor @Suite struct MeaningServiceTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "daftar-meaning-\(UUID().uuidString)")

    /// A `daftar-cli` that prints [stdout] and [stderr] and exits [status].
    func fake(stdout: String = "", stderr: String = "", status: Int32 = 0) throws -> (cli: String, runs: () -> Int) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cli = folder.appending(path: "daftar-cli")
        let count = folder.appending(path: "runs")
        // What it prints is in files, so no quote in it is the shell's.
        try stdout.write(to: folder.appending(path: "out"), atomically: true, encoding: .utf8)
        try stderr.write(to: folder.appending(path: "err"), atomically: true, encoding: .utf8)
        let script = """
            #!/bin/sh
            echo run >> '\(count.path)'
            cat '\(folder.appending(path: "out").path)'
            cat '\(folder.appending(path: "err").path)' >&2
            exit \(status)
            """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return (cli.path, { ((try? String(contentsOf: count, encoding: .utf8)) ?? "").split(separator: "\n").count })
    }

    @Test func theHitsComeBackAndTheModelIsThere() async throws {
        let (cli, _) = try fake(stdout: #"[{"path":"A.md","line":3,"score":0.9,"snippet":"near"}]"#)
        let service = MeaningService()
        service.findCLI = { cli }
        let result = await service.search("kafka", vault: folder)
        #expect(try result?.get() == [Meaning.Hit(path: "A.md", line: 3, score: 0.9, snippet: "near")])
        #expect(service.availability == .ready)
    }

    @Test func exitThreeOffersTheModel() async throws {
        let (cli, _) = try fake(stderr: "daftar-cli: the model is not downloaded", status: 3)
        let service = MeaningService()
        service.findCLI = { cli }
        let result = await service.related("A.md", vault: folder)
        #expect(throws: Meaning.Failure.noModel) { try result?.get() }
        #expect(service.availability == .noModel)
    }

    @Test func anOldCLIIsAskedOnceThenToldToUpgrade() async throws {
        let (cli, runs) = try fake(stderr: "error: unexpected argument '--json' found", status: 2)
        let service = MeaningService()
        service.findCLI = { cli }
        for _ in 0..<3 {
            let result = await service.search("kafka", vault: folder)
            #expect(throws: Meaning.Failure.needsUpgrade) { try result?.get() }
        }
        #expect(runs() == 1)
        #expect(service.availability == .needsUpgrade)
    }

    @Test func noCLIIsSaid() async {
        let service = MeaningService()
        service.findCLI = { nil }
        let result = await service.search("kafka", vault: folder)
        #expect(throws: Meaning.Failure.failed(CLIProcess.notInstalled)) { try result?.get() }
        #expect(service.availability == .notInstalled)
    }

    @Test func theModelIsLookedForInTheCache() throws {
        let cache = folder.appending(path: "cache")
        #expect(!MeaningService.modelDownloaded(environment: ["XDG_CACHE_HOME": cache.path]))
        try FileManager.default.createDirectory(at: cache.appending(path: "daftar/models/potion"), withIntermediateDirectories: true)
        #expect(MeaningService.modelDownloaded(environment: ["XDG_CACHE_HOME": cache.path]))
    }
}
