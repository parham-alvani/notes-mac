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
    /// A block that stands apart (a callout, a fence, a table, a rule): it
    /// has a blank line before and after it. A heading or a list item is
    /// only the start of its line.
    public var apart: Bool
    /// How much of [text] after [cursor] is selected, in UTF-16 units: a
    /// placeholder word, which the first letter typed replaces.
    public var selected: Int

    init(
        _ id: String, _ title: String, _ group: String, _ symbol: String, _ color: String, _ text: String, cursor: Int? = nil, selected: Int = 0,
        block: Bool = false, apart: Bool = false
    ) {
        self.id = id
        self.title = title
        self.group = group
        self.symbol = symbol
        self.color = color
        self.text = text
        self.cursor = cursor ?? (text as NSString).length
        self.selected = selected
        self.block = block || apart
        self.apart = apart
    }
}

extension EditorCommands {
    /// The items of the slash bar, in the order they are listed
    /// (`docs/specs/look.md` in notes-linux, part 2). A callout puts the
    /// caret in its title, and the yellow highlight writes no circle: it is
    /// the default colour.
    public static func slashCommands(today: Day, time: String) -> [Snippet] {
        func callout(_ id: String, _ title: String, _ kind: String, _ symbol: String, _ color: String) -> Snippet {
            let head = "> [!\(kind)] "
            return Snippet(id, title, "Blocks", symbol, color, head + "\n> ", cursor: (head as NSString).length, apart: true)
        }
        var items = [
            Snippet("h1", "Heading 1", "Text", "textformat.size.larger", "orange", "# ", block: true),
            Snippet("h2", "Heading 2", "Text", "textformat.size", "vividYellow", "## ", block: true),
            Snippet("h3", "Heading 3", "Text", "textformat.size.smaller", "blue", "### ", block: true),
            Snippet("task", "Task", "Lists", "checkmark.square", "orange", "- [ ] ", block: true),
            Snippet("task-today", "Task due today", "Lists", "calendar.badge.exclamationmark", "red", "- [ ]  📅 \(today)", cursor: 6, block: true),
            Snippet("bullet", "Bulleted list", "Lists", "list.bullet", "aqua", "- ", block: true),
            Snippet("number", "Numbered list", "Lists", "list.number", "aqua", "1. ", block: true),
            Snippet("quote", "Quote", "Blocks", "text.quote", "warmGrey", "> ", block: true),
            callout("callout", "Callout", "note", "text.bubble", "blue"),
        ]
        items += [
            ("note", "Note callout", "pencil", "blue"),
            ("info", "Info callout", "info.circle", "blue"),
            ("tip", "Tip callout", "flame.fill", "chartreuse"),
            ("important", "Important callout", "exclamationmark.circle", "chartreuse"),
            ("warning", "Warning callout", "exclamationmark.triangle.fill", "orange"),
            ("danger", "Danger callout", "bolt.fill", "red"),
            ("example", "Example callout", "list.bullet.rectangle", "purple"),
            ("question", "Question callout", "questionmark.circle", "yellow"),
            ("success", "Success callout", "checkmark.circle", "green"),
            ("summary", "Summary callout", "doc.plaintext", "mint"),
            ("todo", "Todo callout", "checkmark.circle", "vividYellow"),
        ].map { callout($0.0, $0.1, $0.0, $0.2, $0.3) }
        items += [
            Snippet("code", "Code block", "Blocks", "chevron.left.forwardslash.chevron.right", "pink", "```\n\n```", cursor: 4, apart: true),
            Snippet("mermaid", "Mermaid diagram", "Blocks", "flowchart.fill", "purple", "```mermaid\nflowchart LR\n    A --> B\n```", cursor: 35, apart: true),
            Snippet("math", "Math block", "Blocks", "function", "purple", "$$\n\n$$", cursor: 3, apart: true),
            Snippet("tasks", "Tasks query", "Blocks", "checklist", "orange", "```tasks\nnot done\ndue before tomorrow\n```", apart: true),
            // The first header cell's word is selected: the first letter typed takes its place.
            Snippet(
                "table", "Table", "Blocks", "tablecells", "green", "| \(MarkdownTable.placeholder) | \(MarkdownTable.placeholder) |\n| ------ | ------ |\n|        |        |",
                cursor: 2, selected: (MarkdownTable.placeholder as NSString).length, apart: true),
            Snippet("divider", "Rule", "Blocks", "minus", "grey", "---\n", apart: true),
            Snippet("link", "Link to a note", "Links", "link", "aqua", "[[]]", cursor: 2),
            Snippet("embed", "Embed a note or a file", "Links", "photo.on.rectangle", "pink", "![[]]", cursor: 3),
            Snippet("date", "Today's date", "Insert", "calendar", "orange", today.description),
            Snippet("time", "The time now", "Insert", "clock", "blue", time),
            // The caret after the circle: two UTF-16 units each.
            Snippet("red", "Red highlight", "Highlight", "highlighter", "red", "==🔴==", cursor: 4),
            Snippet("orange", "Orange highlight", "Highlight", "highlighter", "orange", "==🟠==", cursor: 4),
            Snippet("yellow", "Yellow highlight", "Highlight", "highlighter", "vividYellow", "====", cursor: 2),
            Snippet("green", "Green highlight", "Highlight", "highlighter", "green", "==🟢==", cursor: 4),
            Snippet("blue", "Blue highlight", "Highlight", "highlighter", "blue", "==🔵==", cursor: 4),
            Snippet("purple", "Purple highlight", "Highlight", "highlighter", "purple", "==🟣==", cursor: 4),
        ]
        return items
    }

