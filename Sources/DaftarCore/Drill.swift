import Foundation

/// Spaced-repetition drills from the notes as they are: a card is a heading
/// of a note, its section is the answer, and the note's title and the
/// headings above it are the context. Drilling never writes a note; what was
/// rated, and when each card is due, is Daftar's own state, kept per vault
/// in `$XDG_STATE_HOME/daftar/drill-<hash>.json` (`~/.local/state` without
/// it), the file `daftar-cli drill` and its MCP tools read and write, so the
/// app, the command line and an agent share one review history. A port of
/// `drill.rs` in notes-linux: the same cards, ids, schedule and file.
///
/// Which headings are cards, on notes of questions and answers (a `###`
/// question under a `##` part, a `##` problem whose `### The Problem`,
/// `### Test Cases` and `### Solution` belong to it, a `####` example):
///
/// - A **part** of an answer is a heading named as one: Example(s) (and one
///   starting "Example" or "Worked example"), Problem, The Problem, Test
///   Cases, Tests, Solution(s) (and any ending in "Solution(s)", as "Two
///   Solutions"), Answer, Code, Output, Explanation, Hint(s). A part is never
///   a card: it is the answer of the heading above it, with its heading.
/// - A **reference** heading (Related notes, Related, See also, Sources,
///   References, Links, Further reading) is never a card and is left out of
///   every answer.
/// - Every other heading is a card when its answer has text: its own lines,
///   and the parts under it, but not the headings under it that are cards
///   themselves, nor references.
/// - The text above the first heading is no card, and a folder note
///   (`Interview-Preparation/Interview-Preparation.md`) is left out of a
///   folder's deck: it is the folder's index.
///
/// A card is known by its note and its heading path, written as Obsidian
/// links to a nested heading: `Notes/Go.md#Part 1#Q1. What is a goroutine?`.
/// Changing the answer keeps the card's history; renaming a heading above it
/// starts the card again.
///
/// The schedule is SuperMemo's SM-2 (Woźniak, 1990), with its quality grades
/// on four buttons: Again is 2 (forgotten), Hard 3, Good 4, Easy 5. A
/// forgotten card starts its repetitions again at one day and keeps its
/// ease; any other grade changes the ease by
/// `0.1 - (5 - q) * (0.08 + (5 - q) * 0.02)`, never under 1.3, and the
/// interval is 1 day, then 6, then the last one times the ease.
public enum Drill {
    /// The folder a deck is read from when none is named.
    public static let folder = "Learning/Interview-Preparation"
    /// New cards a session takes at most.
    public static let newCards = 10
    /// Cards a session takes at most, due and new, as `daftar-cli drill`.
    public static let limit = 100

    /// A part of the answer of the heading above it.
    public static func isPart(_ heading: String) -> Bool {
        let text = plain(heading)
        return parts.contains(text) || text.hasPrefix("example") || text.hasPrefix("worked example")
            || text.hasSuffix(" solution") || text.hasSuffix(" solutions")
    }

    /// A list of links or sources: no card, and no part of an answer.
    public static func isReference(_ heading: String) -> Bool {
        references.contains(plain(heading))
    }

    private static let parts: Set<String> = [
        "example", "examples", "problem", "the problem", "test cases", "tests", "solution", "solutions", "answer", "the answer", "code",
        "output", "explanation", "hint", "hints", "the solution",
    ]
    private static let references: Set<String> = ["related notes", "related", "see also", "sources", "references", "links", "further reading"]

