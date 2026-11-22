import Foundation

/// What the editor draws in place of a note's text: a task's box, the date
/// chips, a callout's panel and a code block's (docs/specs/look.md in
/// notes-linux, part 2). Each is a pure rule over the text of a line. A
/// drawn part is a way to see the text, never the text: nothing here changes
/// a letter, except the click on a box, which is the task toggle.
public enum DrawnParts {
    /// Whether [selection] is inside [part]: a caret anywhere from before
    /// its first character to after its last, or a selection that reaches
    /// into it. The part is shown raw then.
    public static func isInside(_ selection: NSRange, of part: NSRange) -> Bool {
        selection.length > 0
            ? NSIntersectionRange(part, selection).length > 0
            : selection.location >= part.location && selection.location <= NSMaxRange(part)
    }
}

/// The box drawn in place of a task's `- [ ]`.
public struct TaskBox: Equatable, Sendable {
    /// What the box takes the place of, in the line: the marker, its space
    /// and the brackets (`- [ ]`), or the brackets alone after a number.
    public var cover: NSRange
    /// The character between the brackets.
    public var status: Character
    /// Where the task's text starts in the line, after the space.
    public var text: Int

    /// The box of a line whose list marker (with its indent and spaces) is
    /// [list] and whose brackets are [brackets]: nil until the space after
    /// `]` is typed.
    init?(list: NSRange, brackets: NSRange, in line: NSString) {
        let after = NSMaxRange(brackets)
        guard after < line.length, line.character(at: after) == 0x20, brackets.length >= 3 else { return nil }
        var marker = list.location
        while marker < NSMaxRange(list), line.character(at: marker) == 0x20 || line.character(at: marker) == 0x09 { marker += 1 }
        guard marker < NSMaxRange(list) else { return nil }
        let bullet = [0x2D, 0x2A, 0x2B].contains(line.character(at: marker))
        cover = bullet ? NSRange(location: marker, length: after - marker) : brackets
        status = line.substring(with: NSRange(location: brackets.location + 1, length: brackets.length - 2)).first ?? " "
        text = after + 1
    }

    /// The box of [line], when it is a task with its mark complete.
    public static func find(in line: String) -> TaskBox? {
        MarkdownHighlighter.taskBox(in: line as NSString)
    }

    /// Whether the box is drawn with the caret or the selection at
    /// [selection], in the line's own offsets: inside the cover, the raw
    /// marks show.
    public func isDrawn(with selection: NSRange) -> Bool {
        !DrawnParts.isInside(selection, of: cover)
    }

    /// How a status is drawn: a Lucide icon, filled with one colour.
    public struct Drawing: Equatable, Sendable {
        public var icon: String
        /// The palette's name of the colour: `listMarker`, `done`, `accent`, or a colour.
        public var colour: String

        public init(_ icon: String, _ colour: String) {
            self.icon = icon
            self.colour = colour
        }
    }

    /// The reader's table (`statuses` in web/build.mjs, which writes `tasks.css`).
    static let table: [Character: Drawing] = [
        " ": Drawing("square", "listMarker"), "x": Drawing("square-check-big", "done"), "X": Drawing("square-check-big", "done"),
        "-": Drawing("square-x", "done"), "/": Drawing("square-dot", "accent"), ">": Drawing("square-arrow-right", "blue"),
        "<": Drawing("calendar-clock", "blue"), "!": Drawing("circle-alert", "red"), "?": Drawing("circle-help", "yellow"),
        "*": Drawing("star", "vividYellow"), "\"": Drawing("quote", "warmGrey"), "i": Drawing("info", "blue"),
        "b": Drawing("bookmark", "orange"), "l": Drawing("map-pin", "red"), "I": Drawing("lightbulb", "vividYellow"),
        "S": Drawing("piggy-bank", "green"), "f": Drawing("flame", "red"), "k": Drawing("key", "vividYellow"),
        "w": Drawing("trophy", "vividYellow"), "u": Drawing("thumbs-up", "green"), "p": Drawing("thumbs-up", "green"),
        "d": Drawing("thumbs-down", "red"), "c": Drawing("thumbs-down", "red"),
    ]