    /// Whether the `/` just before [location] opens the menu: at the start
    /// of a line, or after a space, so a path or a URL never does.
    public static func opensSlashMenu(in text: NSString, at location: Int) -> Bool {
        guard location >= 1, location <= text.length, text.character(at: location - 1) == 0x2F else { return false }
        if location == 1 { return true }
        let before = text.character(at: location - 2)
        return before == 0x0A || before == 0x20 || before == 0x09
    }

    /// The edit that puts [snippet] where the `/` at [slash] is, over the
    /// `/` and the [query] UTF-16 units typed after it to find the item:
    /// the range to replace, what goes there, where the cursor ends up and
    /// how much after it is selected. Only the `/` and the query are
    /// replaced, so no other text of the note is ever taken.
    ///
    /// A block after other text on the line starts a line of its own. A
    /// block that stands apart also has a blank line before it and after it
    /// wherever the line beside it is not blank: a paragraph straight under
    /// a table is a row of that table to Markdown, and one straight over a
    /// `---` is a heading.
    public static func apply(_ snippet: Snippet, slashAt slash: Int, query: Int = 0, in text: NSString) -> (range: NSRange, text: String, cursor: Int, selected: Int) {
        let range = NSRange(location: slash, length: 1 + query)
        let line = text.lineRange(for: NSRange(location: slash, length: 0))
        var contents = 0
        text.getLineStart(nil, end: nil, contentsEnd: &contents, for: line)
        func blank(_ range: NSRange) -> Bool { text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let textBefore = !blank(NSRange(location: line.location, length: slash - line.location))
        var lead = snippet.block && textBefore ? "\n" : ""
        var trail = ""
        if snippet.apart {
            if textBefore {
                lead = "\n\n"
            } else if line.location > 0, !blank(text.lineRange(for: NSRange(location: line.location - 1, length: 0))) {
                // The `/`'s own line, left empty, is the blank line.
                lead = "\n"
            }
            // A snippet that ends in a line break (a rule) leaves the caret on an empty line under it: that line is the blank one.
            let open = snippet.text.hasSuffix("\n")
            let after = max(contents, NSMaxRange(range))
            if NSMaxRange(range) < contents, !blank(NSRange(location: NSMaxRange(range), length: contents - NSMaxRange(range))) {
                // What was after the `/` on its line goes under the block, as it is.
                trail = open ? "\n" : "\n\n"
            } else if !open, NSMaxRange(line) < text.length, NSMaxRange(line) > after, !blank(text.lineRange(for: NSRange(location: NSMaxRange(line), length: 0))) {
                trail = "\n"
            }
        }
        return (range, lead + snippet.text + trail, slash + (lead as NSString).length + snippet.cursor, snippet.selected)
    }
}

/// The slash bar: a small list under a typed `/`, filtered as the person
/// types, that never takes the keys (`docs/specs/look.md` in notes-linux,
/// part 2). The rules are here; the editor draws the list and gives it the keys.
public struct SlashBar: Sendable, Equatable {
    /// Where the `/` is.
    public private(set) var slash: Int
    /// What is typed after the `/`, up to the caret.
    public private(set) var query = ""
    /// The items the query finds, best first; none hides the list, which still listens.
    public private(set) var rows: [Snippet]
    /// The chosen row.
    public private(set) var chosen = 0
    /// Where the typed text ends, and how long the note was then.
    private var end: Int
    private var length: Int
    private let items: [Snippet]

