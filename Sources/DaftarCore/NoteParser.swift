import Foundation

/// What the index keeps of one note. Everything here comes from one pass over
/// its lines; the reading view renders the note itself, in the web view.
public struct ParsedNote: Sendable, Equatable {
    public var properties: [(key: String, values: [String])]
    public var aliases: [String]
    public var tags: [String]
    public var headings: [Heading]
    public var links: [Link]
    public var tasks: [ParsedTask]
    /// The text without front matter, comments and markup, for search.
    public var plain: String
    public var rtl: Bool

    public static func == (a: ParsedNote, b: ParsedNote) -> Bool {
        a.aliases == b.aliases && a.tags == b.tags && a.headings == b.headings && a.links == b.links
            && a.tasks == b.tasks && a.plain == b.plain && a.rtl == b.rtl
            && a.properties.map(\.key) == b.properties.map(\.key) && a.properties.map(\.values) == b.properties.map(\.values)
    }
}

public struct Heading: Sendable, Equatable, Hashable {
    public var level: Int
    public var text: String
    /// Zero-based line in the file.
    public var line: Int
}

public struct Link: Sendable, Equatable, Hashable {
    /// As written, before `#` and `|`.
    public var target: String
    public var anchor: String?
    public var embed: Bool
    public var line: Int
}

public struct ParsedTask: Sendable, Equatable, Hashable {
    public var line: Int
    public var status: Character
    /// The sentence, without the Tasks plugin's trailing emoji and without
    /// its `[reason:: …]` field.
    public var text: String
    /// Why it was cancelled or is waiting: the `[reason:: …]` field.
    public var reason: String?
    /// The nearest heading above it, which in this vault is the project.
    public var section: String
    public var created: String?
    public var scheduled: String?
    public var due: String?
    public var start: String?
    public var done: String?
    public var cancelled: String?
    public var recurring: String?
    public var priority: String?
    /// Indented under another item.
    public var nested: Bool

    /// Still to do: open or in progress, by the vault's statuses.
    public var isOpen: Bool { isOpen(in: .current) }

    public func isOpen(in statuses: TaskStatuses) -> Bool { !statuses.isClosed(status) }

    /// The day the task belongs to: due, else scheduled.
    public var day: String? { due ?? scheduled }
}

public enum NoteParser {
    nonisolated(unsafe) private static let headingLine = /^(#{1,6})[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$/

    /// The level and the text of a `#` heading line, or nil. A closing run
    /// of `#` comes off only after a space, as CommonMark has it: `## C#`
    /// is the heading "C#", `## Title ##` is "Title", and `## ##` has no text.
    static func heading(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#"), let match = line.firstMatch(of: headingLine) else { return nil }
        let text = match.2.allSatisfy { $0 == "#" } ? "" : String(match.2)
        return (match.1.count, text)
    }
    nonisolated(unsafe) private static let wikilink = /(!?)\[\[([^\]\n]+?)\]\]/
    nonisolated(unsafe) private static let markdownLink = /(!?)\[[^\]\n]*\]\(<?([^)>\s]+)>?\)/
    nonisolated(unsafe) private static let tag = /(?:^|\s)#([\p{L}\p{N}_\/-]+)/
    nonisolated(unsafe) static let fence = /^\s*(?:>\s*)*(```+|~~~+)/

    /// The marks of a code fence that [line] opens or closes, or nil. A
    /// line of backticks with a backtick after them is not one: the info
    /// string of a backtick fence holds none, so ```` ```a``` b ```` is a
    /// paragraph that starts with inline code (CommonMark).
    static func fenceMark(_ line: String) -> Substring? {
        guard line.hasMark("```") || line.hasMark("~~~"), let match = line.firstMatch(of: fence) else { return nil }
        if match.1.first == "`", line[match.range.upperBound...].utf8.contains(0x60) { return nil }
        return match.1
    }

    public static func parse(_ text: String) -> ParsedNote {
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        let front = FrontMatter.parse(lines)
        var note = ParsedNote(
            properties: front.properties, aliases: front.values("aliases") + front.values("alias"),
            tags: front.values("tags") + front.values("tag"), headings: [], links: [], tasks: [], plain: "", rtl: false)
        note.tags = note.tags.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }

        // A link in a property, `up: "[[Parent]]"`, is a link as Obsidian counts them.
        for index in 1..<max(1, front.lineCount - 1) where lines[index].hasMark("[[") {
            for match in lines[index].matches(of: wikilink) {
                let parts = Wikilink(String(match.2))
                note.links.append(Link(target: parts.target, anchor: parts.anchor, embed: !match.1.isEmpty, line: index))
            }
        }

        var plain: [String] = []
        var fenceMarker: String?
        var inComment = false
        var section = ""
        for index in front.lineCount..<lines.count {
            let raw = lines[index]
            // Each pattern runs only on a line that has the marks it needs:
            // a regular expression on every line was most of the time a
            // large vault took to open.
            if let mark = fenceMark(raw) {
                let marker = String(mark)
                if fenceMarker == nil {
                    fenceMarker = marker
                } else if let open = fenceMarker, marker.first == open.first, marker.count >= open.count {
                    fenceMarker = nil
                }
                continue
            }
            if fenceMarker != nil {
                plain.append(raw)
                continue
            }
            let line = Comments.strip(raw, open: &inComment)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            if let (level, text) = heading(line) {
                note.headings.append(Heading(level: level, text: text, line: index))
                section = text
            }
            let code = InlineCode.removed(from: line)
            for match in code.hasMark("[[") ? code.matches(of: wikilink) : [] {
                let parts = Wikilink(String(match.2))
                note.links.append(Link(target: parts.target, anchor: parts.anchor, embed: !match.1.isEmpty, line: index))
            }
            for match in code.hasMark("](") ? code.matches(of: markdownLink) : [] {
                let url = String(match.2)
                guard !url.contains("://"), !url.hasPrefix("mailto:"), !url.hasPrefix("#") else { continue }
                let decoded = url.removingPercentEncoding ?? url
                let hash = decoded.firstIndex(of: "#")
                let target = hash.map { String(decoded[..<$0]) } ?? decoded
                let anchor = hash.map { String(decoded[decoded.index(after: $0)...]) }
                note.links.append(Link(target: target, anchor: anchor, embed: !match.1.isEmpty, line: index))
            }
            for match in code.mayHoldTag ? code.matches(of: tag) : [] where !match.1.allSatisfy({ $0.isNumber || $0 == "/" || $0 == "-" }) {
                note.tags.append(String(match.1))
            }
            if let task = TaskLine.parse(line, line: index, section: section) {
                note.tasks.append(task)
            }
            plain.append(line)
        }
        note.plain = plain.joined(separator: "\n")
        note.rtl = TextDirection.containsRtl(note.plain)
        var seen = Set<String>()
        note.tags = note.tags.filter { !$0.isEmpty && seen.insert(Slugs.fold($0)).inserted }
        return note
    }
}

