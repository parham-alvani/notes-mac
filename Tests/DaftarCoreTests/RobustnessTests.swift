import Foundation
import Testing

@testable import DaftarCore

/// Notes are written by hand, by plugins and by other apps, and a pull can
/// bring any of them. Every parser takes made-up text, much of it broken,
/// without a crash, and the edits keep what they promise. The text comes
/// from a fixed seed, so a failure happens again on the next run.
@Suite struct RobustnessTests {
    /// SplitMix64: small, fast and the same on every machine.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let pieces = [
        "# ", "## ", "###### ", "#", "#tag", "#a/b/", "#2026", "- ", "- [ ] ", "- [x] ", "- [-] ", "- [/] ", "* ", "1. ", "    ", "\t",
        "> ", "> [!note] ", ">", "```", "```js", "~~~", "`", "``", "$$", "$", "%%", "==", "**", "*", "_", "~~", "[[", "]]", "[[Note|", "]]",
        "![[", "[", "](", ")", "(", "<", ">", "<b>", "</b>", "<!--", "-->", "---", "tags: ", "tags:\n  - ", "aliases: [", "]", ":", "{", "}",
        "\"", "'", "|", "| --- |", "\\", "📅 2026-10-26", "⏳ 2026-02-30", "🛫 ", "🔁 every week", "🔁 every", "✅ 2026-10-26", "⏫", "🔺",
        "^block-id", "https://example.com/a?b#c", "mailto:x@y.z", "+34 612 345 678", "2026-W39", "{{title}}", "{{date:YYYY", "سلام",
        "دنیا", "שלום", "日本語", "👩‍👩‍👧‍👦", "\u{200f}", "\u{202e}", "e\u{301}", "\r", "\r\n", "\n", "\n\n", " ", "  ", "word", "Note",
        "9999-99-99", "0000-00-00", "-0", "1e999", "NaN",
    ]

    static func text(_ random: inout Seeded, pieces count: Int = 40) -> String {
        (0..<Int.random(in: 0...count, using: &random)).map { _ in
            Int.random(in: 0..<10, using: &random) == 0
                ? String(UnicodeScalar(UInt32.random(in: 0x20...0x2FFF, using: &random)) ?? "?")
                : pieces.randomElement(using: &random)!
        }.joined()
    }

    static func samples(_ count: Int, seed: UInt64, pieces: Int = 40) -> [String] {
        var random = Seeded(state: seed)
        return ["", "\n", "---", "---\n", "```", "- [ ]", "#", "[[", String(repeating: "a", count: 20000), String(repeating: "- [ ] x\n    ", count: 500)]
            + (0..<count).map { _ in text(&random, pieces: pieces) }
    }

    @Test func notesParseWhateverTheyHold() {
        for text in Self.samples(1500, seed: 1) {
            let note = NoteParser.parse(text)
            let lines = text.components(separatedBy: "\n").count
            #expect(note.headings.allSatisfy { $0.line >= 0 && $0.line < lines })
            #expect(note.tasks.allSatisfy { $0.line >= 0 && $0.line < lines })
            #expect(note.tags.allSatisfy { !$0.isEmpty })
            _ = MarkdownHighlighter.spans(in: text)
            _ = CalendarWeek.parse(text, path: "Calendar/2026-W39.md")
            _ = UnlinkedMentions.find(["Note", "word"], in: text)
            _ = YAML.parse(text)
            _ = Base.parse(text)
        }
    }

    @Test func theHighlighterStaysInsideTheText() {
        for text in Self.samples(500, seed: 2) {
            let length = (text as NSString).length
            for span in MarkdownHighlighter.spans(in: text) {
                #expect(span.range.location >= 0 && NSMaxRange(span.range) <= length)
            }
        }
    }

    @Test func taskLinesSurviveAnyText() {
        var random = Seeded(state: 3)
        for _ in 0..<3000 {
            let line = ["- [ ] ", "- [x] ", "  - [/] ", "> - [ ] ", ""].randomElement(using: &random)! + Self.text(&random, pieces: 12)
            _ = TaskLine.parse(line, line: 0, section: "")
            _ = TaskLine.toggled(line, today: "2026-10-26")
            _ = TaskMetadata.split(line)
            _ = EditorCommands.onReturn(after: line)
            _ = EditorCommands.toggleTask(line, today: Day(year: 2026, month: 10, day: 26))
            _ = EditorCommands.heading(line, level: Int.random(in: 0...6, using: &random))
            if let fields = TaskLine.fields(line), let edited = TaskLine.edited(line, fields) {
                // Writing a task back from its own fields keeps what it says.
                #expect(TaskLine.fields(edited) == fields, "\(line)")
            }
        }
    }

    @Test func datesAndRulesFromAnyText() {
        var random = Seeded(state: 4)
        for _ in 0..<3000 {
            let text = Self.text(&random, pieces: 4)
            _ = Day(text)
            _ = Recurrence(text)
            _ = Recurrence("every " + text)
            _ = BaseSpan.parse(text)
        }
        for text in ["0000-01-01", "9999-12-31", "2026-02-29", "2024-02-29", "2026-13-01", "-001-01-01"] {
            if let day = Day(text) {
                #expect(day.adding(days: 1) > day)
                #expect(day.adding(months: -1) < day)
            }
        }
    }

    @Test func periodicNamesFromAnyFormatAndPath() {
        var random = Seeded(state: 5)
        let formats = ["YYYY-MM-DD", "YYYY-[W]ww", "GGGG-[W]WW", "YYYY-[Q]Q", "dddd, MMMM Do YYYY", "[", "]", "", "YYYY/MM/", "Do Do", "x"]
        for _ in 0..<1500 {
            let format = Int.random(in: 0..<3, using: &random) == 0 ? Self.text(&random, pieces: 6) : formats.randomElement(using: &random)!
            let notes = PeriodicNotes(DailyNotes(folder: "", format: format))
            let day = Day(year: Int.random(in: 1...9999, using: &random), month: Int.random(in: 1...12, using: &random), day: Int.random(in: 1...28, using: &random))
            let name = MomentFormat.format(format, day)
            _ = notes.period(of: name + ".md")
            _ = notes.period(of: Self.text(&random, pieces: 6) + ".md")
            _ = notes.next(name + ".md")
            _ = notes.previous(name + ".md")
            _ = Templates().fill(Self.text(&random, pieces: 8) + "{{date:\(format)}}", title: "T", day: day, clock: .init(hour: 23, minute: 59))
        }
    }

    @Test func queriesAndExpressionsFromAnyText() {
        var random = Seeded(state: 6)
        let words = ["not done", "due before tomorrow", "path includes x", "(", ")", "AND", "OR", "group by", "sort by", "limit", "file.name", "==", "!=",
            "&&", "||", "\"", "'", ".", ",", "contains(", "date(", "now()", "1", "-", "+", "*", "/", "%", "[", "]", "!", "if(", "this.", "formula.",
            "\n", " ", "filter by function", "=>", "task.due"]
        for _ in 0..<3000 {
            let source = (0..<Int.random(in: 0...12, using: &random)).map { _ in words.randomElement(using: &random)! }.joined(separator: " ")
            _ = TasksQuery.parse(source)
            _ = TaskExpression.parse(source)
            _ = try? BaseParser.parse(source)
        }
    }

    @Test func canvasesFromAnyJSON() throws {
        var random = Seeded(state: 11)
        let words = ["{", "}", "[", "]", ",", ":", "\"nodes\"", "\"edges\"", "\"id\"", "\"type\"", "\"text\"", "\"file\"", "\"link\"", "\"group\"",
            "\"x\"", "\"y\"", "\"width\"", "\"height\"", "\"color\"", "\"fromNode\"", "\"toNode\"", "\"toEnd\"", "\"arrow\"", "\"a\"", "\"b\"",
            "\"1\"", "\"#ff0000\"", "0", "-1", "1e308", "1e999", "null", "true", "\"120\"", "\"", "\\"]
        for _ in 0..<3000 {
            let text = (0..<Int.random(in: 0...40, using: &random)).map { _ in words.randomElement(using: &random)! }.joined()
            let canvas = Canvas.parse(text)
            // What the parser keeps is drawable: every number finite, every
            // edge between two cards; and written out, it reads back the same.
            #expect(canvas.nodes.allSatisfy { [$0.x, $0.y, $0.width, $0.height].allSatisfy(\.isFinite) && $0.width > 0 && $0.height > 0 })
            let ids = Set(canvas.nodes.map(\.id))
            #expect(canvas.edges.allSatisfy { ids.contains($0.fromNode) && ids.contains($0.toNode) })
            let again = Canvas.parse(String(decoding: try JSONEncoder().encode(canvas), as: UTF8.self))
            #expect(again == canvas, "\(text)")
            _ = canvas.nodes.map { Canvas.color($0.color) }
        }
        for text in Self.samples(300, seed: 12) { _ = Canvas.parse(text) }
    }

    @Test func pastesFromAnyHTML() {
        var random = Seeded(state: 7)
        let tags = ["<p>", "</p>", "<b>", "</b>", "<ul>", "<li>", "</ul>", "<ol start=\"x\">", "<table><tr><td>", "</td><td>", "</table>",
            "<pre class=\"language-\">", "</pre>", "<a href=\"\">", "<a href=\"javascript:x\">", "</a>", "<img src=\"data:x\">", "<br>", "<h7>",
            "<h1>", "</h1>", "<blockquote>", "<input type=checkbox checked>", "&amp;", "&nbsp;", "<", ">", "<span style=\"font-weight:700\">", "</span>"]
        for _ in 0..<500 {
            let html = (0..<Int.random(in: 0...20, using: &random)).map { _ in
                Bool.random(using: &random) ? tags.randomElement(using: &random)! : Self.text(&random, pieces: 3)
            }.joined()
            _ = HTMLMarkdown.convert(html)
        }
    }

    @Test func tablesFormatWithoutLosingRows() {
        var random = Seeded(state: 8)
        for _ in 0..<1000 {
            let lines = (1...Int.random(in: 1...6, using: &random)).map { _ in
                "|" + (0..<Int.random(in: 0...5, using: &random)).map { _ in Self.text(&random, pieces: 2).replacingOccurrences(of: "\n", with: " ") + "|" }.joined()
            }
            let formatted = MarkdownTable.format(lines)
            #expect(formatted.count == lines.count)
            let row = Int.random(in: 0..<lines.count, using: &random)
            _ = MarkdownTable.tab(lines, row: row, column: Int.random(in: 0...6, using: &random), back: Bool.random(using: &random))
            _ = MarkdownTable.column(at: Int.random(in: 0...200, using: &random), in: lines[row])
        }
    }

    @Test func editorHelpersTakeAnyCursor() {
        for text in Self.samples(400, seed: 9, pieces: 15) {
            let string = text as NSString
            var random = Seeded(state: UInt64(string.length))
            for _ in 0..<5 {
                let location = Int.random(in: 0...string.length, using: &random)
                let length = Int.random(in: 0...(string.length - location), using: &random)
                _ = EditorCommands.linkQuery(in: string, at: location)
                _ = EditorCommands.opensSlashMenu(in: string, at: location)
                _ = MarkdownHighlighter.blockState(before: location, in: string)
                _ = EditorCommands.moveLines(in: string, selection: NSRange(location: location, length: length), up: Bool.random(using: &random))
            }
            _ = EditorCommands.extractName(from: text)
            _ = EditorCommands.extractBody(text)
        }
    }

    @Test func messagesFromNeovimMayBeBroken() {
        var random = Seeded(state: 10)
        for _ in 0..<5000 {
            let bytes = (0..<Int.random(in: 0...24, using: &random)).map { _ in UInt8.random(in: 0...255, using: &random) }
            // What was read can be written and read again; `int` 5 may come back as `uint` 5.
            if let value = try? MessagePack.decode(Data(bytes)) {
                #expect((try? MessagePack.decode(MessagePack.encode(value))) != nil)
            }
        }
        // A length that claims more than there is.
        for bytes: [UInt8] in [[0xdb, 0xff, 0xff, 0xff, 0xff], [0xdd, 0x7f, 0xff, 0xff, 0xff], [0xdf, 0xff, 0xff, 0xff, 0xff, 0x01], [0xc6, 0xff, 0xff, 0xff, 0xff]] {
            #expect(throws: (any Error).self) { try MessagePack.decode(Data(bytes)) }
        }
    }

    @Test func settingsFilesMayBeBroken() {
        for text in Self.samples(500, seed: 11, pieces: 12) {
            let data = Data(text.utf8)
            _ = try? OrderedJSON.parse(text)
            _ = Iconic.parse(data)
            _ = DailyNotes(json: data)
            _ = Templates(json: data)
            _ = ReadingPlaces(data: data)
            _ = ConfigFile(text: text)
            // A list of names reads back as it was written.
            _ = ConfigFile(text: "x = " + text).strings("x")
            var config = ConfigFile(text: "")
            config.set("files.hidden", .strings([text, "CLAUDE.md"]))
            #expect(config.strings("files.hidden") == [text, "CLAUDE.md"] || text.contains(where: \.isNewline), "\(text.debugDescription) -> \(config.text.debugDescription)")
            let home = Beautitab(json: data)
            #expect(!home.showQuote || !home.quotes.isEmpty)
            _ = Home.pictureURL(text, vault: URL(filePath: "/vault"))
        }
    }

    @Test func theNewEditsKeepEveryLine() {
        for text in Self.samples(1500, seed: 12) {
            if let sorted = TaskSorter.sort(text) {
                #expect(sorted.components(separatedBy: "\n").sorted() == text.components(separatedBy: "\n").sorted())
                #expect(TaskSorter.sort(sorted) == nil)
            }
            let renamed = TagRename.rename(text, from: "tag", to: "label")
            #expect(renamed.components(separatedBy: "\n").count == text.components(separatedBy: "\n").count)
            #expect(TagRename.rename(text, from: "absent-tag", to: "other") == text)
            for heading in [nil, "Inbox", "## Note", "word"] {
                let added = QuickCapture.append("captured ✱", to: text, heading: heading)
                #expect(Self.keeps(text.components(separatedBy: "\n"), in: added.components(separatedBy: "\n")))
                #expect(added.components(separatedBy: "\n").count { $0.hasPrefix("captured ✱") } == 1)
            }
            for (find, regex) in [("a", false), ("#", false), (#"\[\[([^\]]*)\]\]"#, true), ("^", true), (#"\s*"#, true), ("(", true)] {
                let options = VaultReplace.Options(regularExpression: regex, skipCode: find.count % 2 == 0)
                guard let found = try? VaultReplace.matches(in: text, find: find, replace: "$1", options: options) else {
                    // An invalid pattern is reported, never a crash.
                    #expect(find == "(")
                    continue
                }
                #expect(VaultReplace.apply([], to: text) == text)
                let same = found.map { match in var match = match; match.replacement = match.found; return match }
                #expect(VaultReplace.apply(same, to: text) == text)
                _ = VaultReplace.apply(found, to: text)
            }
        }
    }

    /// The properties form reads any front matter, prints it back byte for
    /// byte when nothing changed, and an edit never touches the body.
    @Test func propertiesFromAnyFrontMatter() throws {
        var random = Seeded(state: 15)
        let keys = ["title: ", "tags:\n  - ", "tags: [", "aliases:\n- ", "k: '", "k: \"", "x:", "\n", "\r\n", "  - ", "# ", " #", "&a ", "*a"]
        for (index, text) in Self.samples(1500, seed: 15, pieces: 12).enumerated() {
            let yaml = (0..<Int.random(in: 0...6, using: &random)).map { _ in keys.randomElement(using: &random)! + Self.text(&random, pieces: 3) }
            let body = Self.text(&random, pieces: 8)
            for note in [text, "---\n" + yaml.joined(separator: "\n") + "\n---\n" + body] {
                let read = PropertySheet.read(note)
                #expect(PropertySheet.length(of: note) <= (note as NSString).length)
                guard var sheet = read.sheet else { continue }
                #expect(sheet.applied(to: note) == note, "\(note.debugDescription)")
                let rest = String(decoding: note.utf8.dropFirst(sheet.original.utf8.count), as: UTF8.self)
                // An edit: set, add, rename or remove, then the body is as it was.
                let key = sheet.properties.randomElement(using: &random)?.key
                switch index % 4 {
                case 0: if let key { sheet.set(key, .list(["a", Self.text(&random, pieces: 2)])) }
                case 1: try? sheet.add(Self.text(&random, pieces: 2), .text(Self.text(&random, pieces: 3)))
                case 2: if let key { try? sheet.rename(key, to: Self.text(&random, pieces: 2)) }
                default: if let key { sheet.remove(key) }
                }
                let edited = try #require(sheet.applied(to: note))
                #expect(edited.hasSuffix(rest))
                // What was written reads back as a form with the same values.
                if !sheet.properties.isEmpty, case .form(let again) = PropertySheet.read(edited) {
                    #expect(again.properties.map(\.key) == sheet.properties.map(\.key), "\(edited.debugDescription)")
                    #expect(again.properties.map(\.value) == sheet.properties.map(\.value), "\(edited.debugDescription)")
                } else if !sheet.properties.isEmpty {
                    Issue.record("Not a form after an edit: \(edited.debugDescription)")
                }
            }
        }
    }

    /// Every line of [old] is in [new], in the same order.
    static func keeps(_ old: [String], in new: [String]) -> Bool {
        var rest = new[...]
        for line in old {
            guard let at = rest.firstIndex(of: line) else { return false }
            rest = rest[(at + 1)...]
        }
        return true
    }

    @Test func aDiffTakesTheOldTextToTheNew() {
        var random = Seeded(state: 13)
        for _ in 0..<500 {
            let lines = (0..<Int.random(in: 0...30, using: &random)).map { _ in ["a", "b", "c", "", "- [ ] x"].randomElement(using: &random)! }
            var changed = lines
            for _ in 0..<Int.random(in: 0...6, using: &random) {
                switch Int.random(in: 0..<3, using: &random) {
                case 0 where !changed.isEmpty: changed.remove(at: Int.random(in: 0..<changed.count, using: &random))
                case 1: changed.insert("new", at: Int.random(in: 0...changed.count, using: &random))
                default: if !changed.isEmpty { changed[Int.random(in: 0..<changed.count, using: &random)] = "changed" }
                }
            }
            let diff = LineDiff.lines(from: lines.joined(separator: "\n"), to: changed.joined(separator: "\n"))
            func trimmed(_ lines: [String]) -> [String] { lines.last == "" ? Array(lines.dropLast()) : lines }
            let before = diff.filter { $0.kind != .added }.map(\.text), after = diff.filter { $0.kind != .removed }.map(\.text)
            // A last empty line is the newline at the end of the file.
            #expect(before == trimmed(lines))
            #expect(after == trimmed(changed))
            #expect(LineDiff.hunks(diff).flatMap { $0 }.count { $0.kind != .same } == diff.count { $0.kind != .same })
        }
    }

    @Test func conflictMarksFromAnyText() {
        let marks = ["<<<<<<< HEAD\n", "||||||| base\n", "=======\n", ">>>>>>> abc (mine)\n", "<<<<<<<\r\n", "=======\r\n", ">>>>>>>"]
        var random = Seeded(state: 14)
        for text in Self.samples(1000, seed: 14) {
            #expect(ConflictText.resolve(ConflictText.parse(text), choices: [:]) == text)
            if !text.contains("<<<<<<<") { #expect(ConflictText.parse(text) == [.plain(text)]) }
            // Lines of plain text with marks put in at random.
            let lines = text.components(separatedBy: "\n").flatMap { line in
                Int.random(in: 0..<3, using: &random) == 0 ? [line + "\n", marks.randomElement(using: &random)!] : [line + "\n"]
            }
            let marked = lines.joined()
            let parts = ConflictText.parse(marked)
            #expect(ConflictText.resolve(parts, choices: [:]) == marked)
            // Keeping both keeps every line of both sides.
            let both = ConflictText.resolve(parts, all: .both)
            for conflict in ConflictText.conflicts(in: marked) {
                for line in ConflictText.lines(of: conflict.remote) + ConflictText.lines(of: conflict.mine) { #expect(both.contains(line)) }
            }
            for choice in ConflictText.Choice.allCases { _ = ConflictText.resolve(parts, all: choice) }
        }
    }

    /// A Quick Look preview always has a page: the renderer never throws on
    /// a note, and a `src` that names nothing in the vault stays as it was.
    @Test func quickLookPreviewsAnyNote() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "daftar-robust-ql-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let renderer = quickLookScript.flatMap { QuickLookPreview.Renderer(script: $0) }
        for text in Self.samples(300, seed: 14) {
            let parsed = NoteParser.parse(text)
            let links = QuickLookPreview.links(in: parsed, from: "Note.md", files: ["Note.md", "uploads/a.png"])
            let input = QuickLookPreview.input(text: text, path: "Note.md", links: links)
            let html = renderer.map { $0.html(input) } ?? text
            #expect(html != nil)
            let page = QuickLookPreview.attach(html ?? "", root: root, path: "Note.md")
            #expect(page.attachments.isEmpty)
            #expect(page.html == html)
        }
    }
}