    /// The heading as the rules compare it: lowercase, without emphasis
    /// marks or a closing colon.
    private static func plain(_ heading: String) -> String {
        var text = String(heading.unicodeScalars.filter { $0 != "*" && $0 != "_" && $0 != "`" })
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(":") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The cards of the note at [path] whose text is [text], in its order.
    public static func cards(path: String, text: String) -> [DrillCard] {
        let lines = Sections.lines(text).lines
        let headings = Sections.headings(lines: lines)
        let count = headings.count
        var parent = [Int?](repeating: nil, count: count)
        var children = [[Int]](repeating: [], count: count)
        var open: [Int] = []
        for (index, heading) in headings.enumerated() {
            while let top = open.last, headings[top].level >= heading.level { open.removeLast() }
            if let top = open.last {
                parent[index] = top
                children[top].append(index)
            }
            open.append(index)
        }
        let hasText = { (kept: [Int]) in kept.contains { $0 < lines.count && !lines[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        // Each heading's answer lines and whether it is a card, from the
        // last heading up, since a heading's answer depends on its children.
        var kept = [[Int]](repeating: [], count: count)
        var card = [Bool](repeating: false, count: count)
        for index in stride(from: count - 1, through: 0, by: -1) {
            let heading = headings[index]
            let end = Sections.end(of: index, in: headings, lineCount: lines.count)
            let firstChild = children[index].first.map { headings[$0].line } ?? end
            var answer = Array((heading.line + 1)..<max(heading.line + 1, firstChild))
            for child in children[index] {
                if card[child] || isReference(headings[child].text) || !hasText(kept[child]) { continue }
                answer.append(headings[child].line)
                answer.append(contentsOf: kept[child])
            }
            card[index] = !isPart(heading.text) && !isReference(heading.text) && hasText(answer)
            kept[index] = answer
        }
        let title = Vault.title(of: path)
        var seen = Set<String>()
        var cards: [DrillCard] = []
        for index in 0..<count where card[index] {
            var above: [String] = []
            var at = parent[index]
            while let up = at {
                above.append(headings[up].text)
                at = parent[up]
            }
            above.reverse()
            let id = path + "#" + (above + [headings[index].text]).joined(separator: "#")
            // Two headings of the same path are one card: the first.
            guard seen.insert(id).inserted else { continue }
            let answer = kept[index].compactMap { $0 < lines.count ? lines[$0] : nil }.joined(separator: "\n")
            cards.append(
                DrillCard(
                    id: id, path: path, line: headings[index].line, question: headings[index].text, context: [title] + above,
                    answer: trimmed(answer)))
        }
        return cards
    }

    /// Without the line breaks at either end and the white space at its end.
    private static func trimmed(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars[...]
        while scalars.first == "\n" { scalars.removeFirst() }
        while let last = scalars.last, last == "\n" || last.properties.isWhitespace { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    /// A folder note: `X/X.md`, the index of its folder.
    public static func isFolderNote(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 1, let name = parts.last else { return false }
        return Vault.title(of: String(name)) == parts[parts.count - 2]
    }

    /// The notes of [folder] at any depth, by path in the byte order the
    /// command line sorts them in, without its folder notes and what
    /// [hidden] leaves out.
    public static func notes(in index: VaultIndex, folder: String = Drill.folder, hidden: (String) -> Bool = { _ in false }) -> [String] {
        let folder = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = folder + "/"
        return index.notes.keys
            .filter { (folder.isEmpty || $0.hasPrefix(prefix)) && !isFolderNote($0) && !hidden($0) }
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /// The cards of the notes at [paths] under [root], read now.
    public static func deck(root: URL, paths: [String]) -> [DrillCard] {
        paths.flatMap { path -> [DrillCard] in
            guard let text = try? String(contentsOf: root.appending(path: path), encoding: .utf8) else { return [] }
            return cards(path: path, text: text)
        }
    }

    /// The cards to drill on [today]: the ones due, the longest overdue
    /// first, then at most [new] never rated, in the deck's order; at most
    /// [limit] in all.
    public static func due(_ cards: [DrillCard], state: DrillState, today: Day, new: Int = newCards, limit: Int = limit) -> [DrillCard] {
        let due = cards.enumerated().compactMap { offset, card in
            state.due(card).flatMap { $0 <= today ? (day: $0, offset: offset, card: card) : nil }
        }
        .sorted { ($0.day, $0.offset) < ($1.day, $1.offset) }
        .map(\.card)
        let fresh = cards.lazy.filter { state.due($0) == nil }.prefix(max(new, 0))
        return Array((due + fresh).prefix(max(limit, 0)))
    }

    /// When the next card of [cards] that is not due on [today] comes due:
    /// the day the done page names. Nil when none was rated.
    public static func nextDue(_ cards: [DrillCard], state: DrillState, after today: Day) -> Day? {
        cards.compactMap { state.due($0) }.filter { $0 > today }.min()
    }
}

/// One question: a heading and its section.
public struct DrillCard: Sendable, Equatable, Hashable, Identifiable {
    /// `path#Heading#Under it`, the card's name in the state file.
    public var id: String
    public var path: String
    /// The heading's line in the file, from 0.
    public var line: Int
    /// The heading's text.
    public var question: String
    /// The note's title, then the headings above this one, outermost first.
    public var context: [String]
    /// The section's Markdown, without the cards and references under it.
    public var answer: String

    public init(id: String, path: String, line: Int, question: String, context: [String], answer: String) {
        self.id = id
        self.path = path
        self.line = line
        self.question = question
        self.context = context
        self.answer = answer
    }
}

/// How well a card was remembered: the four buttons, 1 to 4.
public enum DrillRating: Int, Sendable, CaseIterable, Identifiable {
    case again = 1, hard, good, easy

    public var id: Int { rawValue }

    /// `1`–`4`, or the rating's name in any case.
    public init?(parsing text: String) {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "again": self = .again
        case "2", "hard": self = .hard
        case "3", "good": self = .good
        case "4", "easy": self = .easy
        default: return nil
        }
    }

    public var title: String {
        switch self {
        case .again: "Again"
        case .hard: "Hard"
        case .good: "Good"
        case .easy: "Easy"
        }
    }

    /// SM-2's quality grade, 0 to 5.
    var quality: Double { Double(rawValue + 1) }
}

/// What is known of a card that was rated.
public struct DrillReview: Sendable, Equatable {
    /// SM-2's E-Factor, from 1.3 up; 2.5 for a new card.
    public var ease: Double
    /// Days from the last rating to the next.
    public var interval: Int
    /// Ratings in a row that were not Again.
    public var reps: Int
    /// How many times it was forgotten.
    public var lapses: Int
    public var due: Day
    public var last: Day

    public init(ease: Double, interval: Int, reps: Int, lapses: Int, due: Day, last: Day) {
        self.ease = ease
        self.interval = interval
        self.reps = reps
        self.lapses = lapses
        self.due = due
        self.last = last
    }

    static let startEase = 2.5
    static let leastEase = 1.3

    /// The card after [rating] on [today], from what was known of it.
    public static func rate(_ previous: DrillReview?, _ rating: DrillRating, today: Day) -> DrillReview {
        let ease = previous?.ease ?? startEase, interval = previous?.interval ?? 0
        let reps = previous?.reps ?? 0, lapses = previous?.lapses ?? 0
        if rating == .again {
            return DrillReview(ease: ease, interval: 1, reps: 0, lapses: lapses + 1, due: today.adding(days: 1), last: today)
        }
        let q = rating.quality
        // Two places are enough, and keep the file's numbers short.
        let next = (max(ease + (0.1 - (5 - q) * (0.08 + (5 - q) * 0.02)), leastEase) * 100).rounded() / 100
        let count = reps + 1
        let days = switch count {
        case 1: 1
        case 2: 6
        default: Int((Double(max(interval, 1)) * next).rounded())
        }
        return DrillReview(ease: next, interval: days, reps: count, lapses: lapses, due: today.adding(days: days), last: today)
    }

    /// An interval as a button says it: `1 day`, `6 days`, `3 wk`, `4 mo`, `1.5 yr`.
    public static func spoken(days: Int) -> String {
        switch days {
        case ..<1: "now"
        case 1: "1 day"
        case ..<21: "\(days) days"
        case ..<60: "\(Int((Double(days) / 7).rounded())) wk"
        case ..<365: "\(Int((Double(days) / 30).rounded())) mo"
        default:
            String(format: "%.1f yr", Double(days) / 365).replacingOccurrences(of: ".0 ", with: " ")
        }
    }

    fileprivate var json: OrderedJSON {
        .object([
            ("ease", .number(Self.number(ease))), ("interval", .number(String(interval))), ("reps", .number(String(reps))),
            ("lapses", .number(String(lapses))), ("due", .string(due.description)), ("last", .string(last.description)),
        ])
    }

    /// A float as serde_json writes it: the shortest text that reads back,
    /// with `.0` on a whole number.
    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        let text = "\(value)"
        return text.contains(".") || text.contains("e") ? text : text + ".0"
    }

    /// A review from the file: nil when a field it needs is missing or not
    /// of its kind, as the command line reads it.
    fileprivate init?(json: OrderedJSON) {
        func number(_ key: String) -> String? {
            if case .number(let text)? = json[key] { return text }
            return nil
        }
        func day(_ key: String) -> Day? {
            if case .string(let text)? = json[key] { return Day(text) }
            return nil
        }
        // A whole number written as one, as `as_i64` and `as_u64` take it.
        func count(_ key: String) -> Int? { number(key).flatMap { Int($0) }.flatMap { (0...Int(UInt32.max)).contains($0) ? $0 : nil } }
        guard let ease = number("ease").flatMap(Double.init), ease.isFinite, let interval = number("interval").flatMap({ Int($0) }),
            let reps = count("reps"), let due = day("due"), let last = day("last")
        else { return nil }
        self.init(ease: max(ease, Self.leastEase), interval: interval, reps: reps, lapses: count("lapses") ?? 0, due: due, last: last)
    }
}

/// Every card's review, by its id: the state file's content.
public struct DrillState: Sendable, Equatable {
    public var reviews: [String: DrillReview] = [:]

    public init(reviews: [String: DrillReview] = [:]) { self.reviews = reviews }

    /// Daftar's state folder, as the command line finds it: `$XDG_STATE_HOME`
    /// when it is an absolute path, else `~/.local/state`, then `daftar`.
    public static func folder(
        environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let base = environment["XDG_STATE_HOME"].flatMap { $0.hasPrefix("/") ? URL(filePath: $0, directoryHint: .isDirectory) : nil }
        return (base ?? home.appending(path: ".local/state", directoryHint: .isDirectory)).appending(path: "daftar", directoryHint: .isDirectory)
    }

    /// The state file of the vault at [root] in [folder]: `drill-<hash>.json`,
    /// the hash FNV-1a of the vault's path as `reading_places::state_file`
    /// takes it, so the app and `daftar-cli` name the same file.
    public static func file(root: URL, in folder: URL = DrillState.folder()) -> URL {
        folder.appending(path: "drill-\(hash(root)).json")
    }

    /// FNV-1a of the vault's path, sixteen hex digits.
    static func hash(_ root: URL) -> String {
        var path = root.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let value = path.utf8.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01b3 }
        return String(format: "%016llx", value)
    }

    /// The state in [file]; empty when there is none or it cannot be read.
    public static func load(_ file: URL) -> DrillState {
        guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else { return DrillState() }
        return DrillState(text: text)
    }

    /// The state in the file's [text]; empty when it is not JSON.
    public init(text: String) {
        guard let value = try? OrderedJSON.parse(text), case .object(let cards)? = value["cards"] else { return }
        // A key written twice is the last one, as serde_json reads it.
        for (id, review) in cards {
            if let review = DrillReview(json: review) { reviews[id] = review } else { reviews[id] = nil }
        }
    }

    /// The file's text, as the command line writes it: `version`, then the
    /// cards by id in byte order, two spaces deep.
    public var text: String {
        let cards = reviews.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }.map { ($0.key, $0.value.json) }
        return OrderedJSON.object([("version", .number("1")), ("cards", .object(cards))]).text
    }

    /// Writes the state to [file] through a temporary file and a rename, so
    /// a reader never sees half a file.
    public func save(_ file: URL) throws {
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appending(path: ".\(file.lastPathComponent).daftar-\(ProcessInfo.processInfo.processIdentifier)")
        try Data(text.utf8).write(to: temporary)
        if rename(temporary.path(percentEncoded: false), file.path(percentEncoded: false)) != 0 {
            let error = errno
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)])
        }
    }