extension StringProtocol {
    /// Whether the text's UTF-8 holds [mark], a few ASCII characters: the
    /// quick test before a pattern that needs them. Foundation's `contains`
    /// took as long as some of the patterns it was there to spare.
    func hasMark(_ mark: StaticString) -> Bool {
        let needle = UnsafeBufferPointer(start: mark.utf8Start, count: mark.utf8CodeUnitCount)
        func search(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
            guard bytes.count >= needle.count, let first = needle.first else { return needle.isEmpty }
            var at = 0
            while at <= bytes.count - needle.count {
                if bytes[at] == first {
                    var same = true
                    for offset in 1..<needle.count where bytes[at + offset] != needle[offset] {
                        same = false
                        break
                    }
                    if same { return true }
                }
                at += 1
            }
            return false
        }
        return utf8.withContiguousStorageIfAvailable(search) ?? Array(utf8).withUnsafeBufferPointer(search)
    }

    /// Whether a `#` here is followed by something a tag can start with:
    /// not a space, a tab, another `#` or the end. A heading's marks are not.
    var mayHoldTag: Bool {
        func search(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
            var at = 0
            while at + 1 < bytes.count {
                if bytes[at] == UInt8(ascii: "#"), ![UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "#")].contains(bytes[at + 1]) {
                    return true
                }
                at += 1
            }
            return false
        }
        return utf8.withContiguousStorageIfAvailable(search) ?? Array(utf8).withUnsafeBufferPointer(search)
    }
}

/// `target#heading|alias` in its three parts.
public struct Wikilink: Sendable, Equatable {
    public var target: String
    public var anchor: String?
    public var alias: String?
    /// The bar was written `\|`, as it must be inside a table.
    var escaped = false

    public init(_ inner: String) {
        let bar = inner.firstIndex(of: "|")
        var ref = bar.map { String(inner[..<$0]) } ?? inner
        if bar != nil, ref.hasSuffix("\\") {
            ref.removeLast()
            escaped = true
        }
        alias = bar.map { String(inner[inner.index(after: $0)...]) }
        if let hash = ref.firstIndex(of: "#") {
            target = String(ref[..<hash]).trimmingCharacters(in: .whitespaces)
            anchor = String(ref[ref.index(after: hash)...]).trimmingCharacters(in: .whitespaces)
        } else {
            target = ref.trimmingCharacters(in: .whitespaces)
            anchor = nil
        }
    }
}

