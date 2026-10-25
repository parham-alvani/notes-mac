import Foundation

/// One note in the index.
public struct NoteEntry: Sendable, Equatable {
    public var path: String
    public var modified: Date
    public var parsed: ParsedNote

    /// The file name without `.md`, which is what Obsidian shows and links by.
    public var title: String { Vault.title(of: path) }
}

/// A link into a note from another one.
public struct Backlink: Sendable, Hashable {
    public var source: String
    public var line: Int
}

/// A task with the note it is in.
public struct VaultTask: Sendable, Hashable, Identifiable {
    public var path: String
    public var task: ParsedTask
    public var id: String { "\(path):\(task.line)" }
}

/// A folder or a file in the tree, in the order the sidebar shows them:
/// folders first, then files, each by name.
public struct TreeNode: Sendable, Hashable, Identifiable {
    public var path: String
    public var name: String
    public var children: [TreeNode]?
    /// For a folder: its folder note `X/X.md`, which opens when the folder is clicked.
    public var folderNote: String?
    public var id: String { path }
    public var isFolder: Bool { children != nil }
}

/// Everything known about one vault at one moment. A value: a change to the
/// files makes a new one, so a view never reads half of an update.
public struct VaultIndex: Sendable {
    public var notes: [String: NoteEntry] = [:]
    /// Every file the vault holds, notes and attachments, by vault path.
    public var files: Set<String> = []
    public private(set) var resolver = LinkResolver(paths: [])
    public private(set) var backlinks: [String: [Backlink]] = [:]
    public private(set) var tree: [TreeNode] = []
    public private(set) var tags: [String: Int] = [:]

    public init() {}

    /// The path [target] names from [source], or nil when nothing does.
    public func resolve(_ target: String, from source: String) -> String? {
        resolver.resolve(target, from: source)
    }

    /// Every wikilink target in the note, with where it goes, for the reader.
    public func resolvedLinks(of path: String) -> [String: String] {
        guard let note = notes[path] else { return [:] }
        var out: [String: String] = [:]
        for link in note.parsed.links where out[link.target] == nil {
            if let found = resolver.resolve(link.target, from: path) { out[link.target] = found }
        }
        return out
    }

    /// The same, for a text that is not in the index yet.
    public func resolvedLinks(in parsed: ParsedNote, from path: String) -> [String: String] {
        var out: [String: String] = [:]
        for link in parsed.links where out[link.target] == nil {
            if let found = resolver.resolve(link.target, from: path) { out[link.target] = found }
        }
        return out
    }

    /// Every task in the vault.
    public var tasks: [VaultTask] {
        notes.values.flatMap { note in note.parsed.tasks.map { VaultTask(path: note.path, task: $0) } }
    }

    /// The links, tags, tree and resolver again, after [notes] or [files] changed.
    public mutating func derive() {
        var aliases: [String: [String]] = [:]
        for note in notes.values where !note.parsed.aliases.isEmpty { aliases[note.path] = note.parsed.aliases }
        resolver = LinkResolver(paths: files, aliases: aliases)

        var back: [String: [Backlink]] = [:]
        var tagCounts: [String: Int] = [:]
        for note in notes.values {
            var seen = Set<String>()
            for link in note.parsed.links {
                guard let target = resolver.resolve(link.target, from: note.path), target != note.path,
                    seen.insert(target).inserted
                else { continue }
                back[target, default: []].append(Backlink(source: note.path, line: link.line))
            }
            for tag in note.parsed.tags { tagCounts[tag, default: 0] += 1 }
        }
        for key in back.keys { back[key]!.sort { $0.source < $1.source } }
        backlinks = back
        tags = tagCounts
        tree = Vault.tree(of: files)
    }
}

/// The files of a vault on disk: which ones count, and how they are read.
public enum Vault {
    /// Folders never read: the app's settings, git, dependencies, the trash.
    static let skipped: Set<String> = [".obsidian", ".git", ".trash", "node_modules", ".github"]

    public static func title(of path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return name.removingSuffix(".md")
    }

    public static func isNote(_ path: String) -> Bool { path.lowercased().hasSuffix(".md") }

    /// Whether a vault path is one the app reads at all.
    public static func counts(_ path: String) -> Bool {
        !path.split(separator: "/").contains { $0.hasPrefix(".") || skipped.contains(String($0)) }
    }

