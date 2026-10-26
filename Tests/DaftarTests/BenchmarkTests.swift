import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// `just bench`: the paths a person waits on, timed on a made-up vault of
/// 20,000 notes. Off in a plain `just test`, which must stay fast.
let benchmarking = ProcessInfo.processInfo.environment["DAFTAR_BENCH"] == "1"

/// A vault the size of a large real one, from a fixed seed: nested folders,
/// front matter, links (some broken, some with an alias or a heading),
/// tasks with dates and recurrences, ` ```tasks ` queries, a few long
/// notes, Persian text, images and bases.
enum SyntheticVault {
    /// RobustnessTests' SplitMix64; the test targets share no code.
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

    static let words = """
        plan meeting budget review design server cluster deploy network invoice contract travel family garden \
        book chapter reading summary health doctor insurance bank account tax report weekly monthly quarter goal \
        idea draft research paper model data backup storage kubernetes database postgres redis kafka queue \
        release version bug feature test customer partner vendor office hiring interview salary team project \
        roadmap launch market price shop recipe coffee bakery train flight hotel visa passport school course \
        lecture exam thesis advisor friend birthday gift music guitar piano film series podcast article note \
        letter email phone call agenda minutes decision risk issue incident outage alert monitor metric log
        """.split(whereSeparator: \.isWhitespace).map(String.init)
    static let persian = "سلام دنیا یادداشت جلسه پروژه برنامه کتاب خانه سفر کار هفته روز خرید گزارش ایده بودجه دوست خانواده".split(separator: " ").map(String.init)
    static let tops = ["Projects", "Areas", "Companies", "People", "Journal", "Resources", "Archive", "Meetings", "Reading", "Inbox"]

    struct Layout {
        var notes: [String] = []
        /// The note most others link to, for the rename.
        var hub = ""
        var long: [String] = []
        var bases: [String] = []
        var images: [String] = []
    }