/// Inline code and inline math: the text a reader shows as written, where
/// `[[`, `#` and `%%` are letters and not syntax. One rule for the index,
/// the outline and the link rewrites.
enum InlineCode {
    /// The code spans of [line], their backticks included: a run of
    /// backticks to the next run of the same length, as CommonMark reads
    /// them, so ``` ``a ` b`` ``` is one span. A backtick after a
    /// backslash opens nothing.
    static func spans<S: StringProtocol>(in line: S) -> [Range<S.Index>] {
        let bytes = line.utf8
        var out: [Range<S.Index>] = []
        var at = bytes.startIndex
        let end = bytes.endIndex
        var escaped = false
        while at < end {
            guard bytes[at] == 0x60 else {
                escaped = bytes[at] == 0x5C && !escaped
                at = bytes.index(after: at)
                continue
            }
            var opened = at
            while opened < end, bytes[opened] == 0x60 { opened = bytes.index(after: opened) }
            if escaped {
                escaped = false
                at = bytes.index(after: at)
                continue
            }
            let length = bytes.distance(from: at, to: opened)
            var scan = opened
            var close: S.Index?
            while scan < end {
                guard bytes[scan] == 0x60 else {
                    scan = bytes.index(after: scan)
                    continue
                }
                var run = scan
                while run < end, bytes[run] == 0x60 { run = bytes.index(after: run) }
                if bytes.distance(from: scan, to: run) == length {
                    close = run
                    break
                }
                scan = run
            }
            if let close {
                out.append(at..<close)
                at = close
            } else {
                at = opened
            }
        }
        return out
    }

    /// [line] without its code spans and, when it holds a link, without
    /// its inline math (`$…$` and `$$…$$`): what links and tags are read
    /// from. The line itself when it has neither.
    static func removed(from line: String) -> String {
        var text = line
        if line.hasMark("`") {
            let spans = spans(in: line)
            if !spans.isEmpty {
                text = ""
                var from = line.startIndex
                for span in spans {
                    text += line[from..<span.lowerBound]
                    from = span.upperBound
                }
                text += line[from...]
            }
        }
        if text.hasMark("$"), text.hasMark("[[") || text.hasMark("](") { text = withoutMath(text) }
        return text
    }

    /// Inline math as Obsidian reads it: `$` with no space after the
    /// opening one, none before the closing one and no digit after it, so
    /// "$5 and $10" is prose; `$$` to the next `$$`.
    private static func withoutMath(_ text: String) -> String {
        let characters = Array(text)
        var out = ""
        var at = 0
        while at < characters.count {
            let character = characters[at]
            if character == "\\", at + 1 < characters.count {
                out.append(character)
                out.append(characters[at + 1])
                at += 2
                continue
            }
            guard character == "$" else {
                out.append(character)
                at += 1
                continue
            }
            let double = at + 1 < characters.count && characters[at + 1] == "$"
            let start = at + (double ? 2 : 1)
            var close: Int?
            var scan = start
            while scan < characters.count {
                if characters[scan] == "\\" {
                    scan += 2
                    continue
                }
                if characters[scan] == "$" {
                    if double {
                        if scan + 1 < characters.count, characters[scan + 1] == "$" { close = scan + 2; break }
                    } else if scan > start, !characters[scan - 1].isWhitespace, !(scan + 1 < characters.count && characters[scan + 1].isNumber) {
                        close = scan + 1
                        break
                    }
                }
                scan += 1
            }
            if let close, double || (start < characters.count && !characters[start].isWhitespace) {
                at = close
            } else {
                out.append(character)
                at += 1
            }
        }
        return out
    }
}

/// `%% comments %%`, which may run over several lines. A `%%` in inline
/// code is two percent signs, as Obsidian shows it, and opens nothing.
enum Comments {
    static func strip(_ line: String, open: inout Bool) -> String {
        guard open || line.hasMark("%%") else { return line }
        var rest = Substring(line)
        if open {
            // Inside a comment nothing is code: the next `%%` closes it.
            guard let marker = rest.range(of: "%%") else { return "" }
            open = false
            rest = rest[marker.upperBound...]
        }
        let code = rest.hasMark("`") ? InlineCode.spans(in: rest) : []
        var out = ""
        var from = rest.startIndex
        var search = from
        while let marker = rest[search...].range(of: "%%") {
            if let span = code.first(where: { $0.overlaps(marker) }) {
                search = span.upperBound
                continue
            }
            out += rest[from..<marker.lowerBound]
            open = true
            // The spans after a comment are read again: a backtick in the
            // comment pairs with none outside it.
            return out + strip(String(rest[marker.upperBound...]), open: &open)
        }
        return out + rest[from...]
    }
}

