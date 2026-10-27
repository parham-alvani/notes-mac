import Foundation

/// A fuzzy match, as a command palette does it: every letter of the query
/// in order, anywhere in the text. A letter at the start of a word, and
/// letters in a row, score more; a gap scores less.
public enum Fuzzy {
    public struct Match: Sendable, Equatable {
        public var score: Int
        /// The matched characters, as offsets into the text.
        public var positions: [Int]
    }

    public static func match(_ query: String, in text: String) -> Match? {
        let needle = Array(Slugs.search(query).filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return Match(score: 0, positions: []) }
        let haystack = Array(Slugs.search(text))
        let original = Array(text)
        guard haystack.count == original.count else { return nil }
        let n = haystack.count, m = needle.count
        guard m <= n else { return nil }
        // best[i][j]: the best score with letter i of the query at j.
        let none = Int.min / 2
        var best = Array(repeating: Array(repeating: none, count: n), count: m)
        var from = Array(repeating: Array(repeating: -1, count: n), count: m)
        for i in 0..<m {
            for j in i..<n where haystack[j] == needle[i] {
                let own = 1 + (j == 0 ? 8 : isBoundary(original, j) ? 6 : 0)
                if i == 0 {
                    best[i][j] = own
                    continue
                }
                for k in (i - 1)..<j where best[i - 1][k] > none {
                    let step = k == j - 1 ? 5 : -min(4, j - k - 1)
                    let score = best[i - 1][k] + own + step
                    if score > best[i][j] {
                        best[i][j] = score
                        from[i][j] = k
                    }
                }
            }
        }
        guard let last = (0..<n).max(by: { best[m - 1][$0] < best[m - 1][$1] }), best[m - 1][last] > none else { return nil }
        var positions = [last]
        for i in stride(from: m - 1, to: 0, by: -1) { positions.insert(from[i][positions[0]], at: 0) }
        // Shorter texts win a tie: "Sync" over "Sync Now and Push".
        return Match(score: best[m - 1][last] - n / 12, positions: positions)
    }

    /// The start of a word: after a space or punctuation, or a capital after a small letter.
    private static func isBoundary(_ text: [Character], _ at: Int) -> Bool {
        let before = text[at - 1]
        if before.isWhitespace || "-_/.:›(".contains(before) { return true }
        return text[at].isUppercase && before.isLowercase
    }
}
