import Foundation
import Testing

@testable import DaftarCore

@Suite struct MultiCursorTests {
    func r(_ location: Int, _ length: Int = 0) -> NSRange { NSRange(location: location, length: length) }

    @Test func normalizeSortsAndJoins() {
        #expect(MultiCursor.normalize([r(5), r(1), r(5)]) == [r(1), r(5)])
        #expect(MultiCursor.normalize([r(4, 3), r(2, 3)]) == [r(2, 5)])
        // A caret at the edge of a selection is its own cursor.
        #expect(MultiCursor.normalize([r(2, 3), r(5)]) == [r(2, 3), r(5)])
    }

    @Test func theWordAtTheCaret() {
        let text = "one two_2 سلام" as NSString
        #expect(MultiCursor.word(at: 5, in: text) == r(4, 5))
        #expect(MultiCursor.word(at: 4, in: text) == r(4, 5))
        #expect(MultiCursor.word(at: 3, in: text) == r(0, 3))
        #expect(MultiCursor.word(at: 11, in: text) == r(10, 4))
        #expect(MultiCursor.word(at: 1, in: "a  b" as NSString) == r(0, 1))
        #expect(MultiCursor.word(at: 2, in: "a  b" as NSString) == nil)
    }

    @Test func nextOccurrenceGoesOnAndWrapsAround() {
        let text = "cat catalog cat\ncat" as NSString
        // Whole words, as from a caret: `catalog` is not one.
        #expect(MultiCursor.occurrences(of: "cat", in: text, wholeWord: true) == [r(0, 3), r(12, 3), r(16, 3)])
        #expect(MultiCursor.occurrences(of: "cat", in: text, wholeWord: false).count == 4)
        #expect(MultiCursor.nextOccurrence(of: "cat", in: text, after: [r(12, 3)], wholeWord: true) == r(16, 3))
        #expect(MultiCursor.nextOccurrence(of: "cat", in: text, after: [r(12, 3), r(16, 3)], wholeWord: true) == r(0, 3))
        #expect(MultiCursor.nextOccurrence(of: "cat", in: text, after: [r(0, 3), r(12, 3), r(16, 3)], wholeWord: true) == nil)
        #expect(MultiCursor.nextOccurrence(of: "cat", in: text, after: [r(0, 3)], wholeWord: false) == r(4, 3))
    }

    @Test func typingReplacesEveryCursorAndMovesTheCarets() {
        let (edits, carets) = MultiCursor.replace([r(8), r(0, 3), r(4)], with: ["xy"])
        #expect(edits == [.init(range: r(0, 3), text: "xy"), .init(range: r(4), text: "xy"), .init(range: r(8), text: "xy")])
        #expect(carets == [r(2), r(5), r(11)])
        var text = "abc defghij"
        for edit in edits.reversed() { text = (text as NSString).replacingCharacters(in: edit.range, with: edit.text) }
        #expect(text == "xy xydefgxyhij")
        // One text for each cursor, as a paste of as many lines.
        #expect(MultiCursor.replace([r(0), r(1)], with: ["A", "B"]).carets == [r(1), r(3)])
    }

    @Test func backspaceTakesALetterAtEachCaret() {
        let text = "ab\ncd\nسلام👩‍👩‍👧" as NSString
        let gone = MultiCursor.deletions([r(0), r(2), r(5), r(text.length)], in: text, forward: false)
        // Nothing before the first caret; a family emoji goes whole.
        #expect(gone == [r(0), r(1, 1), r(4, 1), r(10, text.length - 10)])
        let (edits, carets) = MultiCursor.replace(gone, with: [""])
        #expect(edits.count == 3)
        #expect(carets == [r(0), r(1), r(3), r(8)])
        #expect(MultiCursor.deletions([r(1), r(2)], in: "abc" as NSString, forward: true) == [r(1, 1), r(2, 1)])
        // Two carets side by side take one letter each and meet.
        let side = MultiCursor.deletions([r(1), r(2)], in: "abc" as NSString, forward: false)
        #expect(side == [r(0, 1), r(1, 1)])
        #expect(MultiCursor.replace(side, with: [""]).carets == [r(0)])
    }