    static func write(to root: URL, notes count: Int = 20_000, seed: UInt64 = 20_261_026) throws -> Layout {
        var random = Seeded(state: seed)
        let manager = FileManager.default
        func word() -> String { words.randomElement(using: &random)! }
        func chance(_ percent: Int) -> Bool { Int.random(in: 0..<100, using: &random) < percent }

        var folders: [String] = []
        for top in tops {
            folders.append(top)
            for a in 0..<6 {
                let middle = top + "/" + word().capitalized + " \(a)"
                folders.append(middle)
                for b in 0..<5 { folders.append(middle + "/" + word().capitalized + " \(b)") }
            }
        }
        var layout = Layout()
        var taken = Set<String>()
        var titles: [String] = []
        for number in 0..<count {
            var title: String
            if number < 20 {
                title = "Hub \(number)"
            } else if chance(8) {
                title = (0..<Int.random(in: 1...3, using: &random)).map { _ in persian.randomElement(using: &random)! }.joined(separator: " ")
            } else {
                title = (0..<Int.random(in: 2...4, using: &random)).map { _ in word() }.joined(separator: " ").capitalized
            }
            // A few names twice, in other folders, as a real vault has.
            if taken.contains(title), !chance(3) { title += " \(number)" }
            taken.insert(title)
            titles.append(title)
            layout.notes.append(folders.randomElement(using: &random)! + "/" + title + ".md")
        }
        layout.hub = layout.notes[0]
        layout.images = (0..<400).map { "Attachments/image-\($0).png" }
        for folder in folders + ["Attachments", "Bases"] {
            try manager.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
        }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 0, count: 64))
        for image in layout.images { try png.write(to: root.appending(path: image)) }

        func sentence() -> String {
            var parts: [String] = []
            for _ in 0..<Int.random(in: 6...18, using: &random) {
                parts.append(chance(10) ? persian.randomElement(using: &random)! : word())
            }
            if chance(35) {
                let target: String
                // Hub 0 is the much-linked note; the other hubs a little less.
                if chance(3) { target = titles[0] } else if chance(10) { target = titles[Int.random(in: 1..<20, using: &random)] } else {
                    target = titles.randomElement(using: &random)!
                }
                switch Int.random(in: 0..<10, using: &random) {
                case 0: parts.append("[[Missing \(word()) \(Int.random(in: 0..<500, using: &random))]]")
                case 1: parts.append("[[\(target)|\(word())]]")
                case 2: parts.append("[[\(target)#\(word().capitalized)]]")
                case 3: parts.append("![[\(layout.images.randomElement(using: &random)!.dropFirst("Attachments/".count))]]")
                default: parts.append("[[\(target)]]")
                }
            }
            if chance(8) { parts.append("#" + ["project", "area", "idea", "read", "work/" + word()].randomElement(using: &random)!) }
            return parts.joined(separator: " ").capitalized(first: true) + "."
        }
        func day(_ offset: ClosedRange<Int>) -> String {
            Day(year: 2026, month: 10, day: 26).adding(days: Int.random(in: offset, using: &random)).description
        }
        func task() -> String {
            let status = ["[ ]", "[ ]", "[ ]", "[x]", "[/]", "[-]"].randomElement(using: &random)!
            var line = "- \(status) " + (0..<Int.random(in: 3...8, using: &random)).map { _ in word() }.joined(separator: " ")
            if chance(40) { line += " 📅 " + day(-30...30) }
            if chance(15) { line += " ⏳ " + day(-10...10) }
            if chance(10) { line += " 🔁 " + ["every week", "every month", "every day", "every 2 weeks when done"].randomElement(using: &random)! }
            if chance(10) { line += " " + ["⏫", "🔼", "🔽", "🔺"].randomElement(using: &random)! }
            if status == "[x]" { line += " ✅ " + day(-30...0) }
            return line
        }
        let queries = [
            "not done\ndue before in 7 days\nsort by due",
            "not done\ngroup by filename\nlimit 50",
            "done\nhas done date\ngroup by function task.done.format(\"YYYY-MM\")",
            "not done\npath includes {{query.file.folder}}",
        ]

        for (number, path) in layout.notes.enumerated() {
            var text = ""
            if chance(80) {
                var tags = ["project", "area", "idea", "read", "person", "meeting", "work/" + word()].shuffled(using: &random)
                tags = Array(tags.prefix(Int.random(in: 0...3, using: &random)))
                text += "---\ntags:\n" + tags.map { "  - \($0)\n" }.joined()
                if chance(10) { text += "aliases: [\(word().capitalized) \(number)]\n" }
                text += "status: \(["open", "done", "waiting"].randomElement(using: &random)!)\n"
                text += "created: \(day(-400...0))\n"
                text += "rating: \(Int.random(in: 1...5, using: &random))\n"
                if chance(30) { text += "related: \"[[\(titles.randomElement(using: &random)!)]]\"\n" }
                text += "---\n"
            }
            let long = number % 4000 == 7
            if long { layout.long.append(path) }
            let sections = long ? 120 : Int.random(in: 1...4, using: &random)
            for section in 0..<sections {
                text += "\n## \(word().capitalized) \(section)\n\n"
                for _ in 0..<Int.random(in: 1...3, using: &random) {
                    text += (0..<Int.random(in: 1...4, using: &random)).map { _ in sentence() }.joined(separator: " ") + "\n\n"
                }
                if chance(30) { text += (0..<Int.random(in: 1...6, using: &random)).map { _ in task() }.joined(separator: "\n") + "\n" }
                if chance(4) { text += "```swift\nlet \(word()) = [[\(word())]] // #notatag\n```\n" }
            }
            if number % 100 == 5 { text += "\n```tasks\n\(queries.randomElement(using: &random)!)\n```\n" }
            if long {
                while text.count < 70_000 { text += sentence() + " " }
            }
            try Data(text.utf8).write(to: root.appending(path: path))
        }

        let base = """
            filters:
              and:
                - file.inFolder("Projects")
                - file.hasTag("project")
            formulas:
              top: file.folder.split("/")[0]
            views:
              - type: table
                name: Open
                filters:
                  and:
                    - status != "done"
                order:
                  - file.name
                  - formula.top
                  - rating
                sort:
                  - property: rating
                    direction: DESC
              - type: table
                name: By status
                groupBy:
                  property: status
                  direction: ASC
                order:
                  - file.name
                  - created
            """
        for number in 0..<4 {
            let path = "Bases/Projects \(number).base"
            try Data(base.utf8).write(to: root.appending(path: path))
            layout.bases.append(path)
        }
        return layout
    }
}

