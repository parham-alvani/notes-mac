import Foundation

/// New, renamed, moved and deleted files, and the links that follow a file
/// when it moves: every `[[link]]` and `[text](link)` that went to the old
/// path goes to the new one, as Obsidian's "always update links" does.
public enum VaultMoves {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case badName(String)
        case exists(String)
        case intoItself

        public var description: String {
            switch self {
            case .badName(let name): "“\(name)” cannot be a file name: it is empty or has one of / \\ : # ^ [ ] |"
            case .exists(let path): "“\(path)” is already in the vault"
            case .intoItself: "A folder cannot go into itself"
            }
        }
    }

    /// A name Obsidian can link to: no path separators, no link syntax.
    public static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.hasPrefix(".") && !trimmed.contains { "/\\:#^[]|".contains($0) }
    }

    /// The name with `.md` added when it names no other kind of file.
    public static func noteName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let ext = (trimmed as NSString).pathExtension.lowercased()
        return ["md", "base", "canvas"].contains(ext) ? trimmed : trimmed + ".md"
    }

    /// `Untitled.md`, else `Untitled 1.md`, and so on: a name in [folder]
    /// that no file has yet.
    public static func freeName(_ base: String, ext: String = "md", in folder: String, files: Set<String>) -> String {
        let prefix = folder.isEmpty ? "" : folder + "/"
        let taken = Set(files.map(Slugs.fold))
        let folders = Set(files.flatMap { path in
            path.split(separator: "/").dropLast().indices.map { path.split(separator: "/")[...$0].joined(separator: "/") }
        }.map(Slugs.fold))
        for number in 0... {
            let name = number == 0 ? base : "\(base) \(number)"
            let path = prefix + (ext.isEmpty ? name : name + "." + ext)
            if !taken.contains(Slugs.fold(path)) && !folders.contains(Slugs.fold(path)) { return path }
        }
        fatalError("unreachable")
    }

    /// Where each file goes when [from] -- a file or a folder -- becomes
    /// [to]. A folder note `X/X.md` takes the folder's new name, as the
    /// folder-notes plugin does.
    public static func plan(_ from: String, to: String, files: Set<String>) throws -> [String: String] {
        guard from != to else { return [:] }
        if to.hasPrefix(from + "/") { throw Failure.intoItself }
        let foldedTo = Slugs.fold(to)
        let caseOnly = Slugs.fold(from) == foldedTo
        if !caseOnly, files.contains(where: { Slugs.fold($0) == foldedTo || Slugs.fold($0).hasPrefix(foldedTo + "/") }) {
            throw Failure.exists(to)
        }
        if files.contains(from) { return [from: to] }
        let oldName = String(from.split(separator: "/").last ?? "")
        let newName = String(to.split(separator: "/").last ?? "")
        var moves: [String: String] = [:]
        for path in files where path.hasPrefix(from + "/") {
            var moved = to + path.dropFirst(from.count)
            if path == from + "/" + oldName + ".md" { moved = to + "/" + newName + ".md" }
            moves[path] = moved
        }
        return moves
    }

    nonisolated(unsafe) private static let wikilink = /(!?)\[\[([^\]\n]+?)\]\]/
    nonisolated(unsafe) private static let markdownLink = /(!?\[[^\]\n]*\]\()(<?)([^)>\s]+)(>?\))/
    nonisolated(unsafe) private static let inlineCode = /`[^`\n]*`/
    nonisolated(unsafe) private static let fence = /^\s*(?:>\s*)*(```+|~~~+)/

    /// The notes whose links change with [moves], each with its new text,
    /// by the path it has after the moves.
    public static func relinked(index: VaultIndex, moves: [String: String], read: (String) -> String?) -> [String: String] {
        guard !moves.isEmpty else { return [:] }
        var after = index.files
        for (old, new) in moves {
            after.remove(old)
            after.insert(new)
        }
        var aliases: [String: [String]] = [:]
        for note in index.notes.values where !note.parsed.aliases.isEmpty { aliases[moves[note.path] ?? note.path] = note.parsed.aliases }
        let resolver = LinkResolver(paths: after, aliases: aliases)
        var names: [String: Int] = [:]
        for path in after { names[Slugs.fold(shortName(path)), default: 0] += 1 }
        let unique = { (name: String) in names[Slugs.fold(name)] == 1 }
        var sources = Set<String>()
        for old in moves.keys { sources.formUnion((index.backlinks[old] ?? []).map(\.source)) }
        var out: [String: String] = [:]
        for source in sources {
            guard let text = read(source) else { continue }
            let target = moves[source] ?? source
            let new = relink(text, source: source, newSource: target, index: index, moves: moves, resolver: resolver, unique: unique)
            if new != text { out[target] = new }
        }
        return out
    }

    static func relink(
        _ text: String, source: String, newSource: String, index: VaultIndex, moves: [String: String], resolver: LinkResolver,
        unique: (String) -> Bool
    ) -> String {
        var lines = text.components(separatedBy: "\n")
        var open: String?
        for at in lines.indices {
            let line = lines[at]
            if let match = line.firstMatch(of: fence) {
                let marker = String(match.1)
                if open == nil { open = marker } else if let first = open, marker.first == first.first, marker.count >= first.count { open = nil }
                continue
            }
            if open != nil || (!line.contains("[[") && !line.contains("](")) { continue }
            let code = line.matches(of: inlineCode).map(\.range)
            func inCode(_ range: Range<String.Index>) -> Bool { code.contains { $0.overlaps(range) } }
            var result = line.replacing(wikilink) { match -> String in
                guard !inCode(match.range) else { return String(match.output.0) }
                let link = Wikilink(String(match.output.2))
                guard !link.target.isEmpty, let old = index.resolve(link.target, from: source), let new = moves[old] else {
                    return String(match.output.0)
                }
                var inner = spelling(link.target, of: new, from: newSource, resolver: resolver, unique: unique)
                if let anchor = link.anchor { inner += "#" + anchor }
                if let alias = link.alias { inner += "|" + alias }
                return match.output.1 + "[[" + inner + "]]"
            }
            if result.contains("](") {
                let code = result.matches(of: inlineCode).map(\.range)
                result = result.replacing(markdownLink) { match -> String in
                    guard !code.contains(where: { $0.overlaps(match.range) }) else { return String(match.output.0) }
                    let url = String(match.output.3)
                    guard !url.contains("://"), !url.hasPrefix("mailto:"), !url.hasPrefix("#") else { return String(match.output.0) }
                    let decoded = url.removingPercentEncoding ?? url
                    let hash = decoded.firstIndex(of: "#")
                    let target = hash.map { String(decoded[..<$0]) } ?? decoded
                    guard let old = index.resolve(target, from: source), let new = moves[old] else { return String(match.output.0) }
                    let anchor = hash.map { String(decoded[$0...]) } ?? ""
                    let written = match.output.2.isEmpty
                        ? (new + anchor).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.union(["#"])) ?? new
                        : new + anchor
                    return match.output.1 + match.output.2 + written + match.output.4
                }
            }
            lines[at] = result
        }
        return lines.joined(separator: "\n")
    }

    /// A note's name without `.md`, any other file's name with its extension.
    static func shortName(_ path: String) -> String {
        let name = String(path.split(separator: "/").last ?? "")
        return Vault.isNote(name) ? String(name.dropLast(3)) : name
    }

    /// How a link names [path] after a move, in the style it was written: a
    /// bare name stays bare while no other file has it, a path stays a path.
    static func spelling(
        _ written: String, of path: String, from source: String, resolver: LinkResolver, unique: (String) -> Bool
    ) -> String {
        let note = Vault.isNote(path)
        let full = note ? String(path.dropLast(3)) : path
        let name = shortName(path)
        var spelled = !written.contains("/") && unique(name) && resolver.resolve(name, from: source) == path ? name : full
        if note, written.lowercased().hasSuffix(".md") { spelled += ".md" }
        return spelled
    }

    /// Moves the files on disk, then writes the notes whose links changed.
    /// Returns every vault path that changed, old and new.
    @discardableResult
    public static func perform(_ from: String, to: String, index: VaultIndex, root: URL) throws -> Set<String> {
        let moves = try plan(from, to: to, files: index.files)
        guard !moves.isEmpty else { return [] }
        let edits = relinked(index: index, moves: moves) { path in
            try? String(contentsOf: root.appending(path: path), encoding: .utf8)
        }
        let manager = FileManager.default
        let destination = root.appending(path: to)
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if Slugs.fold(from) == Slugs.fold(to) {
            // A change of case only: through a free name, for a disk that folds case.
            let step = root.appending(path: to + ".daftar-\(UUID().uuidString.prefix(8))")
            try manager.moveItem(at: root.appending(path: from), to: step)
            try manager.moveItem(at: step, to: destination)
        } else {
            try manager.moveItem(at: root.appending(path: from), to: destination)
        }
        // The folder note, renamed with its folder.
        let oldName = String(from.split(separator: "/").last ?? ""), newName = String(to.split(separator: "/").last ?? "")
        let carried = to + "/" + oldName + ".md"
        if moves[from + "/" + oldName + ".md"] == to + "/" + newName + ".md", oldName != newName {
            try manager.moveItem(at: root.appending(path: carried), to: root.appending(path: to + "/" + newName + ".md"))
        }
        for (path, text) in edits {
            try Data(text.utf8).write(to: root.appending(path: path), options: .atomic)
        }
        return Set(moves.keys).union(moves.values).union([from, to])
    }
}