    /// Rates the card [id] on [today], and its review after.
    @discardableResult
    public mutating func rate(_ id: String, _ rating: DrillRating, today: Day) -> DrillReview {
        let review = DrillReview.rate(reviews[id], rating, today: today)
        reviews[id] = review
        return review
    }

    /// Rates the card [id] in [file]: the file is read again first, so a
    /// rating `daftar-cli` or an agent made since is kept, then written.
    /// Answers the state as written and the card's review.
    public static func rate(_ id: String, _ rating: DrillRating, today: Day, in file: URL) throws -> (state: DrillState, review: DrillReview) {
        var state = load(file)
        let review = state.rate(id, rating, today: today)
        try state.save(file)
        return (state, review)
    }

    /// The day [card] is due, or nil for a card never rated.
    public func due(_ card: DrillCard) -> Day? { reviews[card.id]?.due }
}

/// A session of drill: the cards due, asked one by one, as `daftar-cli
/// drill` asks them. A card rated Again comes back at the end of the
/// session, as SM-2 repeats what was forgotten, but only its first rating
/// counts: the state is written for that one alone.
public struct DrillSession: Sendable, Equatable {
    public struct Turn: Sendable, Equatable {
        public var card: DrillCard
        /// Asked again after it was forgotten in this session.
        public var again: Bool
    }

    private(set) var queue: [Turn]
    /// The cards the session started with.
    public let total: Int
    /// The cards rated for the first time.
    public private(set) var rated = 0
    /// The cards forgotten on their first rating.
    public private(set) var forgotten = 0

    public init(cards: [DrillCard]) {
        queue = cards.map { Turn(card: $0, again: false) }
        total = cards.count
    }

    /// The card asked now; nil when the session is done.
    public var current: Turn? { queue.first }
    public var isDone: Bool { queue.isEmpty }
    /// Cards still to be asked, those asked again too.
    public var left: Int { queue.count }

    /// Rates the card asked now and goes on to the next. Answers whether
    /// the rating is the card's first, to be written to the state.
    @discardableResult
    public mutating func rate(_ rating: DrillRating) -> Bool {
        guard let turn = queue.first else { return false }
        queue.removeFirst()
        if !turn.again { rated += 1 }
        if rating == .again {
            if !turn.again { forgotten += 1 }
            queue.append(Turn(card: turn.card, again: true))
        }
        return !turn.again
    }
}
