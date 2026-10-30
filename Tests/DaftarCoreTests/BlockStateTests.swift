import Foundation
import Testing

@testable import DaftarCore

/// `blockState` jumps from mark to mark; it must say what reading every line
/// says, at every line.
@Suite struct BlockStateTests {
    /// Every line, one after the other: the reading the jump must match.
    static func lineByLine(before location: Int, in text: NSString) -> MarkdownHighlighter.BlockState {
        var state = MarkdownHighlighter.BlockState.normal
        var start = 0
        var first = true
        while start < location, start < text.length {
            let lineRange = text.lineRange(for: NSRange(location: start, length: 0))
            let line = text.substring(with: lineRange).trimmingCharacters(in: .newlines)
            state = MarkdownHighlighter.next(after: line, from: state, firstLine: first)
            first = false
            start = NSMaxRange(lineRange)
        }
        return state
    }

    static let pieces = [
        "---", "title: x", "...", "```swift", "```", "````", "~~~", "~~~~ x", "> ```", "  ```",
        "$$", "$$ x $$", "x $$", "%%", "a %% b", "a %% b %% c", "plain", "", "# Heading", "- [ ] task",
        "    code", "text ``` inline", "\\r", "---", "سلام %%",
    ]

    @Test func theJumpReadsAsEveryLineDoes() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<3000 {
            let count = Int.random(in: 0...14, using: &generator)
            var lines = (0..<count).map { _ in Self.pieces.randomElement(using: &generator)! }
            lines = lines.map { $0 == "\\r" ? "with cr\r" : $0 }
            let text = lines.joined(separator: "\n") + (Bool.random(using: &generator) ? "\n" : "") as NSString
            var start = 0
            while true {
                #expect(
                    MarkdownHighlighter.blockState(before: start, in: text) == Self.lineByLine(before: start, in: text),
                    "\((text as String).debugDescription) at \(start)")
                guard start < text.length else { break }
                start = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0)))
            }
            // A location inside a line, as `spans` never asks but may.
            if text.length > 2 {
                let middle = text.length / 2
                #expect(MarkdownHighlighter.blockState(before: middle, in: text) == Self.lineByLine(before: middle, in: text))
            }
        }
    }
}
