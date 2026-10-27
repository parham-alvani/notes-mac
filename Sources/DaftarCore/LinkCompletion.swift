import Foundation

/// What the editor offers as a link or a tag is typed, as Obsidian does:
/// `[[` notes and their aliases, `[[Note#` the note's headings, `[[Note#^`
/// its blocks, `[[#` the headings of the note itself, and `#` at the start
/// of a word the vault's tags.
public enum LinkCompletion {
    /// What is typed after `[[`.
    public enum Query: Sendable, Equatable {
        case note(String)
        /// An empty note is the note being edited.
        case heading(note: String, query: String)
        case block(note: String, query: String)
    }

    /// A row of the list: what it shows, and what takes the typed text's place.
    public struct Item: Sendable, Equatable {
        public var label: String
        public var insert: String

        public init(label: String, insert: String) {
            self.label = label
            self.insert = insert
        }
    }

    /// The text from just after an open `[[` to [location], and what it
    /// asks for; nil outside a link, or once a `|` or `]]` is typed.
    public static func query(in text: NSString, at location: Int) -> (range: NSRange, query: Query)? {
        guard location <= text.length else { return nil }
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        let before = text.substring(with: NSRange(location: line.location, length: location - line.location)) as NSString
        let open = before.range(of: "[[", options: .backwards)
        guard open.location != NSNotFound else { return nil }
        let typed = before.substring(from: NSMaxRange(open))
        guard !typed.contains("]]"), !typed.contains("|") else { return nil }
        let range = NSRange(location: line.location + NSMaxRange(open), length: (typed as NSString).length)
        if let hash = typed.firstIndex(of: "#") {
            let note = String(typed[..<hash])
            let rest = typed[typed.index(after: hash)...]
            if rest.hasPrefix("^") { return (range, .block(note: note, query: String(rest.dropFirst()))) }
            return (range, .heading(note: note, query: String(rest)))
        }
        if let caret = typed.firstIndex(of: "^") {
            return (range, .block(note: String(typed[..<caret]), query: String(typed[typed.index(after: caret)...])))
        }
        return (range, .note(typed))
    }

    // MARK: Notes

    /// A note the list may offer: the name a link writes, and its aliases.
    public struct Note: Sendable, Equatable {
        public var name: String
        public var aliases: [String]

        public init(name: String, aliases: [String] = []) {
            self.name = name
            self.aliases = aliases
        }
    }

    /// The notes, ranked already, as rows. An alias the query matches gets
    /// a row of its own, `alias → Note`, which writes `Note|alias` as
    /// Obsidian does; it comes first when the name itself does not match.
    public static func notes(_ notes: [Note], matching query: String) -> [Item] {
        var items: [Item] = []
        let typed = query.trimmingCharacters(in: .whitespaces)
        for note in notes {
            var own = [Item(label: note.name, insert: note.name)]
            if !typed.isEmpty {
                let nameMatches = Fuzzy.match(typed, in: note.name) != nil
                for alias in note.aliases where !alias.isEmpty && Fuzzy.match(typed, in: alias) != nil {
                    let row = Item(label: "\(alias) → \(note.name)", insert: "\(note.name)|\(alias)")
                    if nameMatches { own.append(row) } else { own.insert(row, at: own.count - 1) }
                }
            }
            items += own
        }
        return unique(items)
    }

    // MARK: Headings

    /// The headings of [note] as rows, indented by their level: all of
    /// them in order for an empty query, else the best first.
    public static func headings(_ headings: [Heading], matching query: String, note: String) -> [Item] {
        let rows = QuickSwitcher.headings(query.trimmingCharacters(in: .whitespaces), in: headings).map { heading in
            Item(label: String(repeating: "  ", count: max(0, heading.level - 1)) + heading.text, insert: note + "#" + anchor(heading.text))
        }
        return unique(rows)
    }

    /// A heading as a link names it: a link's own marks -- `[[`, `]]`, `|`,
    /// `#` and `^` -- cannot be in it, so Obsidian writes a space for them.
    public static func anchor(_ heading: String) -> String {
        heading.replacingOccurrences(of: "[[", with: " ").replacingOccurrences(of: "]]", with: " ")
            .map { "|#^".contains($0) ? " " : String($0) }.joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Blocks

    /// The blocks a link can name, for the query: paragraphs, list items,
    /// tables, quotes and code, in order for an empty query, else those
    /// whose text holds every word, closest first.
    public static func blocks(_ blocks: [BlockRefs.Block], matching query: String, limit: Int = 50) -> [BlockRefs.Block] {
        let candidates = blocks.filter { $0.kind != .heading && !$0.text.isEmpty }
        let words = Slugs.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return Array(candidates.prefix(limit)) }
        let scored = candidates.compactMap { block -> (BlockRefs.Block, Int)? in
            let text = Slugs.fold(block.text + " " + (block.id ?? ""))
            guard words.allSatisfy({ text.contains($0) }) else { return nil }
            return (block, text.hasPrefix(words[0]) ? 1 : 0)
        }
        return scored.enumerated().sorted { a, b in a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset }
            .prefix(limit).map(\.element.0)
    }

