import Foundation
import Testing

@testable import DaftarCore

/// The tests of `drill.rs` in notes-linux, ported by name, and the state
/// file both apps share.
@Suite struct DrillTests {
    func day(_ text: String) -> Day { Day(text)! }

    static let questions = """
        - [A source](https://example.com)

        Every question has a short answer.

        ## The Table to Remember

        | Problem | Tool |
        | --- | --- |
        | Slow | Plan |

        ## Part 1: Indexes

        ### Q1. What does an index change?

        **Answer:** reads get faster, writes slower.

        #### Example

        ```sql
        ## not a heading
        CREATE INDEX ON users (email);
        ```

        ### Q2. When is an index not used?

        When a function wraps the column.

        ## Part 2: Writing SQL

        Joins and groups.

        ### Q3. WHERE or HAVING?

        WHERE filters rows, HAVING groups.

        ## Related notes

        - [[Elsewhere]]

        """

    @Test func aQuestionUnderAPartIsACardAndItsExampleIsItsAnswer() {
        let cards = Drill.cards(path: "Prep/Database Questions.md", text: Self.questions)
        #expect(
            cards.map(\.question) == [
                "The Table to Remember", "Q1. What does an index change?", "Q2. When is an index not used?", "Part 2: Writing SQL",
                "Q3. WHERE or HAVING?",
            ])
        let q1 = cards[1]
        #expect(q1.id == "Prep/Database Questions.md#Part 1: Indexes#Q1. What does an index change?")
        #expect(q1.context == ["Database Questions", "Part 1: Indexes"])
        #expect(q1.line == 12)
        #expect(q1.answer.hasPrefix("**Answer:** reads get faster"))
        #expect(q1.answer.contains("#### Example"))
        #expect(q1.answer.contains("## not a heading"))
        #expect(!q1.answer.contains("Q2"))
        // A part with an introduction is a card of the introduction alone.
        #expect(cards[3].answer == "Joins and groups.")
        #expect(!cards.contains { $0.answer.contains("Elsewhere") })
    }

    @Test func aProblemIsOneCardWithItsParts() {
        let text = """
            # Coding

            ## Most Frequent Item

            ### The Problem

            Return the item seen most.

            ### Test Cases

            | In | Out |
            | --- | --- |
            | [] | None |

            ### What to Ask First

            Ties?

            ### Two Solutions

            Count in a map.

            #### Example

            ```python
            pass
            ```

            ## Sources

            - a book

            """
        let cards = Drill.cards(path: "Coding.md", text: text)
        #expect(cards.map(\.question) == ["Most Frequent Item", "What to Ask First"])
        let item = cards[0]
        #expect(item.answer.hasPrefix("### The Problem\n\nReturn the item seen most."))
        #expect(item.answer.contains("### Test Cases"))
        #expect(item.answer.contains("### Two Solutions\n\nCount in a map."))
        #expect(item.answer.contains("#### Example"))
        #expect(!item.answer.contains("Ties?"))
        #expect(cards[1].context == ["Coding", "Coding", "Most Frequent Item"])
    }

    @Test func headingsWithNothingUnderThemAreNoCards() {
        #expect(Drill.cards(path: "A.md", text: "# A\n\n## B\n\n### C\n").isEmpty)
        #expect(Drill.cards(path: "A.md", text: "Text with no heading.\n").isEmpty)
        #expect(Drill.cards(path: "A.md", text: "## Example\n\nAlone.\n").isEmpty)
        #expect(Drill.cards(path: "A.md", text: "## Same\n\nOne.\n\n## Same\n\nTwo.\n").count == 1)
    }

    @Test func partsAndReferencesAreNamedSo() {
        for part in ["Example", "**Examples**", "Worked Example: URL Shortener", "The Problem", "Test Cases", "Two Solutions", "Solution:"] {
            #expect(Drill.isPart(part), "\(part)")
        }
        for card in ["Q1. What is an example of a race?", "Problems", "How to Run the Round"] {
            #expect(!Drill.isPart(card), "\(card)")
        }
        #expect(Drill.isReference("Related Notes"))
        #expect(!Drill.isReference("Related work"))
    }

    @Test func sm2SpacesGoodAnswersOutAndStartsAForgottenCardAgain() {
        let today = day("2026-11-08")
        let first = DrillReview.rate(nil, .good, today: today)
        #expect(first.interval == 1 && first.reps == 1 && first.due == day("2026-11-09"))
        #expect(abs(first.ease - 2.5) < 1e-9)
        let second = DrillReview.rate(first, .good, today: first.due)
        #expect(second.interval == 6 && second.due == day("2026-11-15"))
        let third = DrillReview.rate(second, .good, today: second.due)
        #expect(third.interval == 15)
        let easy = DrillReview.rate(second, .easy, today: second.due)
        #expect(abs(easy.ease - 2.6) < 1e-9)
        #expect(easy.interval == 16)
        let hard = DrillReview.rate(second, .hard, today: second.due)
        #expect(abs(hard.ease - 2.36) < 1e-9)
        #expect(hard.interval == 14)
        let forgotten = DrillReview.rate(third, .again, today: third.due)
        #expect(forgotten.interval == 1 && forgotten.reps == 0 && forgotten.lapses == 1)
        #expect(abs(forgotten.ease - third.ease) < 1e-9)
        let back = DrillReview.rate(forgotten, .good, today: forgotten.due)
        #expect(back.interval == 1)
    }

    @Test func theEaseNeverFallsUnder1_3() {
        var review = DrillReview.rate(nil, .hard, today: day("2026-01-01"))
        for _ in 0..<20 { review = DrillReview.rate(review, .hard, today: review.due) }
        #expect(abs(review.ease - 1.3) < 1e-9)
    }

    @Test func theDueCardsComeFirstThenAFewNewOnes() {
        let cards = Drill.cards(path: "N.md", text: "## A\n\na\n\n## B\n\nb\n\n## C\n\nc\n\n## D\n\nd\n")
        let today = day("2026-11-08")
        var state = DrillState()
        state.reviews["N.md#C"] = DrillReview.rate(nil, .good, today: day("2026-11-01"))
        state.reviews["N.md#D"] = DrillReview.rate(nil, .good, today: day("2026-11-05"))
        state.reviews["N.md#B"] = DrillReview.rate(nil, .good, today: today)
        #expect(Drill.due(cards, state: state, today: today, new: 10, limit: 100).map(\.question) == ["C", "D", "A"])
        #expect(Drill.due(cards, state: state, today: today, new: 0, limit: 100).count == 2)
        #expect(Drill.due(cards, state: state, today: today, new: 10, limit: 1).count == 1)
        #expect(Drill.nextDue(cards, state: state, after: today) == day("2026-11-09"))
    }

    @Test func theStateComesBackFromItsFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "drill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "state/drill.json")
        var state = DrillState()
        state.rate("N.md#A", .good, today: day("2026-11-08"))
        state.rate("N.md#A", .easy, today: day("2026-11-09"))
        try state.save(file)
        let back = DrillState.load(file)
        #expect(back == state)
        #expect(back.reviews["N.md#A"]?.due == day("2026-11-15"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path).count == 1)
        #expect(DrillState(text: "not json") == DrillState())
        #expect(DrillState.load(folder.appending(path: "none.json")) == DrillState())
    }

    @Test func aFoldersDeckLeavesItsFolderNoteOut() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "drill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "Prep/Go"), withIntermediateDirectories: true)
        try "## Notes in This Category\n\n- [[Go]]\n".write(to: root.appending(path: "Prep/Prep.md"), atomically: true, encoding: .utf8)
        try "## Q1. What is a goroutine?\n\nA light thread.\n".write(to: root.appending(path: "Prep/Go/Go Questions.md"), atomically: true, encoding: .utf8)
        try "## Elsewhere\n\nText.\n".write(to: root.appending(path: "Other.md"), atomically: true, encoding: .utf8)
        let index = Vault.index(root)
        let notes = Drill.notes(in: index, folder: "Prep/")
        #expect(notes == ["Prep/Go/Go Questions.md"])
        let deck = Drill.deck(root: root, paths: notes)
        #expect(deck.count == 1)
        #expect(deck.first?.answer == "A light thread.")
        #expect(Drill.notes(in: index, folder: "Prep", hidden: { $0.contains("Go") }).isEmpty)
    }

    // MARK: Shared with the command line

    /// Written by `daftar-cli` 0.21's MCP `drill_rate` (good, again, easy):
    /// the file the app must read and write back byte for byte.
    static let rustFile = """
        {
          "version": 1,
          "cards": {
            "Prep/Go.md#Q1. What is a \\"goroutine\\"?": {
              "ease": 2.5,
              "interval": 1,
              "reps": 1,
              "lapses": 0,
              "due": "2026-11-13",
              "last": "2026-11-12"
            },
            "Prep/Go.md#Zed": {
              "ease": 2.6,
              "interval": 1,
              "reps": 1,
              "lapses": 0,
              "due": "2026-11-13",
              "last": "2026-11-12"
            },
            "Prep/Go.md#پرسش دوم": {
              "ease": 2.5,
              "interval": 1,
              "reps": 0,
              "lapses": 1,
              "due": "2026-11-13",
              "last": "2026-11-12"
            }
          }
        }
        """

    @Test func theCommandLinesFileIsReadAndWrittenTheSame() {
        let state = DrillState(text: Self.rustFile)
        #expect(state.reviews.count == 3)
        let quoted = state.reviews["Prep/Go.md#Q1. What is a \"goroutine\"?"]
        #expect(quoted == DrillReview(ease: 2.5, interval: 1, reps: 1, lapses: 0, due: day("2026-11-13"), last: day("2026-11-12")))
        #expect(state.reviews["Prep/Go.md#پرسش دوم"]?.lapses == 1)
        #expect(state.reviews["Prep/Go.md#Zed"]?.ease == 2.6)
        // Byte for byte: the keys in byte order, the floats as serde_json writes them.
        #expect(state.text == Self.rustFile)
        // A card's id is the command line's, so the cards meet their reviews.
        let cards = Drill.cards(path: "Prep/Go.md", text: "## Q1. What is a \"goroutine\"?\n\nA light thread.\n\n## پرسش دوم\n\nپاسخ.\n\n## Zed\n\nz\n")
        #expect(cards.map { state.due($0) } == Array(repeating: day("2026-11-13"), count: 3))
    }

    @Test func aFileWrittenElsewhereIsReadLeniently() {
        // Whole floats get `.0`; a review missing a field, or with a count
        // written as a float, is dropped as `serde_json` drops it.
        let text = """
            {"cards": {"A.md#A": {"ease": 3, "interval": 4, "reps": 2, "due": "2026-01-05", "last": "2026-01-01"},
            "A.md#B": {"ease": 2.5, "interval": 1.0, "reps": 1, "due": "2026-01-02", "last": "2026-01-01"},
            "A.md#C": {"ease": 1.0, "interval": 1, "reps": 1, "due": "2026-01-02", "last": "2026-01-01"}}}
            """
        let state = DrillState(text: text)
        #expect(state.reviews.keys.sorted() == ["A.md#A", "A.md#C"])
        #expect(state.reviews["A.md#A"]?.lapses == 0)
        #expect(state.reviews["A.md#C"]?.ease == 1.3)
        #expect(state.text.contains("\"ease\": 3.0,"))
        #expect(DrillState(text: "[1, 2]") == DrillState())
    }

    @Test func theStateFileIsTheCommandLines() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        let folder = DrillState.folder(environment: [:], home: home)
        #expect(folder.path(percentEncoded: false) == "/Users/someone/.local/state/daftar/")
        #expect(DrillState.folder(environment: ["XDG_STATE_HOME": "/tmp/state"], home: home).path(percentEncoded: false) == "/tmp/state/daftar/")
        // A relative `XDG_STATE_HOME` is not taken, as the XDG spec says.
        #expect(DrillState.folder(environment: ["XDG_STATE_HOME": "state"], home: home) == folder)
        // FNV-1a of the path, as `reading_places::state_file` names the file.
        #expect(DrillState.hash(URL(filePath: "/home/a/vault")) == "3ce90dc2d0a15db6")
        #expect(DrillState.hash(URL(filePath: "/Users/someone/Notes/", directoryHint: .isDirectory)) == "577cb4302b31064b")
        #expect(
            DrillState.file(root: URL(filePath: "/home/a/vault"), in: folder).path(percentEncoded: false)
                == "/Users/someone/.local/state/daftar/drill-3ce90dc2d0a15db6.json")
    }

    @Test func aRatingReadsTheFileAgainFirst() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "drill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "drill.json")
        let today = day("2026-11-08")
        // The app loaded an empty state; then the command line rated A.
        let loaded = DrillState.load(file)
        var other = DrillState()
        other.rate("N.md#A", .good, today: today)
        try other.save(file)
        let (state, review) = try DrillState.rate("N.md#B", .easy, today: today, in: file)
        #expect(loaded.reviews.isEmpty)
        #expect(review.interval == 1)
        #expect(Set(state.reviews.keys) == ["N.md#A", "N.md#B"])
        #expect(DrillState.load(file) == state)
    }

    @Test func aSessionAsksAForgottenCardAgainAndKeepsItsFirstRating() {
        let cards = Drill.cards(path: "Go.md", text: "## Part 1\n\n### Q1\n\nA function run on its own.\n\n### Q2\n\nA typed pipe.\n")
        var session = DrillSession(cards: cards)
        #expect(session.total == 2 && session.current?.card.question == "Q1")
        let first = [session.rate(.again), session.rate(.good)]
        #expect(first == [true, true])
        #expect(session.current?.card.question == "Q1" && session.current?.again == true)
        let again = [session.rate(.again), session.rate(.good)]
        #expect(again == [false, false])
        #expect(session.isDone && session.rated == 2 && session.forgotten == 1)
    }

    @Test func intervalsAreSaidShort() {
        #expect(DrillReview.spoken(days: 1) == "1 day")
        #expect(DrillReview.spoken(days: 6) == "6 days")
        #expect(DrillReview.spoken(days: 28) == "4 wk")
        #expect(DrillReview.spoken(days: 120) == "4 mo")
        #expect(DrillReview.spoken(days: 365) == "1 yr")
        #expect(DrillReview.spoken(days: 548) == "1.5 yr")
    }
}
