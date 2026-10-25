import Foundation

/// Obsidian's bookmarks, `.obsidian/bookmarks.json`: files, folders,
/// searches, headings and groups of them. Daftar shows the files and
/// folders and adds or removes files; every other item is written back as
/// it was read, so the file stays Obsidian's.
public struct Bookmarks: @unchecked Sendable {
    /// The items as JSON objects, in the file's order.
    public var items: [[String: Any]] = []

    public struct Entry: Sendable, Equatable {
        public var path: String
        public var title: String?
        /// The group it is in, when it is in one.
        public var group: String?
        public var folder: Bool
    }

    public enum Failure: LocalizedError, Equatable {
        /// The file is there but could not be read, so it is not written over.
        case unreadable

        public var errorDescription: String? { "bookmarks.json could not be read, so it is left as it is" }
    }

    /// True when the file was there but could not be read: the bookmarks
    /// are empty, and `save` refuses rather than lose the file.
    public private(set) var unreadable = false

    public init(items: [[String: Any]] = []) { self.items = items }

    static func url(_ root: URL) -> URL { root.appending(path: ".obsidian/bookmarks.json") }

    /// No file is no bookmarks yet; a file that does not read is `unreadable`.
    public static func load(_ root: URL) -> Bookmarks {
        let url = url(root)
        guard FileManager.default.fileExists(atPath: url.path) else { return Bookmarks() }
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let items = object["items"] as? [[String: Any]]
        else {
            var bookmarks = Bookmarks()
            bookmarks.unreadable = true
            return bookmarks
        }
        return Bookmarks(items: items)
    }

    public func save(_ root: URL) throws {
        guard !unreadable else { throw Failure.unreadable }
        let data = try JSONSerialization.data(withJSONObject: ["items": items], options: [.prettyPrinted, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: Self.url(root).deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: Self.url(root), options: .atomic)
    }

    /// The files and folders, groups opened, in order.
    public var entries: [Entry] {
        func walk(_ items: [[String: Any]], group: String?) -> [Entry] {
            items.flatMap { item -> [Entry] in
                switch item["type"] as? String {
                case "file", "folder":
                    guard let path = item["path"] as? String else { return [] }
                    return [Entry(path: path, title: item["title"] as? String, group: group, folder: item["type"] as? String == "folder")]
                case "group":
                    return walk(item["items"] as? [[String: Any]] ?? [], group: item["title"] as? String ?? group)
                default:
                    return []
                }
            }
        }
        return walk(items, group: nil)
    }

    public func contains(_ path: String) -> Bool { entries.contains { !$0.folder && $0.path == path } }

    /// Adds a file at the end, or removes it from wherever it is.
    public mutating func toggle(_ path: String, now: Date = Date()) {
        if contains(path) {
            remove(path)
        } else {
            items.append(["type": "file", "ctime": Int64(now.timeIntervalSince1970 * 1000), "path": path])
        }
    }

    /// Takes away every bookmark of [path], or of anything in it when it is a folder.
    public mutating func remove(_ path: String) {
        func keep(_ items: [[String: Any]]) -> [[String: Any]] {
            items.compactMap { item in
                if let bookmarked = item["path"] as? String, ["file", "folder"].contains(item["type"] as? String),
                    bookmarked == path || bookmarked.hasPrefix(path + "/")
                {
                    return nil
                }
                guard item["type"] as? String == "group", let inner = item["items"] as? [[String: Any]] else { return item }
                var group = item
                group["items"] = keep(inner)
                return group
            }
        }
        items = keep(items)
    }

    /// After files moved, each bookmark goes where its file went. Returns
    /// whether anything changed.
    @discardableResult
    public mutating func follow(_ moves: [String: String], folder: (from: String, to: String)? = nil) -> Bool {
        var changed = false
        func move(_ items: [[String: Any]]) -> [[String: Any]] {
            items.map { item in
                var item = item
                if let path = item["path"] as? String {
                    if let new = moves[path] {
                        item["path"] = new
                        changed = true
                    } else if let folder, path == folder.from || path.hasPrefix(folder.from + "/") {
                        item["path"] = folder.to + path.dropFirst(folder.from.count)
                        changed = true
                    }
                }
                if let inner = item["items"] as? [[String: Any]] { item["items"] = move(inner) }
                return item
            }
        }
        items = move(items)
        return changed
    }
}
