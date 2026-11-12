import Foundation
import Testing

@testable import DaftarCore

@Suite struct MeaningTests {
    @Test func theJSONIsReadAsHitsEachNoteOnce() throws {
        let json = """
            [{"path":"Learning/Kafka.md","line":12,"score":0.83,"snippet":"A log of events"},
             {"path":"Learning/Kafka.md","line":40,"score":0.61,"snippet":"Partitions"},
             {"path":"Personal/سفر.md","line":1,"score":0.5,"snippet":"سفر به شیراز"}]
            """
        let hits = try Meaning.hits(Data(json.utf8))
        #expect(hits == [
            Meaning.Hit(path: "Learning/Kafka.md", line: 12, score: 0.83, snippet: "A log of events"),
            Meaning.Hit(path: "Personal/سفر.md", line: 1, score: 0.5, snippet: "سفر به شیراز"),
        ])
        #expect(hits[0].zeroBasedLine == 11)
        #expect(try Meaning.hits(Data("[]".utf8)).isEmpty)
    }

    @Test func aMissingFieldIsNotAReasonToDropTheNote() throws {
        let hits = try Meaning.hits(Data(#"[{"path":"A.md"},{"path":"B.md","line":3,"score":0.2,"snippet":null,"extra":true}]"#.utf8))
        #expect(hits.map(\.path) == ["A.md", "B.md"])
        #expect(hits[0].line == 1 && hits[0].zeroBasedLine == 0 && hits[0].snippet.isEmpty)
        #expect(hits[1].line == 3)
    }

    @Test func aPathOutsideTheVaultIsDropped() throws {
        let json = #"[{"path":"../secret.md","line":1,"score":1,"snippet":""},{"path":"/etc/hosts","line":1,"score":1,"snippet":""},{"path":"","line":1,"score":1,"snippet":""},{"path":"Ok.md","line":2,"score":1,"snippet":""}]"#
        #expect(try Meaning.hits(Data(json.utf8)).map(\.path) == ["Ok.md"])
    }

    @Test func whatIsNotTheListThrows() {
        #expect(throws: (any Error).self) { try Meaning.hits(Data("A.md:12 a log".utf8)) }
        #expect(throws: (any Error).self) { try Meaning.hits(Data(#"{"path":"A.md"}"#.utf8)) }
    }

    @Test func theArgumentsPutTheQueryAndTheNoteLast() {
        let vault = URL(filePath: "/Users/someone/vault")
        #expect(Meaning.searchArguments(vault: vault, query: "kafka log")
            == ["--vault", "/Users/someone/vault", "search", "--meaning-only", "--json", "-n", "20", "--", "kafka log"])
        #expect(Meaning.searchArguments(vault: vault, query: "-x", mode: .together, limit: 5)
            == ["--vault", "/Users/someone/vault", "search", "--meaning", "--json", "-n", "5", "--", "-x"])
        #expect(Meaning.relatedArguments(vault: vault, note: "--help.md")
            == ["--vault", "/Users/someone/vault", "related", "--json", "-n", "10", "--", "--help.md"])
        #expect(Meaning.indexArguments(vault: vault) == ["--vault", "/Users/someone/vault", "semantic-index"])
        #expect(Meaning.indexArguments(vault: vault, download: true) == ["--vault", "/Users/someone/vault", "semantic-index", "--download-model"])
    }

    @Test func exitThreeIsAModelNotDownloaded() {
        #expect(Meaning.failure(status: 3, errors: "daftar-cli: the model is not there") == .noModel)
        // daftar-cli 0.21 said it in words, with exit 1.
        let older = "daftar-cli: search by meaning needs its model, which is not downloaded: run `daftar-cli semantic-index --download-model` once (531 MB, into /x)"
        #expect(Meaning.failure(status: 1, errors: older) == .noModel)
    }

    @Test func anOldCLIIsToldToUpgrade() {
        let json = """
            error: unexpected argument '--json' found

              tip: to pass '--json' as a value, use '-- --json'

            Usage: daftar-cli search --meaning <QUERY>...

            For more information, try '--help'.
            """
        #expect(Meaning.failure(status: 2, errors: json) == .needsUpgrade)
        #expect(Meaning.failure(status: 2, errors: "error: unrecognized subcommand 'related'\n\nUsage: daftar-cli [OPTIONS] [COMMAND]\n") == .needsUpgrade)
        #expect(Meaning.failure(status: 2, errors: "error: unexpected argument '--meaning-only' found\n") == .needsUpgrade)
        #expect(Meaning.failure(status: 2, errors: "error: unrecognized subcommand 'semantic-index'\n") == .needsUpgrade)
        #expect(Meaning.Failure.needsUpgrade.message == "Search by meaning needs daftar-cli 0.23.0 or later: brew upgrade parham-alvani/tap/daftar-cli")
    }

    @Test func anyOtherFailureSaysItsLastLine() {
        #expect(Meaning.failure(status: 2, errors: "error: unexpected argument '--frobnicate' found\n") == .failed("daftar-cli: unexpected argument '--frobnicate' found"))
        #expect(Meaning.failure(status: 1, errors: "reading the vault\ndaftar-cli: no note Missing.md\n") == .failed("no note Missing.md"))
        #expect(Meaning.failure(status: 1, errors: "  \n") == .failed("daftar-cli failed (exit 1)."))
    }

    @Test func theProgressOfABuildIsReadFromItsLines() {
        #expect(Meaning.progress("indexed 120/4300") == .indexing(done: 120, total: 4300))
        #expect(Meaning.progress("embedding 43883/43883 sections") == .indexing(done: 43883, total: 43883))
        #expect(Meaning.progress("40% of 531 MB") == .downloading(percent: 40))
        #expect(Meaning.progress("100% of 531 MB")?.fraction == 1)
        #expect(Meaning.progress("indexed 5/0") == nil)
        #expect(Meaning.progress("indexed some/notes") == nil)
        #expect(Meaning.progress("downloading minishlab/potion-multilingual-128M at 73908c34 (531 MB) into /x") == nil)
        #expect(Meaning.progress("2830 notes, 43883 sections in /x/e5b.sqlite") == nil)
        // More done than there are is all of them.
        #expect(Meaning.progress("indexed 9/4") == .indexing(done: 4, total: 4))
    }
}
