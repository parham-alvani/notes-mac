import Foundation
import Testing

@testable import DaftarCore

// Every fixture here is made up. The repository is public; the vault is not.

@Suite struct LinkResolverTests {
    let resolver = LinkResolver(
        paths: ["Learning/Kubernetes.md", "Work/Kubernetes.md", "Projects/Alpha/Alpha.md", "uploads/diagram.png", "Notes/Inbox.md"],
        aliases: ["Notes/Inbox.md": ["In tray"]])

    @Test func bareNamesAndPartialPaths() {
        #expect(resolver.resolve("Inbox", from: "A.md") == "Notes/Inbox.md")
        #expect(resolver.resolve("Notes/Inbox", from: "A.md") == "Notes/Inbox.md")
        #expect(resolver.resolve("Notes/Inbox.md", from: "A.md") == "Notes/Inbox.md")
        #expect(resolver.resolve("diagram.png", from: "A.md") == "uploads/diagram.png")
    }

    @Test func folderNoteAnswersToItsFolder() {
        #expect(resolver.resolve("Projects/Alpha", from: "A.md") == "Projects/Alpha/Alpha.md")
    }

    @Test func caseIsFoldedOnlyWhenExactMisses() {
        #expect(resolver.resolve("inbox", from: "A.md") == "Notes/Inbox.md")
    }

    @Test func aliasIsAskedLast() {
        #expect(resolver.resolve("In tray", from: "A.md") == "Notes/Inbox.md")
        #expect(resolver.resolve("Nowhere", from: "A.md") == nil)
    }

    @Test func ambiguousNamePrefersTheSourcesFolder() {
        #expect(resolver.resolve("Kubernetes", from: "Work/Deploy.md") == "Work/Kubernetes.md")
        #expect(resolver.resolve("Kubernetes", from: "Learning/Pods.md") == "Learning/Kubernetes.md")
    }
}

@Suite struct NoteParserTests {
    let text = """
        ---
        aliases: [First, "Second"]
        tags:
          - project/alpha
        ---
        # Heading one

        A link to [[Inbox#Today|today]] and ![[diagram.png|300]], a [doc](Notes/Other%20note.md).
        `[[not a link]]` and #inline-tag but not #123.
        %% [[hidden]] %%

        ## Tasks
        - [ ] Write the plan ➕ 2026-10-01 ⏳ 2026-10-04
            - [x] Draft ✅ 2026-10-02
        > - [/] Inside a callout 📅 2026-10-09

        ```
        - [ ] code, not a task
        [[code link]]
        ```
        """

    @Test func frontMatter() {
        let note = NoteParser.parse(text)
        #expect(note.aliases == ["First", "Second"])
        #expect(note.tags.contains("project/alpha"))
    }

    @Test func linksOutsideCodeAndComments() {
        let note = NoteParser.parse(text)
        #expect(note.links.map(\.target) == ["Inbox", "diagram.png", "Notes/Other note.md"])
        #expect(note.links[0].anchor == "Today")
        #expect(note.links[1].embed)
        #expect(note.links[0].line == 7)
    }

    @Test func tagsHeadingsAndTasks() {
        let note = NoteParser.parse(text)
        #expect(note.tags.contains("inline-tag"))
        #expect(!note.tags.contains("123"))
        #expect(note.headings.map(\.text) == ["Heading one", "Tasks"])
        #expect(note.tasks.count == 3)
        let first = note.tasks[0]
        #expect(first.text == "Write the plan")
        #expect(first.scheduled == "2026-10-04")
        #expect(first.created == "2026-10-01")
        #expect(first.section == "Tasks")
        #expect(first.line == 12)
        #expect(note.tasks[1].nested && !note.tasks[1].isOpen)
        #expect(note.tasks[2].status == "/" && note.tasks[2].due == "2026-10-09" && note.tasks[2].isOpen)
    }

    @Test func persianIsRightToLeft() {
        #expect(NoteParser.parse("سلام، این یک یادداشت است").rtl)
        #expect(!NoteParser.parse("Plain English").rtl)
    }
}

@Suite struct TaskLineTests {
    @Test func completeAddsTheDoneDate() {
        #expect(TaskLine.toggled("- [ ] Ship it ⏳ 2026-10-04", today: "2026-10-05") == ["- [x] Ship it ⏳ 2026-10-04 ✅ 2026-10-05"])
        #expect(TaskLine.toggled("    - [/] Half done", today: "2026-10-05") == ["    - [x] Half done ✅ 2026-10-05"])
    }

