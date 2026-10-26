import Foundation

/// A file that git left with conflict marks, in parts: plain text, and the
/// conflicts between `<<<<<<<` and `>>>>>>>`, with diff3's `|||||||` base
/// when it is there. Daftar only rebases, and in a rebase the side above
/// `=======` is the remote's ("ours", the upstream the commits are replayed
/// on) and the side below is the person's own commit ("theirs"); the names
/// here say that, so no view has to.
public enum ConflictText {
    public struct Conflict: Sendable, Equatable {
        /// The upstream's lines, above `=======`, each with its line end.
        public var remote: String
        /// The person's lines, below `=======`.
        public var mine: String
        /// diff3's common ancestor, between `|||||||` and `=======`.
        public var base: String?
        /// The mark lines as they were, so an open conflict is written back unchanged.
        public var open: String
        public var baseMark: String?
        public var separator: String
        public var close: String

        /// What follows `>>>>>>>`: in a rebase, the commit being replayed.
        public var mineLabel: String { label(close) }
        /// What follows `<<<<<<<`: in a rebase, usually the upstream's commit.
        public var remoteLabel: String { label(open) }

        private func label(_ mark: String) -> String {
            mark.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// The conflict as git wrote it, marks and all.
        public var marked: String { open + remote + (baseMark.map { $0 + (base ?? "") } ?? "") + separator + mine + close }
    }

    public enum Part: Sendable, Equatable {
        case plain(String)
        case conflict(Conflict)
    }

    /// Which side of a conflict to keep.
    public enum Choice: Sendable, Equatable, CaseIterable {
        case remote, mine
        /// The remote's lines, then the person's.
        case both
    }

    /// [text] in parts. Text with no complete conflict is one plain part,
    /// and a mark that starts a conflict that never ends is plain text too.
    public static func parse(_ text: String) -> [Part] {
        var parts: [Part] = []
        var plain = ""
        func flush() {
            if !plain.isEmpty { parts.append(.plain(plain)) }
            plain = ""
        }
        let lines = lines(of: text)
        var index = 0
        while index < lines.count {
            guard isMark(lines[index], "<"), let (conflict, next) = conflict(in: lines, from: index) else {
                plain += lines[index]
                index += 1
                continue
            }
            flush()
            parts.append(.conflict(conflict))
            index = next
        }
        flush()
        return parts.isEmpty ? [.plain(text)] : parts
    }

    /// The conflicts in [text], in order.
    public static func conflicts(in text: String) -> [Conflict] {
        parse(text).compactMap { if case let .conflict(conflict) = $0 { conflict } else { nil } }
    }

    /// The text with the [choices] made, the n-th for the n-th conflict. A
    /// conflict with no choice keeps its marks.
    public static func resolve(_ parts: [Part], choices: [Int: Choice]) -> String {
        var out = ""
        var number = 0
        for part in parts {
            switch part {
            case let .plain(text):
                out += text
            case let .conflict(conflict):
                switch choices[number] {
                case .remote: out += conflict.remote
                case .mine: out += conflict.mine
                case .both: out += conflict.remote + conflict.mine
                case nil: out += conflict.marked
                }
                number += 1
            }
        }
        return out
    }

    /// The text with one [choice] for every conflict.
    public static func resolve(_ parts: [Part], all choice: Choice) -> String {
        let count = parts.count { if case .conflict = $0 { true } else { false } }
        return resolve(parts, choices: Dictionary(uniqueKeysWithValues: (0..<count).map { ($0, choice) }))
    }

    /// The conflict that starts at [start], and the line after its end.
    private static func conflict(in lines: [String], from start: Int) -> (Conflict, Int)? {
        var remote = "", base: String?, mine = ""
        var baseMark: String?, separator: String?
        var index = start + 1
        while index < lines.count {
            let line = lines[index]
            if separator == nil {
                if isMark(line, "=") {
                    separator = line
                } else if isMark(line, "|"), baseMark == nil {
                    baseMark = line
                    base = ""
                } else if baseMark != nil {
                    base! += line
                } else if isMark(line, "<") {
                    // Another conflict starts before this one has a middle: this one is broken.
                    return nil
                } else {
                    remote += line
                }
            } else if isMark(line, ">") {
                return (Conflict(remote: remote, mine: mine, base: base, open: lines[start], baseMark: baseMark, separator: separator!, close: line), index + 1)
            } else if isMark(line, "<") || isMark(line, "=") {
                return nil
            } else {
                mine += line
            }
            index += 1
        }
        return nil
    }

    /// Seven of [mark] alone, or followed by a space and a label. `=======`
    /// takes no label.
    static func isMark(_ line: Substring, _ mark: Character) -> Bool {
        // Scalars, not characters: "\r\n" is one character.
        var scalars = line.unicodeScalars[...]
        while let last = scalars.last, last == "\n" || last == "\r" { scalars = scalars.dropLast() }
        let body = Substring(scalars)
        guard body.count >= 7, body.prefix(7).allSatisfy({ $0 == mark }) else { return false }
        let rest = body.dropFirst(7)
        if mark == "=" { return rest.isEmpty }
        return rest.isEmpty || rest.first == " "
    }

    static func isMark(_ line: String, _ mark: Character) -> Bool { isMark(line[...], mark) }

    /// The lines of [text], each with its line end; the last may have none.
    static func lines(of text: String) -> [String] {
        var lines: [String] = []
        // Scalars, not characters: "\r\n" is one character, and not "\n".
        let scalars = text.unicodeScalars
        var start = scalars.startIndex
        while let end = scalars[start...].firstIndex(of: "\n") {
            let next = scalars.index(after: end)
            lines.append(String(scalars[start..<next]))
            start = next
        }
        if start < scalars.endIndex { lines.append(String(scalars[start...])) }
        return lines
    }
}
