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

    public init(path: String, task: ParsedTask) {
        self.path = path
        self.task = task
    }
}

/// A folder or a file in the tree, in the order the sidebar shows them:
/// folders first, then files, each by name.
public struct TreeNode: Sendable, Hashable, Identifiable {
    public var path: String
    public var name: String
    public var children: [TreeNode]?
    /// For a folder: its folder note `X/X.md`, which opens when the folder is clicked.
    public var folderNote: String?
    /// For a folder: its `logo.svg` (or `.png`, `.jpg`, `.webp`), drawn as its icon.
    public var logo: String?
    public var id: String { path }
    public var isFolder: Bool { children != nil }
}

/// Everything known about one vault at one moment. A value: a change to the
/// files makes a new one, so a view never reads half of an update.
public struct VaultIndex: Sendable {
    public var notes: [String: NoteEntry] = [:]
    /// Every file the vault holds, notes and attachments, by vault path.
    public var files: Set<String> = []
    /// Folders with no file in them at any depth, which the tree still shows:
    /// a new folder is empty until something goes into it.
    public var emptyFolders: Set<String> = []
    public private(set) var resolver = LinkResolver(paths: [])
    public private(set) var backlinks: [String: [Backlink]] = [:]
    public private(set) var tree: [TreeNode] = []
    public private(set) var tags: [String: Int] = [:]
    /// The tags as the tag pane shows them, each note counted once per branch.
    public private(set) var tagTree: [TagNode] = []
    /// The task statuses of the Tasks plugin's settings.
    public var statuses = TaskStatuses.defaults
    /// What the resolver and the tree were made from. A saved note changes
    /// neither, and with 20,000 files they took most of a second to make.
    private var resolved: (files: Set<String>, aliases: [String: [String]])?
    private var treed: (files: Set<String>, empty: Set<String>)?
    /// Each note's links as [backlinks] holds them, each target once with
    /// the line of its first link, and its tags: what a note gave before
    /// it changed, for [derive(changed:)] to take back.
    private var given: [String: (links: [(target: String, line: Int)], tags: [String])] = [:]

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

    /// The folder at [path] in the tree; "" is the vault itself.
    public func folder(_ path: String) -> [TreeNode]? { Vault.folder(path, in: tree) }

    /// Every task in the vault.
    public var tasks: [VaultTask] {
        notes.values.flatMap { note in note.parsed.tasks.map { VaultTask(path: note.path, task: $0) } }
    }

    /// Every task by its note's path, then by its line: the order a
    /// ` ```tasks ` query keeps for ties. The notes are put in order, not
    /// the tasks, which are in line order in each note already.
    public var tasksInOrder: [VaultTask] {
        notes.values.sorted { $0.path < $1.path }.flatMap { note in note.parsed.tasks.map { VaultTask(path: note.path, task: $0) } }
    }

    /// The links, tags, tree and resolver again, after [notes] or [files] changed.
    public mutating func derive() {
        var aliases: [String: [String]] = [:]
        for note in notes.values where !note.parsed.aliases.isEmpty { aliases[note.path] = note.parsed.aliases }
        if resolved?.files != files || resolved?.aliases != aliases {
            resolver = LinkResolver(paths: files, aliases: aliases)
            resolved = (files, aliases)
        }

        var back: [String: [Backlink]] = [:]
        var tagCounts: [String: Int] = [:]
        var given: [String: (links: [(target: String, line: Int)], tags: [String])] = [:]
        given.reserveCapacity(notes.count)
        for note in notes.values {
            let links = outgoing(note)
            for link in links { back[link.target, default: []].append(Backlink(source: note.path, line: link.line)) }
            for tag in note.parsed.tags { tagCounts[tag, default: 0] += 1 }
            given[note.path] = (links, note.parsed.tags)
        }
        for key in back.keys { back[key]!.sort { $0.source < $1.source } }
        backlinks = back
        tags = tagCounts
        self.given = given
        tagTree = TagNode.tree(notes: notes.values.map(\.parsed.tags))
        if treed?.files != files || treed?.empty != emptyFolders {
            tree = Vault.tree(of: files, emptyFolders: emptyFolders)
            treed = (files, emptyFolders)
        }
    }

