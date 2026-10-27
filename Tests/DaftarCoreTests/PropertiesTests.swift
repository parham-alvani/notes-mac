import Foundation
import Testing

@testable import DaftarCore

@Suite struct PropertiesTests {
    static let representable = [
        "---\ntitle: Plain\n---\nBody",
        "---\ntitle: 'single ''quoted'''\nother: \"double \\\"quoted\\\" \\\\ x\"\n---\n",
        "---\ntags: [a, \"b c\", 'd']\naliases: []\n---\n# Heading\n",
        "---\ntags:\n  - a\n  - b\naliases:\n- one\n- 'two'\n---\n",
        "---\ntags:\n    -   spaced\n    -   items\n---\n",
        "---\nempty:\nnext: 1\n---\n",
        "---\n\ntitle: blank lines kept\n\n\nother: x\n\n---\n",
        "---\r\ntitle: crlf\r\ntags:\r\n  - a\r\n---\r\nBody\r\n",
        "---\ntitle: no newline after the fence\n---",
        "---\n---\nNo properties",
        "---\ndone: true\ncount: 12\nratio: -0.5\nday: 2026-10-25\nwhen: 2026-10-25T09:30\nup: \"[[Parent]]\"\n---\n",
        "---\n\"quoted key\": v\n'single key': w\ndue date: 2026-01-01\n---\n",
        "---\nurl: https://example.com/a?b=c#frag\ntime: 09:30\n---\n",
        "---\nعنوان: سلام دنیا\nتگ‌ها: [کار, خانه]\n---\nمتن\n",
        "---\ntitle: trailing spaces   \n...\nBody with --- in it\n---\n",
        "---\nlist:\n  -\n  - x\n---\n",
    ]

    @Test(arguments: representable) func aFormReadsAndPrintsTheSameBytes(_ note: String) throws {
        guard case .form(let sheet) = PropertySheet.read(note) else {
            Issue.record("Not a form: \(PropertySheet.read(note))")
            return
        }
        #expect(sheet.text == sheet.original)
        #expect(sheet.applied(to: note) == note)
        // A value set to what it is changes nothing.
        var same = sheet
        for property in sheet.properties { same.set(property.key, property.value) }
        #expect(same.applied(to: note) == note)
    }

    static let raw: [(String, String)] = [
        ("---\n# a comment\ntitle: x\n---\n", "comment"),
        ("---\ntitle: x # a comment\n---\n", "comment"),
        ("---\nbase: &anchor x\nother: *anchor\n---\n", "anchor"),
        ("---\nmap:\n  inner: 1\n---\n", "map inside a map"),
        ("---\ntext: |\n  line one\n  line two\n---\n", "more than one line"),
        ("---\ntext: >\n  folded\n---\n", "more than one line"),
        ("---\ntext: plain\n  goes on\n---\n", "more than one line"),
        ("---\ntext: \"open\n  quote\"\n---\n", "does not close"),
        ("---\nlist:\n  - a: 1\n---\n", "map inside a list"),
        ("---\nlist: [[Link]]\n---\n", "list inside a list"),
        ("---\nflow: {a: 1}\n---\n", "map inside a map"),
        ("---\ntitle: x\ntitle: y\n---\n", "twice"),
        ("---\n- a\n- b\n---\n", "list"),
        ("---\ntagged: !!str x\n---\n", "YAML tag"),
        ("---\njust text\n---\n", "not a property"),
        ("---\nlist:\n  - a\n    more\n---\n", "more than one line"),
    ]

    @Test func yamlTheFormCannotShowStaysRawAndSaysWhy() {
        for (note, why) in Self.raw {
            guard case .source(let reason) = PropertySheet.read(note) else {
                Issue.record("A form for \(note.debugDescription)")
                continue
            }
            #expect(reason.contains(why), "\(note.debugDescription): \(reason)")
        }
    }