extension String {
    fileprivate func capitalized(first: Bool) -> String { prefix(1).uppercased() + dropFirst() }
}

/// The times, as a table on standard output.
@MainActor
final class Stopwatch {
    var rows: [(name: String, ms: Double, note: String)] = []

    /// The best of [runs] runs: the time the work takes, not the noise.
    @discardableResult
    func time<T>(_ name: String, runs: Int = 3, note: String = "", _ work: () throws -> T) rethrows -> T {
        var best = Double.infinity
        var result: T?
        for _ in 0..<runs {
            let clock = ContinuousClock.now
            result = try work()
            let elapsed = ContinuousClock.now - clock
            best = min(best, Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        rows.append((name, best, note))
        return result!
    }

    func waiting<T>(_ name: String, note: String = "", _ work: () async throws -> T) async rethrows -> T {
        let clock = ContinuousClock.now
        let result = try await work()
        let elapsed = ContinuousClock.now - clock
        rows.append((name, Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15, note))
        return result
    }

    var table: String {
        let width = rows.map(\.name.count).max() ?? 0
        return (["| path" + String(repeating: " ", count: max(0, width - 4)) + " |       ms | |", "|" + String(repeating: "-", count: width + 2) + "|---------:|-|"]
            + rows.map { row in
                "| " + row.name.padding(toLength: width, withPad: " ", startingAt: 0) + " | "
                    + String(format: "%8.1f", row.ms) + " | " + row.note + " |"
            }).joined(separator: "\n")
    }
}

@MainActor
@Suite(.serialized, .enabled(if: benchmarking)) struct BenchmarkTests {
    @Test func aLargeVault() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "daftar-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let watch = Stopwatch()
        let layout = try watch.time("write the synthetic vault", runs: 1) { try SyntheticVault.write(to: root) }

        // Opening the vault: the files read and parsed, the links, tags and tree derived.
        let index = watch.time("open: Vault.index, no search") { Vault.index(root) }
        let tasks = index.tasks
        let bytes = layout.notes.reduce(0) { $0 + ((try? root.appending(path: $1).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        watch.rows[watch.rows.count - 1].note = "\(index.notes.count) notes, \(index.files.count) files, \(bytes / 1_000_000) MB, \(tasks.count) tasks"
        var copy = index
        watch.time("derive (links, tags, tree)") { copy.derive() }
        let search = SearchIndex()
        watch.time("FTS5 index build", runs: 1) {
            search.transaction {
                for note in index.notes.values { search.put(path: note.path, title: note.title, body: note.parsed.plain) }
            }
        }
        let settings = AppSettings(url: root.appending(path: ".config/config.toml"))
        let store = VaultStore(settings: settings, openVault: false)
        watch.time("open: VaultStore, index and search", runs: 1) { store.openSynchronously(root) }
        for query in ["meeting", "kubernetes deploy", "پروژه", "\"weekly report\"", "p"] {
            let hits = watch.time("search \(query)") { store.search.search(query) }
            watch.rows[watch.rows.count - 1].note = "\(hits.count) hits"
        }

        // Quick open: the first ⌘P folds every name, then each key ranks them.
        watch.time("quick open: first keystroke (candidates)", runs: 1) { store.switcher("p", recent: []) }
        for query in ["p", "pr", "proj", "proj meet", "plan budget", "comp/acme", "جلسه"] {
            let ranking = watch.time("quick open \"\(query)\"") { store.switcher(query, recent: []) }
            watch.rows[watch.rows.count - 1].note = "\(ranking.paths.count) shown"
        }

        // The sidebar of the much-linked note.
        let hub = layout.hub
        let backlinks = watch.time("backlinks of the hub") { store.index.backlinks[hub] ?? [] }
        watch.rows[watch.rows.count - 1].note = "\(backlinks.count) notes"
        let long = layout.long[0]
        watch.time("outgoing of a long note") { store.index.resolvedLinks(of: long) }
        _ = await watch.waiting("unlinked mentions of the hub") { await store.unlinkedMentions(of: hub) }
        let longText = try String(contentsOf: root.appending(path: long), encoding: .utf8)
        watch.time("parse a 70,000-character note") { NoteParser.parse(longText) }

        // A note with a query is drawn again at every change of any note.
        for source in ["not done\ndue before in 7 days\nsort by due", "not done\ngroup by filename", "done\ngroup by function task.done.format(\"YYYY-MM\")"] {
            let found = watch.time("tasks query: \(source.replacingOccurrences(of: "\n", with: "; "))") { () -> [VaultTask] in
                let query = TasksQuery.parse(source, file: "Projects/Note.md")
                let all = store.index.tasks.sorted { ($0.path, $0.task.line) < ($1.path, $1.task.line) }
                return query.run(all, today: Day(year: 2026, month: 10, day: 26)) { QueryTask($0) }
            }
            watch.rows[watch.rows.count - 1].note = "\(found.count) of \(tasks.count)"
        }
        watch.time("Today: task groups") { store.taskGroups(today: Day(year: 2026, month: 10, day: 26)) }

        let graph = watch.time("graph: NoteGraph.vault") { NoteGraph.vault(store.index) }
        watch.rows[watch.rows.count - 1].note = "\(graph.nodes.count) nodes, \(graph.edges.count) edges"
        watch.time("graph: layout, 160 steps", runs: 1) {
            var layout = GraphLayout(graph)
            layout.run(160)
        }

        let baseSource = try String(contentsOf: root.appending(path: layout.bases[0]), encoding: .utf8)
        let tables = watch.time("base: two views over Projects") { () -> [BaseTable] in
            let engine = BaseEngine(index: store.index, now: Date(timeIntervalSince1970: 1_793_000_000))
            return engine.run(Base.parse(baseSource), context: layout.bases[0])
        }
        watch.rows[watch.rows.count - 1].note = tables.map { "\($0.count) rows" }.joined(separator: ", ")

        // The file watcher's batch: one saved note, and a pull of 500.
        let one: Set<String> = [layout.notes[1234]]
        watch.time("watcher: apply 1 changed file") { Vault.update(store.index, changed: one, in: root, search: store.search) }
        var shuffle = SyntheticVault.Seeded(state: 5)
        let pulled = Set(layout.notes.shuffled(using: &shuffle).prefix(500))
        watch.time("watcher: apply 500 changed files") { Vault.update(store.index, changed: pulled, in: root, search: store.search) }

        // The edits write the files: they come last, once each.
        let tagged = store.notes(tagged: "project")
        let written = watch.time("tag rename: project -> job", runs: 1) { store.renameTag("project", to: "job") }
        watch.rows[watch.rows.count - 1].note = "\(written) of \(tagged.count) notes written"
        watch.time("watcher: apply the renamed tags", runs: 1) {
            _ = Vault.update(store.index, changed: Set(tagged), in: root, search: store.search)
        }
        let moved = try await watch.waiting("rename the hub (links follow)") {
            try await store.move(hub, to: String(hub.dropLast(3)) + " renamed.md")
        }
        watch.rows[watch.rows.count - 1].note = "\(moved.count) moved, \(backlinks.count) notes linking"

        print("\n" + watch.table + "\n")
        if let out = ProcessInfo.processInfo.environment["DAFTAR_BENCH_OUT"] {
            try Data((watch.table + "\n").utf8).write(to: URL(filePath: out))
        }
        #expect(index.notes.count == 20_000)
    }
}
