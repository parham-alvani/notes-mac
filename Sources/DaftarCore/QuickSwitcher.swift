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
        /// Folded once, when the index changes, not on each keystroke: by
        /// `Slugs.matching`, as the query is, so a Persian name is found
        /// with or without its half spaces and from an Arabic keyboard.
        let title: String
        let aliases: [String]
        let folders: String
        /// The folders and the name, as a word with a `/` is matched.
        let full: String
        let note: Bool
        /// Which of the texts are plain ASCII, matched on their bytes ([Fuzzy.plainASCII]).
        let titleASCII: Bool
        let aliasesASCII: [Bool]
        let foldersASCII: Bool
        /// The path's length, which breaks a tie, counted once.
        let length: Int

        public init(path: String, title: String, aliases: [String] = []) {
            self.path = path
            self.title = Slugs.matching(title)
            self.aliases = aliases.map(Slugs.matching)
            folders = Slugs.matching(QuickSwitcher.folder(of: path))
            full = folders.isEmpty ? self.title : folders + "/" + self.title
            // A picture opens in the app too, but ranks as the attachment it is.
            note = Vault.opensInApp(path) && !Vault.isImage(path)
            titleASCII = Fuzzy.plainASCII(self.title)
            aliasesASCII = self.aliases.map(Fuzzy.plainASCII)
            foldersASCII = Fuzzy.plainASCII(folders)
            length = path.count
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
        let needle = Slugs.matching(query.trimmingCharacters(in: .whitespaces))
        let words = needle.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return Ranking(paths: Array(recent.prefix(limit)), loose: false) }
        let recency = Dictionary(recent.enumerated().map { ($1, $0) }) { a, _ in a }
        let prepared = words.map(Word.init)
        let needleASCII = Fuzzy.plainASCII(needle)
        var scored: [(path: String, score: Int, match: Int, close: Bool, length: Int)] = []
        scored.reserveCapacity(64)
        for candidate in candidates {
            guard let (match, close) = score(prepared, candidate) else { continue }
            var score = match
            if candidate.title == needle || candidate.aliases.contains(needle) || candidate.full == needle { score += 1000 }
            else if starts(candidate.title, with: needle, ascii: needleASCII && candidate.titleASCII) { score += 300 }
            else if holds(candidate.title, needle, ascii: needleASCII && candidate.titleASCII) { score += 120 }
            if candidate.note { score += 8 }
            // A note opened lately wins a close race, not a clear one.
            if let at = recency[candidate.path] { score += max(1, 12 - at) }
            scored.append((candidate.path, score, match, close, candidate.length))
        }
        // Once one file holds every word closely, the files that only hold
        // the letters are noise: "car insurance" is not "Cards … Reinsurance".
        let loose = !scored.contains(where: \.close)
        if !loose { scored.removeAll { !$0.close } }
        // Letters spread over a path match nearly anything: once something
        // matches well, what matches under half as well is noise, not a
        // result. The words alone are compared, not the bonus of an exact
        // name, which would leave that one note alone in the list. Left
        // out before the sort, which then orders only what may be shown.
        guard let best = scored.map(\.match).max() else { return Ranking(paths: [], loose: false) }
        scored.removeAll { !($0.match == best || $0.match * 2 >= best) }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.length != b.length { return a.length < b.length }
            return a.path < b.path
        }
        return Ranking(paths: scored.prefix(limit).map(\.path), loose: loose)
    }

    /// A word of the query, with whether it is plain ASCII, worked out once per query.
    struct Word {
        let text: String
        let ascii: Bool
        init(_ text: String) {
            self.text = text
            ascii = Fuzzy.plainASCII(text)
        }
    }

    /// `text.hasPrefix(prefix)`, on the bytes when both are plain ASCII.
    static func starts(_ text: String, with prefix: String, ascii: Bool) -> Bool {
        ascii ? text.utf8.starts(with: prefix.utf8) : text.hasPrefix(prefix)
    }

    /// `text.contains(part)`, on the bytes when both are plain ASCII.
    static func holds(_ text: String, _ part: String, ascii: Bool) -> Bool {
        guard ascii else { return text.contains(part) }
        var text = text, part = part
        return text.withUTF8 { hay in part.withUTF8 { find($0, in: hay, after: nil) } }
    }

    /// Whether [part] is in [hay], right after the byte [after] when one is given.
    static func find(_ part: UnsafeBufferPointer<UInt8>, in hay: UnsafeBufferPointer<UInt8>, after: UInt8?) -> Bool {
        let need = part.count + (after == nil ? 0 : 1)
        guard need <= hay.count else { return false }
        if part.isEmpty { return after == nil || hay.contains(after!) }
        let first = part[0]
        var at = after == nil ? 0 : 1
        while at + part.count <= hay.count {
            if hay[at] == first, after.map({ hay[at - 1] == $0 }) ?? true {
                var same = true
                for offset in 1..<part.count where hay[at + offset] != part[offset] {
                    same = false
                    break
                }
                if same { return true }
            }
            at += 1
        }
        return false
    }

    /// The sum of each word's best match, and whether every word matched
    /// closely; nil when a word matches nowhere.
    static func score(_ words: [String], _ candidate: Candidate) -> (Int, Bool)? {
        score(words.map(Word.init), candidate)
    }

    static func score(_ words: [Word], _ candidate: Candidate) -> (Int, Bool)? {
        var total = 0, close = true
        for prepared in words {
            let word = prepared.text
            var best: Int?, near = false
            func consider(_ text: String, ascii: Bool, weight: Int) {
                if ascii {
                    // A word with a letter beyond ASCII is not in an ASCII text.
                    guard prepared.ascii else { return }
                    var text = text, word = word
                    guard let value = text.withUTF8({ hay in word.withUTF8 { asciiValue($0, in: hay, weight: weight, near: &near) } }) else { return }
                    if best == nil || value > best! { best = value }
                    return
                }
                guard let value = value(word, in: text, weight: weight, near: &near) else { return }
                if best == nil || value > best! { best = value }
            }
            if word.contains("/") {
                consider(candidate.full, ascii: candidate.titleASCII && candidate.foldersASCII, weight: 30)
            } else {
                consider(candidate.title, ascii: candidate.titleASCII, weight: 60)
                for (alias, ascii) in zip(candidate.aliases, candidate.aliasesASCII) { consider(alias, ascii: ascii, weight: 45) }
                consider(candidate.folders, ascii: candidate.foldersASCII, weight: 0)
            }
            guard let found = best else { return nil }
            total += found
            close = close && near
        }
        return (total, close)
    }

    /// What one word of the query is worth in one text of a candidate
    /// (its name, an alias, its folders), nil for no match; [near] becomes
    /// true when the match is close ([isClose]).
    static func value(_ word: String, in text: String, weight: Int, near: inout Bool) -> Int? {
        guard mayMatch(word, text), let match = Fuzzy.match(word, in: text) else { return nil }
        near = near || isClose(word, text, match.positions)
        var value = match.score * 4 + weight
        // The word as written, and at the start of a word, beats letters spread out.
        if text.hasPrefix(word) { value += 40 } else if text.contains(" " + word) || text.contains("-" + word) || text.contains("/" + word) { value += 25 } else if text.contains(word) { value += 12 }
        // Letters spread far apart are barely a match.
        if let first = match.positions.first, let last = match.positions.last, last - first + 1 > word.count * 3 { value -= 30 }
        return value
    }

    /// [value] for a plain ASCII word in a plain ASCII text, on their
    /// bytes, without folding the text again: the same value.
    static func asciiValue(_ word: UnsafeBufferPointer<UInt8>, in text: UnsafeBufferPointer<UInt8>, weight: Int, near: inout Bool) -> Int? {
        // mayMatch: every letter of the word, in order.
        var next = 0
        for byte in text where next < word.count && byte == word[next] { next += 1 }
        guard next == word.count, let match = Fuzzy.matchASCII(word, in: text) else { return nil }
        let holds = find(word, in: text, after: nil)
        // isClose
        if holds {
            near = true
        } else if let first = match.positions.first, let last = match.positions.last {
            let start = first == 0 || [0x20, 0x2D, 0x5F, 0x2F, 0x2E, 0x28].contains(text[first - 1])  // space - _ / . (
            if start && last - first + 1 <= word.count * 2 { near = true }
        }
        var value = match.score * 4 + weight
        if text.starts(with: word) { value += 40 } else if find(word, in: text, after: 0x20) || find(word, in: text, after: 0x2D) || find(word, in: text, after: 0x2F) { value += 25 } else if holds { value += 12 }
        if let first = match.positions.first, let last = match.positions.last, last - first + 1 > word.count * 3 { value -= 30 }
        return value
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