    @Test func reopenTakesTheDateOff() {
        #expect(TaskLine.toggled("- [x] Ship it ⏳ 2026-10-04 ✅ 2026-10-05", today: "2026-10-06") == ["- [ ] Ship it ⏳ 2026-10-04"])
        #expect(TaskLine.toggled("- [-] Dropped ❌ 2026-10-05", today: "2026-10-06") == ["- [ ] Dropped"])
    }

    @Test func repeatLeavesTheNextOneAbove() {
        let lines = TaskLine.toggled("- [ ] Water plants 🔁 every week ⏳ 2026-10-01 📅 2026-10-03", today: "2026-10-02")
        #expect(lines == [
            "- [ ] Water plants 🔁 every week ⏳ 2026-10-08 📅 2026-10-10",
            "- [x] Water plants 🔁 every week ⏳ 2026-10-01 📅 2026-10-03 ✅ 2026-10-02",
        ])
    }

    @Test func lateRepeatLandsInTheFuture() {
        let lines = TaskLine.toggled("- [ ] Daily 🔁 every day ⏳ 2026-10-01", today: "2026-10-10")
        #expect(lines?.first == "- [ ] Daily 🔁 every day ⏳ 2026-10-11")
    }

    @Test func repeatWhenDoneCountsFromToday() {
        let lines = TaskLine.toggled("- [ ] Haircut 🔁 every month when done ⏳ 2026-01-31", today: "2026-03-15")
        #expect(lines?.first == "- [ ] Haircut 🔁 every month when done ⏳ 2026-04-15")
    }

    @Test func unknownRuleCompletesWithoutARepeat() {
        let lines = TaskLine.toggled("- [ ] Gym 🔁 every Monday ⏳ 2026-10-05", today: "2026-10-05")
        #expect(lines == ["- [x] Gym 🔁 every Monday ⏳ 2026-10-05 ✅ 2026-10-05"])
    }

    @Test func emojiInProseIsProse() {
        let split = TaskMetadata.split("Book ✅ the table — for dinner ⏳ 2026-10-04")
        #expect(split.text == "Book ✅ the table — for dinner")
        #expect(split.meta == [.init(emoji: "⏳", value: "2026-10-04")])
    }
}

@Suite struct VaultEditsTests {
    @Test func toggleChecksTheLineStillSaysTheSame() throws {
        let text = "# T\n- [ ] One\n- [ ] Two\n"
        let out = try VaultEdits.toggleTask(in: text, line: 2, status: " ", today: Day("2026-10-05")!)
        #expect(out == "# T\n- [ ] One\n- [x] Two ✅ 2026-10-05\n")
        #expect(throws: VaultEdits.Failure.taskMoved) {
            try VaultEdits.toggleTask(in: text, line: 0, status: " ", today: Day("2026-10-05")!)
        }
        #expect(throws: VaultEdits.Failure.taskMoved) {
            try VaultEdits.toggleTask(in: text, line: 1, status: "x", today: Day("2026-10-05")!)
        }
    }

    @Test func windowsLineEndingsSurvive() throws {
        let out = try VaultEdits.toggleTask(in: "- [ ] One\r\n", line: 0, status: " ", today: Day("2026-10-05")!)
        #expect(out == "- [x] One ✅ 2026-10-05\r\n")
    }
}

@Suite struct DayTests {
    @Test func parseAndArithmetic() {
        #expect(Day("2026-02-30") == nil)
        #expect(Day("2026-10-25")?.adding(days: 7).description == "2026-11-01")
        #expect(Day("2026-01-31")?.adding(months: 1).description == "2026-02-28")
    }
}

@Suite struct CalendarWeekTests {
    let note = """
        # 2026-W53

        Generated by Daftar from the calendars on the phone. Times are Europe/Madrid, and free time is counted from 09:00 to 18:00 every day. Edits to this note are written over.

        ## Thursday 31 December

        Free: 09:00–10:00, 11:00–18:00.

        - All day Holiday (<personal@example.com>)
        - 10:00–11:00 Planning \\#3 (maybe) (<personal@example.com>, <work@example.com>)
            - Overlaps: 10:30 Standup
            - Join: <https://meet.example.com/abc>
        - 23:00–Fri 01:00 Late call (<work@example.com>)

        ## Friday 1 January

        No events.
        """

