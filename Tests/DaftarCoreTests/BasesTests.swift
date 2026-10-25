import Foundation
import Testing

@testable import DaftarCore

// Every fixture here is made up. The repository is public; the vault is not.

@Suite struct YAMLTests {
    @Test func blockMapsListsAndScalars() {
        let node = YAML.parse("""
            filters:
              and:
                - file.inFolder("Shops")
                - 'tags.contains("x: y")'
            formulas:
              shop: file.folder.split("/")[1]
            views:
              - type: table
                name: All # a comment
                order:
                  - file.name
                limit: 5
            empty:
            flow: [a, "b, c"]
            text: |
              one
              two
            """)
        #expect(node["filters"]?["and"]?.items.compactMap(\.string) == ["file.inFolder(\"Shops\")", "tags.contains(\"x: y\")"])
        #expect(node["formulas"]?["shop"]?.string == "file.folder.split(\"/\")[1]")
        let view = node["views"]?.items.first
        #expect(view?["name"]?.string == "All")
        #expect(view?["order"]?.items.compactMap(\.string) == ["file.name"])
        #expect(view?["limit"]?.string == "5")
        #expect(node["empty"] == .null)
        #expect(node["flow"]?.items.compactMap(\.string) == ["a", "b, c"])
        #expect(node["text"]?.string == "one\ntwo")
    }

    @Test func listUnderAKeyAtTheSameIndent() {
        let node = YAML.parse("order:\n- a\n- b\nnext: 1\n")
        #expect(node["order"]?.items.compactMap(\.string) == ["a", "b"])
        #expect(node["next"]?.string == "1")
    }
}

