import Foundation

/// Obsidian's block references: a paragraph or a list item named by a
/// `^id` at its end, which `[[Note#^id]]` links to and `![[Note#^id]]`
/// embeds. A table, a quote or a code block takes its id on a line of its
/// own after it, with an empty line between, as Obsidian writes it.
public enum BlockRefs {
    public enum Kind: Sendable, Equatable {
        case paragraph, item, heading, table, quote, code
    }

    public struct Block: Sendable, Equatable {
        public var kind: Kind
        /// The block's first and last line, zero-based, in the file.
        public var start: Int
        public var end: Int
        public var id: String?
        /// What it says on one line, without its id or a list's marker.
        public var text: String
    }

    nonisolated(unsafe) private static let trailingId = /\s\^([A-Za-z0-9-]+)\s*$/
    nonisolated(unsafe) private static let ownLineId = /^\s*\^([A-Za-z0-9-]+)\s*$/
    nonisolated(unsafe) private static let itemMark = /^\s*(?:[-*+]|\d+[.)])(?:\s+\[[^\]]\])?(?:\s+|$)/
    nonisolated(unsafe) private static let heading = /^\s{0,3}(#{1,6})[ \t]+(.*?)[ \t]*#*[ \t]*$/
    nonisolated(unsafe) private static let fence = /^\s*(```+|~~~+)/

    /// The letters an id is made of.
    static let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    /// The blocks of [text] in order: headings, paragraphs, list items,
    /// tables, quotes and code blocks; front matter and empty lines are none.
    public static func blocks(in text: String) -> [Block] {
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        var blocks: [Block] = []
        var index = FrontMatter.parse(lines).lineCount
        func isBlank(_ at: Int) -> Bool { lines[at].allSatisfy(\.isWhitespace) }
        func startsBlock(_ line: String) -> Bool {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            return trimmed.hasPrefix("|") || trimmed.hasPrefix(">") || trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
                || trimmed.hasPrefix("$$") || line.firstMatch(of: itemMark) != nil || (trimmed.hasPrefix("#") && line.wholeMatch(of: heading) != nil)
        }
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
                continue
            }
            // `^id` alone names the table, quote or code block above it.
            if line.hasMark("^"), let match = line.wholeMatch(of: ownLineId), let last = blocks.indices.last,
                [.table, .quote, .code].contains(blocks[last].kind), blocks[last].id == nil,
                (blocks[last].end + 1..<index).allSatisfy(isBlank)
            {
                blocks[last].id = String(match.1)
                index += 1
                continue
            }
            let mark = line.hasMark("```") || line.hasMark("~~~") ? line.firstMatch(of: fence).map { String($0.1) } : nil
            if mark != nil || trimmed == "$$" {
                // To its closing line, or to the end when it never closes.
                var close = index + 1
                while close < lines.count {
                    let other = lines[close]
                    if let mark, let match = other.firstMatch(of: fence), match.1.first == mark.first, match.1.count >= mark.count { break }
                    if mark == nil, other.trimmingCharacters(in: .whitespaces) == "$$" { break }
                    close += 1
                }
                let end = min(close, lines.count - 1)
                let body = lines[min(index + 1, end)..<end].joined(separator: " ")
                blocks.append(Block(kind: .code, start: index, end: end, id: nil, text: flat(body)))
                index = end + 1
                continue
            }
            if trimmed.hasPrefix("#"), let match = line.wholeMatch(of: heading) {
                blocks.append(Block(kind: .heading, start: index, end: index, id: nil, text: String(match.2)))
                index += 1
                continue
            }
            if trimmed.hasPrefix("|") || trimmed.hasPrefix(">") {
                let pipe = trimmed.hasPrefix("|")
                var end = index
                while end + 1 < lines.count, lines[end + 1].trimmingCharacters(in: .whitespaces).hasPrefix(pipe ? "|" : ">") { end += 1 }
                let body = lines[index...end].map { line in
                    pipe ? line.replacingOccurrences(of: "|", with: " ") : String(line.drop { $0 == " " || $0 == ">" })
                }
                let words = body.filter { !$0.allSatisfy { " -:".contains($0) } }.joined(separator: " ")
                blocks.append(Block(kind: pipe ? .table : .quote, start: index, end: end, id: nil, text: flat(words)))
                index = end + 1
                continue
            }
            if let marker = line.firstMatch(of: itemMark) {
                // The item's own text: its line, and the lines that carry it on
                // below, but not the items nested under it.
                var end = index
                while end + 1 < lines.count, !isBlank(end + 1), !startsBlock(lines[end + 1]) { end += 1 }
                let first = String(line[marker.range.upperBound...])
                let body = ([first] + lines[(index + 1)..<(end + 1)]).joined(separator: " ")
                blocks.append(Block(kind: .item, start: index, end: end, id: id(of: lines[end]), text: flat(withoutId(body))))
                index = end + 1
                continue
            }
            var end = index
            while end + 1 < lines.count, !isBlank(end + 1), !startsBlock(lines[end + 1]) { end += 1 }
            let body = lines[index...end].joined(separator: " ")
            blocks.append(Block(kind: .paragraph, start: index, end: end, id: id(of: lines[end]), text: flat(withoutId(body))))
            index = end + 1
        }
        return blocks
    }

    /// The block [line] is in, or nil on an empty line or in front matter.
    public static func block(atLine line: Int, in text: String) -> Block? {
        blocks(in: text).first { $0.start <= line && line <= $0.end }
    }

    /// The block [id] names, as the reader finds it.
    public static func block(id: String, in text: String) -> Block? {
        let wanted = id.hasPrefix("^") ? String(id.dropFirst()) : id
        return blocks(in: text).first { $0.id?.lowercased() == wanted.lowercased() }
    }

    /// Every block id in [text], whatever it names.
    public static func ids(in text: String) -> Set<String> {
        var ids = Set<String>()
        for line in text.components(separatedBy: "\n") where line.hasMark("^") {
            if let match = line.firstMatch(of: trailingId) ?? line.wholeMatch(of: ownLineId) { ids.insert(String(match.1).lowercased()) }
        }
        return ids
    }

    /// Six random lowercase letters and digits that no block of the note has yet.
    public static func newId(taken: Set<String>, using random: inout some RandomNumberGenerator) -> String {
        while true {
            let id = String((0..<6).map { _ in alphabet.randomElement(using: &random)! })
            if !taken.contains(id) { return id }
        }
    }

    public static func newId(taken: Set<String>) -> String {
        var random = SystemRandomNumberGenerator()
        return newId(taken: taken, using: &random)
    }

    /// Where [id] goes for [block] of [text]: an offset in UTF-16 units and
    /// the text to put there. After a paragraph's or an item's last word,
    /// or on its own line after a table, a quote or a code block. Nil for a
    /// heading, which a link names by its text.
    public static func insertion(_ id: String, for block: Block, in text: String) -> (offset: Int, text: String)? {
        guard block.kind != .heading else { return nil }
        // Lines end at `\n` alone, as the blocks were read; a lone `\r` is text.
        let units = Array(text.utf16)
        var start = 0
        for _ in 0..<block.end {
            guard let newline = units[start...].firstIndex(of: 0x0A) else { return nil }
            start = newline + 1
        }
        let lineEnd = units[start...].firstIndex(of: 0x0A) ?? units.count
        let crlf = lineEnd < units.count && lineEnd > start && units[lineEnd - 1] == 0x0D
        let contentsEnd = crlf ? lineEnd - 1 : lineEnd
        switch block.kind {
        case .paragraph, .item:
            var end = contentsEnd
            while end > start, units[end - 1] == 0x20 || units[end - 1] == 0x09 { end -= 1 }
            return (end, " ^" + id)
        default:
            let newline = crlf ? "\r\n" : "\n"
            // A line straight after would join the id's paragraph.
            let nextEnd = lineEnd < units.count ? units[(lineEnd + 1)...].firstIndex(of: 0x0A) ?? units.count : lineEnd
            let next = lineEnd < units.count ? String(decoding: units[(lineEnd + 1)..<nextEnd], as: UTF16.self) : ""
            let separate = next.allSatisfy(\.isWhitespace) ? "" : newline
            return (contentsEnd, newline + newline + "^" + id + separate)
        }
    }

    /// [text] with [id] given to the block that starts on [line] and says
    /// [expected]. Read from the file just before: it refuses when the block
    /// is not there any more, or has an id already.
    public static func addId(_ id: String, toBlockAt line: Int, expected: String, in text: String) throws -> String {
        guard let block = blocks(in: text).first(where: { $0.start == line }), block.text == expected, block.id == nil,
            let insertion = insertion(id, for: block, in: text)
        else { throw VaultEdits.Failure.textMoved }
        return (text as NSString).replacingCharacters(in: NSRange(location: insertion.offset, length: 0), with: insertion.text)
    }

    private static func id(of line: String) -> String? {
        guard line.hasMark("^") else { return nil }
        return line.firstMatch(of: trailingId).map { String($0.1) }
    }

    private static func withoutId(_ text: String) -> String {
        guard text.hasMark("^"), let match = text.firstMatch(of: trailingId) else { return text }
        return String(text[..<match.range.lowerBound])
    }

    private static func flat(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
