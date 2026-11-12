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

    /// [match] for an ASCII query and text with no carriage return, on
    /// their bytes: the same scores and positions, without folding the
    /// text again or making arrays of its characters. Quick open runs it on
    /// every file at each key. Nil when the text has no match; the caller
    /// checks that both are such ASCII ([plainASCII]).
    static func matchASCII(_ query: UnsafeBufferPointer<UInt8>, in text: UnsafeBufferPointer<UInt8>) -> Match? {
        // The query as `Slugs.search` folds it, without whitespace.
        let needle = query.filter { !isSpace($0) }.map(lower)
        guard !needle.isEmpty else { return Match(score: 0, positions: []) }
        let n = text.count, m = needle.count
        guard m <= n else { return nil }
        let none = Int.min / 2
        return withUnsafeTemporaryAllocation(of: Int.self, capacity: 2 * m * n) { table in
            let best = UnsafeMutableBufferPointer(rebasing: table[0..<(m * n)])
            let from = UnsafeMutableBufferPointer(rebasing: table[(m * n)...])
            best.initialize(repeating: none)
            from.initialize(repeating: -1)
            for i in 0..<m {
                let letter = needle[i]
                for j in i..<n where lower(text[j]) == letter {
                    let own = 1 + (j == 0 ? 8 : isBoundaryASCII(text, j) ? 6 : 0)
                    if i == 0 {
                        best[j] = own
                        continue
                    }
                    let row = i * n, above = (i - 1) * n
                    for k in (i - 1)..<j where best[above + k] > none {
                        let step = k == j - 1 ? 5 : -min(4, j - k - 1)
                        let score = best[above + k] + own + step
                        if score > best[row + j] {
                            best[row + j] = score
                            from[row + j] = k
                        }
                    }
                }
            }
            let lastRow = (m - 1) * n
            guard let last = (0..<n).max(by: { best[lastRow + $0] < best[lastRow + $1] }), best[lastRow + last] > none else { return nil }
            var positions = [Int](repeating: 0, count: m)
            positions[m - 1] = last
            for i in stride(from: m - 1, to: 0, by: -1) { positions[i - 1] = from[i * n + positions[i]] }
            return Match(score: best[lastRow + last] - n / 12, positions: positions)
        }
    }

    /// ASCII with no carriage return: each byte is one character, as
    /// [matchASCII] needs (a CR before a LF would be one character).
    public static func plainASCII(_ text: String) -> Bool {
        text.utf8.allSatisfy { $0 < 0x80 && $0 != 0x0D }
    }

    @inline(__always) private static func lower(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
    }

    /// `Character.isWhitespace` for an ASCII byte.
    @inline(__always) private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
    }

    /// [isBoundary] for ASCII.
    @inline(__always) private static func isBoundaryASCII(_ text: UnsafeBufferPointer<UInt8>, _ at: Int) -> Bool {
        let before = text[at - 1]
        if isSpace(before) { return true }
        switch before {
        case 0x2D, 0x5F, 0x2F, 0x2E, 0x3A, 0x28: return true  // - _ / . : (
        default: break
        }
        let upper = text[at] >= 0x41 && text[at] <= 0x5A
        let small = before >= 0x61 && before <= 0x7A
        return upper && small
    }

    /// The start of a word: after a space or punctuation, or a capital after a small letter.
    private static func isBoundary(_ text: [Character], _ at: Int) -> Bool {
        let before = text[at - 1]
        if before.isWhitespace || "-_/.:›(".contains(before) { return true }
        return text[at].isUppercase && before.isLowercase
    }
}