    @Test func readsDaysAcrossTheYear() {
        let days = CalendarWeek.parse(note, path: "Calendar/2026-W53.md")
        #expect(days.map(\.day.description) == ["2026-12-31", "2027-01-01"])
        #expect(days[0].free == "09:00–10:00, 11:00–18:00")
        #expect(days[1].meetings.isEmpty)
    }

    @Test func readsMeetings() throws {
        let meetings = CalendarWeek.parse(note, path: "Calendar/2026-W53.md")[0].meetings
        #expect(meetings.count == 3)
        #expect(meetings[0].allDay && meetings[0].title == "Holiday")
        let planning = meetings[1]
        #expect(planning.title == "Planning #3")
        #expect(planning.tentative)
        #expect(planning.calendars == ["personal@example.com", "work@example.com"])
        #expect(planning.join == URL(string: "https://meet.example.com/abc"))
        #expect(planning.overlaps == "10:30 Standup")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        let start = try #require(planning.start)
        #expect(calendar.component(.hour, from: start) == 10)
        let late = meetings[2]
        #expect(late.end!.timeIntervalSince(late.start!) == 2 * 3600)
    }

    @Test func weekNotePath() {
        #expect(CalendarWeek.path(for: Day("2026-10-25")!) == "Calendar/2026-W43.md")
        #expect(CalendarWeek.path(for: Day("2027-01-01")!) == "Calendar/2026-W53.md")
        #expect(CalendarWeek.isWeekNote("Calendar/2026-W43.md"))
        #expect(!CalendarWeek.isWeekNote("Calendar/CLAUDE.md"))
    }
}

@Suite struct SearchIndexTests {
    @Test func everyWordAsAPrefix() {
        let index = SearchIndex()
        index.put(path: "a.md", title: "Kubernetes", body: "pods and deployments")
        index.put(path: "b.md", title: "Cooking", body: "pasta with deployment of sauce")
        index.put(path: "c.md", title: "فارسی", body: "یادداشت درباره کتاب")
        #expect(index.search("deploy").map(\.path).sorted() == ["a.md", "b.md"])
        #expect(index.search("deploy pods").map(\.path) == ["a.md"])
        #expect(index.search("کتاب").map(\.path) == ["c.md"])
        #expect(index.search("\"pasta with\"").map(\.path) == ["b.md"])
        index.remove(path: "a.md")
        #expect(index.search("pods").isEmpty)
    }

    @Test func syntaxIsQuoted() {
        #expect(SearchIndex.matchExpression("a AND -b:c") == "\"a\"* AND \"AND\"* AND \"-b:c\"*")
        #expect(SearchIndex.matchExpression("  ") == nil)
    }
}

@Suite struct VaultTests {
    func makeVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "daftar-test-\(UUID().uuidString)")
        let files = [
            "Notes/Inbox.md": "# Inbox\n- [ ] Call [[Alpha]] ⏳ 2026-10-04\n",
            "Projects/Alpha/Alpha.md": "Alpha project, see [[Inbox]].",
            "Projects/Alpha/Plan.md": "Plan for [[Projects/Alpha]].",
            "uploads/logo.png": "png",
            ".obsidian/app.json": "{}",
            "node_modules/x/README.md": "skip",
        ]
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test func indexesTheVault() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = Vault.index(root)
        #expect(index.files == ["Notes/Inbox.md", "Projects/Alpha/Alpha.md", "Projects/Alpha/Plan.md", "uploads/logo.png"])
        #expect(index.backlinks["Projects/Alpha/Alpha.md"]?.map(\.source).sorted() == ["Notes/Inbox.md", "Projects/Alpha/Plan.md"])
        #expect(index.tasks.count == 1)
        let projects = try #require(index.tree.first { $0.name == "Projects" })
        let alpha = try #require(projects.children?.first)
        #expect(alpha.folderNote == "Projects/Alpha/Alpha.md")
        #expect(alpha.children?.map(\.name) == ["Plan"])
    }

    @Test func updateReadsChangesAndDropsDeletions() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let search = SearchIndex()
        var index = Vault.index(root, search: search)
        try "New note about [[Inbox]] and zebras".write(to: root.appending(path: "New.md"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appending(path: "Projects/Alpha/Plan.md"))
        index = Vault.update(index, changed: ["New.md", "Projects/Alpha/Plan.md"], in: root, search: search)
        #expect(index.notes["New.md"] != nil)
        #expect(index.notes["Projects/Alpha/Plan.md"] == nil)
        #expect(index.backlinks["Notes/Inbox.md"]?.map(\.source).sorted() == ["New.md", "Projects/Alpha/Alpha.md"])
        #expect(search.search("zebras").map(\.path) == ["New.md"])
        #expect(search.search("Plan").isEmpty)
    }
}

