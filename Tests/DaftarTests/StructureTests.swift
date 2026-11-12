import Foundation
import Testing

@testable import DaftarUI

/// `structure(of:)` searches for its marks; it must find what reading every
/// line finds.
@MainActor
@Suite struct StructureTests {
    /// Every line, one after the other: the reading the searches must match.
    static func lineByLine(_ text: NSString) -> [String] {
        let length = text.length
        var marks: [(Int, String)] = []
        for needle in ["$$", "%%"] {
            var from = 0
            while from < length {
                let found = text.range(of: needle, options: .literal, range: NSRange(location: from, length: length - from))
                guard found.location != NSNotFound else { break }
                let line = text.lineRange(for: found)
                marks.append((line.location, text.substring(with: line)))
                from = NSMaxRange(line)
            }
        }
        var start = 0
        while start < length {
            var end = 0, contents = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contents, for: NSRange(location: start, length: 0))
            var at = start
            while at < contents, [32, 9, 62].contains(text.character(at: at)) { at += 1 }
            if at < contents {
                let first = text.character(at: at)
                if first == 96 || first == 126 || first == 45 {
                    let rest = text.substring(with: NSRange(location: at, length: contents - at))
                    if rest.hasPrefix("```") || rest.hasPrefix("~~~") {
                        marks.append((start, rest))
                    } else if rest.hasPrefix("---"), rest.allSatisfy({ $0 == "-" || $0 == " " }) {
                        marks.append((start, "---"))
                    }
                }
            }
            start = end
        }
        return marks.sorted { $0.0 < $1.0 }.map(\.1)
    }

    static let pieces = [
        "---", "----", "- - -", "--- x", "  ---", "> ---", "```", "````js", "~~~", "~~~ ```", "``` ~~~", "a ```",
        "> > ```", "\t~~~", "$$", "x $$ y", "%%", "%% ``` %%", "plain", "", "- item", "-- not", "```---", "with cr\r",
    ]

    @Test func theSearchesFindWhatEveryLineSays() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<3000 {
            let count = Int.random(in: 0...12, using: &generator)
            let lines = (0..<count).map { _ in Self.pieces.randomElement(using: &generator)! }
            let text = lines.joined(separator: "\n") + (Bool.random(using: &generator) ? "\n" : "") as NSString
            #expect(EditorController.structure(of: text) == Self.lineByLine(text), "\((text as String).debugDescription)")
        }
    }

    /// The marks an edit keeps and finds again are those of the whole text
    /// after it, whatever the edit: a line break typed or taken (`\r\n` too),
    /// a mark split or joined, text at either end.
    @Test func theMarksOfAnEditAreThoseOfTheWholeText() {
        var generator = SystemRandomNumberGenerator()
        let typed = ["\n", "\r", "\r\n", "`", "``", "$", "%", "-", " ", ">", "x", "~", "```js\n", "$$\n", "---\n"]
        for _ in 0..<3000 {
            let count = Int.random(in: 0...10, using: &generator)
            let text = NSMutableString(string: (0..<count).map { _ in Self.pieces.randomElement(using: &generator)! }.joined(separator: "\n"))
            var marks = EditorController.marks(of: text, in: NSRange(location: 0, length: text.length))
            for _ in 0..<4 {
                let at = Int.random(in: 0...text.length, using: &generator)
                let gone = Int.random(in: 0...min(3, text.length - at), using: &generator)
                let added = Bool.random(using: &generator) ? typed.randomElement(using: &generator)! : ""
                let before = text.copy() as! String
                text.replaceCharacters(in: NSRange(location: at, length: gone), with: added)
                let edited = NSRange(location: at, length: (added as NSString).length)
                marks = EditorController.marks(after: edited, delta: (added as NSString).length - gone, in: text, from: marks)
                let whole = EditorController.marks(of: text, in: NSRange(location: 0, length: text.length))
                #expect(marks == whole, "\(before.debugDescription) -> \((text as String).debugDescription)")
                if marks != whole { return }
            }
        }
    }
}