@Suite struct BasesTests {
    /// 2026-10-25 12:00 local time.
    let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12))!

    func makeIndex() -> VaultIndex {
        var index = VaultIndex()
        let notes: [String: (String, Int)] = [
            "Shops/Bakery/Bakery.md": ("---\nstage: open\nopened: 2026-10-20\nnext: 2026-10-27T09:30\nroles:\n  - baker\n---\nSee [[Cafe]].", 2),
            "Shops/Bakery/Ovens.md": ("Ovens of [[Bakery]] #kit/ovens", 40),
            "Shops/Cafe/Cafe.md": ("---\nstage: closed\nopened: 2026-09-01\nclosed: 2026-10-11\nrating: 4.5\n---\n", 10),
            "Shops/CLAUDE.md": ("rules", 1),
            "Home.md": ("[[Bakery]] and [[Cafe]]", 100),
        ]
        for (path, (text, daysOld)) in notes {
            index.notes[path] = NoteEntry(path: path, modified: now.addingTimeInterval(Double(-daysOld) * 86_400), parsed: NoteParser.parse(text))
        }
        index.files = Set(notes.keys).union(["uploads/map.png"])
        index.derive()
        return index
    }

    func engine() -> BaseEngine {
        BaseEngine(index: makeIndex(), now: now, types: ["roles": "multitext", "next": "datetime"])
    }

    func evaluate(_ source: String, in path: String = "Shops/Bakery/Bakery.md") throws -> String {
        let engine = engine()
        let value = engine.evaluate(try BaseParser.parse(source), BaseEngine.Row(path: path), [:])
        return engine.display(value)
    }

    @Test func fileProperties() throws {
        #expect(try evaluate("file.name") == "Bakery.md")
        #expect(try evaluate("file.basename") == "Bakery")
        #expect(try evaluate("file.ext") == "md")
        #expect(try evaluate("file.folder") == "Shops/Bakery")
        #expect(try evaluate("file.folder.split(\"/\")[1]") == "Bakery")
        #expect(try evaluate("file.backlinks.length") == "2")
        #expect(try evaluate("file.inFolder(\"Shops\") && !file.inFolder(\"Shop\")") == "true")
        #expect(try evaluate("file.hasProperty(\"stage\")") == "true")
        #expect(try evaluate("file.hasTag(\"kit\")", in: "Shops/Bakery/Ovens.md") == "true")
        #expect(try evaluate("file.hasLink(\"Cafe\")") == "true")
        #expect(try evaluate("file.name", in: "Home.md") == "Home.md")
        #expect(try evaluate("file.folder", in: "Home.md") == "/")
    }

    @Test func propertiesAndOperators() throws {
        #expect(try evaluate("stage == \"open\"") == "true")
        #expect(try evaluate("note.stage") == "open")
        #expect(try evaluate("roles.contains(\"baker\")") == "true")
        #expect(try evaluate("[\"open\", \"new\"].contains(stage)") == "true")
        #expect(try evaluate("rating * 2", in: "Shops/Cafe/Cafe.md") == "9")
        #expect(try evaluate("(closed - opened) / 86400000", in: "Shops/Cafe/Cafe.md") == "40")
        #expect(try evaluate("((closed - opened) / 86400000).round()", in: "Shops/Cafe/Cafe.md") == "40")
        #expect(try evaluate("missing") == "")
        #expect(try evaluate("missing.lower()") == "")
        #expect(try evaluate("if(missing, \"yes\", \"no\")") == "no")
        #expect(try evaluate("if(stage == \"open\", \"1 Open\", if(stage == \"closed\", \"2 Closed\", \"3\"))") == "1 Open")
        #expect(try evaluate("\"a\" + 1 + 2") == "a12")
        #expect(try evaluate("1 + 2 * 3 - -1") == "8")
        #expect(try evaluate("10 % 4") == "2")
    }

    @Test func dates() throws {
        #expect(try evaluate("next >= today()") == "true")
        #expect(try evaluate("opened < today() - \"3 days\"") == "true")
        #expect(try evaluate("file.mtime > now() - \"30 days\"") == "true")
        #expect(try evaluate("file.mtime > now() - \"30 days\"", in: "Shops/Bakery/Ovens.md") == "false")
        #expect(try evaluate("next.format(\"ddd D MMM, HH:mm\")") == "Tue 27 Oct, 09:30")
        #expect(try evaluate("next.format(\"YYYY-MM-DD [at] h A, Do\")") == "2026-10-27 at 9 AM, 27th")
        #expect(try evaluate("next.relative()") == "in 2 days")
        #expect(try evaluate("opened.relative()") == "6 days ago")
        #expect(try evaluate("file.mtime.relative()", in: "Home.md") == "3 months ago")
        #expect(try evaluate("date(\"2024-12-01\") + \"1M\" + \"4h\"") == "2025-01-01 04:00")
        #expect(try evaluate("opened") == "2026-10-20")
        #expect(try evaluate("opened.year") == "2026")
    }

    @Test func stringsListsAndRegex() throws {
        #expect(try evaluate("\"a-b-c\".split(\"-\", 2).join(\"+\")") == "a+b")
        #expect(try evaluate("\"Hello world\".replace(/o/g, \"0\")") == "Hell0 w0rld")
        #expect(try evaluate("\"hello big world\".title()") == "Hello Big World")
        #expect(try evaluate("\"abcdef\".slice(1, -1)") == "bcde")
        #expect(try evaluate("[3, 1, 2].sort().reverse()") == "3, 2, 1")
        #expect(try evaluate("[1, 2, 3].filter(value > 1).map(value * 10)") == "20, 30")
        #expect(try evaluate("[1, 2, 3].reduce(acc + value, 0)") == "6")
        #expect(try evaluate("[1, 1, 2].unique().length") == "2")
        #expect(try evaluate("/ak/.matches(file.name)") == "true")
        #expect(try evaluate("(5).toFixed(2)") == "5.00")
    }

    @Test func badExpressionsAreErrors() {
        #expect(throws: BaseParseError.self) { try BaseParser.parse("a ==") }
        #expect(throws: BaseParseError.self) { try BaseParser.parse("\"open") }
        #expect(throws: BaseParseError.self) { try BaseParser.parse("a b") }
    }

    @Test func spans() {
        #expect(BaseSpan.parse("30 days") == BaseSpan(milliseconds: 30 * 86_400_000))
        #expect(BaseSpan.parse("1M 4h") == BaseSpan(months: 1, milliseconds: 4 * 3_600_000))
        #expect(BaseSpan.parse("2y") == BaseSpan(months: 24))
        #expect(BaseSpan.parse("soon") == nil)
    }

    let source = """
        filters:
          and:
            - file.inFolder("Shops")
            - file.ext == "md"
            - file.basename != "CLAUDE"
        formulas:
          shop: file.folder.split("/")[1]
          label: if(stage == "open", "1 Open", "2 " + formula.shop)
          loop: formula.loop + 1
        properties:
          formula.shop:
            displayName: Shop
        views:
          - type: table
            name: Shops
            filters:
              and:
                - file.basename == formula.shop
            order:
              - file.name
              - formula.shop
              - rating
            sort:
              - property: file.mtime
                direction: DESC
          - type: table
            name: Grouped
            groupBy:
              property: formula.shop
              direction: DESC
            order:
              - file.name
              - formula.label
              - roles
            sort:
              - property: file.name
                direction: ASC
            limit: 2
          - type: cards
            name: Broken
            filters:
              or:
                - stage ==
                - formula.loop > 0
        """

    @Test func runsTheViews() throws {
        let engine = engine()
        let tables = engine.run(Base.parse(source), context: "Shops/Shops.base")
        #expect(tables.map(\.name) == ["Shops", "Grouped", "Broken"])

        let shops = tables[0]
        #expect(shops.columns == ["file name", "Shop", "rating"])
        #expect(shops.groups.count == 1 && shops.groups[0].name == nil)
        // Newest first: the bakery changed two days ago, the cafe ten.
        #expect(shops.groups[0].rows.map(\.path) == ["Shops/Bakery/Bakery.md", "Shops/Cafe/Cafe.md"])
        let cafe = shops.groups[0].rows[1].cells
        #expect(cafe[0] == BaseCell(parts: [.init(text: "Cafe", path: "Shops/Cafe/Cafe.md")]))
        #expect(cafe[1].text == "Cafe")
        #expect(cafe[2] == BaseCell(parts: [.init(text: "4.5")], numeric: true))

        // The limit keeps the first two by name, then the groups sort Z to A.
        let grouped = tables[1]
        #expect(grouped.count == 2)
        #expect(grouped.groups.map(\.name) == ["Cafe", "Bakery"])
        #expect(grouped.groups.map { $0.rows[0].cells[1].text } == ["2 Cafe", "1 Open"])
        #expect(grouped.groups[1].rows[0].cells[2].text == "baker")

        // A statement that does not parse is not applied, and is reported;
        // so is a formula that uses itself.
        #expect(tables[2].type == "cards")
        #expect(engine.problems.contains { $0.contains("stage ==") })
        #expect(engine.problems.contains { $0.contains("loop uses itself") })
    }

    @Test func aBaseWithNoViewsHasOne() {
        let tables = engine().run(Base.parse("filters: file.name == \"Home.md\""), context: "")
        #expect(tables.count == 1)
        #expect(tables[0].groups[0].rows.map(\.path) == ["Home.md"])
    }

    @Test func aColumnIdIsAPropertyNotASum() {
        var index = VaultIndex()
        for (path, text) in ["A.md": "---\ndate-created: 2026-10-01\nmy-key: b\n---\n", "B.md": "---\ndate-created: 2026-09-01\nmy-key: a\n---\n"] {
            index.notes[path] = NoteEntry(path: path, modified: now, parsed: NoteParser.parse(text))
        }
        index.files = ["A.md", "B.md"]
        index.derive()
        let base = Base.parse("""
            views:
              - type: table
                name: All
                order:
                  - file.name
                  - note.date-created
                  - my-key
                sort:
                  - property: my-key
                    direction: ASC
            """)
        let table = BaseEngine(index: index, now: now).run(base, context: "")[0]
        #expect(table.groups[0].rows.map(\.path) == ["B.md", "A.md"])
        #expect(table.groups[0].rows[0].cells.map(\.text) == ["B", "2026-09-01", "a"])
    }

    @Test func badNumbersAreNullNotACrash() throws {
        for source in [
            "[1, 2][0 / 0]", "\"ab\"[1 / 0]", "[1, 2][100000000000000000000000]", "(1.5).round(1 / 0)", "(1.5).toFixed(0 / 0)",
            "\"ab\".repeat(1 / 0)", "\"a-b\".split(\"-\", -1)", "\"a-b\".split(\"-\", 0 / 0)",
            "duration(\"1M\") * (1 / 0)", "\"abc\".slice(0 / 0, 1 / 0)", "[1, 2, 3].slice(-100000000000000000000000)",
            "duration(\"99999999999999999999 years\")",
        ] {
            _ = try evaluate(source)
        }
        #expect(try evaluate("[1, 2][0 / 0]") == "")
        #expect(try evaluate("\"a-b\".split(\"-\", -1).length") == "2")
        #expect(try evaluate("\"abc\".slice(0 / 0, 1 / 0)") == "abc")
        #expect(BaseSpan.parse("99999999999999999999 years") == nil)
    }
}
