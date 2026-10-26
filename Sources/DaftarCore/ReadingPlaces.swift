import Foundation

/// Where each note was being read: the source line of the reading cursor,
/// kept across launches so a note opens where it was left. The notes read
/// last are kept, up to [limit]; a move or a rename takes its place along.
public struct ReadingPlaces: Sendable, Equatable {
    public static let limit = 1000

    private var lines: [String: Int] = [:]
    /// Read first to read last.
    private var order: [String] = []

    public init() {}

    public subscript(path: String) -> Int? { lines[path] }

    public var count: Int { lines.count }

    public mutating func set(_ path: String, line: Int) {
        if lines.updateValue(line, forKey: path) != nil {
            if order.last == path { return }
            order.removeAll { $0 == path }
        }
        order.append(path)
        while order.count > Self.limit { lines[order.removeFirst()] = nil }
    }

    /// After a move or a rename: [moves] maps each file's old path to its new one.
    public mutating func moved(_ moves: [String: String]) {
        guard moves.keys.contains(where: { lines[$0] != nil }) else { return }
        var next: [String: Int] = [:]
        for (path, line) in lines { next[moves[path] ?? path] = line }
        lines = next
        order = order.map { moves[$0] ?? $0 }
    }

    /// After a delete: the file, or every file in the folder.
    public mutating func forget(_ path: String) {
        let gone = { (other: String) in other == path || other.hasPrefix(path + "/") }
        order.removeAll(where: gone)
        lines = lines.filter { !gone($0.key) }
    }

    // MARK: The file

    private struct File: Codable {
        var places: [[String: Int]]
    }

    /// `{"places": [{"Folder/Note.md": 12}, …]}`, read first to read last.
    public var data: Data {
        let file = File(places: order.compactMap { path in lines[path].map { [path: $0] } })
        return (try? JSONEncoder().encode(file)) ?? Data()
    }

    /// Places from [data]; none from a file that is missing or broken.
    public init(data: Data) {
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return }
        for entry in file.places {
            for (path, line) in entry { set(path, line: line) }
        }
    }
}
