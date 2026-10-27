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
    /// The sentence, without the Tasks plugin's trailing emoji.
    public var text: String
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

    /// Still to do: open or in progress.
    public var isOpen: Bool { !TaskLine.closed.contains(status) }

    /// The day the task belongs to: due, else scheduled.
    public var day: String? { due ?? scheduled }
}

public enum NoteParser {
    nonisolated(unsafe) static let heading = /^(#{1,6})[ \t]+(.*?)[ \t]*#*[ \t]*$/
    nonisolated(unsafe) private static let wikilink = /(!?)\[\[([^\]\n]+?)\]\]/
    nonisolated(unsafe) private static let markdownLink = /(!?)\[[^\]\n]*\]\(<?([^)>\s]+)>?\)/
    nonisolated(unsafe) private static let tag = /(?:^|\s)#([\p{L}\p{N}_\/-]+)/
    nonisolated(unsafe) private static let inlineCode = /`[^`\n]*`/
    nonisolated(unsafe) static let fence = /^\s*(?:>\s*)*(```+|~~~+)/

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
            if raw.hasMark("```") || raw.hasMark("~~~"), let match = raw.firstMatch(of: fence) {
                let marker = String(match.1)
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

            if line.hasPrefix("#"), let match = line.firstMatch(of: heading) {
                let text = String(match.2)
                note.headings.append(Heading(level: match.1.count, text: text, line: index))
                section = text
            }
            let code = line.hasMark("`") ? line.replacing(inlineCode, with: "") : line
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

/// `%% comments %%`, which may run over several lines.
enum Comments {
    static func strip(_ line: String, open: inout Bool) -> String {
        guard open || line.hasMark("%%") else { return line }
        var out = ""
        var rest = Substring(line)
        while true {
            guard let marker = rest.range(of: "%%") else {
                if !open { out += rest }
                break
            }
            if !open { out += rest[..<marker.lowerBound] }
            open.toggle()
            rest = rest[marker.upperBound...]
        }
        return out
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

    /// From the first strong letter, as `dir="auto"` decides it.
    public static func startsRtl(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if isRtl(scalar) { return true }
            if scalar.properties.isAlphabetic { return false }
        }
        return false
    }
}
