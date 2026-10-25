import Foundation

/// The editing rules that are more than inserting a character: what Return
/// does in a list, what Tab does to an item, what ⌘↩ does to a line. Pure
/// functions of one line, so the editor stays thin and these are tested.
public enum EditorCommands {
    nonisolated(unsafe) private static let item = /^(\s*(?:>\s?)*\s*)([-*+]|(\d+)([.)]))(\s+)(\[[^\]]\]\s+)?(.*)$/

    /// What Return inserts after [line]: the next item's marker, or nil to
    /// insert a plain newline. An empty item ends the list instead, which is
    /// `.endList` -- the editor clears the marker.
    public enum Return: Equatable {
        case insert(String)
        case endList
    }

    public static func onReturn(after line: String) -> Return? {
        guard let match = line.wholeMatch(of: item) else { return nil }
        let indent = String(match.1)
        let space = String(match.5)
        let text = String(match.7)
        let hasTask = match.6 != nil
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return .endList }
        var marker = String(match.2)
        if let number = match.3.flatMap({ Int($0) }), let close = match.4 { marker = "\(number + 1)\(close)" }
        return .insert("\n" + indent + marker + space + (hasTask ? "[ ] " : ""))
    }

    /// The vault indents a nested item by four spaces.
    public static let indentUnit = "    "

    public static func indent(_ line: String) -> String { indentUnit + line }

    public static func outdent(_ line: String) -> String {
        if line.hasPrefix(indentUnit) { return String(line.dropFirst(indentUnit.count)) }
        if line.hasPrefix("\t") { return String(line.dropFirst()) }
        return String(line.drop { $0 == " " })
    }

    public static func isListItem(_ line: String) -> Bool { line.wholeMatch(of: item) != nil }

    /// The link a dropped file gets: `[[Note]]`, or the path when another
    /// note has the same name; pictures, sound, video and PDFs embedded.
    public static func link(to path: String, files: Set<String>) -> String {
        let name = String(path.split(separator: "/").last ?? "")
        let short = Vault.isNote(path) ? String(name.dropLast(3)) : name
        let same = files.filter { String($0.split(separator: "/").last ?? "").lowercased() == name.lowercased() }.count
        let target = same > 1 ? (Vault.isNote(path) ? String(path.dropLast(3)) : path) : short
        let media = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "avif", "mp3", "m4a", "wav", "ogg", "flac", "mp4", "mov", "webm", "mkv", "pdf"]
        return (media.contains((path as NSString).pathExtension.lowercased()) ? "!" : "") + "[[" + target + "]]"
    }

    /// One web address and nothing else, as a paste over a selection takes it.
    public static func isWebAddress(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace), let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto"].contains(scheme) && (url.host != nil || scheme == "mailto")
    }

    /// ⌘↩: a task is ticked or opened again, as a click on its box does; a
    /// list item becomes a task; any other line becomes a task item.
    public static func toggleTask(_ line: String, today: Day) -> [String] {
        if let toggled = TaskLine.toggled(line, today: today.description) { return toggled }
        if let match = line.wholeMatch(of: item) {
            return [String(match.1) + String(match.2) + String(match.5) + "[ ] " + String(match.7)]
        }
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let text = line.dropFirst(indent.count)
        return [indent + "- [ ] " + text]
    }

    /// The name Obsidian gives a pasted image, in the attachment folder.
    public static func pastedImageName(at date: Date = Date(), ext: String = "png") -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyyMMddHHmmss"
        return "Pasted image \(format.string(from: date)).\(ext)"
    }

    /// The text after an unclosed `[[` that ends at [location], which `[[`
    /// completion replaces, or nil when the cursor is not in one.
    public static func linkQuery(in text: NSString, at location: Int) -> NSRange? {
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        let before = text.substring(with: NSRange(location: line.location, length: location - line.location)) as NSString
        let open = before.range(of: "[[", options: .backwards)
        guard open.location != NSNotFound else { return nil }
        let typed = before.substring(from: NSMaxRange(open))
        guard !typed.contains("]]"), !typed.contains("|"), !typed.contains("#") else { return nil }
        return NSRange(location: line.location + NSMaxRange(open), length: (typed as NSString).length)
    }
}

/// What a slash command inserts: `/` at the start of a line or after a
/// space opens the menu, and the chosen snippet takes the slash's place.
public struct Snippet: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var group: String
    /// An SF Symbol, and the palette colour it is drawn in.
    public var symbol: String
    public var color: String
    public var text: String
    /// Where the cursor goes, in UTF-16 units into [text].
    public var cursor: Int
    /// A block (a heading, a fence, a table) starts a line of its own.
    public var block: Bool

    init(_ id: String, _ title: String, _ group: String, _ symbol: String, _ color: String, _ text: String, cursor: Int? = nil, block: Bool = false) {
        self.id = id
        self.title = title
        self.group = group
        self.symbol = symbol
        self.color = color
        self.text = text
        self.cursor = cursor ?? (text as NSString).length
        self.block = block
    }
}

