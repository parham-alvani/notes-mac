import Foundation

/// The lines that one text of a note adds and removes from another, as
/// `git diff` shows them, for a note's history.
public enum LineDiff {
    public enum Kind: Sendable { case same, added, removed }

    public struct Line: Sendable, Equatable {
        public var kind: Kind
        public var text: String
        /// The line's number, from 1, in the old text and in the new one.
        public var old: Int?
        public var new: Int?
    }

    /// Every line of [old] and [new], each removed, added or the same.
    public static func lines(from old: String, to new: String) -> [Line] {
        func split(_ text: String) -> [String] {
            var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
            if lines.last == "" { lines.removeLast() }
            return lines
        }
        let a = split(old), b = split(new)
        let difference = b.difference(from: a)
        var removed = Set<Int>(), added = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): added.insert(offset)
            }
        }
        var result: [Line] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                result.append(Line(kind: .removed, text: a[i], old: i + 1))
                i += 1
            } else if j < b.count, added.contains(j) {
                result.append(Line(kind: .added, text: b[j], new: j + 1))
                j += 1
            } else if i < a.count, j < b.count {
                result.append(Line(kind: .same, text: a[i], old: i + 1, new: j + 1))
                i += 1
                j += 1
            } else {
                break
            }
        }
        return result
    }

    /// The changed lines with [context] lines around them, a run of changes
    /// apart from the next when more than twice [context] lines lie between.
    public static func hunks(_ lines: [Line], context: Int = 3) -> [[Line]] {
        let changed = lines.indices.filter { lines[$0].kind != .same }
        guard let first = changed.first else { return [] }
        var ranges: [ClosedRange<Int>] = []
        var current = max(0, first - context)...min(lines.count - 1, first + context)
        for index in changed.dropFirst() {
            let range = max(0, index - context)...min(lines.count - 1, index + context)
            if range.lowerBound <= current.upperBound + 1 {
                current = current.lowerBound...range.upperBound
            } else {
                ranges.append(current)
                current = range
            }
        }
        ranges.append(current)
        return ranges.map { Array(lines[$0]) }
    }

    /// How many lines [lines] adds and removes.
    public static func counts(_ lines: [Line]) -> (added: Int, removed: Int) {
        (lines.count { $0.kind == .added }, lines.count { $0.kind == .removed })
    }
}