    /// [derive] after only the notes at [changed] were read again, added or
    /// dropped: their old links and tags are taken back and their new ones
    /// put in, the same as [derive] would make. A file that came or went,
    /// or an alias that changed, can change where any link goes, so then
    /// everything is derived again. A saved note took 130 ms in a vault of
    /// 20,000 notes, nearly all of it resolving every link of every note.
    public mutating func derive(changed: Set<String>) {
        guard let resolved, resolved.files == files else { return derive() }
        for path in changed where (notes[path]?.parsed.aliases ?? []) != (resolved.aliases[path] ?? []) { return derive() }
        var tagsChanged = false
        for path in changed {
            let old: (links: [(target: String, line: Int)], tags: [String]) = given[path] ?? ([], [])
            let note = notes[path]
            let links = note.map(outgoing) ?? []
            let tags = note?.parsed.tags ?? []
            for link in old.links {
                guard var list = backlinks[link.target] else { continue }
                if let at = Self.position(of: path, in: list), at < list.count, list[at].source == path { list.remove(at: at) }
                backlinks[link.target] = list.isEmpty ? nil : list
            }
            for link in links {
                var list = backlinks[link.target] ?? []
                list.insert(Backlink(source: path, line: link.line), at: Self.position(of: path, in: list) ?? list.count)
                backlinks[link.target] = list
            }
            if old.tags != tags {
                tagsChanged = true
                for tag in old.tags {
                    let count = (self.tags[tag] ?? 0) - 1
                    self.tags[tag] = count > 0 ? count : nil
                }
                for tag in tags { self.tags[tag, default: 0] += 1 }
            }
            if note == nil { given[path] = nil } else { given[path] = (links, tags) }
        }
        if tagsChanged { tagTree = TagNode.tree(notes: notes.values.map(\.parsed.tags)) }
        if treed?.files != files || treed?.empty != emptyFolders {
            tree = Vault.tree(of: files, emptyFolders: emptyFolders)
            treed = (files, emptyFolders)
        }
    }

