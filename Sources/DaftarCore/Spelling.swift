import Foundation

/// What the editor's spelling looks at, and in which language: each line
/// in the language of its first strong letter, as its direction is decided,
/// and none of the parts that are not prose.
public enum Spelling {
    public enum Language: String, Sendable {
        case english = "en"
        case persian = "fa"
    }

    /// A stretch of one line to check in [language].
    public struct Part: Equatable, Sendable {
        public var range: NSRange
        public var language: Language
        public init(range: NSRange, language: Language) {
            self.range = range
            self.language = language
        }
    }

    /// Code, a code block and its fences, the front matter, web addresses,
    /// a wikilink's target, an embed, tags, math and block ids.
    static func isSkipped(_ kind: MarkdownHighlighter.Kind) -> Bool {
        switch kind {
        case .code, .codeBlock, .fence, .frontMatter, .url, .embed, .tag, .math, .blockId, .metadata: true
        default: false
        }
    }

    /// The parts of the lines that [range] touches that spelling checks.
    public static func parts(in text: NSString, range: NSRange) -> [Part] {
        guard text.length > 0 else { return [] }
        let location = min(max(0, range.location), text.length)
        let lines = text.lineRange(for: NSRange(location: location, length: min(max(0, range.length), text.length - location)))
        var skipped: [NSRange] = []
        for span in MarkdownHighlighter.spans(in: text, range: lines) {
            if isSkipped(span.kind) {
                skipped.append(span.range)
            } else if span.kind == .link, span.range.length >= 4, text.substring(with: NSRange(location: span.range.location, length: 2)) == "[[" {
                // `[[target|label]]`: the label is prose, the target a name.
                let inner = NSRange(location: span.range.location + 2, length: span.range.length - 4)
                let bar = text.range(of: "|", options: .literal, range: inner)
                skipped.append(bar.location == NSNotFound ? span.range : NSRange(location: span.range.location, length: NSMaxRange(bar) - span.range.location))
            }
        }
        skipped.sort { $0.location < $1.location }
        var out: [Part] = []
        var start = lines.location
        while start < NSMaxRange(lines) {
            var end = 0, contents = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contents, for: NSRange(location: start, length: 0))
            let line = NSRange(location: start, length: contents - start)
            let language: Language = TextDirection.startsRtl(text.substring(with: line)) ? .persian : .english
            var from = line.location
            for skip in skipped where NSIntersectionRange(skip, line).length > 0 {
                if skip.location > from { out.append(Part(range: NSRange(location: from, length: skip.location - from), language: language)) }
                from = max(from, NSMaxRange(skip))
            }
            if NSMaxRange(line) > from { out.append(Part(range: NSRange(location: from, length: NSMaxRange(line) - from), language: language)) }
            guard end > start else { break }
            start = end
        }
        return out
    }

    /// True when a word at [range] may be marked: it lies in one part, in a
    /// language the Mac has a dictionary for.
    public static func marks(_ range: NSRange, in parts: [Part], dictionaries: Set<String>) -> Bool {
        parts.contains { part in
            NSIntersectionRange(part.range, range) == range && range.length > 0 && dictionaries.contains(part.language.rawValue)
        }
    }

    /// The dictionaries among the spell checker's languages, as `en` and `fa`:
    /// `en_GB` counts as English.
    public static func dictionaries(_ available: [String]) -> Set<String> {
        Set(available.map { String($0.split(separator: "_").first ?? "") }.filter { $0 == "en" || $0 == "fa" })
    }
}

/// Focus mode: the paragraph the cursor is in, the lines between two empty
/// lines, stays bright and the rest dims.
public enum FocusParagraph {
    public static func range(at location: Int, in text: NSString) -> NSRange {
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }
        let at = min(max(0, location), text.length)
        func blank(_ line: NSRange) -> Bool {
            text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let here = text.lineRange(for: NSRange(location: at, length: 0))
        // On an empty line, that line is the paragraph.
        if blank(here) { return here }
        var start = here.location
        while start > 0 {
            let above = text.lineRange(for: NSRange(location: start - 1, length: 0))
            guard !blank(above) else { break }
            start = above.location
        }
        var end = NSMaxRange(here)
        while end < text.length {
            let below = text.lineRange(for: NSRange(location: end, length: 0))
            guard !blank(below) else { break }
            end = NSMaxRange(below)
        }
        return NSRange(location: start, length: end - start)
    }
}