    /// Every icon a box may be drawn with.
    public static var icons: Set<String> { Set(table.values.map(\.icon)).union(["square-dashed"]) }

    /// The drawing of [symbol]: the reader's table first, then the type the
    /// vault gives the symbol; a symbol the vault does not have is dashed.
    public static func drawing(_ symbol: Character, statuses: TaskStatuses = .current) -> Drawing {
        if let known = table[symbol] { return known }
        guard let status = statuses.all.first(where: { $0.symbol == symbol }) else { return Drawing("square-dashed", "listMarker") }
        return switch status.type {
        case .todo: Drawing("square", "listMarker")
        case .done: Drawing("square-check-big", "done")
        case .inProgress: Drawing("square-dot", "accent")
        case .cancelled: Drawing("square-x", "done")
        case .nonTask: Drawing("square-dashed", "listMarker")
        }
    }

    /// The lines [line] becomes at a click on its box: the task toggle's
    /// answer (`TaskLine.toggled`), and nothing for a line with no box.
    public static func clicked(_ line: String, today: String, statuses: TaskStatuses = .current) -> [String]? {
        guard find(in: line) != nil else { return nil }
        return TaskLine.toggled(line, today: today, statuses: statuses)
    }

    /// Where the place [offset] of the note is after a click replaced the
    /// line at [line] (without its line break) with [lines]: a place before
    /// the line stays, one after it moves with the text, and one in the line
    /// keeps its offset in the task's own line, which is the last of [lines]
    /// (a repeating task leaves its next occurrence above).
    public static func moved(_ offset: Int, line: NSRange, lines: [String]) -> Int {
        let lengths = lines.map { ($0 as NSString).length }
        let total = lengths.reduce(0, +) + max(0, lines.count - 1)
        if offset < line.location { return offset }
        if offset > NSMaxRange(line) { return offset + total - line.length }
        let last = lengths.last ?? 0
        return line.location + total - last + min(offset - line.location, last)
    }
}

/// A date of a task, drawn as a pill: the emoji and the day as written.
public struct DateChip: Equatable, Sendable {
    public enum Kind: Hashable, Sendable {
        case due, late, scheduled, start, created, done, cancelled, repeats

        /// The palette's name of the chip's colour.
        public var colour: String {
            switch self {
            case .due: "orange"
            case .late, .cancelled: "red"
            case .scheduled: "blue"
            case .start: "purple"
            case .created: "muted"
            case .done: "green"
            case .repeats: "pink"
            }
        }
    }

    public var kind: Kind
    /// From the emoji to the last digit, or to the last letter of a rule.
    public var range: NSRange

