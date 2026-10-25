import Testing

@testable import DaftarCore

@Suite struct FuzzyTests {
    @Test func lettersInOrder() throws {
        let match = try #require(Fuzzy.match("nn", in: "New Note"))
        #expect(match.positions == [0, 4])
        #expect(Fuzzy.match("xz", in: "New Note") == nil)
        #expect(Fuzzy.match("", in: "Anything")?.score == 0)
    }

    @Test func wordStartsAndRunsScoreMore() throws {
        let starts = try #require(Fuzzy.match("tt", in: "Toggle Terminal"))
        let middle = try #require(Fuzzy.match("tt", in: "Bottle"))
        #expect(starts.score > middle.score)
        let run = try #require(Fuzzy.match("sync", in: "Sync Now"))
        let spread = try #require(Fuzzy.match("sync", in: "Show your notes, cleanly"))
        #expect(run.score > spread.score)
    }

    @Test func picksTheBestPlace() throws {
        // "rn" at the word starts of "Random Note", not the "r" in "Rename".
        let match = try #require(Fuzzy.match("rn", in: "Open Random Note"))
        #expect(match.positions == [5, 12])
    }

    @Test func foldsCaseAndCountsCapitals() throws {
        #expect(Fuzzy.match("NEW", in: "new note") != nil)
        let camel = try #require(Fuzzy.match("qo", in: "QuickOpen"))
        #expect(camel.positions == [0, 5])
    }
}
