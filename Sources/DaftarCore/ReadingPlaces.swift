import Foundation

/// What the app remembers of each note it showed, kept across launches:
/// the source line of the reading cursor, so a note opens where it was
/// left; the sections folded shut; and when the note was last read, so a
/// note changed by a pull since then can say so. The notes read last are
/// kept, up to [limit]; a move or a rename takes its entry along.
public struct ReadingPlaces: Sendable, Equatable {
    public static let limit = 1000

    public struct Entry: Sendable, Equatable {
        public var line: Int?
        /// Each folded heading as `level:text`, which an edit above it does not move.
        public var folds: [String]?
        /// When the note was last on screen.
        public var read: Date?
    }

    private var entries: [String: Entry] = [:]
    /// Read first to read last.
    private var order: [String] = []

    public init() {}

    public subscript(path: String) -> Int? { entries[path]?.line }

    public var count: Int { entries.count }

    public func folds(_ path: String) -> [String] { entries[path]?.folds ?? [] }

    public func lastRead(_ path: String) -> Date? { entries[path]?.read }

    public mutating func set(_ path: String, line: Int) {
        update(path) { $0.line = line }
    }

    public mutating func setFolds(_ path: String, _ folds: [String]) {
        update(path) { $0.folds = folds.isEmpty ? nil : folds }
    }

    public mutating func markRead(_ path: String, at date: Date = Date()) {
        // Whole seconds, as the file keeps them.
        update(path) { $0.read = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)) }
    }

    private mutating func update(_ path: String, _ change: (inout Entry) -> Void) {
        var entry = entries[path] ?? Entry()
        let before = entries[path]
        change(&entry)
        if before == entry { return }
        entries[path] = entry
        if before != nil {
            if order.last == path { return }
            order.removeAll { $0 == path }
        }
        order.append(path)
        while order.count > Self.limit { entries[order.removeFirst()] = nil }
    }

    /// After a move or a rename: [moves] maps each file's old path to its new one.
    public mutating func moved(_ moves: [String: String]) {
        guard moves.keys.contains(where: { entries[$0] != nil }) else { return }
        var next: [String: Entry] = [:]
        for (path, entry) in entries { next[moves[path] ?? path] = entry }
        entries = next
        order = order.map { moves[$0] ?? $0 }
    }

    /// After a delete: the file, or every file in the folder.
    public mutating func forget(_ path: String) {
        let gone = { (other: String) in other == path || other.hasPrefix(path + "/") }
        order.removeAll(where: gone)
        entries = entries.filter { !gone($0.key) }
    }

    // MARK: The file

    private struct File: Codable {
        /// The first format, lines only: `[{"Folder/Note.md": 12}]`.
        var places: [[String: Int]]?
        var notes: [Note]?
    }

    private struct Note: Codable {
        var path: String
        var line: Int?
        var folds: [String]?
        var read: Date?
    }

    /// `{"notes": [{"path": "Folder/Note.md", "line": 12, "folds": ["2:Plan"], "read": …}, …]}`, read first to read last.
    public var data: Data {
        let notes = order.compactMap { path in entries[path].map { Note(path: path, line: $0.line, folds: $0.folds, read: $0.read) } }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(File(notes: notes))) ?? Data()
    }

    /// Entries from [data]; none from a file that is missing or broken.
    public init(data: Data) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(File.self, from: data) else { return }
        for entry in file.places ?? [] {
            for (path, line) in entry { set(path, line: line) }
        }
        for note in file.notes ?? [] {
            update(note.path) { $0 = Entry(line: note.line, folds: note.folds, read: note.read) }
        }
    }
}
