import Foundation

/// Obsidian's bookmarks, `.obsidian/bookmarks.json`: files, folders,
/// searches, headings and groups of them. Daftar shows the files and
/// folders and adds or removes files; every other item is written back as
/// it was read, so the file stays Obsidian's.
public struct Bookmarks: Sendable, Equatable {
    /// The file as it was read, so every key Daftar does not know, and the
    /// order of all of them, is written back as it was.
    private var root: OrderedJSON = .object([("items", .array([]))])

    /// The items as JSON objects, in the file's order.
    public var items: [OrderedJSON] {
        get {
            if case .array(let items) = root["items"] { return items }
            return []
        }
        set { root["items"] = .array(newValue) }
    }

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

    public init(items: [OrderedJSON] = []) { self.items = items }

    static func url(_ root: URL) -> URL { root.appending(path: ".obsidian/bookmarks.json") }

    /// No file is no bookmarks yet; a file that does not read is `unreadable`.
    public static func load(_ root: URL) -> Bookmarks {
        let url = url(root)
        guard FileManager.default.fileExists(atPath: url.path) else { return Bookmarks() }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
            let json = try? OrderedJSON.parse(text), case .object = json, case .array = json["items"]
        else {
            var bookmarks = Bookmarks()
            bookmarks.unreadable = true
            return bookmarks
        }
        var bookmarks = Bookmarks()
        bookmarks.root = json
        return bookmarks
    }

    /// Written as Obsidian writes it: two spaces, the keys in their order.
    public func save(_ root: URL) throws {
        guard !unreadable else { throw Failure.unreadable }
        try FileManager.default.createDirectory(at: Self.url(root).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(self.root.text.utf8).write(to: Self.url(root), options: .atomic)
    }

    private static func string(_ item: OrderedJSON, _ key: String) -> String? {
        if case .string(let text) = item[key] { return text }
        return nil
    }

    private static func inner(_ item: OrderedJSON) -> [OrderedJSON]? {
        if case .array(let items) = item["items"] { return items }
        return nil
    }

    /// The files and folders, groups opened, in order.
    public var entries: [Entry] {
        func walk(_ items: [OrderedJSON], group: String?) -> [Entry] {
            items.flatMap { item -> [Entry] in
                switch Self.string(item, "type") {
                case "file", "folder":
                    guard let path = Self.string(item, "path") else { return [] }
                    return [Entry(path: path, title: Self.string(item, "title"), group: group, folder: Self.string(item, "type") == "folder")]
                case "group":
                    return walk(Self.inner(item) ?? [], group: Self.string(item, "title") ?? group)
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
            items.append(.object([
                ("type", .string("file")), ("ctime", .number(String(Int64(now.timeIntervalSince1970 * 1000)))), ("path", .string(path)),
            ]))
        }
    }

    /// Takes away every bookmark of [path], or of anything in it when it is a folder.
    public mutating func remove(_ path: String) {
        func keep(_ items: [OrderedJSON]) -> [OrderedJSON] {
            items.compactMap { item in
                if let bookmarked = Self.string(item, "path"), ["file", "folder"].contains(Self.string(item, "type")),
                    bookmarked == path || bookmarked.hasPrefix(path + "/")
                {
                    return nil
                }
                guard Self.string(item, "type") == "group", let inner = Self.inner(item) else { return item }
                var group = item
                group["items"] = .array(keep(inner))
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
        func move(_ items: [OrderedJSON]) -> [OrderedJSON] {
            items.map { item in
                var item = item
                if let path = Self.string(item, "path") {
                    if let new = moves[path] {
                        item["path"] = .string(new)
                        changed = true
                    } else if let folder, path == folder.from || path.hasPrefix(folder.from + "/") {
                        item["path"] = .string(folder.to + path.dropFirst(folder.from.count))
                        changed = true
                    }
                }
                if let inner = Self.inner(item) { item["items"] = .array(move(inner)) }
                return item
            }
        }
        items = move(items)
        return changed
    }
}
