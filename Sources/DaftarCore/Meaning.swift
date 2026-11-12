import Foundation

/// Search by meaning, by `daftar-cli`: its model (531 MB, downloaded once,
/// when the person asks) embeds every section of a note, so a query finds
/// the notes that say the same thing in other words, Persian and English
/// alike. The app runs the command and reads its JSON; nothing here runs it.
/// The spec is `meaning-search.md` in notes-linux's `docs/specs`.
public enum Meaning {
    /// One place the command found: a note, the 1-based line of its section,
    /// how near it is (higher is nearer) and a few words of it.
    public struct Hit: Decodable, Hashable, Sendable {
        public var path: String
        public var line: Int
        public var score: Double
        public var snippet: String

        public init(path: String, line: Int, score: Double, snippet: String) {
            self.path = path
            self.line = line
            self.score = score
            self.snippet = snippet
        }

        /// The line as the app counts them, from 0.
        public var zeroBasedLine: Int { max(0, line - 1) }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            path = try values.decode(String.self, forKey: .path)
            // A field left out is not a reason to drop the note.
            line = (try? values.decodeIfPresent(Int.self, forKey: .line)) ?? 1
            score = (try? values.decodeIfPresent(Double.self, forKey: .score)) ?? 0
            snippet = (try? values.decodeIfPresent(String.self, forKey: .snippet)) ?? ""
        }

        private enum CodingKeys: String, CodingKey {
            case path, line, score, snippet
        }
    }

    /// What the command prints: a JSON array of hits. Each note once, at its
    /// nearest section, in the command's order; a path that is empty, or
    /// that leaves the vault (`..`, `/`), is dropped.
    public static func hits(_ json: Data) throws -> [Hit] {
        let all = try JSONDecoder().decode([Hit].self, from: json)
        var seen = Set<String>()
        return all.filter { hit in
            let path = hit.path
            guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return false }
            return seen.insert(path).inserted
        }
    }

    /// The two searches: the words and the meaning ranked together, or the meaning alone.
    public enum Mode: Sendable {
        case together, only

        var flag: String {
            switch self {
            case .together: "--meaning"
            case .only: "--meaning-only"
            }
        }
    }

    /// `daftar-cli search`'s arguments. The query comes last, after `--`, so a
    /// query that starts with `-` is words, not an option.
    public static func searchArguments(vault: URL, query: String, mode: Mode = .only, limit: Int = 20) -> [String] {
        ["--vault", vault.path, "search", mode.flag, "--json", "-n", String(limit), "--", query]
    }

    /// `daftar-cli related`'s arguments: the notes nearest [note] that it does not link to yet.
    public static func relatedArguments(vault: URL, note: String, limit: Int = 10) -> [String] {
        ["--vault", vault.path, "related", "--json", "-n", String(limit), "--", note]
    }

    /// `daftar-cli semantic-index`'s arguments: brings the index up to the
    /// notes that changed, and with [download] gets the model first.
    public static func indexArguments(vault: URL, download: Bool = false) -> [String] {
        ["--vault", vault.path, "semantic-index"] + (download ? ["--download-model"] : [])
    }

    /// The exit code that says the model is not downloaded.
    public static let noModelStatus: Int32 = 3

    /// The notice for a `daftar-cli` that does not know the flags.
    public static let upgrade = "Search by meaning needs daftar-cli 0.23.0 or later: brew upgrade parham-alvani/tap/daftar-cli"

    /// Why a run gave no hits.
    public enum Failure: Error, Equatable, Sendable {
        /// The model is not downloaded: the app offers to download it.
        case noModel
        /// This `daftar-cli` does not know `--json`, `--meaning`, `related`
        /// or `semantic-index`: [upgrade] says what to do.
        case needsUpgrade
        /// Anything else, in the command's own words.
        case failed(String)

        public var message: String {
            switch self {
            case .noModel: "The model of search by meaning is not downloaded."
            case .needsUpgrade: Meaning.upgrade
            case .failed(let said): said
            }
        }
    }

    /// What a run that exited with [status] and printed [errors] on stderr
    /// failed of. A usage error about the flags or the commands this needs
    /// (clap's `error: unexpected argument '--json'`, `unrecognized
    /// subcommand 'related'`) is an old `daftar-cli`; exit 3, or an older
    /// one's "is not downloaded", is a missing model.
    public static func failure(status: Int32, errors: String) -> Failure {
        if status == noModelStatus { return .noModel }
        let lines = errors.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let usage = lines.first(where: { $0.lowercased().hasPrefix("error: ") }) {
            let known = ["'--json'", "'--meaning'", "'--meaning-only'", "'--download-model'", "'related'", "'semantic-index'"]
            if (usage.contains("unexpected argument") || usage.contains("unrecognized subcommand")) && known.contains(where: usage.contains) {
                return .needsUpgrade
            }
            return .failed("daftar-cli: " + usage.dropFirst("error: ".count))
        }
        if lines.contains(where: { $0.contains("is not downloaded") }) { return .noModel }
        guard let line = lines.last else { return .failed("daftar-cli failed (exit \(status)).") }
        return .failed(line.hasPrefix("daftar-cli: ") ? String(line.dropFirst("daftar-cli: ".count)) : line)
    }

    /// A step of a build, read from a line of its stderr.
    public enum Step: Equatable, Sendable {
        /// The model coming down: `40% of 531 MB`.
        case downloading(percent: Int)
        /// The notes or sections embedded: `indexed 120/4300`, `embedding 120/4300 sections`.
        case indexing(done: Int, total: Int)

        /// From 0 to 1.
        public var fraction: Double {
            switch self {
            case .downloading(let percent): Double(percent) / 100
            case .indexing(let done, let total): Double(done) / Double(total)
            }
        }
    }

    /// How far a build is, from a line of its stderr; any other line is nil.
    public static func progress(_ line: String) -> Step? {
        let line = line.trimmingCharacters(in: .whitespaces)
        if let range = line.range(of: "% of "), let percent = Int(line[..<range.lowerBound].split(separator: " ").last ?? "") {
            return .downloading(percent: max(0, min(100, percent)))
        }
        for word in ["indexed ", "embedding "] {
            guard let range = line.range(of: word) else { continue }
            let rest = line[range.upperBound...].prefix { $0.isNumber || $0 == "/" }
            let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, let done = Int(parts[0]), let total = Int(parts[1]), total > 0, done >= 0 else { continue }
            return .indexing(done: min(done, total), total: total)
        }
        return nil
    }
}