@Suite struct GitTests {
    @Test func syncCommitsPullsAndPushes() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "daftar-git-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let remote = base.appending(path: "remote.git")
        let clone = base.appending(path: "clone")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let git = Git(root: base)
        try await git.run(["init", "-q", "--bare", "-b", "main", remote.path])
        try await git.run(["clone", "-q", remote.path, clone.path])
        let vault = Git(root: clone)
        try await vault.run(["config", "user.email", "test@example.com"])
        try await vault.run(["config", "user.name", "Test"])
        try "one".write(to: clone.appending(path: "a.md"), atomically: true, encoding: .utf8)
        // The first push has no upstream yet.
        try await vault.run(["add", "-A"])
        try await vault.run(["commit", "-qm", "first"])
        try await vault.run(["push", "-q", "-u", "origin", "main"])

        try "two".write(to: clone.appending(path: "a.md"), atomically: true, encoding: .utf8)
        #expect(try await vault.sync(message: Git.message(host: "falcon.local")))
        let log = try await Git(root: remote).run(["log", "--format=%s", "-1"])
        #expect(log.hasPrefix("update notes @ ") && log.hasSuffix(" on falcon"))
        #expect(try await !vault.sync(message: "nothing"))
    }
}

@Suite struct ConfigFileTests {
    @Test func readsTheTemplate() {
        let file = ConfigFile(text: ConfigFile.template)
        #expect(file.string("vault") == "")
        #expect(file.string("appearance.theme") == "system")
        #expect(file.int("appearance.text_size") == 15)
        #expect(file.bool("git.pull_on_launch") == true)
        #expect(file.string("notifications.digest_time") == "09:00")
    }

    @Test func setKeepsCommentsAndOrder() {
        var file = ConfigFile(text: "# mine\nvault = \"~/a\"\n\n[git]\nsync_interval = 0 # off\n")
        file.set("git.sync_interval", .int(5))
        file.set("vault", .string("/x \"y\""))
        file.set("git.pull_on_launch", .bool(false))
        file.set("terminal.font_size", .int(14))
        #expect(file.text == "# mine\nvault = \"/x \\\"y\\\"\"\n\n[git]\nsync_interval = 5 # off\npull_on_launch = false\n\n[terminal]\nfont_size = 14\n")
        #expect(file.string("vault") == "/x \"y\"")
        #expect(file.int("git.sync_interval") == 5)
        #expect(file.bool("git.pull_on_launch") == false)
    }

    @Test func aKeyInAnotherSectionIsAnotherKey() {
        let file = ConfigFile(text: "[a]\nsize = 1\n[b]\nsize = 2\n")
        #expect(file.int("a.size") == 1)
        #expect(file.int("b.size") == 2)
        #expect(file.int("size") == nil)
    }
}

@Suite struct IconicTests {
    @Test func iconsAndFolderRules() throws {
        let json = """
            {"fileIcons": {"Banking": {"icon": "lucide-piggy-bank", "color": "green"}, "Food.md": {"icon": "🍲"}},
             "folderRules": [{"enabled": true, "match": "all", "icon": "lucide-building", "color": "cyan",
               "conditions": [{"source": "tree", "operator": "matches", "value": "^Work/[^/]*$"}]}]}
            """
        let iconic = Iconic.parse(Data(json.utf8))
        #expect(iconic.icon(for: "Banking", folder: true) == .init(name: "lucide-piggy-bank", color: "green"))
        #expect(iconic.icon(for: "Food.md", folder: false)?.isEmoji == true)
        #expect(iconic.icon(for: "Work/Acme", folder: true)?.name == "lucide-building")
        #expect(iconic.icon(for: "Work/Acme/Team", folder: true) == nil)
        #expect(iconic.icon(for: "Work/Acme", folder: false) == nil)
    }
}
