import Foundation

/// The ⌘P switcher's ranking, as Obsidian's quick switcher and VS Code's
/// Quick Open work: every word of the query, in any order, matches the
/// file's name, one of its aliases or its folders, fuzzily. A word with a
/// `/` in it matches the whole path, so `comp/acme` and `Companies/` find
/// the files in that folder. The name counts most and the folders least;
/// an exact name, and a name that starts with the query, come first, and a
/// note comes before an attachment that matches as well.
public enum QuickSwitcher {
    public struct Candidate: Sendable {
        public var path: String
        /// Folded once, when the index changes, not on each keystroke.
        let title: String
        let aliases: [String]
        let folders: String
        /// The folders and the name, as a word with a `/` is matched.
        let full: String
        let note: Bool

        public init(path: String, title: String, aliases: [String] = []) {
            self.path = path
            self.title = Slugs.fold(title)
            self.aliases = aliases.map(Slugs.fold)
            folders = Slugs.fold(QuickSwitcher.folder(of: path))
            full = folders.isEmpty ? self.title : folders + "/" + self.title
            note = Vault.opensInApp(path)
        }
    }

    /// The folders a path is in, as the switcher shows them: `A/B`.
    public static func folder(of path: String) -> String {
        path.split(separator: "/").dropLast().joined(separator: "/")
    }

    /// What the switcher lists for a query.
    public struct Ranking: Sendable, Equatable {
        public var paths: [String]
        /// No file holds the words as written or at the start of its
        /// words: the paths only hold their letters, spread out.
        public var loose: Bool
    }

    public static func rank(_ query: String, in candidates: [Candidate], recent: [String] = [], limit: Int = 50) -> [String] {
        ranking(query, in: candidates, recent: recent, limit: limit).paths
    }

    public static func ranking(_ query: String, in candidates: [Candidate], recent: [String] = [], limit: Int = 50) -> Ranking {
        let needle = Slugs.fold(query.trimmingCharacters(in: .whitespaces))
        let words = needle.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return Ranking(paths: Array(recent.prefix(limit)), loose: false) }
        let recency = Dictionary(recent.enumerated().map { ($1, $0) }) { a, _ in a }
        var scored: [(path: String, score: Int, match: Int, close: Bool)] = []
        scored.reserveCapacity(64)
        for candidate in candidates {
            guard let (match, close) = score(words, candidate) else { continue }
            var score = match
            if candidate.title == needle || candidate.aliases.contains(needle) || candidate.full == needle { score += 1000 }
            else if candidate.title.hasPrefix(needle) { score += 300 }
            else if candidate.title.contains(needle) { score += 120 }
            if candidate.note { score += 8 }
            // A note opened lately wins a close race, not a clear one.
            if let at = recency[candidate.path] { score += max(1, 12 - at) }
            scored.append((candidate.path, score, match, close))
        }
        // Once one file holds every word closely, the files that only hold
        // the letters are noise: "car insurance" is not "Cards … Reinsurance".
        let loose = !scored.contains(where: \.close)
        if !loose { scored.removeAll { !$0.close } }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.path.count != b.path.count { return a.path.count < b.path.count }
            return a.path < b.path
        }
        // Letters spread over a path match nearly anything: once something
        // matches well, what matches under half as well is noise, not a
        // result. The words alone are compared, not the bonus of an exact
        // name, which would leave that one note alone in the list.
        guard let best = scored.map(\.match).max() else { return Ranking(paths: [], loose: false) }
        return Ranking(paths: scored.filter { $0.match == best || $0.match * 2 >= best }.prefix(limit).map(\.path), loose: loose)
    }

    /// The sum of each word's best match, and whether every word matched
    /// closely; nil when a word matches nowhere.
    static func score(_ words: [String], _ candidate: Candidate) -> (Int, Bool)? {
        var total = 0, close = true
        for word in words {
            var best: Int?, near = false
            func consider(_ text: String, weight: Int) {
                guard mayMatch(word, text), let match = Fuzzy.match(word, in: text) else { return }
                near = near || isClose(word, text, match.positions)
                var value = match.score * 4 + weight
                // The word as written, and at the start of a word, beats letters spread out.
                if text.hasPrefix(word) { value += 40 } else if text.contains(" " + word) || text.contains("-" + word) || text.contains("/" + word) { value += 25 } else if text.contains(word) { value += 12 }
                // Letters spread far apart are barely a match.
                if let first = match.positions.first, let last = match.positions.last, last - first + 1 > word.count * 3 { value -= 30 }
                if best == nil || value > best! { best = value }
            }
            if word.contains("/") {
                consider(candidate.full, weight: 30)
            } else {
                consider(candidate.title, weight: 60)
                for alias in candidate.aliases { consider(alias, weight: 45) }
                consider(candidate.folders, weight: 0)
            }
            guard let found = best else { return nil }
            total += found
            close = close && near
        }
        return (total, close)
    }

    /// The word as written, or its letters from the start of a word and
    /// not spread far: `kube` in "Kubernetes", `fwr` in "firewall rules".
    static func isClose(_ word: String, _ text: String, _ positions: [Int]) -> Bool {
        if text.contains(word) { return true }
        guard let first = positions.first, let last = positions.last else { return false }
        let characters = Array(text)
        let start = first == 0 || " -_/.(".contains(characters[first - 1])
        return start && last - first + 1 <= word.count * 2
    }

    // MARK: Headings

    /// `Note#Heading`: the file part and the heading part, or nil when the
    /// query has no `#`.
    public static func heading(in query: String) -> (file: String, heading: String)? {
        guard let mark = query.firstIndex(of: "#") else { return nil }
        return (String(query[..<mark]).trimmingCharacters(in: .whitespaces), String(query[query.index(after: mark)...]).trimmingCharacters(in: .whitespaces))
    }

    /// The headings that match [query], best first; all of them, in order,
    /// for an empty one.
    public static func headings(_ query: String, in headings: [Heading]) -> [Heading] {
        guard !query.isEmpty else { return headings }
        return headings.compactMap { heading in Fuzzy.match(query, in: heading.text).map { (heading, $0.score) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.line < $1.0.line }
            .map(\.0)
    }

    /// The letters of [title] and of [folder] that [query] matched, as
    /// offsets, for the switcher to mark them.
    public static func highlights(_ query: String, title: String, folder: String) -> (title: Set<Int>, folder: Set<Int>) {
        var inTitle = Set<Int>(), inFolder = Set<Int>()
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let whole = folder.isEmpty ? title : folder + "/" + title
        let start = folder.isEmpty ? 0 : folder.count + 1
        for word in words {
            if word.contains("/") {
                for at in Fuzzy.match(word, in: whole)?.positions ?? [] {
                    if at >= start { inTitle.insert(at - start) } else { inFolder.insert(at) }
                }
            } else if let match = Fuzzy.match(word, in: title) {
                inTitle.formUnion(match.positions)
            } else if let match = Fuzzy.match(word, in: folder) {
                inFolder.formUnion(match.positions)
            }
        }
        return (inTitle, inFolder)
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