    /// Whether the `/` typed just before [location] opens the bar: at the
    /// start of a line or after a space, and never in a code block, inline
    /// code, the front matter, math or a comment. [state] is the block
    /// state the `/`'s line starts in, when the caller knows it.
    public static func opens(in text: NSString, at location: Int, startingIn state: MarkdownHighlighter.BlockState? = nil) -> Bool {
        guard EditorCommands.opensSlashMenu(in: text, at: location) else { return false }
        let slash = location - 1
        let line = text.lineRange(for: NSRange(location: slash, length: 0))
        let state = state ?? MarkdownHighlighter.blockState(before: line.location, in: text)
        return !MarkdownHighlighter.spans(in: text, range: line, startingIn: state).contains { span in
            guard NSLocationInRange(slash, span.range) else { return false }
            switch span.kind {
            case .code, .codeBlock, .fence, .fenceEnd, .frontMatter, .math, .comment: return true
            default: return false
            }
        }
    }

    /// The items of [items] the bar shows for [query]: those whose title or
    /// id it matches as the palette matches (`Fuzzy.match`), best first, and
    /// in the list's order when two match the same. An empty query shows
    /// every item.
    public static func matches(_ query: String, in items: [Snippet]) -> [Snippet] {
        guard !query.isEmpty else { return items }
        let found: [(score: Int, order: Int)] = items.enumerated().compactMap { order, item in
            [item.title, item.id].compactMap { Fuzzy.match(query, in: $0)?.score }.max().map { ($0, order) }
        }
        return found.sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }.map { items[$0.order] }
    }

    /// The bar for the `/` just typed before [location], or nil where a `/` opens none.
    public init?(typedAt location: Int, in text: NSString, items: [Snippet], startingIn state: MarkdownHighlighter.BlockState? = nil) {
        guard Self.opens(in: text, at: location, startingIn: state) else { return nil }
        slash = location - 1
        end = location
        length = text.length
        self.items = items
        rows = items
    }

    /// The bar after the text or the caret changed, or nil when it closes:
    /// the `/` went, a space was typed, or the caret left the place between
    /// the `/` and the end of what was typed.
    public func following(_ text: NSString, caret: Int) -> SlashBar? {
        var next = self
        next.end += text.length - length
        next.length = text.length
        guard slash < text.length, text.character(at: slash) == 0x2F, caret > slash, caret <= next.end, next.end <= text.length else { return nil }
        let typed = text.substring(with: NSRange(location: slash + 1, length: caret - slash - 1))
        guard !typed.contains(where: { $0.isWhitespace }) else { return nil }
        guard typed != query else { return next }
        next.query = typed
        next.rows = Self.matches(typed, in: items)
        // The first row is chosen whenever the list changes.
        next.chosen = 0
        return next
    }

    /// Down and Up choose the next row or the one before, and stop at the ends.
    public mutating func move(by rows: Int) {
        chosen = max(0, min(self.rows.count - 1, chosen + rows))
    }

    /// The chosen item, or nil while the list is hidden: Enter and Tab are ordinary keys then.
    public var choice: Snippet? { rows.indices.contains(chosen) ? rows[chosen] : nil }

    /// The group's header over row [index]: only with nothing typed, and
    /// only over the first row of each group.
    public func header(over index: Int) -> String? {
        guard query.isEmpty, rows.indices.contains(index), index == 0 || rows[index - 1].group != rows[index].group else { return nil }
        return rows[index].group
    }

    /// The edit that puts [snippet] in place of the `/` and the query, as one step.
    public func edit(_ snippet: Snippet, in text: NSString) -> (range: NSRange, text: String, cursor: Int, selected: Int) {
        EditorCommands.apply(snippet, slashAt: slash, query: end - slash - 1, in: text)
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

    nonisolated(unsafe) private static let headingMarks = /^(\s{0,3})(#{1,6})\s+/

    /// ⌥⌘1 to ⌥⌘6: the line as a heading of [level]; the same level again,
    /// or 0, makes it plain text. A list or quote mark stays where it is not a heading.
    public static func heading(_ line: String, level: Int) -> String {
        let current = line.firstMatch(of: headingMarks)
        let text = current.map { String(line[$0.range.upperBound...]) } ?? line
        if level == 0 || current.map({ $0.2.count == level }) == true { return text }
        return String(repeating: "#", count: level) + " " + text
    }
}