    /// Every file under [root] that counts, by vault path.
    public static func scan(_ root: URL) -> Set<String> {
        let base = root.standardizedFileURL.path.removingSuffix("/") + "/"
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        var found = Set<String>()
        for case let url as URL in walker {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base) else { continue }
            let relative = String(path.dropFirst(base.count))
            if skipped.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                found.insert(Slugs.normalize(relative))
            }
        }
        return found
    }

    /// Reads and parses each note in [paths], several at a time.
    public static func read(_ paths: [String], in root: URL) -> [NoteEntry] {
        // Each iteration writes its own slot, so the slots need no lock.
        nonisolated(unsafe) let results = UnsafeMutableBufferPointer<NoteEntry?>.allocate(capacity: paths.count)
        results.initialize(repeating: nil)
        defer { results.deallocate() }
        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            results[index] = read(paths[index], in: root)
        }
        return results.compactMap { $0 }
    }

    public static func read(_ path: String, in root: URL) -> NoteEntry? {
        let url = root.appending(path: path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return NoteEntry(path: path, modified: modified, parsed: NoteParser.parse(text))
    }

    /// Builds the whole index of the vault at [root].
    public static func index(_ root: URL, search: SearchIndex? = nil) -> VaultIndex {
        var index = VaultIndex()
        index.files = scan(root)
        let notes = read(index.files.filter(isNote).sorted(), in: root)
        for note in notes { index.notes[note.path] = note }
        search?.transaction {
            for note in notes { search?.put(path: note.path, title: note.title, body: note.parsed.plain) }
        }
        index.derive()
        return index
    }

    /// The index after the files at [changed] changed on disk: each is read
    /// again, or dropped when it is gone.
    public static func update(_ index: VaultIndex, changed: Set<String>, in root: URL, search: SearchIndex? = nil) -> VaultIndex {
        var index = index
        let manager = FileManager.default
        var reread: [String] = []
        for path in changed where counts(path) {
            var isDirectory: ObjCBool = false
            let exists = manager.fileExists(atPath: root.appending(path: path).path, isDirectory: &isDirectory)
            if exists && isDirectory.boolValue {
                // A folder that came or went: its files are found again.
                let base = path.removingSuffix("/") + "/"
                let now = scan(root).filter { $0.hasPrefix(base) }
                let before = index.files.filter { $0.hasPrefix(base) }
                for gone in before.subtracting(now) {
                    index.files.remove(gone)
                    index.notes[gone] = nil
                    search?.remove(path: gone)
                }
                for added in now { index.files.insert(added); if isNote(added) { reread.append(added) } }
            } else if exists {
                index.files.insert(path)
                if isNote(path) { reread.append(path) }
            } else {
                let base = path.removingSuffix("/") + "/"
                for gone in index.files.filter({ $0 == path || $0.hasPrefix(base) }) {
                    index.files.remove(gone)
                    index.notes[gone] = nil
                    search?.remove(path: gone)
                }
            }
        }
        for note in read(reread, in: root) {
            index.notes[note.path] = note
            search?.put(path: note.path, title: note.title, body: note.parsed.plain)
        }
        index.derive()
        return index
    }

    /// The folder tree. A folder note `X/X.md` is not listed inside its folder;
    /// the folder opens it, as the folder-notes plugin does.
    public static func tree(of files: Set<String>) -> [TreeNode] {
        final class Folder {
            var folders: [String: Folder] = [:]
            var files: [String] = []
        }
        let root = Folder()
        for path in files {
            var folder = root
            let parts = path.split(separator: "/").map(String.init)
            for part in parts.dropLast() {
                if folder.folders[part] == nil { folder.folders[part] = Folder() }
                folder = folder.folders[part]!
            }
            folder.files.append(path)
        }
        func order(_ a: String, _ b: String) -> Bool {
            a.localizedStandardCompare(b) == .orderedAscending
        }
        func build(_ folder: Folder, prefix: String) -> [TreeNode] {
            let subfolders = folder.folders.keys.sorted(by: order).map { name -> TreeNode in
                let path = prefix + name
                let child = folder.folders[name]!
                let note = path + "/" + name + ".md"
                let hasNote = child.files.contains(note)
                var children = build(child, prefix: path + "/")
                if hasNote { children.removeAll { $0.path == note } }
                return TreeNode(path: path, name: name, children: children, folderNote: hasNote ? note : nil)
            }
            let leaves = folder.files.sorted { order(title(of: $0), title(of: $1)) }.map {
                TreeNode(path: $0, name: isNote($0) ? title(of: $0) : String($0.split(separator: "/").last!), children: nil)
            }
            return subfolders + leaves
        }
        return build(root, prefix: "")
    }
}