    /// Where [source] is or would go in [list], which is in order of source.
    private static func position(of source: String, in list: [Backlink]) -> Int? {
        var low = 0, high = list.count
        while low < high {
            let middle = (low + high) / 2
            if list[middle].source < source { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The notes [note] links to, each once with the line of its first link, itself left out.
    private func outgoing(_ note: NoteEntry) -> [(target: String, line: Int)] {
        var seen = Set<String>()
        var out: [(target: String, line: Int)] = []
        for link in note.parsed.links {
            guard let target = resolver.resolve(link.target, from: note.path), target != note.path, seen.insert(target).inserted else { continue }
            out.append((target, link.line))
        }
        return out
    }
}

/// The files of a vault on disk: which ones count, and how they are read.
public enum Vault {
    /// Folders never read: the app's settings, git, dependencies, the trash.
    static let skipped: Set<String> = [".obsidian", ".git", ".trash", "node_modules", ".github"]

    /// Front matter the reader does not print: the plugins' own keys.
    public static let hiddenProperties: Set<String> = ["cssclasses", "cssclass", "icon", "iconColor", "position"]

    public static func title(of path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return name.removingSuffix(".md")
    }

    public static func isNote(_ path: String) -> Bool { path.lowercased().hasSuffix(".md") }

    /// A note, a base, a canvas or a picture: a file the app shows itself
    /// rather than handing it to the app the system gives it to.
    public static func opensInApp(_ path: String) -> Bool { isNote(path) || Base.isBase(path) || Canvas.isCanvas(path) || isImage(path) }

    /// The pictures the reader's web view draws, and the editor under an
    /// embed: WebKit decodes each of these on macOS 26, an animated GIF,
    /// WebP or APNG animates. Any other picture opens in its own app.
    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "avif", "heic", "heif", "tif", "tiff",
    ]

    /// A picture the app shows on its own page, with zoom.
    public static func isImage(_ path: String) -> Bool {
        guard let dot = path.lastIndex(of: "."), !path[dot...].contains("/") else { return false }
        return imageExtensions.contains(path[path.index(after: dot)...].lowercased())
    }

    /// The files a link may hand to the app the system gives it to.
    static let outsideExtensions: Set<String> = [
        "pdf", "epub", "djvu", "txt", "csv", "tsv", "rtf", "doc", "docx", "odt", "xls", "xlsx", "ods", "ppt", "pptx", "odp", "key",
        "pages", "numbers", "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "avif", "heic", "heif", "tif", "tiff", "ico", "mp3",
        "m4a", "wav", "ogg", "oga", "flac", "opus", "aac", "mp4", "m4v", "mov", "webm", "mkv", "avi", "ogv", "zip", "tar", "gz", "7z",
        "xz",
    ]

    /// A file a link may hand to the app the system gives it to: a document,
    /// a picture, a sound, a film or an archive, which the system opens in a
    /// viewer. Anything else (a script, a `.command` file, an app) could run,
    /// so a click only shows it in Finder.
    public static func opensOutside(_ path: String) -> Bool {
        let name = path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return outsideExtensions.contains(name[name.index(after: dot)...].lowercased())
    }

    /// The schemes of the links that leave the app: web, mail and phone.
    /// A note's `file:`, `smb:` or `shortcuts:` link would start an app or
    /// a script, so it is never opened.
    public static let outsideSchemes: Set<String> = ["http", "https", "mailto", "tel", "sms", "geo"]

    /// Whether [url] is a link the app hands to the system.
    public static func leavesTheApp(_ url: URL) -> Bool { outsideSchemes.contains(url.scheme?.lowercased() ?? "") }

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
        // The walker's URLs are the root's with plain names after it, so the
        // part after the root is the vault path: standardizing every URL
        // was half of the scan of 20,000 files.
        let start = root.path.removingSuffix("/") + "/"
        var found = Set<String>()
        for case let url as URL in walker {
            let relative: String
            if case let path = url.path, path.hasPrefix(start) {
                relative = String(path.dropFirst(start.count))
            } else {
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(base) else { continue }
                relative = String(path.dropFirst(base.count))
            }
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
        // Deinitialized too, or every note read stays in memory for good.
        defer {
            _ = results.deinitialize()
            results.deallocate()
        }
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
        index.statuses = TaskStatuses.load(root)
        index.files = scan(root)
        index.emptyFolders = emptyFolders(root, files: index.files)
        let notes = read(index.files.filter(isNote).sorted(), in: root)
        for note in notes { index.notes[note.path] = note }
        search?.transaction {
            for note in notes { search?.put(path: note.path, title: note.title, body: note.parsed.plain) }
        }
        index.derive()
        return index
    }

    /// The index after the files at [changed] changed on disk: each is read
    /// again, or dropped when it is gone. The Tasks plugin's settings are
    /// read again when they are among them.
    public static func update(_ index: VaultIndex, changed: Set<String>, in root: URL, search: SearchIndex? = nil) -> VaultIndex {
        var index = index
        if changed.contains(TaskStatuses.file) { index.statuses = TaskStatuses.load(root) }
        let manager = FileManager.default
        var reread: [String] = []
        // A folder came or went, or its last file did: the empty ones are found again.
        var folders = false
        for path in changed where counts(path) {
            var isDirectory: ObjCBool = false
            let exists = manager.fileExists(atPath: root.appending(path: path).path, isDirectory: &isDirectory)
            if !exists || isDirectory.boolValue { folders = true }
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
        if folders { index.emptyFolders = emptyFolders(root, files: index.files) }
        index.derive(changed: Set(changed.filter(counts)).union(reread))
        return index
    }

    /// Every folder under [root] that holds none of [files], however deep.
    public static func emptyFolders(_ root: URL, files: Set<String>) -> Set<String> {
        let base = root.standardizedFileURL.path.removingSuffix("/") + "/"
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        else { return [] }
        var full = Set<String>()
        for file in files {
            var parts = file.split(separator: "/").dropLast()
            while !parts.isEmpty {
                guard full.insert(parts.joined(separator: "/")).inserted else { break }
                parts = parts.dropLast()
            }
        }
        var empty = Set<String>()
        for case let url as URL in walker {
            if skipped.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base) else { continue }
            let relative = Slugs.normalize(String(path.dropFirst(base.count)))
            if !full.contains(relative) { empty.insert(relative) }
        }
        return empty
    }

    /// The names a folder's logo may have, best first: a drawing before a picture.
    public static let logoNames = ["logo.svg", "logo.png", "logo.webp", "logo.jpg", "logo.jpeg"]

    /// The logo among a folder's own [files], when it has one.
    static func logo(in files: [String]) -> String? {
        let byName = Dictionary(files.map { (String($0.split(separator: "/").last ?? "").lowercased(), $0) }) { a, _ in a }
        return logoNames.lazy.compactMap { byName[$0] }.first
    }

    /// The logo of the folder at [path], from the vault's files.
    public static func logo(of folder: String, in files: Set<String>) -> String? {
        let prefix = folder.isEmpty ? "" : folder + "/"
        return logoNames.lazy.compactMap { name in
            files.first { $0.count == prefix.count + name.count && $0.lowercased() == (prefix + name).lowercased() }
        }.first
    }

    /// The folder at [path] in [tree]; "" is the vault itself.
    public static func folder(_ path: String, in tree: [TreeNode]) -> [TreeNode]? {
        if path.isEmpty { return tree }
        var level = tree
        for part in path.split(separator: "/").map(String.init) {
            guard let next = level.first(where: { $0.isFolder && $0.name == part }) else { return nil }
            level = next.children ?? []
        }
        return level
    }

    /// The folder tree. A folder note `X/X.md` is not listed inside its folder;
    /// the folder opens it, as the folder-notes plugin does.
    public static func tree(of files: Set<String>, emptyFolders: Set<String> = []) -> [TreeNode] {
        final class Folder {
            var folders: [String: Folder] = [:]
            var files: [String] = []
        }
        let root = Folder()
        for path in emptyFolders {
            var folder = root
            for part in path.split(separator: "/").map(String.init) {
                if folder.folders[part] == nil { folder.folders[part] = Folder() }
                folder = folder.folders[part]!
            }
        }
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
                let logo = logo(in: child.files)
                var children = build(child, prefix: path + "/")
                // The folder note and the logo are the folder, not files in it.
                children.removeAll { child in
                    child.path == note || (!child.isFolder && logoNames.contains(child.name.lowercased()))
                }
                return TreeNode(path: path, name: name, children: children, folderNote: hasNote ? note : nil, logo: logo)
            }
            // Each title once, not twice in every comparison of the sort.
            let leaves = folder.files.map { ($0, title(of: $0)) }.sorted { order($0.1, $1.1) }.map {
                TreeNode(path: $0.0, name: isNote($0.0) ? $0.1 : String($0.0.split(separator: "/").last!), children: nil)
            }
            return subfolders + leaves
        }
        return build(root, prefix: "")
    }
}