extension EditorCommands {
    public static func slashCommands(today: Day, time: String) -> [Snippet] {
        [
            Snippet("h1", "Heading 1", "Text", "textformat.size.larger", "orange", "# ", block: true),
            Snippet("h2", "Heading 2", "Text", "textformat.size", "vividYellow", "## ", block: true),
            Snippet("h3", "Heading 3", "Text", "textformat.size.smaller", "blue", "### ", block: true),
            Snippet("task", "Task", "Lists", "checkmark.square", "orange", "- [ ] ", block: true),
            Snippet("task-today", "Task due today", "Lists", "calendar.badge.exclamationmark", "red", "- [ ]  📅 \(today)", cursor: 6, block: true),
            Snippet("bullet", "Bulleted list", "Lists", "list.bullet", "aqua", "- ", block: true),
            Snippet("number", "Numbered list", "Lists", "list.number", "aqua", "1. ", block: true),
            Snippet("quote", "Quote", "Blocks", "text.quote", "warmGrey", "> ", block: true),
            Snippet("note", "Note callout", "Blocks", "pencil", "blue", "> [!note] \n> ", block: true),
            Snippet("tip", "Tip callout", "Blocks", "flame.fill", "chartreuse", "> [!tip] \n> ", block: true),
            Snippet("warning", "Warning callout", "Blocks", "exclamationmark.triangle.fill", "orange", "> [!warning] \n> ", block: true),
            Snippet("danger", "Danger callout", "Blocks", "bolt.fill", "red", "> [!danger] \n> ", block: true),
            Snippet("code", "Code block", "Blocks", "chevron.left.forwardslash.chevron.right", "pink", "```\n\n```", cursor: 4, block: true),
            Snippet("mermaid", "Mermaid diagram", "Blocks", "flowchart.fill", "purple", "```mermaid\nflowchart LR\n    A --> B\n```", cursor: 35, block: true),
            Snippet("math", "Math block", "Blocks", "function", "purple", "$$\n\n$$", cursor: 3, block: true),
            Snippet("table", "Table", "Blocks", "tablecells", "green", "| Column | Column |\n| ------ | ------ |\n|        |        |", cursor: 42, block: true),
            Snippet("tasks", "Tasks query", "Blocks", "checklist", "orange", "```tasks\nnot done\ndue before tomorrow\n```", block: true),
            Snippet("divider", "Divider", "Blocks", "minus", "grey", "---\n", block: true),
            Snippet("link", "Link to a note", "Links", "link", "aqua", "[[]]", cursor: 2),
            Snippet("embed", "Embed a note or a file", "Links", "photo.on.rectangle", "pink", "![[]]", cursor: 3),
            Snippet("date", "Today's date", "Insert", "calendar", "orange", today.description),
            Snippet("time", "The time now", "Insert", "clock", "blue", time),
            Snippet("red", "Red highlight", "Highlight", "highlighter", "red", "==🔴 ==", cursor: 5),
            Snippet("orange", "Orange highlight", "Highlight", "highlighter", "orange", "==🟠 ==", cursor: 5),
            Snippet("yellow", "Yellow highlight", "Highlight", "highlighter", "vividYellow", "==🟡 ==", cursor: 5),
            Snippet("green", "Green highlight", "Highlight", "highlighter", "green", "==🟢 ==", cursor: 5),
            Snippet("blue", "Blue highlight", "Highlight", "highlighter", "blue", "==🔵 ==", cursor: 5),
            Snippet("purple", "Purple highlight", "Highlight", "highlighter", "purple", "==🟣 ==", cursor: 5),
        ]
    }

    /// Whether the `/` just before [location] opens the menu: at the start
    /// of a line, or after a space, so a path or a URL never does.
    public static func opensSlashMenu(in text: NSString, at location: Int) -> Bool {
        guard location >= 1, location <= text.length, text.character(at: location - 1) == 0x2F else { return false }
        if location == 1 { return true }
        let before = text.character(at: location - 2)
        return before == 0x0A || before == 0x20 || before == 0x09
    }

    /// The edit that puts [snippet] where the `/` at [slash] is: the range
    /// to replace, what goes there, and where the cursor ends up.
    public static func apply(_ snippet: Snippet, slashAt slash: Int, in text: NSString) -> (range: NSRange, text: String, cursor: Int) {
        let line = text.lineRange(for: NSRange(location: slash, length: 0))
        let before = text.substring(with: NSRange(location: line.location, length: slash - line.location))
        // A block after other text on the line starts a line of its own.
        let lead = snippet.block && !before.trimmingCharacters(in: .whitespaces).isEmpty ? "\n" : ""
        let insert = lead + snippet.text
        return (NSRange(location: slash, length: 1), insert, slash + (lead as NSString).length + snippet.cursor)
    }
}

extension EditorCommands {
    /// A name for a note made from [text]: its first line, without the
    /// heading marks, bullets and characters a file name cannot have.
    public static func extractName(from text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var name = first.replacing(/^\s*(?:>\s*)*(?:#{1,6}\s+|[-*+]\s+(?:\[.\]\s+)?|\d+[.)]\s+)?/, with: "")
        name = name.replacing(/\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/) { String($0.2 ?? $0.1) }
        name = String(name.map { "/\\:#^[]|*\"<>?".contains($0) ? " " : $0 })
        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // A leading dot would hide the file.
        name = String(name.drop { $0 == "." || $0 == " " })
        if name.count > 60 { name = String(name.prefix(60)).trimmingCharacters(in: .whitespaces) }
        return name.isEmpty ? "Untitled" : name
    }

    /// The text of a note made from a selection: a heading on its first
    /// line is moved up to the note's title, so it is not said twice.
    public static func extractBody(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if let first = lines.first, first.wholeMatch(of: /\s*#{1,6}\s+.*/) != nil { lines.removeFirst() }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }
}
