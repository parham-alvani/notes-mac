import Foundation

/// Find and replace in the text of a note, for "Replace in Vault": the
/// matches with their lines and a preview, and the text with a chosen part
/// of them replaced. A pattern is plain text, or a regular expression whose
/// replacement can name its groups as `$1`. Code blocks and inline code can
/// be left out, as `TagRename` leaves them.
public enum VaultReplace {
    public struct Options: Sendable, Hashable {
        public var matchCase = false
        public var wholeWord = false
        public var regularExpression = false
        /// Leave fenced code blocks and inline code as they are.
        public var skipCode = true

        public init(matchCase: Bool = false, wholeWord: Bool = false, regularExpression: Bool = false, skipCode: Bool = true) {
            self.matchCase = matchCase
            self.wholeWord = wholeWord
            self.regularExpression = regularExpression
            self.skipCode = skipCode
        }
    }

    public enum Failure: Error, Equatable, LocalizedError {
        /// The regular expression does not compile; the system's message.
        case badPattern(String)
        /// The note's matches are not the ones the preview showed.
        case changed

        public var errorDescription: String? {
            switch self {
            case let .badPattern(message): "The regular expression is not valid: \(message)"
            case .changed: "The note changed after the preview."
            }
        }
    }

    /// One match in a text. The range is in UTF-16 units of the whole text.
    public struct Match: Sendable, Hashable, Identifiable {
        public var location: Int
        public var length: Int
        /// The match's first line, from 0.
        public var line: Int
        public var found: String
        public var replacement: String
        /// The rest of the line before and after the match, cut short when long.
        public var prefix: String
        public var suffix: String
        public var id: Int { location }
        /// The match's line as it is, and as it will be; a line break shows as ↵.
        public var before: String { prefix + VaultReplace.flat(found) + suffix }
        public var after: String { prefix + VaultReplace.flat(replacement) + suffix }
    }

    /// A find pattern and its replacement, compiled once for many notes.
    public struct Pattern: @unchecked Sendable {
        let regex: NSRegularExpression
        let template: String
        let skipCode: Bool

        /// Nil for an empty find text; throws for a regular expression that does not compile.
        public init?(find: String, replace: String, options: Options) throws {
            guard !find.isEmpty else { return nil }
            var pattern = options.regularExpression ? find : NSRegularExpression.escapedPattern(for: find)
            // A word is letters, digits and `_` in every script; ICU's \b would split at Persian joiners.
            if options.wholeWord { pattern = "(?<![\\p{L}\\p{N}_])(?:\(pattern))(?![\\p{L}\\p{N}_])" }
            var flags: NSRegularExpression.Options = [.anchorsMatchLines]
            if !options.matchCase { flags.insert(.caseInsensitive) }
            do {
                regex = try NSRegularExpression(pattern: pattern, options: flags)
            } catch {
                throw Failure.badPattern(error.localizedDescription)
            }
            template = options.regularExpression ? replace : NSRegularExpression.escapedTemplate(for: replace)
            skipCode = options.skipCode
        }
    }

    /// The matches of [find] in [text], in order.
    public static func matches(in text: String, find: String, replace: String, options: Options) throws -> [Match] {
        guard let pattern = try Pattern(find: find, replace: replace, options: options) else { return [] }
        return matches(in: text, pattern: pattern)
    }

    public static func matches(in text: String, pattern: Pattern) -> [Match] {
        let string = text as NSString
        let code = pattern.skipCode ? codeRanges(in: text) : []
        var starts = [0]
        for (offset, unit) in text.utf16.enumerated() where unit == 0x0A { starts.append(offset + 1) }
        func line(of location: Int) -> Int {
            var low = 0, high = starts.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if starts[middle] <= location { low = middle } else { high = middle - 1 }
            }
            return low
        }
        func lineEnd(_ index: Int) -> Int {
            index + 1 < starts.count ? starts[index + 1] - 1 : string.length
        }

        var out: [Match] = []
        for result in pattern.regex.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            let range = result.range
            guard range.location != NSNotFound else { continue }
            if code.contains(where: { NSIntersectionRange($0, range).length > 0 || ($0.contains(range.location) && range.length == 0) }) { continue }
            let first = line(of: range.location)
            let last = line(of: range.location + range.length)
            let prefix = string.substring(with: NSRange(location: starts[first], length: range.location - starts[first]))
            let suffixStart = range.location + range.length
            let suffix = string.substring(with: NSRange(location: suffixStart, length: max(0, lineEnd(last) - suffixStart)))
            let found = string.substring(with: range)
            let replacement = pattern.regex.replacementString(for: result, in: text, offset: 0, template: pattern.template)
            let head = shortened(prefix, keepingEnd: true), tail = shortened(suffix, keepingEnd: false)
            out.append(Match(location: range.location, length: range.length, line: first, found: found, replacement: replacement,
                prefix: flat(head), suffix: flat(tail)))
        }
        return out
    }

    /// [text] with the [chosen] matches replaced. A match whose range is
    /// not in the text, or overlaps one before it, is left out.
    public static func apply(_ chosen: [Match], to text: String) -> String {
        let string = NSMutableString(string: text)
        var end = Int.max
        for match in chosen.sorted(by: { $0.location > $1.location }) {
            guard match.location >= 0, match.length >= 0, match.location + match.length <= min(end, string.length) else { continue }
            string.replaceCharacters(in: NSRange(location: match.location, length: match.length), with: match.replacement)
            end = match.location
        }
        return string as String
    }

    /// The text of a note read again before a write: its matches must be
    /// the [shown] ones, or the note is refused; then the [chosen] ids are replaced.
    public static func replace(in text: String, pattern: Pattern, shown: [Match], chosen: Set<Int>) throws -> String {
        let now = matches(in: text, pattern: pattern)
        guard now == shown else { throw Failure.changed }
        return apply(now.filter { chosen.contains($0.id) }, to: text)
    }

    nonisolated(unsafe) private static let inlineCode = /`[^`\n]*`/

    /// Fenced code blocks, with their fence lines, and inline code spans.
    static func codeRanges(in text: String) -> [NSRange] {
        var out: [NSRange] = []
        var offset = 0
        var fenceMarker: String?
        var blockStart = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let length = line.utf16.count
            if let match = line.prefixMatch(of: TagRename.fence) {
                let marker = String(match.1)
                if fenceMarker == nil {
                    fenceMarker = marker
                    blockStart = offset
                } else if let open = fenceMarker, marker.first == open.first, marker.count >= open.count {
                    fenceMarker = nil
                    out.append(NSRange(location: blockStart, length: offset + length - blockStart))
                }
            } else if fenceMarker == nil, line.contains("`") {
                for span in line.matches(of: inlineCode) {
                    let start = line.utf16.distance(from: line.startIndex, to: span.range.lowerBound)
                    out.append(NSRange(location: offset + start, length: span.output.utf16.count))
                }
            }
            offset += length + 1
        }
        // A block left open runs to the end of the note, as Obsidian shows it.
        if fenceMarker != nil { out.append(NSRange(location: blockStart, length: max(0, offset - 1 - blockStart))) }
        return out
    }

    /// A preview is one line: a line break in it shows as ↵.
    static func flat(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "↵")
    }

    private static func shortened(_ text: String, keepingEnd: Bool) -> String {
        let limit = 60
        let clean = text
        guard clean.count > limit else { return clean }
        return keepingEnd ? "…" + clean.suffix(limit) : clean.prefix(limit) + "…"
    }
}
