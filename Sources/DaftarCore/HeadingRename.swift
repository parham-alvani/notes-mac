import Foundation

/// A heading renamed, and the links that name it: `[[Note#Old]]`,
/// `[[Note#Old|alias]]`, `![[Note#Old]]`, `[[Note#Parent#Old]]`, `[[#Old]]`
/// in the note itself and `[x](Note.md#Old%20heading)`. A link's heading is
/// found as Obsidian finds it: the text without its marks and case, and
/// each `#` part under the one before it. The first heading that matches
/// is the one named, so a link to another heading of the same name stays.
public enum HeadingRename {
    /// Headings renamed in one note: its headings before, and the new text
    /// of each renamed one by its place among them.
    public struct Change: Sendable, Equatable, Hashable {
        public var path: String
        public var headings: [Heading]
        public var renames: [Int: String]

        public init(path: String, headings: [Heading], renames: [Int: String]) {
            self.path = path
            self.headings = headings
            self.renames = renames
        }
    }

    /// A line that changes: its number, its text before and after, and
    /// the links on it that change.
    public struct Edit: Sendable, Hashable, Identifiable {
        public var line: Int
        public var before: String
        public var after: String
        public var links: Int
        public var id: Int { line }

        public init(line: Int, before: String, after: String, links: Int = 1) {
            self.line = line
            self.before = before
            self.after = after
            self.links = links
        }
    }

    /// The lines of one note that change.
    public struct NoteEdits: Sendable, Hashable, Identifiable {
        public var path: String
        public var edits: [Edit]
        public var id: String { path }

        public init(path: String, edits: [Edit]) {
            self.path = path
            self.edits = edits
        }
    }

    public enum Failure: Error, Equatable {
        /// The note changed after the preview: a line is not what it showed.
        case changed
    }

    /// The headings that took a new name between [old] and [new]: the
    /// headings the same in both are paired in order, and between two
    /// such pairs, headings of the same levels in the same number are the
    /// old ones renamed. A heading added or removed is no rename.
    public static func renamed(from old: [Heading], to new: [Heading]) -> [Int: String] {
        let a = old.map { "\($0.level) \(key($0.text))" }, b = new.map { "\($0.level) \(key($0.text))" }
        // The longest common subsequence, from the end.
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var renames: [Int: String] = [:]
        var i = 0, j = 0, gapA = 0, gapB = 0
        func closeGap() {
            let lengthA = i - gapA, lengthB = j - gapB
            if lengthA == lengthB, lengthA > 0, (0..<lengthA).allSatisfy({ old[gapA + $0].level == new[gapB + $0].level }) {
                for k in 0..<lengthA { renames[gapA + k] = new[gapB + k].text }
            }
        }
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                closeGap()
                i += 1
                j += 1
                gapA = i
                gapB = j
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        i = a.count
        j = b.count
        closeGap()
        return renames
    }

    /// How a link's heading and a heading compare: without the marks
    /// Obsidian leaves out of a link, white space collapsed, case folded.
    public static func key(_ text: String) -> String {
        Slugs.heading(String(text.filter { !"*_`=~[]#|^:%".contains($0) }))
    }