    @Test func aNoteWithoutFrontMatterGetsOneWhenAPropertyIsAdded() throws {
        guard case .none(var sheet) = PropertySheet.read("# Title\nBody") else {
            Issue.record("front matter found")
            return
        }
        #expect(sheet.applied(to: "# Title\nBody") == "# Title\nBody")
        try sheet.add("tags", .list(["a"]))
        #expect(sheet.applied(to: "# Title\nBody") == "---\ntags:\n  - a\n---\n# Title\nBody")
        guard case .none(var crlf) = PropertySheet.read("Body\r\n") else {
            Issue.record("front matter found")
            return
        }
        try crlf.add("title", .text("x"))
        #expect(crlf.applied(to: "Body\r\n") == "---\r\ntitle: x\r\n---\r\nBody\r\n")
        // The note got front matter in the meantime: the edit is refused.
        #expect(sheet.applied(to: "---\nx: 1\n---\n# Title\nBody") == nil)
    }

    @Test func anEditKeepsTheStyleOfEveryOtherLine() throws {
        let note = """
            ---
            title: 'Single'
            tags: [one, "two"]
            aliases:
                - First
                - "Second"
            count: 3
            ---
            # Body stays
            tags: [not, front, matter]
            """
        guard case .form(var sheet) = PropertySheet.read(note) else {
            Issue.record("not a form")
            return
        }
        sheet.set("title", .text("It's new"))
        sheet.set("tags", .list(["one", "two", "three, four"]))
        sheet.set("aliases", .list(["Second", "Third"]))
        #expect(sheet.applied(to: note) == """
            ---
            title: 'It''s new'
            tags: [one, "two", "three, four"]
            aliases:
                - "Second"
                - Third
            count: 3
            ---
            # Body stays
            tags: [not, front, matter]
            """)
    }

    @Test func renameRemoveAndAddKeepTheOrder() throws {
        let note = "---\na: 1\nb: [x, y]\n\nc: 'z'\n---\nbody"
        guard case .form(var sheet) = PropertySheet.read(note) else {
            Issue.record("not a form")
            return
        }
        try sheet.rename("b", to: "due date")
        #expect(sheet.applied(to: note) == "---\na: 1\ndue date: [x, y]\n\nc: 'z'\n---\nbody")
        #expect(throws: PropertySheet.Failure.exists("a")) { try sheet.rename("c", to: "a") }
        #expect(throws: PropertySheet.Failure.badName) { try sheet.add("  ", .empty) }
        try sheet.rename("c", to: "key: with colon")
        sheet.remove("a")
        try sheet.add("done", .text("true"))
        try sheet.add("empty", .empty)
        try sheet.add("link", .text("[[Note]]"))
        try sheet.add("nothing", .text("null"))
        #expect(sheet.applied(to: note) == """
            ---
            due date: [x, y]

            "key: with colon": 'z'
            done: true
            empty:
            link: "[[Note]]"
            nothing: "null"
            ---
            body
            """)
        for key in sheet.properties.map(\.key) { sheet.remove(key) }
        #expect(sheet.applied(to: note) == "body")
    }

    @Test func anEditIsRefusedWhenTheFrontMatterChangedOnDisk() {
        let note = "---\ntitle: a\n---\nbody"
        guard case .form(var sheet) = PropertySheet.read(note) else {
            Issue.record("not a form")
            return
        }
        sheet.set("title", .text("b"))
        #expect(sheet.applied(to: "---\ntitle: a\n---\nthe body changed, that is fine") == "---\ntitle: b\n---\nthe body changed, that is fine")
        #expect(sheet.applied(to: "---\ntitle: c\n---\nbody") == nil)
        #expect(sheet.applied(to: "body") == nil)
    }

    @Test func aWrittenValueReadsBackTheSame() throws {
        let values = ["plain", "with: colon", "# hash", "- dash", "-5", "it's", "say \"hi\"", "back\\slash", " padded ", "a #b", "[[Link]]",
                      "null", "~", "{x}", "&amp", "*star", "%", "سلام", "tab\there", "a,b", ""]
        for quote in [PropertySheet.Style.Quote.plain, .single, .double] {
            for value in values where !value.isEmpty {
                for flow in [false, true] {
                    let text = PropertySheet.quoted(value, quote, flow: flow)
                    let (read, _) = try PropertySheet.scalar(text, in: "k")
                    #expect(read == value, "\(quote) \(flow): \(text)")
                }
            }
        }
        guard case .form(var sheet) = PropertySheet.read("---\nlist: [a]\nblock:\n  - a\n---\n") else {
            Issue.record("not a form")
            return
        }
        sheet.set("list", .list(values))
        sheet.set("block", .list(values))
        guard case .form(let again) = PropertySheet.read(sheet.text) else {
            Issue.record("not a form: \(sheet.text)")
            return
        }
        #expect(again.value("list") == .list(values))
        #expect(again.value("block") == .list(values))
    }

    @Test func typesAreInferredAsObsidianDoes() {
        #expect(PropertyType.infer("tags", .text("a")) == .tags)
        #expect(PropertyType.infer("Aliases", .list([])) == .aliases)
        #expect(PropertyType.infer("cssclasses", .text("wide")) == .multitext)
        #expect(PropertyType.infer("list", .list(["a"])) == .multitext)
        #expect(PropertyType.infer("done", .text("true")) == .checkbox)
        #expect(PropertyType.infer("done", .text("False")) == .checkbox)
        #expect(PropertyType.infer("count", .text("12")) == .number)
        #expect(PropertyType.infer("count", .text("-1.5e3")) == .number)
        #expect(PropertyType.infer("day", .text("2026-10-25")) == .date)
        #expect(PropertyType.infer("when", .text("2026-10-25T09:30")) == .datetime)
        #expect(PropertyType.infer("when", .text("2026-10-25 09:30:00")) == .datetime)
        #expect(PropertyType.infer("title", .text("2026 plans")) == .text)
        #expect(PropertyType.infer("title", .empty) == .text)
    }

    @Test func typesJSONWins() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "properties-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: ".obsidian"), withIntermediateDirectories: true)
        try Data(#"{"types":{"year":"text","rating":"number","related":"multitext","seen":"checkbox","kind":"unknown"}}"#.utf8)
            .write(to: root.appending(path: ".obsidian/types.json"))
        let types = BaseEngine.types(in: root)
        #expect(PropertyType.infer("year", .text("2026"), types: types) == .text)
        #expect(PropertyType.infer("Rating", .text("x"), types: types) == .number)
        #expect(PropertyType.infer("related", .text("[[A]]"), types: types) == .multitext)
        #expect(PropertyType.infer("seen", .empty, types: types) == .checkbox)
        #expect(PropertyType.infer("kind", .text("12"), types: types) == .number)
    }

    @Test func datesAreWrittenAsObsidianWritesThem() throws {
        let date = try #require(PropertyType.date(from: "2026-10-25T09:30"))
        #expect(PropertyType.format(date, time: true) == "2026-10-25T09:30")
        #expect(PropertyType.format(date, time: false) == "2026-10-25")
    }

    @Test func theFrontMatterLengthIsInUTF16() {
        #expect(PropertySheet.length(of: "no front matter") == 0)
        #expect(PropertySheet.length(of: "---\nt: 😀\n---\nbody") == ("---\nt: 😀\n---\n" as NSString).length)
        #expect(PropertySheet.length(of: "---\nopen") == 0)
    }

    @Test func namesAreRankedAndCompleted() {
        let names = PropertyNames.ranked(["tags", "status", "tags", "Status", "due", "tags", "status"])
        #expect(names == ["tags", "status", "due", "Status"])
        #expect(PropertyNames.complete("st", from: names) == ["status", "Status"])
        #expect(PropertyNames.complete("u", from: names) == ["status", "due", "Status"])
        #expect(PropertyNames.complete("", from: names, limit: 2) == ["tags", "status"])
    }
}
