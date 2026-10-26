import Foundation
import Testing

@testable import DaftarCore

@Suite struct ReadingPlacesTests {
    @Test func placesComeBackFromTheirFile() {
        var places = ReadingPlaces()
        places.set("Notes/Plan.md", line: 12)
        places.set("Notes/Inbox.md", line: 3)
        places.set("Notes/Plan.md", line: 40)
        let back = ReadingPlaces(data: places.data)
        #expect(back == places)
        #expect(back["Notes/Plan.md"] == 40)
        #expect(back["Notes/Inbox.md"] == 3)
        #expect(ReadingPlaces(data: Data("not json".utf8)).count == 0)
    }

    @Test func theOldestGoFirst() {
        var places = ReadingPlaces()
        for index in 0..<(ReadingPlaces.limit + 5) { places.set("Note \(index).md", line: index) }
        // A note read again is new again.
        places.set("Note 5.md", line: 1)
        places.set("One more.md", line: 1)
        #expect(places.count == ReadingPlaces.limit)
        #expect(places["Note 0.md"] == nil)
        #expect(places["Note 5.md"] == 1)
        #expect(places["Note 6.md"] == nil)
    }

    @Test func placesFollowMovesAndDeletes() {
        var places = ReadingPlaces()
        places.set("Old/Plan.md", line: 7)
        places.set("Old/Sub/Deep.md", line: 2)
        places.set("Keep.md", line: 1)
        places.moved(["Old/Plan.md": "New/Plan.md"])
        #expect(places["New/Plan.md"] == 7)
        #expect(places["Old/Plan.md"] == nil)
        places.forget("Old")
        #expect(places["Old/Sub/Deep.md"] == nil)
        #expect(places["Keep.md"] == 1)
        #expect(ReadingPlaces(data: places.data) == places)
    }

    @Test func foldsAndReadTimesComeBack() {
        var places = ReadingPlaces()
        places.setFolds("Plan.md", ["2:Done", "3:Old ideas"])
        places.markRead("Plan.md", at: Date(timeIntervalSince1970: 1_800_000_000.7))
        places.set("Plan.md", line: 4)
        let back = ReadingPlaces(data: places.data)
        #expect(back == places)
        #expect(back.folds("Plan.md") == ["2:Done", "3:Old ideas"])
        #expect(back.lastRead("Plan.md") == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(back["Plan.md"] == 4)
        places.setFolds("Plan.md", [])
        #expect(places.folds("Plan.md").isEmpty)
        places.moved(["Plan.md": "Roadmap.md"])
        #expect(places.lastRead("Roadmap.md") != nil)
    }

    @Test func theFirstFormatIsStillRead() {
        let old = ReadingPlaces(data: Data(#"{"places":[{"A.md":3},{"B.md":9}]}"#.utf8))
        #expect(old["A.md"] == 3)
        #expect(old["B.md"] == 9)
    }
}