    /// The heading text as a link writes it: without `[`, `]`, `#`, `|`,
    /// `^`, `:` and `%`, as Obsidian writes it, since they end or split a link.
    public static func anchorText(_ text: String) -> String {
        text.filter { !"[]#|^:%".contains($0) }.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The headings an anchor `A#B#C` names, one for each part, each under
    /// the one before; nil when one is not found.
    public static func resolve(_ anchor: String, in headings: [Heading]) -> [Int]? {
        let parts = anchor.split(separator: "#", omittingEmptySubsequences: false).map { key(String($0)) }
        guard !parts.isEmpty, !parts.contains(where: \.isEmpty) else { return nil }
        var low = 0, high = headings.count
        var chain: [Int] = []
        for part in parts {
            guard let found = (low..<high).first(where: { key(headings[$0].text) == part }) else { return nil }
            chain.append(found)
            low = found + 1
            high = min(high, headings[low...].firstIndex { $0.level <= headings[found].level } ?? headings.count)
        }
        return chain
    }

    /// [anchor] with each part that names a renamed heading written anew,
    /// or nil when it names none.
    static func rewrite(_ anchor: String, _ change: Change) -> String? {
        guard let chain = resolve(anchor, in: change.headings), chain.contains(where: { change.renames[$0] != nil }) else { return nil }
        let parts = anchor.split(separator: "#", omittingEmptySubsequences: false).map(String.init)
        return zip(parts, chain).map { part, index in
            guard let new = change.renames[index] else { return part }
            // A part keeps the spaces it had around it: `[[Note# Old ]]`.
            let lead = part.prefix { $0 == " " }, trail = String(part.reversed().prefix { $0 == " " })
            return lead + anchorText(new) + trail
        }.joined(separator: "#")
    }

    nonisolated(unsafe) private static let wikilink = /(!?)\[\[([^\]\n]+?)\]\]/
    nonisolated(unsafe) private static let markdownLink = /(!?\[[^\]\n]*\]\()(<?)([^)>\s]+|[^)>\n]+(?=>))(>?\))/
    nonisolated(unsafe) private static let inlineCode = /`[^`\n]*`/
    /// A markdown link's anchor: spaces and `(` `)` encoded, as Obsidian writes it.
    private static let anchorAllowed = CharacterSet.urlFragmentAllowed.subtracting(CharacterSet(charactersIn: "()#"))

    /// The lines of [text], the note at [source], whose links name a renamed
    /// heading of [change], with their new text. [linksTo] says whether a
    /// link's target, as written, goes to the renamed note; an empty
    /// target is the note itself. Links in code are left as they are.
    public static func edits(in text: String, source: String, change: Change, linksTo: (String) -> Bool) -> [Edit] {
        let isSelf = source == change.path
        func names(_ target: String) -> Bool { target.isEmpty ? isSelf : linksTo(target) }
        var edits: [Edit] = []
        var open: String?
        var links = 0
        for (at, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.hasMark("```") || line.hasMark("~~~"), let match = line.firstMatch(of: NoteParser.fence) {
                let marker = String(match.1)
                if open == nil { open = marker } else if let first = open, marker.first == first.first, marker.count >= first.count { open = nil }
                continue
            }
            if open != nil || !line.hasMark("#") || (!line.hasMark("[[") && !line.hasMark("](")) { continue }
            let code = line.hasMark("`") ? line.matches(of: inlineCode).map(\.range) : []
            func inCode(_ range: Range<String.Index>) -> Bool { code.contains { $0.overlaps(range) } }
            var result = !line.hasMark("[[") ? line : line.replacing(wikilink) { match -> String in
                guard !inCode(match.range) else { return String(match.output.0) }
                let inner = String(match.output.2)
                let link = Wikilink(inner)
                guard let anchor = link.anchor, names(link.target), let hash = inner.firstIndex(of: "#") else { return String(match.output.0) }
                // The anchor as written runs from the first `#` to the bar.
                var end = inner.firstIndex(of: "|") ?? inner.endIndex
                if link.escaped, end > hash { end = inner.index(before: end) }
                guard end > hash, let new = rewrite(String(inner[inner.index(after: hash)..<end]), change), !anchor.isEmpty else {
                    return String(match.output.0)
                }
                links += 1
                return match.output.1 + "[[" + inner[...hash] + new + inner[end...] + "]]"
            }
            if result.hasMark("](") {
                let code = result.hasMark("`") ? result.matches(of: inlineCode).map(\.range) : []
                result = result.replacing(markdownLink) { match -> String in
                    guard !code.contains(where: { $0.overlaps(match.range) }) else { return String(match.output.0) }
                    let url = String(match.output.3)
                    guard !url.contains("://"), !url.hasPrefix("mailto:"), let hash = url.firstIndex(of: "#") else { return String(match.output.0) }
                    let bracketed = !match.output.2.isEmpty
                    let target = String(url[..<hash])
                    let decodedTarget = bracketed ? target : target.removingPercentEncoding ?? target
                    let fragment = String(url[url.index(after: hash)...])
                    let anchor = bracketed ? fragment : fragment.removingPercentEncoding ?? fragment
                    guard names(decodedTarget), let new = rewrite(anchor, change) else { return String(match.output.0) }
                    let written = bracketed
                        ? new
                        : new.split(separator: "#", omittingEmptySubsequences: false)
                            .map { $0.addingPercentEncoding(withAllowedCharacters: anchorAllowed) ?? String($0) }.joined(separator: "#")
                    links += 1
                    return match.output.1 + match.output.2 + target + "#" + written + match.output.4
                }
            }
            if result != line { edits.append(Edit(line: at, before: line, after: result, links: links)) }
            links = 0
        }
        return edits
    }

    /// A heading line with new text, its `#` marks as they were.
    public static func retitle(_ line: String, to text: String) -> String {
        let marks = line.prefix { $0 == "#" }
        return marks + " " + text.trimmingCharacters(in: .whitespaces)
    }

    /// [text] with [edits] made. Throws when a line is not the one the
    /// edit was made from: the note changed after the preview.
    public static func apply(_ edits: [Edit], to text: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        for edit in edits {
            guard lines.indices.contains(edit.line) else { throw Failure.changed }
            let cr = lines[edit.line].hasSuffix("\r")
            guard (cr ? String(lines[edit.line].dropLast()) : lines[edit.line]) == edit.before else { throw Failure.changed }
            lines[edit.line] = edit.after + (cr ? "\r" : "")
        }
        return lines.joined(separator: "\n")
    }
}