    @Test func aPasteOfAsManyLinesGivesALineToEach() {
        #expect(MultiCursor.pieces(of: "a\nb\nc", cursors: 3) == ["a", "b", "c"])
        #expect(MultiCursor.pieces(of: "a\nb\n", cursors: 2) == ["a", "b"])
        #expect(MultiCursor.pieces(of: "a\nb", cursors: 3) == ["a\nb"])
        #expect(MultiCursor.pieces(of: "a", cursors: 1) == ["a"])
    }

    @Test func aColumnTakesTheSameCharactersOnEachLine() {
        let text = "abcdef\nab\nabcdefgh\n\nxyz" as NSString
        // From column 1 on the first line to column 4 on the third.
        #expect(MultiCursor.column(in: text, from: 1, to: 14) == [r(1, 3), r(8, 1), r(11, 3)])
        // Upwards is the same.
        #expect(MultiCursor.column(in: text, from: 14, to: 1) == [r(1, 3), r(8, 1), r(11, 3)])
        // Straight down: a caret on each line, at its end when it is short.
        #expect(MultiCursor.column(in: text, from: 3, to: 23) == [r(3), r(9), r(13), r(19), r(23)])
        // Persian letters are one column each.
        let persian = "سلام\nدنیا" as NSString
        #expect(MultiCursor.column(in: persian, from: 1, to: 7) == [r(1, 1), r(6, 1)])
        #expect(MultiCursor.lines(in: "a\n" as NSString, from: 0, to: 2) == [r(0, 1), r(2)])
    }
}

@Suite struct SpellingTests {
    func checked(_ text: String) -> [(String, Spelling.Language)] {
        let ns = text as NSString
        return Spelling.parts(in: ns, range: NSRange(location: 0, length: ns.length)).map { (ns.substring(with: $0.range), $0.language) }
    }

    @Test func eachLineInItsOwnLanguage() {
        let parts = checked("Hello world\nسلام دنیا\nNotes about تهران\n")
        #expect(parts.map(\.0) == ["Hello world", "سلام دنیا", "Notes about تهران"])
        #expect(parts.map(\.1) == [.english, .persian, .english])
    }

    @Test func codeLinksTagsAndFrontMatterAreLeftOut() {
        let text = "---\ntags: [projct]\n---\nSee `teh code` and [[Notte|the labl]] at https://exmple.com #tagg\n```\nfoo brr\n```\n![[pictre.png]] $x^2$ end"
        let parts = checked(text).map(\.0)
        #expect(parts == ["See ", " and ", "the labl]] at ", " ", " ", " end"])
        // A wikilink without a label is all name.
        #expect(checked("go to [[Somewhere]] now").map(\.0) == ["go to ", " now"])
    }

    @Test func onlyWordsInALanguageWithADictionaryAreMarked() {
        let text = "Helo\nسلامم" as NSString
        let parts = Spelling.parts(in: text, range: NSRange(location: 0, length: text.length))
        let english = Spelling.dictionaries(["en_GB", "de", "ar"])
        #expect(english == ["en"])
        #expect(Spelling.marks(NSRange(location: 0, length: 4), in: parts, dictionaries: english))
        // No Persian dictionary: the Persian line is not marked at all.
        #expect(!Spelling.marks(NSRange(location: 5, length: 5), in: parts, dictionaries: english))
        #expect(Spelling.marks(NSRange(location: 5, length: 5), in: parts, dictionaries: ["en", "fa"]))
        // Across a part's end: no.
        #expect(!Spelling.marks(NSRange(location: 2, length: 5), in: parts, dictionaries: english))
    }

    @Test func focusTakesTheParagraphBetweenEmptyLines() {
        let text = "one\ntwo\n\nthree\nfour\n\n\nfive" as NSString
        #expect(text.substring(with: FocusParagraph.range(at: 5, in: text)) == "one\ntwo\n")
        #expect(text.substring(with: FocusParagraph.range(at: 12, in: text)) == "three\nfour\n")
        #expect(text.substring(with: FocusParagraph.range(at: 8, in: text)) == "\n")
        #expect(text.substring(with: FocusParagraph.range(at: text.length, in: text)) == "five")
        #expect(FocusParagraph.range(at: 0, in: "" as NSString) == NSRange(location: 0, length: 0))
    }
}
