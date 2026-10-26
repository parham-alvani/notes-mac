import Foundation
import Testing

@testable import DaftarCore

@Suite struct VaultReplaceTests {
    @Test func plainTextIsFoundOnItsLines() throws {
        let text = "Call Alice\nalice and ALICE\nMalice"
        let found = try VaultReplace.matches(in: text, find: "alice", replace: "Bob", options: .init())
        #expect(found.map(\.line) == [0, 1, 1, 2])
        #expect(found.map(\.found) == ["Alice", "alice", "ALICE", "alice"])
        #expect(found[1].before == "alice and ALICE" && found[1].after == "Bob and ALICE")
        #expect(VaultReplace.apply(found, to: text) == "Call Bob\nBob and Bob\nMBob")
        // The replacement of plain text is plain: `$1` is `$1`.
        let dollars = try VaultReplace.matches(in: "a.b", find: ".", replace: "$1", options: .init())
        #expect(VaultReplace.apply(dollars, to: "a.b") == "a$1b")
    }

    @Test func caseAndWholeWordNarrowTheMatches() throws {
        let text = "Alice alice Malice alice_x کارها کار"
        #expect(try VaultReplace.matches(in: text, find: "alice", replace: "", options: .init(matchCase: true)).count == 3)
        #expect(try VaultReplace.matches(in: text, find: "alice", replace: "", options: .init(wholeWord: true)).map(\.found) == ["Alice", "alice"])
        #expect(try VaultReplace.matches(in: text, find: "کار", replace: "", options: .init(wholeWord: true)).map(\.location) == [33])
    }

    @Test func aRegularExpressionNamesItsGroups() throws {
        let text = "2026-10-26 and 2025-01-02"
        let options = VaultReplace.Options(regularExpression: true)
        let found = try VaultReplace.matches(in: text, find: #"(\d{4})-(\d\d)-(\d\d)"#, replace: "$3.$2.$1", options: options)
        #expect(VaultReplace.apply(found, to: text) == "26.10.2026 and 02.01.2025")
        // Anchors match at each line.
        let lines = try VaultReplace.matches(in: "a\nb", find: "^", replace: "- ", options: options)
        #expect(VaultReplace.apply(lines, to: "a\nb") == "- a\n- b")
        #expect(throws: VaultReplace.Failure.self) { try VaultReplace.matches(in: text, find: "(", replace: "", options: options) }
        #expect(try VaultReplace.matches(in: text, find: "", replace: "x", options: options).isEmpty)
    }

    @Test func codeIsSkippedWhenAsked() throws {
        let text = """
            word `word` word
            ```
            word
            ```
            > ~~~
            > word
            > ~~~
            word
            """
        let skipped = try VaultReplace.matches(in: text, find: "word", replace: "X", options: .init())
        #expect(skipped.map(\.line) == [0, 0, 7])
        #expect(VaultReplace.apply(skipped, to: text).hasPrefix("X `word` X\n```\nword"))
        #expect(try VaultReplace.matches(in: text, find: "word", replace: "X", options: .init(skipCode: false)).count == 6)
        // A block left open runs to the end.
        #expect(try VaultReplace.matches(in: "word\n```\nword", find: "word", replace: "X", options: .init()).count == 1)
    }

    @Test func onlyTheChosenMatchesAreReplaced() throws {
        let text = "one one one"
        let found = try VaultReplace.matches(in: text, find: "one", replace: "two", options: .init())
        #expect(VaultReplace.apply([found[1]], to: text) == "one two one")
        #expect(VaultReplace.apply([], to: text) == text)
        let pattern = try #require(try VaultReplace.Pattern(find: "one", replace: "two", options: .init()))
        #expect(try VaultReplace.replace(in: text, pattern: pattern, shown: found, chosen: [found[0].id, found[2].id]) == "two one two")
        // The note changed after the preview: refused.
        #expect(throws: VaultReplace.Failure.changed) {
            try VaultReplace.replace(in: "one one", pattern: pattern, shown: found, chosen: [found[0].id])
        }
    }

    @Test func aLongLineIsCutInThePreview() throws {
        let text = String(repeating: "a", count: 200) + " needle " + String(repeating: "b", count: 200) + "\nnext"
        let match = try #require(try VaultReplace.matches(in: text, find: "needle", replace: "pin", options: .init()).first)
        #expect(match.before.hasPrefix("…") && match.before.hasSuffix("…") && match.before.count < 140)
        #expect(match.after.contains(" pin "))
        let across = try VaultReplace.matches(in: "a\nb", find: #"a\nb"#, replace: "c", options: .init(regularExpression: true))
        #expect(across.first?.before == "a↵b")
    }
}