    private static let dated: [String: Kind] = ["➕": .created, "⏳": .scheduled, "🛫": .start, "📅": .due, "✅": .done, "❌": .cancelled]
    /// What a line must hold to have a chip.
    private static let marks = CharacterSet(charactersIn: "➕⏳🛫📅✅❌🔁")
    /// What ends a repeat's rule: the next date, a priority.
    private static let ends = CharacterSet(charactersIn: "➕⏳🛫📅✅❌🔁🔺⏫🔼🔽⏬")
    nonisolated(unsafe) private static let date = try! NSRegularExpression(pattern: #"(➕|⏳|🛫|📅|✅|❌)\x{FE0F}? ([0-9]{4}-[0-9]{2}-[0-9]{2})(?![0-9])"#)
    nonisolated(unsafe) private static let blockId = try! NSRegularExpression(pattern: #"\s\^[A-Za-z0-9-]+\s*$"#)

    /// The chips of a task's line, from [from] on (the task's text):
    /// each date emoji with one space and a real day, and `🔁` with its
    /// rule. A due date is late when its day is before [today] and [status]
    /// is still open.
    static func chips(in line: NSString, from: Int, status: Character, today: String?, statuses: TaskStatuses = .current) -> [DateChip] {
        let rest = NSRange(location: from, length: line.length - from)
        guard rest.length > 0, line.rangeOfCharacter(from: marks, options: [], range: rest).location != NSNotFound else { return [] }
        var out: [DateChip] = []
        date.enumerateMatches(in: line as String, range: rest) { match, _, _ in
            guard let match, let kind = dated[line.substring(with: match.range(at: 1))] else { return }
            let day = line.substring(with: match.range(at: 2))
            // A day that is not real stays as written: the audit names it.
            guard Day(day) != nil else { return }
            var late = false
            if kind == .due, let today, day < today {
                let type = statuses.type(status)
                late = type == .todo || type == .inProgress
            }
            out.append(DateChip(kind: late ? .late : kind, range: match.range))
        }
        var at = from
        while at < line.length {
            let mark = line.range(of: "🔁", options: .literal, range: NSRange(location: at, length: line.length - at))
            guard mark.location != NSNotFound else { break }
            var start = NSMaxRange(mark)
            if start < line.length, line.character(at: start) == 0xFE0F { start += 1 }
            var end = line.rangeOfCharacter(from: ends, options: [], range: NSRange(location: start, length: line.length - start)).location
            if end == NSNotFound { end = line.length }
            let id = blockId.rangeOfFirstMatch(in: line as String, range: NSRange(location: start, length: line.length - start))
            if id.location != NSNotFound { end = min(end, id.location) }
            while end > start, line.character(at: end - 1) == 0x20 || line.character(at: end - 1) == 0x09 { end -= 1 }
            // `🔁` with no rule after it says nothing.
            if end > start { out.append(DateChip(kind: .repeats, range: NSRange(location: mark.location, length: end - mark.location))) }
            at = max(end, NSMaxRange(mark))
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    /// The chips of [line]: none on a line that is not a task.
    public static func chips(in line: String, today: Day, statuses: TaskStatuses = .current) -> [DateChip] {
        guard let box = TaskBox.find(in: line) else { return [] }
        return chips(in: line as NSString, from: box.text, status: box.status, today: today.description, statuses: statuses)
    }
}

/// A callout: a run of `>` lines whose first is `> [!kind]`.
public enum Callout {
    /// The first line of a callout.
    public struct Head: Equatable, Sendable {
        /// The kind as written, in small letters.
        public var kind: String
        /// The kind it is drawn as: `note` for one the reader does not know.
        public var drawn: String
        /// The title: as written, or the kind's name with a capital when none is.
        public var title: String
        /// A title is written on the line.
        public var titled: Bool
    }

    /// Each kind's Lucide icon, with Obsidian's aliases (`calloutIcons` in web/build.mjs).
    static let table: [String: String] = {
        let groups: [([String], String)] = [
            (["note"], "pencil"), (["info"], "info"), (["abstract", "summary", "tldr"], "clipboard-list"), (["todo"], "circle-check"),
            (["tip", "hint", "important"], "flame"), (["success", "check", "done"], "check"), (["question", "help", "faq"], "circle-help"),
            (["warning", "caution", "attention"], "triangle-alert"), (["failure", "fail", "missing"], "x"), (["danger", "error"], "zap"),
            (["bug"], "bug"), (["example"], "list"), (["quote", "cite"], "quote"), (["figure"], "image"), (["read"], "book-open"),
        ]
        var out: [String: String] = [:]
        for (kinds, icon) in groups { for kind in kinds { out[kind] = icon } }
        return out
    }()

    /// Every icon a callout may be drawn with.
    public static var icons: Set<String> { Set(table.values) }

    /// The Lucide icon of [kind]; a kind the reader does not know has `note`'s.
    public static func icon(of kind: String) -> String { table[kind.lowercased()] ?? "pencil" }

    nonisolated(unsafe) private static let head = try! NSRegularExpression(pattern: #"^(?:[ \t]*>)+[ \t]?\[!([\w-]+)\][+-]?(.*)$"#)

    /// The head of a callout, when [line] is one: `> [!kind]`, with `+` or
    /// `-` and a title after it or not.
    public static func head(of line: String) -> Head? {
        guard line.utf8.contains(UInt8(ascii: "!")) else { return nil }
        let ns = line as NSString
        guard let match = head.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let kind = ns.substring(with: match.range(at: 1)).lowercased()
        let written = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
        return Head(
            kind: kind, drawn: table[kind] == nil ? "note" : kind,
            title: written.isEmpty ? name(of: kind) : written, titled: !written.isEmpty)
    }

    /// The kind's name as a title: `tip` reads "Tip". It is drawn, never written.
    public static func name(of kind: String) -> String {
        kind.prefix(1).uppercased() + kind.dropFirst().lowercased()
    }

    /// One callout's panel: its lines, from 0, and what its first line says.
    public struct Panel: Equatable, Sendable {
        public var lines: Range<Int>
        public var kind: String
        public var title: String
    }

    /// The panels of the callouts in [text]. A `>` run with no `[!kind]`
    /// is a quote and has none.
    public static func panels(in text: String) -> [Panel] {
        var out: [Panel] = []
        var state = MarkdownHighlighter.BlockState.normal
        var open: (start: Int, head: Head?)?
        let lines = text.components(separatedBy: "\n")
        func close(at line: Int) {
            if let run = open, let head = run.head { out.append(Panel(lines: run.start..<line, kind: head.drawn, title: head.title)) }
            open = nil
        }
        for (index, line) in lines.enumerated() {
            let before = state
            state = MarkdownHighlighter.next(after: line, from: state, firstLine: index == 0)
            let quoted = line.drop { $0 == " " || $0 == "\t" }.hasPrefix(">")
            // A `>` line of a code block that no quote opened is code.
            guard quoted, open != nil || before == .normal else {
                close(at: index)
                continue
            }
            if open == nil { open = (index, head(of: line)) }
        }
        close(at: lines.count)
        return out
    }
}

/// A code block: from its opening fence to its closing one.
public enum CodeBlock {
    /// The language word of a fence's line, in small letters; nil when it names none.
    public static func word(ofFence line: String) -> String? {
        let word = line.trimmingCharacters(in: CharacterSet(charactersIn: "`~> \t\n")).split(separator: " ").first.map { $0.lowercased() }
        return word?.isEmpty == false ? word : nil
    }

    /// One block's panel: its lines, from 0, fences and all, and its word.
    public struct Panel: Equatable, Sendable {
        public var lines: Range<Int>
        public var word: String?
    }

    /// The panels of the code blocks in [text]. A fence that is not closed
    /// runs to the note's end, and so does its panel.
    public static func panels(in text: String) -> [Panel] {
        var out: [Panel] = []
        var state = MarkdownHighlighter.BlockState.normal
        var open: (start: Int, word: String?)?
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let before = state
            state = MarkdownHighlighter.next(after: line, from: state, firstLine: index == 0)
            if case .fence = state, before == .normal {
                open = (index, word(ofFence: line))
            } else if case .fence = before, state == .normal, let block = open {
                out.append(Panel(lines: block.start..<index + 1, word: block.word))
                open = nil
            }
        }
        if let block = open { out.append(Panel(lines: block.start..<lines.count, word: block.word)) }
        return out
    }
}

/// A Markdown table the editor draws as a grid: a header row, a delimiter
/// row under it, then its rows, each a line that starts with `|` at the
/// line's start or after spaces. The text stays a Markdown table: the grid
/// is how its pipes, its padding and its delimiter row are drawn.
public struct TableGrid: Equatable, Sendable {
    /// The side of a column its cells stand on, from the delimiter row's colons.
    public enum Side: Equatable, Sendable {
        /// No colon: each cell on the side its own text reads from.
        case none
        case start, centre, end
    }

    /// One line of the table.
    public struct Row: Equatable, Sendable {
        /// The line in the text, without its line break.
        public var line: NSRange
        /// Each cell's text in the text, without the padding spaces. An
        /// empty cell is a place after its first padding space.
        public var cells: [NSRange]
        /// The pipes that part the cells: not an escaped `\|`.
        public var pipes: [Int]

        /// The cell that holds [offset]: between its two pipes, the place
        /// just after the first and the place just before the second
        /// counted. Nil before the first pipe and after the closing one.
        public func cell(at offset: Int) -> Int? {
            let before = pipes.prefix { $0 < offset }.count
            guard before >= 1, before - 1 < cells.count, offset <= NSMaxRange(line) else { return nil }
            return before - 1
        }
    }

    /// From the header's first letter to the last row's last.
    public var range: NSRange
    /// The header, the delimiter row, then the rows.
    public var rows: [Row]
    /// Each column's side.
    public var sides: [Side]

    /// As many columns as the widest row has cells.
    public var columns: Int { rows.enumerated().filter { $0.offset != 1 }.map(\.element.cells.count).max() ?? 0 }

    /// A table of more rows under its delimiter row is not a grid.
    public static let mostRows = 200

    /// Whether the line that starts at [start] is a table's row: a pipe at
    /// the line's start or after spaces only.
    public static func isRow(_ text: NSString, at start: Int) -> Bool {
        var at = start
        while at < text.length, text.character(at: at) == 0x20 { at += 1 }
        return at < text.length && text.character(at: at) == 0x7C
    }

    /// The rows next to each other around the line at [location]: from the
    /// first row's start to the last row's end, without its line break. Nil
    /// when that line is no row. It looks no further than [most] lines each
    /// way: [whole] says it found both ends.
    public static func run(around location: Int, in text: NSString, most: Int = mostRows + 10) -> (range: NSRange, whole: Bool)? {
        var start = 0, end = 0, contents = 0
        text.getLineStart(&start, end: &end, contentsEnd: &contents, for: NSRange(location: min(location, text.length), length: 0))
        guard isRow(text, at: start), start < contents else { return nil }
        var first = start, last = contents, next = end
        var whole = true, count = 0
        while first > 0 {
            var above = 0
            text.getLineStart(&above, end: nil, contentsEnd: nil, for: NSRange(location: first - 1, length: 0))
            guard isRow(text, at: above) else { break }
            guard count < most else {
                whole = false
                break
            }
            first = above
            count += 1
        }
        count = 0
        // A line with nothing after its break is the text's end, not a row.
        while next < text.length, next > last {
            guard isRow(text, at: next) else { break }
            guard count < most else {
                whole = false
                break
            }
            var lineEnd = 0, lineContents = 0
            text.getLineStart(nil, end: &lineEnd, contentsEnd: &lineContents, for: NSRange(location: next, length: 0))
            last = lineContents
            next = lineEnd
            count += 1
        }
        return (NSRange(location: first, length: last - first), whole)
    }

    /// One row's cells and pipes, for the line [line] of [text] (without its line break).
    public static func row(_ text: NSString, line: NSRange) -> Row {
        var pipes: [Int] = []
        var escaped = false
        let end = NSMaxRange(line)
        for at in line.location..<end {
            let unit = text.character(at: at)
            if unit == 0x7C, !escaped { pipes.append(at) }
            escaped = unit == 0x5C && !escaped
        }
        func blank(_ at: Int) -> Bool { text.character(at: at) == 0x20 || text.character(at: at) == 0x09 }
        /// The text between [from] and [to], without the spaces around it.
        func cell(_ from: Int, _ to: Int) -> NSRange {
            var low = from, high = to
            while low < high, blank(low) { low += 1 }
            while high > low, blank(high - 1) { high -= 1 }
            // An empty cell: between its two padding spaces, or just after its pipe.
            if low == high { return NSRange(location: min(from + (to > from ? 1 : 0), to), length: 0) }
            return NSRange(location: low, length: high - low)
        }
        var cells: [NSRange] = []
        for (index, pipe) in pipes.enumerated() {
            if index + 1 < pipes.count {
                cells.append(cell(pipe + 1, pipes[index + 1]))
            } else {
                // A row with no closing pipe: what is after the last one is a cell.
                let rest = cell(pipe + 1, end)
                if rest.length > 0 { cells.append(rest) }
            }
        }
        return Row(line: line, cells: cells, pipes: pipes)
    }

    /// The grid of the rows at [range] of [text], as `run` gave it: nil
    /// when the second line is no delimiter row, or the rows are too many.
    public init?(_ range: NSRange, in text: NSString) {
        var rows: [Row] = []
        var at = range.location
        let end = NSMaxRange(range)
        while at <= end, at < text.length || rows.isEmpty {
            var lineEnd = 0, contents = 0
            text.getLineStart(nil, end: &lineEnd, contentsEnd: &contents, for: NSRange(location: at, length: 0))
            rows.append(TableGrid.row(text, line: NSRange(location: at, length: contents - at)))
            guard lineEnd > at, lineEnd <= end else { break }
            at = lineEnd
            guard rows.count <= TableGrid.mostRows + 2 else { return nil }
        }
        guard rows.count >= 2, rows.count - 2 <= TableGrid.mostRows else { return nil }
        let marks = rows[1].cells.map { text.substring(with: $0) }
        guard MarkdownTable.isSeparator(marks) else { return nil }
        self.range = range
        self.rows = rows
        sides = marks.map { mark in
            switch (mark.hasPrefix(":"), mark.hasSuffix(":")) {
            case (true, true): .centre
            case (true, false): .start
            case (false, true): .end
            case (false, false): .none
            }
        }
    }

    /// The grid that holds the line at [location] of [text].
    public static func find(around location: Int, in text: NSString) -> TableGrid? {
        guard let run = run(around: location, in: text), run.whole else { return nil }
        return TableGrid(run.range, in: text)
    }

    /// The grid of [lines], one after the other with a line break between
    /// them: the header first.
    public static func find(in lines: [String]) -> TableGrid? {
        guard !lines.isEmpty else { return nil }
        let text = lines.joined(separator: "\n") as NSString
        guard let found = find(around: 0, in: text), NSMaxRange(found.range) == text.length else { return nil }
        return found
    }

    /// The row that holds [offset], its end counted.
    public func row(at offset: Int) -> Int? {
        rows.firstIndex { offset >= $0.line.location && offset <= NSMaxRange($0.line) }
    }

    /// Whether the table shows raw with the caret or the selection at
    /// [selection]: the caret on the delimiter row, or a selection that
    /// reaches outside one cell. A caret in a cell edits it in place.
    public func isRaw(with selection: NSRange) -> Bool {
        if selection.length == 0 { return row(at: selection.location) == 1 }
        let end = NSMaxRange(selection)
        guard selection.location < NSMaxRange(range), end > range.location else { return false }
        guard let first = row(at: selection.location), first == row(at: end), first != 1,
            let cell = rows[first].cell(at: selection.location), cell == rows[first].cell(at: end)
        else { return true }
        return false
    }

    /// Whether the table reads from the right: as the reader has it, the
    /// direction of the first cell with a letter.
    public func rightToLeft(in text: NSString) -> Bool {
        for (index, row) in rows.enumerated() where index != 1 {
            for cell in row.cells where cell.length > 0 {
                if let rtl = TextDirection.ofLine(text.substring(with: cell)) { return rtl }
            }
        }
        return false
    }

    /// How the caret came to a place.
    public enum Step: Sendable {
        /// One place on, one place back, or from anywhere (a click, a line up or down).
        case forward, back, near
    }

    /// Where a caret put at [offset] of [row] stands: in a cell's text it
    /// stays; on a pipe or in the padding it goes on to the next cell's
    /// text, back to the end of the one before, or to the nearest. Nil when
    /// the row has no cell that way: the caret leaves the row.
    public static func caret(_ offset: Int, in row: Row, step: Step) -> Int? {
        if row.cells.contains(where: { offset >= $0.location && offset <= NSMaxRange($0) }) { return offset }
        switch step {
        case .forward: return row.cells.first { $0.location > offset }?.location
        case .back: return row.cells.last { NSMaxRange($0) < offset }.map { NSMaxRange($0) }
        case .near:
            let places = row.cells.flatMap { [$0.location, NSMaxRange($0)] }
            return places.min { abs($0 - offset) < abs($1 - offset) } ?? offset
        }
    }
}
