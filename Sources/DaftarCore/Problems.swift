import Foundation

/// One finding of `daftar-cli check`, `lint` or `fmt --check`, read from
/// their `--json` output: what `just audit` and `just check` report about a
/// note, at a line of it.
public struct Problem: Hashable, Sendable, Identifiable {
    public enum Tool: String, Sendable, CaseIterable {
        case check, lint, fmt
    }

    public enum Level: String, Sendable, Comparable {
        case error, warning

        public static func < (a: Level, b: Level) -> Bool { a == .error && b == .warning }
    }

    public var tool: Tool
    public var level: Level
    /// The note's vault path.
    public var path: String
    /// From 1; 0 is the whole file.
    public var line: Int
    /// From 1, when the tool knows it.
    public var column: Int?
    public var code: String
    public var message: String
    /// The tool's own fix mends it: `lint --fix`, `check --fix` or `fmt`.
    public var fixable: Bool

    public init(tool: Tool, level: Level, path: String, line: Int, column: Int? = nil, code: String, message: String, fixable: Bool = false) {
        self.tool = tool
        self.level = level
        self.path = path
        self.line = line
        self.column = column
        self.code = code
        self.message = message
        self.fixable = fixable
    }

    public var id: String { "\(tool.rawValue)|\(path)|\(line)|\(column ?? 0)|\(code)|\(message)" }

    /// The source line from 0 the note opens at, or nil for the whole file.
    public var sourceLine: Int? { line > 0 ? line - 1 : nil }
}

/// Reading, counting and grouping the findings.
public enum Problems {
    /// The findings of JSON Lines output, one object a line. A line that
    /// is not a finding -- blank, a progress line, an object without a
    /// path, a level or a tool this does not know -- is skipped, never an
    /// error: a newer `daftar-cli` may say more than this reads.
    public static func parse(_ output: String) -> [Problem] {
        var out: [Problem] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), let problem = finding(Data(trimmed.utf8)) else { continue }
            out.append(problem)
        }
        return out
    }

    private static func finding(_ data: Data) -> Problem? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tool = (object["tool"] as? String).flatMap(Problem.Tool.init(rawValue:)),
            let level = (object["level"] as? String).flatMap(Problem.Level.init(rawValue:)),
            let path = object["path"] as? String, !path.isEmpty
        else { return nil }
        return Problem(
            tool: tool, level: level, path: path,
            line: max(0, integer(object["line"]) ?? 0),
            column: integer(object["column"]).flatMap { $0 > 0 ? $0 : nil },
            code: object["code"] as? String ?? "",
            message: object["message"] as? String ?? "",
            fixable: object["fixable"] as? Bool ?? false)
    }

    /// A JSON number that is a whole number; `true` is not one, though
    /// `JSONSerialization` gives it as an `NSNumber` too.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, abs(double) < 1e15 else { return nil }
        return number.intValue
    }

    /// What the panel lists: errors, warnings or both.
    public enum Filter: String, Sendable, CaseIterable {
        case errors, warnings, all

        public func admits(_ problem: Problem) -> Bool {
            switch self {
            case .errors: problem.level == .error
            case .warnings: problem.level == .warning
            case .all: true
            }
        }
    }

    public struct Counts: Equatable, Sendable {
        public var errors = 0
        public var warnings = 0

        public init(errors: Int = 0, warnings: Int = 0) {
            self.errors = errors
            self.warnings = warnings
        }

        public var total: Int { errors + warnings }

        /// "2 errors, 1 warning", "No problems".
        public var spoken: String {
            guard total > 0 else { return "No problems" }
            func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
            return [errors > 0 ? count(errors, "error") : nil, warnings > 0 ? count(warnings, "warning") : nil]
                .compactMap { $0 }.joined(separator: ", ")
        }
    }

    public static func counts(_ problems: [Problem]) -> Counts {
        var counts = Counts()
        for problem in problems {
            if problem.level == .error { counts.errors += 1 } else { counts.warnings += 1 }
        }
        return counts
    }

    /// The findings of one note.
    public struct Note: Identifiable, Equatable, Sendable {
        public var path: String
        /// Errors first, then by line and column.
        public var problems: [Problem]
        public var counts: Counts
        public var id: String { path }
        /// Something in it a tool can mend.
        public var fixable: Bool { problems.contains(where: \.fixable) }
    }

    /// The findings the filter admits, by note: notes with errors first,
    /// then by path; in each note errors first, then by line. The same
    /// finding twice (two tools that say the same) is listed once.
    public static func grouped(_ problems: [Problem], filter: Filter = .all) -> [Note] {
        var seen = Set<String>()
        var byPath: [String: [Problem]] = [:]
        for problem in problems where filter.admits(problem) && seen.insert(problem.id).inserted {
            byPath[problem.path, default: []].append(problem)
        }
        let notes = byPath.map { path, list in
            Note(path: path, problems: list.sorted(by: order), counts: counts(list))
        }
        return notes.sorted { a, b in
            let aErrors = a.counts.errors > 0, bErrors = b.counts.errors > 0
            if aErrors != bErrors { return aErrors }
            return a.path.localizedStandardCompare(b.path) == .orderedAscending
        }
    }

    private static func order(_ a: Problem, _ b: Problem) -> Bool {
        if a.level != b.level { return a.level < b.level }
        if a.line != b.line { return a.line < b.line }
        if (a.column ?? 0) != (b.column ?? 0) { return (a.column ?? 0) < (b.column ?? 0) }
        return a.code < b.code
    }

    /// The findings of [path] by source line from 0, for the margin of the
    /// note on screen: errors first on each line. A finding of the whole
    /// file is on no line.
    public static func lines(_ problems: [Problem], of path: String) -> [Int: [Problem]] {
        var out: [Int: [Problem]] = [:]
        for problem in problems where problem.path == path {
            guard let line = problem.sourceLine else { continue }
            out[line, default: []].append(problem)
        }
        return out.mapValues { $0.sorted(by: order) }
    }
}