/// Obsidian's "excluded files" (`userIgnoreFilters` in `.obsidian/app.json`)
/// and the files for AI agents and other tools (`files.hidden` in the
/// config, by name in any folder): kept out of the tree, search, the
/// switcher and the graph. Links to them still work, and they still open
/// by their path. A filter is a path prefix (`uploads/` hides the folder and
/// all in it), or a regular expression between slashes.
public struct ExcludedFiles: Sendable {
    public var prefixes: [String] = []
    nonisolated(unsafe) public var patterns: [NSRegularExpression] = []
    /// Whole file names, folded: `CLAUDE.md` hides `Work/CLAUDE.md`, not `MyCLAUDE.md`.
    public var names: Set<String> = []

    public init(filters: [String] = [], names: [String] = []) {
        for filter in filters {
            let trimmed = filter.trimmingCharacters(in: .whitespaces)
            if trimmed.count > 2, trimmed.hasPrefix("/"), trimmed.hasSuffix("/") {
                if let regex = try? NSRegularExpression(pattern: String(trimmed.dropFirst().dropLast())) { patterns.append(regex) }
            } else if !trimmed.isEmpty {
                prefixes.append(Slugs.fold(trimmed))
            }
        }
        self.names = Set(names.map { Slugs.fold($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty })
    }

    public static func load(_ root: URL, names: [String] = []) -> ExcludedFiles {
        guard let data = try? Data(contentsOf: root.appending(path: ".obsidian/app.json")),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let filters = object["userIgnoreFilters"] as? [String]
        else { return ExcludedFiles(names: names) }
        return ExcludedFiles(filters: filters, names: names)
    }

    public var isEmpty: Bool { prefixes.isEmpty && patterns.isEmpty && names.isEmpty }

    public func contains(_ path: String) -> Bool {
        if isEmpty { return false }
        let folded = Slugs.fold(path)
        if prefixes.contains(where: { folded.hasPrefix($0) }) { return true }
        if !names.isEmpty, names.contains(Self.name(folded)) { return true }
        guard !patterns.isEmpty else { return false }
        let range = NSRange(path.startIndex..., in: path)
        return patterns.contains { $0.firstMatch(in: path, range: range) != nil }
    }

    /// The file name of a folded path: what follows its last `/`. Found in
    /// the bytes of an ASCII path, where each byte is a character.
    static func name(_ folded: String) -> String {
        if folded.utf8.allSatisfy({ $0 < 0x80 && $0 != 0x0D }) {
            guard let slash = folded.utf8.lastIndex(of: UInt8(ascii: "/")) else { return folded }
            return String(folded[folded.utf8.index(after: slash)...])
        }
        return String(folded[(folded.lastIndex(of: "/").map(folded.index(after:)) ?? folded.startIndex)...])
    }

    /// The folder at [path] is excluded itself, as `uploads/` excludes `uploads`.
    public func containsFolder(_ path: String) -> Bool {
        let folded = Slugs.fold(path) + "/"
        if prefixes.contains(where: { folded.hasPrefix($0) }) { return true }
        let folder = path + "/"
        let range = NSRange(folder.startIndex..., in: folder)
        return patterns.contains { $0.firstMatch(in: folder, range: range) != nil }
    }

    /// The tree without the excluded files and folders. A folder that holds
    /// only hidden files (a `CLAUDE.md`) stays, as an empty folder.
    public func tree(of files: Set<String>, emptyFolders: Set<String> = []) -> [TreeNode] {
        guard !isEmpty else { return Vault.tree(of: files, emptyFolders: emptyFolders) }
        var shown = Set<String>()
        var empty = Set<String>()
        for path in files {
            if !contains(path) {
                shown.insert(path)
                continue
            }
            // Each folder above a hidden file that is not hidden itself.
            var folder = path
            while let slash = folder.lastIndex(of: "/") {
                folder = String(folder[..<slash])
                if !containsFolder(folder) { empty.insert(folder); break }
            }
        }
        for folder in emptyFolders where !containsFolder(folder) { empty.insert(folder) }
        return Vault.tree(of: shown, emptyFolders: empty)
    }
}
