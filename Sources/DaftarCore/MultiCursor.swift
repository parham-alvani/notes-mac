import Foundation

/// The editor's many cursors: a list of ranges in UTF-16 offsets, each a
/// caret (length 0) or a selection. Pure functions of the text, so the view
/// only applies what they give and these are tested.
public enum MultiCursor {
    /// One replacement: [range] of the text before any edit becomes [text].
    public struct Edit: Equatable, Sendable {
        public var range: NSRange
        public var text: String
        public init(range: NSRange, text: String) {
            self.range = range
            self.text = text
        }
    }

    /// Sorted, and the ranges that overlap made one. Two carets at one place
    /// are one; a caret at the edge of a selection stays apart from it.
    public static func normalize(_ ranges: [NSRange]) -> [NSRange] {
        var out: [NSRange] = []
        for range in ranges.sorted(by: { ($0.location, $0.length) < ($1.location, $1.length) }) {
            guard let last = out.last else {
                out.append(range)
                continue
            }
            let overlaps = range.location < NSMaxRange(last) || (range == last)
                || (range.length == 0 && last.length == 0 && range.location == last.location)
            if overlaps {
                out[out.count - 1] = NSRange(location: last.location, length: max(NSMaxRange(last), NSMaxRange(range)) - last.location)
            } else {
                out.append(range)
            }
        }
        return out
    }

    private static func isWordCharacter(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar == "_" || CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar)
    }

    /// The word the caret at [location] is in or next to, or nil between spaces.
    public static func word(at location: Int, in text: NSString) -> NSRange? {
        guard text.length > 0 else { return nil }
        let at = min(max(0, location), text.length)
        var start = at, end = at
        while start > 0, isWordCharacter(text.character(at: start - 1)) { start -= 1 }
        while end < text.length, isWordCharacter(text.character(at: end)) { end += 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    /// Every place [needle] is in [text], in order and apart. With
    /// [wholeWord], only where no letter touches it on either side.
    public static func occurrences(of needle: String, in text: NSString, wholeWord: Bool) -> [NSRange] {
        let length = (needle as NSString).length
        guard length > 0 else { return [] }
        var out: [NSRange] = []
        var from = 0
        while from < text.length {
            let found = text.range(of: needle, options: .literal, range: NSRange(location: from, length: text.length - from))
            guard found.location != NSNotFound else { break }
            let free = !wholeWord
                || ((found.location == 0 || !isWordCharacter(text.character(at: found.location - 1)))
                    && (NSMaxRange(found) == text.length || !isWordCharacter(text.character(at: NSMaxRange(found)))))
            if free { out.append(found) }
            from = free ? NSMaxRange(found) : found.location + 1
        }
        return out
    }

    /// ⌥⌘E: the next place [needle] is after the last of [ranges], from the
    /// top again past the end, that is not one of them already; nil when
    /// every place is.
    public static func nextOccurrence(of needle: String, in text: NSString, after ranges: [NSRange], wholeWord: Bool) -> NSRange? {
        let all = occurrences(of: needle, in: text, wholeWord: wholeWord)
        let taken = Set(ranges.map { [$0.location, $0.length] })
        let last = ranges.map(NSMaxRange).max() ?? 0
        let free = all.filter { found in !taken.contains([found.location, found.length]) && !ranges.contains { NSIntersectionRange($0, found).length > 0 } }
        return free.first { $0.location >= last } ?? free.first
    }

    /// Each range replaced by its text (one text for all, or one for each),
    /// as the edits to make and the carets after: each at the end of what
    /// went in. The edits are in order, and none of them changes nothing.
    public static func replace(_ ranges: [NSRange], with texts: [String]) -> (edits: [Edit], carets: [NSRange]) {
        let sorted = normalize(ranges)
        var edits: [Edit] = []
        var carets: [NSRange] = []
        var shift = 0
        for (index, range) in sorted.enumerated() {
            let text = texts.count == sorted.count ? texts[index] : texts.first ?? ""
            let width = (text as NSString).length
            carets.append(NSRange(location: range.location + shift + width, length: 0))
            if range.length > 0 || width > 0 { edits.append(Edit(range: range, text: text)) }
            shift += width - range.length
        }
        return (edits, normalize(carets))
    }

    /// What Backspace (or Delete, [forward]) takes at each cursor: a
    /// selection, or the letter before (after) a caret, a whole composed
    /// character. A caret at the start (end) of the text takes nothing.
    public static func deletions(_ ranges: [NSRange], in text: NSString, forward: Bool) -> [NSRange] {
        normalize(ranges.map { range in
            guard range.length == 0 else { return range }
            if forward {
                guard range.location < text.length else { return range }
                return text.rangeOfComposedCharacterSequence(at: range.location)
            }
            guard range.location > 0 else { return range }
            return text.rangeOfComposedCharacterSequence(at: range.location - 1)
        })
    }

    /// A paste with many cursors: one line of [pasted] for each cursor when
    /// it has as many lines as there are cursors, else all of it at each.
    public static func pieces(of pasted: String, cursors: Int) -> [String] {
        var lines = pasted.components(separatedBy: "\n")
        if lines.count == cursors + 1, lines.last == "" { lines.removeLast() }
        return cursors > 1 && lines.count == cursors ? lines : [pasted]
    }

    /// The lines from [anchor]'s to [head]'s, each without its line break.
    public static func lines(in text: NSString, from anchor: Int, to head: Int) -> [NSRange] {
        let low = min(max(0, min(anchor, head)), text.length)
        let high = min(max(0, max(anchor, head)), text.length)
        let last = text.lineRange(for: NSRange(location: high, length: 0)).location
        var out: [NSRange] = []
        var start = text.lineRange(for: NSRange(location: low, length: 0)).location
        while true {
            var end = 0, contents = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contents, for: NSRange(location: start, length: 0))
            out.append(NSRange(location: start, length: contents - start))
            guard start < last, end > start else { break }
            start = end
        }
        return out
    }

    /// The column, in characters, of [offset] on its line.
    public static func column(of offset: Int, in text: NSString) -> Int {
        let at = min(max(0, offset), text.length)
        let line = text.lineRange(for: NSRange(location: at, length: 0))
        var column = 0, index = line.location
        while index < at {
            index = NSMaxRange(text.rangeOfComposedCharacterSequence(at: index))
            column += 1
        }
        return column
    }

    /// The offset of [column] characters into [line], or the end of the line's text.
    public static func offset(ofColumn column: Int, in line: NSRange, of text: NSString) -> Int {
        var index = line.location, left = column
        while left > 0, index < NSMaxRange(line) {
            index = min(NSMaxRange(text.rangeOfComposedCharacterSequence(at: index)), NSMaxRange(line))
            left -= 1
        }
        return index
    }

    /// ⌥-drag from [anchor] to [head]: on each line between them, the
    /// characters between the two columns. A line too short for the left
    /// column gets a caret at its end; a drag straight down gives a caret on
    /// each line, so typing goes into every one of them.
    public static func column(in text: NSString, from anchor: Int, to head: Int) -> [NSRange] {
        let a = column(of: anchor, in: text), b = column(of: head, in: text)
        let left = min(a, b), right = max(a, b)
        return lines(in: text, from: anchor, to: head).map { line in
            let start = offset(ofColumn: left, in: line, of: text)
            let end = offset(ofColumn: right, in: line, of: text)
            return NSRange(location: start, length: end - start)
        }
    }
}
