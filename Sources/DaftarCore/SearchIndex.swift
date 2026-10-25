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
                path UNINDEXED, title, body,
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
            sqlite3_prepare_v2(db, "INSERT INTO note_fts (path, title, body) VALUES (?, ?, ?)", -1, &statement, nil)
            sqlite3_bind_text(statement, 1, path, -1, Self.transient)
            sqlite3_bind_text(statement, 2, title, -1, Self.transient)
            sqlite3_bind_text(statement, 3, body, -1, Self.transient)
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
    }

    public func remove(path: String) {
        lock.withLock { delete(path) }
    }

    private func delete(_ path: String) {
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM note_fts WHERE path = ?", -1, &statement, nil)
        sqlite3_bind_text(statement, 1, path, -1, Self.transient)
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    public func transaction(_ work: () -> Void) {
        exec("BEGIN")
        work()
        exec("COMMIT")
    }

    /// Notes that hold every word of [query], best first. Each word matches as
    /// a prefix, and a quoted phrase matches as written.
    public func search(_ query: String, limit: Int = 100) -> [Hit] {
        guard let match = Self.matchExpression(query) else { return [] }
        return lock.withLock {
            var statement: OpaquePointer?
            let sql = """
                SELECT path, snippet(note_fts, 2, char(1), char(2), '…', 16)
                FROM note_fts WHERE note_fts MATCH ?
                ORDER BY bm25(note_fts, 0, 8, 1) LIMIT ?
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
