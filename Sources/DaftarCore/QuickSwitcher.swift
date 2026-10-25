import Foundation

/// The ⌘P switcher's ranking, as Obsidian's quick switcher works: every
/// word of the query, in any order, matches the note's name, one of its
/// aliases or its folders, fuzzily. The name counts most and the folders
/// least; an exact name, and a name that starts with the query, come first.
public enum QuickSwitcher {
    public struct Candidate: Sendable {
        public var path: String
        /// Folded once, when the index changes, not on each keystroke.
        let title: String
        let aliases: [String]
        let folders: String

        public init(path: String, title: String, aliases: [String] = []) {
            self.path = path
            self.title = Slugs.fold(title)
            self.aliases = aliases.map(Slugs.fold)
            folders = Slugs.fold(path.split(separator: "/").dropLast().joined(separator: " "))
        }
    }

    public static func rank(_ query: String, in candidates: [Candidate], recent: [String] = [], limit: Int = 50) -> [String] {
        let needle = Slugs.fold(query.trimmingCharacters(in: .whitespaces))
        let words = needle.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return Array(recent.prefix(limit)) }
        let recency = Dictionary(recent.enumerated().map { ($1, $0) }) { a, _ in a }
        var scored: [(path: String, score: Int, match: Int)] = []
        scored.reserveCapacity(64)
        for candidate in candidates {
            guard let match = score(words, candidate) else { continue }
            var score = match
            if candidate.title == needle || candidate.aliases.contains(needle) { score += 1000 }
            else if candidate.title.hasPrefix(needle) { score += 300 }
            else if candidate.title.contains(needle) { score += 120 }
            // A note opened lately wins a close race, not a clear one.
            if let at = recency[candidate.path] { score += max(1, 12 - at) }
            scored.append((candidate.path, score, match))
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.path.count != b.path.count { return a.path.count < b.path.count }
            return a.path < b.path
        }
        // Letters spread over a path match nearly anything: once something
        // matches well, what matches under half as well is noise, not a
        // result. The words alone are compared, not the bonus of an exact
        // name, which would leave that one note alone in the list.
        guard let best = scored.map(\.match).max() else { return [] }
        return scored.filter { $0.match * 2 >= best }.prefix(limit).map(\.path)
    }

    /// The sum of each word's best match, or nil when a word matches nowhere.
    static func score(_ words: [String], _ candidate: Candidate) -> Int? {
        var total = 0
        for word in words {
            var best: Int?
            func consider(_ text: String, weight: Int) {
                guard mayMatch(word, text), let match = Fuzzy.match(word, in: text) else { return }
                var value = match.score * 4 + weight
                // The word as written, and at the start of a word, beats letters spread out.
                if text.hasPrefix(word) { value += 40 } else if text.contains(" " + word) || text.contains("-" + word) { value += 25 } else if text.contains(word) { value += 12 }
                // Letters spread far apart are barely a match.
                if let first = match.positions.first, let last = match.positions.last, last - first + 1 > word.count * 3 { value -= 30 }
                if best == nil || value > best! { best = value }
            }
            consider(candidate.title, weight: 60)
            for alias in candidate.aliases { consider(alias, weight: 45) }
            consider(candidate.folders, weight: 0)
            guard let found = best else { return nil }
            total += found
        }
        return total
    }

    /// Every letter of [word] in [text] in order: the quick test that spares
    /// the full match for the many notes that cannot match at all.
    static func mayMatch(_ word: String, _ text: String) -> Bool {
        var rest = word[...]
        for character in text where character == rest.first {
            rest = rest.dropFirst()
            if rest.isEmpty { return true }
        }
        return rest.isEmpty
    }
}
