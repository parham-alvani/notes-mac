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

/// `BlockStates` keeps the states of lines styled, goes on from the nearest
/// one, and forgets those after an edit: what it says is what a search from
/// the top says, through random edits.
@Suite struct BlockStatesTests {
    @Test func theCacheReadsAsTheSearchDoes() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<400 {
            let count = Int.random(in: 1...20, using: &generator)
            let text = NSMutableString(string: (0..<count).map { _ in BlockStateTests.pieces.randomElement(using: &generator)! }.joined(separator: "\n"))
            var states = MarkdownHighlighter.BlockStates()
            for _ in 0..<30 {
                // Ask at a few line starts, as styling does.
                for _ in 0..<3 {
                    let at = text.length == 0 ? 0 : text.lineRange(for: NSRange(location: Int.random(in: 0..<text.length, using: &generator), length: 0)).location
                    #expect(states.state(before: at, in: text) == MarkdownHighlighter.blockState(before: at, in: text), "\((text as String).debugDescription) at \(at)")
                }
                // An edit: a piece put in, or a stretch taken out.
                let location = Int.random(in: 0...text.length, using: &generator)
                let length = Int.random(in: 0...min(6, text.length - location), using: &generator)
                let piece = Bool.random(using: &generator) ? "" : ["\n", "```", "%%", "$$", "x", "\n---\n", "~~~\n"].randomElement(using: &generator)!
                text.replaceCharacters(in: NSRange(location: location, length: length), with: piece)
                states.edited(at: location)
            }
        }
    }

    /// Going on from a known line gives what the search from the top gives.
    @Test func theSearchGoesOnFromALineKnown() {
        let text = "intro\n```swift\nlet a\n```\n%% hidden\nstill %%\nafter\n" as NSString
        for line in ["let a", "```\n%%", "still", "after"] {
            let at = text.range(of: line).location
            let known = text.range(of: "```swift").location
            let from = (known, MarkdownHighlighter.blockState(before: known, in: text))
            #expect(MarkdownHighlighter.blockState(before: at, in: text, from: from) == MarkdownHighlighter.blockState(before: at, in: text))
        }
    }
}
