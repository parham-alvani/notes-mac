import Foundation
import SQLite3

/// Full-text search over one vault, in an SQLite FTS5 table held in memory.
///
/// In memory because the vault on disk is the record: the index is built
/// again at each launch (a few seconds for a few thousand notes) and kept in
/// step with the files after that, so it has no schema to migrate and cannot
/// disagree with the files for longer than one change.
public final class SearchIndex: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    /// Each note's row. `path` is not indexed, so a delete by path reads
    /// the whole table: at every put, that made the first build of a
    /// 20,000-note vault take a minute.
    private var rows: [String: Int64] = [:]

    public struct Hit: Sendable, Hashable {
        public var path: String
        /// The matching text, with the words between `\u{1}` and `\u{2}`.
        public var snippet: String

        public init(path: String, snippet: String) {
            self.path = path
            self.snippet = snippet
        }
    }

    public init() {
        sqlite3_open(":memory:", &db)
        exec("""
            CREATE VIRTUAL TABLE note_fts USING fts5(
                path UNINDEXED, title, body, folded,
                tokenize = 'unicode61 remove_diacritics 2'
            )
            """)
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public func put(path: String, title: String, body: String) {
        lock.withLock {
            delete(path)
            var statement: OpaquePointer?
            // Persian as a search finds it, when that is not the text itself:
            // matched, never shown, so a snippet keeps the note's own letters.
            let (titleFolded, bodyFolded) = (Self.persian(title), Self.persian(body))
            let folded = titleFolded == title && bodyFolded == body ? "" : titleFolded + "\n" + bodyFolded
            sqlite3_prepare_v2(db, "INSERT INTO note_fts (path, title, body, folded) VALUES (?, ?, ?, ?)", -1, &statement, nil)
            sqlite3_bind_text(statement, 1, path, -1, Self.transient)
            sqlite3_bind_text(statement, 2, title, -1, Self.transient)
            sqlite3_bind_text(statement, 3, body, -1, Self.transient)
            sqlite3_bind_text(statement, 4, folded, -1, Self.transient)
            if sqlite3_step(statement) == SQLITE_DONE { rows[path] = sqlite3_last_insert_rowid(db) }
            sqlite3_finalize(statement)
        }
    }

    public func remove(path: String) {
        lock.withLock { delete(path) }
    }

    private func delete(_ path: String) {
        guard let row = rows.removeValue(forKey: path) else { return }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM note_fts WHERE rowid = ?", -1, &statement, nil)
        sqlite3_bind_int64(statement, 1, row)
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    public func transaction(_ work: () -> Void) {
        exec("BEGIN")
        work()
        exec("COMMIT")
    }

    /// Notes that hold every word of [query], best first. Each word matches as
    /// a prefix, and a quoted phrase matches as written. The words side by
    /// side, as typed, come first; then the words near each other; then the
    /// notes that hold them anywhere. Within each, the title counts most.
    public func search(_ query: String, limit: Int = 100) -> [Hit] {
        let tiers = Self.matchTiers(Self.persian(query))
        guard !tiers.isEmpty else { return [] }
        return lock.withLock {
            var hits: [Hit] = []
            var seen = Set<String>()
            for match in tiers where hits.count < limit {
                for hit in run(match, limit: limit) where seen.insert(hit.path).inserted {
                    hits.append(hit)
                    if hits.count == limit { break }
                }
            }
            return hits
        }
    }

    private func run(_ match: String, limit: Int) -> [Hit] {
        var statement: OpaquePointer?
        let sql = """
            SELECT path, snippet(note_fts, 2, char(1), char(2), '…', 16)
            FROM note_fts WHERE note_fts MATCH ?
            ORDER BY bm25(note_fts, 0, 8, 1, 1) LIMIT ?
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, match, -1, Self.transient)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var hits: [Hit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let path = String(cString: sqlite3_column_text(statement, 0))
            let snippet = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            hits.append(Hit(path: path, snippet: snippet))
        }
        return hits
    }

    /// Persian letters as `Slugs.persianLetter` makes them one, with the
    /// half space (ZWNJ) taken out: `می‌خواهم` is found as `میخواهم` too,
    /// while the tokenizer, which splits at a ZWNJ, finds `می خواهم` in the
    /// text.
    static func persian(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { (0x0600...0x06FF).contains($0.value) || $0.value == 0x200C }) else { return text }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where scalar.value != 0x200C { scalars.append(Slugs.persianLetter(scalar)) }
        return String(scalars)
    }

    /// The FTS5 expressions [search] runs, best first: with two or more
    /// unquoted words, the words as one phrase (the last one a prefix, as it
    /// may be half typed) and the words within ten of each other, before
    /// [matchExpression]'s every word anywhere.
    static func matchTiers(_ query: String) -> [String] {
        guard let every = matchExpression(query) else { return [] }
        let words = query.contains("\"") ? [] : query.split(whereSeparator: \.isWhitespace).map { $0.replacingOccurrences(of: "\"", with: "") }
        guard words.count > 1 else { return [every] }
        let quoted = words.map { "\"\($0)\"" }
        let phrase = quoted.dropLast().joined(separator: " + ") + " + " + quoted.last! + "*"
        let near = "NEAR(" + quoted.dropLast().joined(separator: " ") + " " + quoted.last! + "*, 10)"
        return [phrase, near, every]
    }

    /// The person's words as an FTS5 expression. Every word is quoted, so
    /// that `AND`, `-` or a `:` in what they type is a word and not syntax.
    static func matchExpression(_ query: String) -> String? {
        var terms: [String] = []
        var phrase = ""
        var inPhrase = false
        func flush(_ word: String, prefix: Bool) {
            let clean = word.replacingOccurrences(of: "\"", with: "")
            guard !clean.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            terms.append("\"\(clean)\"" + (prefix ? "*" : ""))
        }
        var word = ""
        for ch in query {
            if ch == "\"" {
                if inPhrase { flush(phrase, prefix: false); phrase = "" } else { flush(word, prefix: true); word = "" }
                inPhrase.toggle()
            } else if inPhrase {
                phrase.append(ch)
            } else if ch.isWhitespace {
                flush(word, prefix: true)
                word = ""
            } else {
                word.append(ch)
            }
        }
        flush(inPhrase ? phrase : word, prefix: !inPhrase)
        return terms.isEmpty ? nil : terms.joined(separator: " AND ")
    }
}