/// The front matter: a small, forgiving reading of the YAML this vault writes.
/// `key: value`, `key: [a, b]` and a block list of `- item` lines.
public struct FrontMatter: Sendable {
    public var properties: [(key: String, values: [String])] = []
    /// Lines the front matter takes, fences included; 0 when there is none.
    public var lineCount = 0

    public func values(_ key: String) -> [String] {
        properties.first { $0.key.lowercased() == key }?.values ?? []
    }

    public static func parse(_ lines: [String]) -> FrontMatter {
        var result = FrontMatter()
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return result }
        guard let end = lines.indices.dropFirst().first(where: {
            let line = lines[$0].trimmingCharacters(in: .whitespaces)
            return line == "---" || line == "..."
        }) else { return result }
        result.lineCount = end + 1
        for line in lines[1..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("- "), !result.properties.isEmpty, line.first?.isWhitespace ?? false || line.hasPrefix("- ") {
                result.properties[result.properties.count - 1].values.append(unquote(String(trimmed.dropFirst(2))))
                continue
            }
            guard let colon = line.firstIndex(of: ":"), !(line.first?.isWhitespace ?? false) else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("["), value.hasSuffix("]") {
                let items = value.dropFirst().dropLast().split(separator: ",").map {
                    unquote($0.trimmingCharacters(in: .whitespaces))
                }
                result.properties.append((key, items.filter { !$0.isEmpty }))
            } else {
                result.properties.append((key, value.isEmpty ? [] : [unquote(value)]))
            }
        }
        return result
    }

    private static func unquote(_ value: String) -> String {
        if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}

/// Per-text direction, from the letters in it.
public enum TextDirection {
    public static func isRtl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x05FF, 0x0600...0x06FF, 0x0700...0x074F, 0x0750...0x077F, 0x08A0...0x08FF,
            0xFB1D...0xFDFF, 0xFE70...0xFEFF:
            return true
        default:
            return false
        }
    }

    public static func containsRtl(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isRtl)
    }

    /// The direction of a markdown line as it reads, from its first strong
    /// letter after the syntax a reader does not show: the list mark, the
    /// task box, the heading and quote marks, a callout's type and a
    /// wikilink's target before its alias. `- [x] سلام` is right to left,
    /// though `x` is a Latin letter. `nil` when it has no letter at all.
    public static func ofLine(_ line: String) -> Bool? {
        var rest = Substring(line).drop(while: \.isWhitespace)
        while true {
            let before = rest
            rest = rest.drop(while: { $0 == ">" || $0 == "#" || $0 == " " || $0 == "\t" })
            for mark in ["- ", "* ", "+ "] where rest.hasPrefix(mark) { rest = rest.dropFirst(2) }
            let digits = rest.prefix(while: { $0.isASCII && $0.isNumber }).count
            if digits > 0, let next = rest.dropFirst(digits).first, next == "." || next == ")" {
                rest = rest.dropFirst(digits + 1)
            }
            if rest.first == "[" {
                let after = rest.dropFirst()
                if after.count >= 2, after.dropFirst().first == "]" {
                    rest = after.dropFirst(2)
                } else if after.first == "!" {
                    let kind = after.dropFirst()
                    if let end = kind.firstIndex(of: "]") { rest = kind[kind.index(after: end)...] }
                }
            }
            if rest == before { break }
        }
        var at = rest.startIndex
        while at < rest.endIndex {
            // `[[target|alias]]` reads as its alias.
            if rest[at...].hasPrefix("[[") {
                let inner = rest[rest.index(at, offsetBy: 2)...]
                let close = inner.range(of: "]]")?.lowerBound ?? inner.endIndex
                if let bar = inner[..<close].firstIndex(of: "|") {
                    if let found = firstStrong(inner[inner.index(after: bar)..<close]) { return found }
                    at = close
                    continue
                }
            }
            for scalar in rest[at].unicodeScalars {
                if isRtl(scalar) { return true }
                if scalar.properties.isAlphabetic { return false }
            }
            at = rest.index(after: at)
        }
        return nil
    }

    /// Whether the first letter of [text] is right to left, as a text
    /// layout finds a paragraph's direction; `nil` with no letter.
    public static func firstStrong(_ text: some StringProtocol) -> Bool? {
        for scalar in text.unicodeScalars {
            if isRtl(scalar) { return true }
            if scalar.properties.isAlphabetic { return false }
        }
        return nil
    }

    /// From the first strong letter, as `dir="auto"` decides it.
    public static func startsRtl(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if isRtl(scalar) { return true }
            if scalar.properties.isAlphabetic { return false }
        }
        return false
    }
}
