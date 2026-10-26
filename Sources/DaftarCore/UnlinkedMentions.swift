import Foundation

/// The places where a note's name, or one of its aliases, is written in
/// another note without a link, as Obsidian's "Unlinked mentions" lists
/// them. A mention is the name as a whole word, in any case, outside links,
/// code, web addresses, tags and the front matter.
public enum UnlinkedMentions {
    public struct Mention: Sendable, Hashable {
        /// Zero-based line in the file.
        public var line: Int
        /// Where the name starts in the line, in UTF-16, and its length.
        public var column: Int
        public var length: Int
        /// The name as the note writes it.
        public var text: String
        /// The line around the name, and where the name is in it (UTF-16).
        public var excerpt: String
        public var excerptRange: NSRange
    }

    /// Names shorter than this match too many words to be worth a list.
    public static let shortest = 3

    /// The mentions of [names] in [text]: each place once, the longest name
    /// that matches there.
    public static func find(_ names: [String], in text: String) -> [Mention] {
        let names = Array(Set(names.filter { $0.count >= shortest })).sorted { $0.count > $1.count }
        guard !names.isEmpty else { return [] }
        var found: [Mention] = []
        var fenced = false, front = false
        for (number, line) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if number == 0, trimmed == "---" { front = true; continue }
            if front {
                if trimmed == "---" || trimmed == "..." { front = false }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle(); continue }
            if fenced { continue }
            let string = line as NSString
            var taken = protected(in: string)
            for name in names {
                var from = 0
                while from < string.length {
                    let range = string.range(of: name, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: from, length: string.length - from))
                    guard range.location != NSNotFound else { break }
                    from = NSMaxRange(range)
                    guard isWord(range, in: string), !taken.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
                    taken.append(range)
                    found.append(mention(range, line: number, in: string))
                }
            }
        }
        return found.sorted { ($0.line, $0.column) < ($1.line, $1.column) }
    }

    /// [text] with the mention a link: `[[Name]]` when it is written as the
    /// name is, `[[Name|as written]]` when not. Throws when the line no
    /// longer holds it where it was found.
    public static func link(_ mention: Mention, to name: String, in text: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(mention.line) else { throw VaultEdits.Failure.textMoved }
        let line = lines[mention.line] as NSString
        let range = NSRange(location: mention.column, length: mention.length)
        guard NSMaxRange(range) <= line.length, line.substring(with: range) == mention.text else { throw VaultEdits.Failure.textMoved }
        let link = mention.text == name ? "[[\(name)]]" : "[[\(name)|\(mention.text)]]"
        lines[mention.line] = line.replacingCharacters(in: range, with: link)
        return lines.joined(separator: "\n")
    }

    /// Links, code, web addresses and tags: text a mention cannot be in.
    static func protected(in line: NSString) -> [NSRange] {
        let whole = NSRange(location: 0, length: line.length)
        return patterns.flatMap { pattern in pattern.matches(in: line as String, range: whole).map(\.range) }
    }

    private static let patterns: [NSRegularExpression] = [
        #"!?\[\[[^\]]*\]\]"#,
        #"!?\[[^\]]*\]\([^)]*\)"#,
        #"`[^`]*`"#,
        #"[a-zA-Z][a-zA-Z0-9+.-]*://\S+"#,
        #"(?<![\p{L}\p{N}])#[\p{L}\p{N}_/-]+"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// No letter or digit right before or after: "Acme" in "Acme's", not in "Acmes".
    static func isWord(_ range: NSRange, in line: NSString) -> Bool {
        func letter(_ at: Int) -> Bool {
            guard at >= 0, at < line.length else { return false }
            let character = line.substring(with: line.rangeOfComposedCharacterSequence(at: at))
            return character.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        }
        return !letter(range.location - 1) && !letter(NSMaxRange(range))
    }

    /// The mention, with up to 60 characters of the line on each side.
    static func mention(_ range: NSRange, line number: Int, in line: NSString) -> Mention {
        let start = max(0, range.location - 60), end = min(line.length, NSMaxRange(range) + 60)
        let around = line.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        var excerpt = line.substring(with: around)
        var offset = range.location - around.location
        let lead = excerpt.prefix { $0 == " " || $0 == "\t" }
        excerpt.removeFirst(lead.count)
        offset -= (String(lead) as NSString).length
        if around.location > 0 { excerpt = "…" + excerpt; offset += 1 }
        if NSMaxRange(around) < line.length { excerpt += "…" }
        return Mention(line: number, column: range.location, length: range.length, text: line.substring(with: range),
            excerpt: excerpt, excerptRange: NSRange(location: offset, length: range.length))
    }
}
