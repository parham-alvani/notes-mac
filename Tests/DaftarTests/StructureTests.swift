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
}