    /// A block's row: the start of its text, and its id when it has one.
    public static func label(of block: BlockRefs.Block) -> String {
        let text = block.text.count > 70 ? String(block.text.prefix(69)) + "…" : block.text
        return block.id.map { "\(text)  ^\($0)" } ?? text
    }

    // MARK: Tags

    /// The tag typed so far, after a `#` at the start of a word: its range
    /// without the `#`. Nil inside code, in front matter, in a link or an
    /// address, and for a heading's `#` marks; at the start of a line only
    /// once a letter follows, since `# ` is a heading.
    public static func tagQuery(in text: NSString, at location: Int) -> NSRange? {
        guard location <= text.length else { return nil }
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        let before = text.substring(with: NSRange(location: line.location, length: location - line.location))
        guard let hash = before.lastIndex(of: "#") else { return nil }
        let typed = before[before.index(after: hash)...]
        guard typed.allSatisfy(isTagCharacter) else { return nil }
        let lead = before[..<hash]
        if let previous = lead.last, !previous.isWhitespace { return nil }
        if lead.allSatisfy({ $0 == " " || $0 == "\t" }), typed.isEmpty { return nil }
        // An odd number of backticks before it: inside inline code.
        if lead.filter({ $0 == "`" }).count % 2 == 1 { return nil }
        if inCodeOrFrontMatter(text, line: line.location) { return nil }
        let start = line.location + (String(before[..<hash]) as NSString).length + 1
        return NSRange(location: start, length: location - start)
    }

    /// The vault's tags for the query, nested ones included: those that
    /// start with it first, then those with a part that does, then the
    /// rest that hold its letters; the most used first in each.
    public static func tags(_ counts: [String: Int], matching query: String, limit: Int = 60) -> [Item] {
        // `#Tag` and `#tag` are one tag; it is written as it is written most.
        var merged: [String: (spelling: String, count: Int, best: Int)] = [:]
        for (tag, count) in counts {
            let key = Slugs.fold(tag)
            let old = merged[key]
            let spelling = old.map { $0.best >= count ? $0.spelling : tag } ?? tag
            merged[key] = (spelling, (old?.count ?? 0) + count, max(old?.best ?? 0, count))
        }
        let needle = Slugs.fold(query)
        let rows = merged.compactMap { key, value -> (String, Int, Int)? in
            let rank: Int
            if needle.isEmpty || key.hasPrefix(needle) { rank = 3 }
            else if key.contains("/" + needle) || key.contains("-" + needle) || key.contains("_" + needle) { rank = 2 }
            else if key.contains(needle) { rank = 1 }
            else if Fuzzy.match(needle, in: key) != nil { rank = 0 }
            else { return nil }
            return (value.spelling, value.count, rank)
        }
        return rows.sorted { a, b in
            if a.2 != b.2 { return a.2 > b.2 }
            if a.1 != b.1 { return a.1 > b.1 }
            return a.0 < b.0
        }.prefix(limit).map { Item(label: "#\($0.0)  \($0.1)", insert: $0.0) }
    }

    static func isTagCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "/" || character == "-"
    }

    /// Whether the line at [offset] is in a fenced code block or the front
    /// matter: the lines above it are read, fence by fence.
    static func inCodeOrFrontMatter(_ text: NSString, line offset: Int) -> Bool {
        let above = text.substring(to: offset)
        var lines = above.components(separatedBy: "\n")
        lines.removeLast()
        // Front matter whose closing `---` is not above the line holds it.
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
            !lines.dropFirst().contains(where: { ["---", "..."].contains($0.trimmingCharacters(in: .whitespaces)) })
        {
            return true
        }
        var fence: Substring?
        for line in lines where line.hasMark("```") || line.hasMark("~~~") {
            let trimmed = line.drop { $0 == " " || $0 == "\t" || $0 == ">" }
            let mark = trimmed.prefix { $0 == "`" || $0 == "~" }
            guard mark.count >= 3, Set(mark).count == 1 else { continue }
            if let open = fence {
                if mark.first == open.first, mark.count >= open.count { fence = nil }
            } else {
                fence = mark
            }
        }
        return fence != nil
    }

    /// The rows with no label twice: the list tells rows apart by label.
    private static func unique(_ items: [Item]) -> [Item] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.label).inserted }
    }
}
