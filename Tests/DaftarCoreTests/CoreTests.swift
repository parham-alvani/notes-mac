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

    @Test func persianIsSearchedAsItIsMeant() {
        #expect(Slugs.search("علي كتاب ۱۲") == "علی کتاب 12")
        // Swift counts the half space as part of the letter before it, so it goes, and the text keeps its length.
        #expect(Slugs.search("می\u{200C}خواهم") == "میخواهم")
        #expect(Slugs.search("می\u{200C}خواهم").count == "می\u{200C}خواهم".count)
        #expect(Slugs.search("پائیز آب").count == "پائیز آب".count)
        #expect(Slugs.search("پائیز آب") == "پاییز اب")
        #expect(Slugs.search("Hello") == "hello")
        #expect(Fuzzy.match("می خواهم", in: "می\u{200C}خواهم") != nil)
        #expect(Fuzzy.match("كتاب", in: "کتاب‌ها") != nil)
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

    @Test func percentSignsInCodeOpenNoComment() {
        // `%%` in inline code is two percent signs: the rest of the note is still read.
        let note = NoteParser.parse("- `%%` is a percent sign\n\n## After\n\n- [ ] still a task [[Kept]]\n")
        #expect(note.headings.map(\.text) == ["After"])
        #expect(note.tasks.map(\.text) == ["still a task [[Kept]]"])
        #expect(note.links.map(\.target) == ["Kept"])
        #expect(Sections.headings(in: "`a %% b`\n# One\n``%%``\n# Two").map(\.text) == ["One", "Two"])
        // A real comment still hides its text, on one line and over several.
        let hidden = NoteParser.parse("see %%[[Hidden]] `%%` [[Shown]]\n%%\n# Gone\n%% `%%` [[Too]]\n# Here")
        #expect(hidden.links.map(\.target) == ["Shown", "Too"])
        #expect(hidden.headings.map(\.text) == ["Here"])
        var open = false
        #expect(Comments.strip("a `%%` b %%c%% d", open: &open) == "a `%%` b  d")
        #expect(!open)
    }

    @Test func linksInCodeAndMathAreNotLinks() {
        let note = NoteParser.parse("``[[Double]]`` and ``a ` [[Inner]]`` and $[[Math]]$ and $$x [[Display]]$$ then [[Real]]\ncosts $5 and $10 for [[Paid]]")
        #expect(note.links.map(\.target) == ["Real", "Paid"])
        #expect(InlineCode.spans(in: "a `b` ``c ` d`` `open").count == 2)
        #expect(InlineCode.removed(from: "\\`[[Escaped]]\\`") == "\\`[[Escaped]]\\`")
    }

    @Test func aLineThatStartsWithInlineCodeOpensNoFence() {
        // The info string of a backtick fence holds no backtick, so this is a paragraph.
        let text = "```a``` is inline code\n\n## After\n\n- [ ] a task [[Kept]]\n"
        let note = NoteParser.parse(text)
        #expect(note.headings.map(\.text) == ["After"])
        #expect(note.tasks.count == 1)
        #expect(note.links.map(\.target) == ["Kept"])
        #expect(Sections.headings(in: text).map(\.text) == ["After"])
        #expect(BlockRefs.blocks(in: text).map(\.kind) == [.paragraph, .heading, .item])
        // A real fence still hides what is in it, whatever its info string.
        let fenced = NoteParser.parse("```js title\n# not a heading\n```\n~~~ `a`\n[[Hidden]]\n~~~\n# Shown")
        #expect(fenced.headings.map(\.text) == ["Shown"])
        #expect(fenced.links.isEmpty)
    }

    @Test func aHeadingMayEndInAHash() {
        // The closing `#` run comes off only after a space: C# keeps its sharp.
        let text = "## C#\n## F# and C#\n## Closed ##\n## Closed too ##  \n## ##\n### Plain"
        let wanted = ["C#", "F# and C#", "Closed", "Closed too", "", "Plain"]
        #expect(NoteParser.parse(text).headings.map(\.text) == wanted)
        #expect(Sections.headings(in: text).map(\.text) == wanted)
        #expect(BlockRefs.blocks(in: text).map(\.text) == wanted)
        #expect(NoteParser.parse("## C#\n- [ ] learn it").tasks.first?.section == "C#")
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

    @Test func aLineReadsInTheDirectionOfItsTextNotItsSyntax() {
        #expect(TextDirection.ofLine("- [x] تماس با علی") == true)
        #expect(TextDirection.ofLine("  * [ ] buy milk") == false)
        #expect(TextDirection.ofLine("12. مورد") == true)
        #expect(TextDirection.ofLine("## کارها") == true)
        #expect(TextDirection.ofLine("> [!note] یادداشت") == true)
        #expect(TextDirection.ofLine("- [[Start|پیوند]] و") == true)
        #expect(TextDirection.ofLine("[[Start]] سلام") == false)
        #expect(TextDirection.ofLine("Mixed فارسی") == false)
        #expect(TextDirection.ofLine("- [ ] 12:30") == nil)
        #expect(TextDirection.ofLine("") == nil)
        #expect(TextDirection.firstStrong("12 سلام") == true)
        #expect(TextDirection.firstStrong("- 12") == nil)
    }
}

@Suite struct TaskLineTests {
    @Test func tagsAfterTheDatesStayInTheText() throws {
        let task = try #require(TaskLine.parse("- [ ] Fix the oven door 📅 2026-10-20 ⏫ #kit #home", line: 0, section: ""))
        #expect(task.due == "2026-10-20")
        #expect(task.priority == "⏫")
        #expect(task.text == "Fix the oven door #kit #home")
    }

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

    @Test func jalaliRulesAreRead() {
        func rule(_ text: String) -> String? { Recurrence(text).map { "\($0.amount) \($0.unit) \($0.whenDone)" } }
        #expect(rule("every jalali month") == "1 jalaliMonth false")
        #expect(rule("Every 3 Jalali Months when done") == "3 jalaliMonth true")
        #expect(rule("every jalali year") == "1 jalaliYear false")
        #expect(rule("every 2 jalali years") == "2 jalaliYear false")
        #expect(rule("every month") == "1 month false")
        for refused in ["every jalali week", "every jalali day", "every jalali", "every 0 jalali months", "every jalali month on the 10th"] {
            #expect(rule(refused) == nil, "\(refused)")
        }
    }

    @Test func jalaliRepeatKeepsTheDayOfTheJalaliMonth() {
        func next(_ line: String, _ today: String) -> String? { TaskLine.toggled(line, today: today)?.first }
        #expect(next("- [ ] Pay 🔁 every jalali month ⏳ 2026-12-31", "2026-12-31") == "- [ ] Pay 🔁 every jalali month ⏳ 2027-01-30")
        #expect(next("- [ ] Pay 🔁 every jalali month ⏳ 2026-09-22", "2026-09-22") == "- [ ] Pay 🔁 every jalali month ⏳ 2026-10-22")
        #expect(next("- [ ] Pay 🔁 every jalali year ⏳ 2025-03-20", "2025-03-20") == "- [ ] Pay 🔁 every jalali year ⏳ 2026-03-20")
        #expect(next("- [ ] Pay 🔁 every jalali month ⏳ 2026-09-01", "2026-11-03") == "- [ ] Pay 🔁 every jalali month ⏳ 2026-12-01")
        #expect(next("- [ ] Pay 🔁 every jalali month when done ⏳ 2026-10-01", "2026-11-01")
            == "- [ ] Pay 🔁 every jalali month when done ⏳ 2026-12-01")
        #expect(next("- [ ] Pay 🔁 every jalali month ➕ 2026-12-01 ⏳ 2026-12-31 📅 2027-01-02", "2026-12-31")
            == "- [ ] Pay 🔁 every jalali month ➕ 2026-12-01 ⏳ 2027-01-30 📅 2027-02-01")
        #expect(next("- [ ] Pay 🔁 every 3 jalali months ⏳ 2026-12-31", "2026-12-31") == "- [ ] Pay 🔁 every 3 jalali months ⏳ 2027-03-30")
        #expect(TaskLine.toggled("- [ ] Pay 🔁 every jalali month ⏳ 2026-12-31", today: "2026-12-31")?.last
            == "- [x] Pay 🔁 every jalali month ⏳ 2026-12-31 ✅ 2026-12-31")
    }

    @Test func aJalaliRepeatOffTheCalendarCompletesWithoutOne() {
        #expect(TaskLine.toggled("- [ ] Far 🔁 every 9000 jalali years ⏳ 2026-12-31", today: "2026-12-31")
            == ["- [x] Far 🔁 every 9000 jalali years ⏳ 2026-12-31 ✅ 2026-12-31"])
    }

    @Test func aNumberOverTheLimitIsRefused() {
        #expect(Recurrence("every 10000 years")?.amount == 10_000)
        for refused in ["every 10001 days", "every 999999999 years", "every 4000000000 days", "every 99999999999999999999 weeks"] {
            #expect(Recurrence(refused) == nil, "\(refused)")
        }
        // Ticked with no next occurrence, never a crash.
        #expect(TaskLine.toggled("- [ ] Far 🔁 every 999999999 years 📅 2026-01-01", today: "2026-01-01")
            == ["- [x] Far 🔁 every 999999999 years 📅 2026-01-01 ✅ 2026-01-01"])
        #expect(TaskLine.toggled("- [ ] Far 🔁 every 10000 years 📅 2026-01-01", today: "2026-01-01")?.first
            == "- [ ] Far 🔁 every 10000 years 📅 12026-01-01")
    }

    @Test func aTaskTickedYearsLateComesBackAfterToday() {
        func next(_ line: String) -> String? { TaskLine.toggled(line, today: "2026-11-06")?.first }
        #expect(next("- [ ] Water 🔁 every day 📅 1990-01-01") == "- [ ] Water 🔁 every day 📅 2026-11-07")
        #expect(next("- [ ] Bins 🔁 every 2 weeks 📅 1990-01-01") == "- [ ] Bins 🔁 every 2 weeks 📅 2026-11-16")
        #expect(next("- [ ] Rent 🔁 every month 📅 1990-01-31") == "- [ ] Rent 🔁 every month 📅 2026-11-28")
        #expect(next("- [ ] Early 🔁 every day 📅 2026-12-01") == "- [ ] Early 🔁 every day 📅 2026-12-02")
    }

    @Test func theBlockIdStaysLast() {
        let lines = TaskLine.toggled("- [ ] t 🔁 every day 📅 2026-10-25 ^abc", today: "2026-10-25")
        #expect(lines == ["- [ ] t 🔁 every day 📅 2026-10-26", "- [x] t 🔁 every day 📅 2026-10-25 ✅ 2026-10-25 ^abc"])
        #expect(TaskLine.toggled("- [ ] t ^abc", today: "2026-10-25") == ["- [x] t ✅ 2026-10-25 ^abc"])
        #expect(TaskLine.toggled("- [x] t ✅ 2026-10-25 ^abc", today: "2026-10-26") == ["- [ ] t ^abc"])
        #expect(EditorCommands.toggleTask("- [ ] t ^abc", today: Day("2026-10-25")!) == ["- [x] t ✅ 2026-10-25 ^abc"])
    }

    @Test func aSignifierWithAVariationSelectorIsRead() throws {
        // Some keyboards write U+FE0F after an emoji; the Tasks plugin reads the date all the same.
        let task = try #require(TaskLine.parse("- [ ] Water the plants ⏫\u{FE0F} 🔁\u{FE0F} every week ⏳\u{FE0F} 2026-11-10 📅\u{FE0F}2026-11-12", line: 0, section: ""))
        #expect(task.text == "Water the plants")
        #expect(task.priority == "⏫")
        #expect(task.recurring == "every week")
        #expect(task.scheduled == "2026-11-10")
        #expect(task.due == "2026-11-12")
        #expect(TaskLine.parse("- [x] Done ✅\u{FE0F} 2026-11-10", line: 0, section: "")?.done == "2026-11-10")
        // Ticked, it repeats; written back, it is the plain form.
        #expect(TaskLine.toggled("- [ ] Water 🔁\u{FE0F} every week ⏳\u{FE0F} 2026-11-10", today: "2026-11-10")?.first == "- [ ] Water 🔁 every week ⏳ 2026-11-17")
        let fields = try #require(TaskLine.fields("- [ ] Water ⏳\u{FE0F} 2026-11-10"))
        #expect(TaskLine.edited("- [ ] Water ⏳\u{FE0F} 2026-11-10", fields) == "- [ ] Water ⏳ 2026-11-10")
        // An emoji in the sentence keeps its selector.
        #expect(TaskLine.parse("- [ ] Buy ✅\u{FE0F} stickers 📅 2026-11-10", line: 0, section: "")?.text == "Buy ✅\u{FE0F} stickers")
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
        #expect(throws: VaultEdits.Failure.taskMoved) {
            try VaultEdits.toggleTask(in: text, line: 9, status: " ", today: Day("2026-10-05")!)
        }
        // The text the page showed must still be the line's.
        #expect(throws: VaultEdits.Failure.taskMoved) {
            try VaultEdits.toggleTask(in: text, line: 2, status: " ", expected: "One", today: Day("2026-10-05")!)
        }
        _ = try VaultEdits.toggleTask(in: text, line: 2, status: " ", expected: "Two", today: Day("2026-10-05")!)
    }

    @Test func windowsLineEndingsSurvive() throws {
        let out = try VaultEdits.toggleTask(in: "- [ ] One\r\n", line: 0, status: " ", today: Day("2026-10-05")!)
        #expect(out == "- [x] One ✅ 2026-10-05\r\n")
    }
}

@Suite struct DayTests {
    @Test func onlyASCIIDigitsAreADay() {
        #expect(Day("2026-11-10") != nil)
        #expect(Day("۲۰۲۶-۱۱-۱۰") == nil)
        #expect(Day("٢٠٢٦-١١-١٠") == nil)
        // A date in another script's digits is part of the sentence, not a due date with no day.
        let task = TaskLine.parse("- [ ] pay rent 📅 ۲۰۲۶-۱۱-۱۰", line: 0, section: "")
        #expect(task?.due == nil)
        #expect(task?.text == "pay rent 📅 ۲۰۲۶-۱۱-۱۰")
        #expect(Recurrence("every ۲ weeks") == nil)
        #expect(TasksQuery.parse("due in ۳ days\nlimit ۵\ndue ٢٠٢٦-١١-١٠").notUnderstood.count == 3)
    }

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

    @Test func digitsOfAnotherScriptAreNotATime() {
        // `Int` reads ASCII digits only: a time in Persian digits is no event, and never a crash.
        let text = "Times are Europe/Madrid.\n\n## Monday 9 November\n\n- ۱۰:۰۰–۱۱:۰۰ Standup\n- 25:99–26:00 Never\n- 10:00–11:00 Real\n\n## Tuesday ۱۰ November\n\n- All day Lost\n"
        let days = CalendarWeek.parse(text, path: "Calendar/2026-W46.md")
        #expect(days.count == 1)
        #expect(days[0].meetings.map(\.title) == ["Never", "Real", "Lost"])
        #expect(days[0].meetings.map(\.allDay) == [true, false, true])
        #expect(!CalendarWeek.isWeekNote("Calendar/۲۰۲۶-W۴۶.md"))
        #expect(CalendarWeek.parse(text, path: "Calendar/۲۰۲۶-W۴۶.md").isEmpty)
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

    /// The words side by side come first, then near each other, then
    /// anywhere: "House II" finds the note that names it before one about a
    /// house that mentions World War II.
    @Test func thePhraseFirst() {
        let index = SearchIndex()
        index.put(path: "war.md", title: "History", body: "A house burned down in the old town, and the long story of that night is told by the people who lived there through World War II.")
        index.put(path: "near.md", title: "Flats", body: "The house we call II is by the sea.")
        index.put(path: "flat.md", title: "Identity", body: "Address of House II: the second flat.")
        index.put(path: "other.md", title: "Other", body: "Nothing here.")
        #expect(index.search("House II").map(\.path) == ["flat.md", "near.md", "war.md"])
        // Half typed: the last word is a prefix in the phrase too.
        #expect(index.search("house i").first?.path == "flat.md")
        // Quotes keep their meaning and run alone.
        #expect(SearchIndex.matchTiers("\"House II\"") == ["\"House II\""])
        #expect(SearchIndex.matchTiers("house").count == 1)
        #expect(index.search("house ii", limit: 2).count == 2)
    }

    @Test func persianIsFoundHoweverItWasTyped() {
        let index = SearchIndex()
        index.put(path: "a.md", title: "سفر", body: "می\u{200C}خواهم كتاب علي را ۱۲ بار بخوانم")
        index.put(path: "b.md", title: "Other", body: "nothing here")
        for query in ["میخواهم", "می\u{200C}خواهم", "می خواهم", "کتاب", "علی", "12", "۱۲"] {
            #expect(index.search(query, limit: 10).map(\.path) == ["a.md"], "\(query)")
        }
        // A word with its vowel marks or stretched with a tatweel is the word without them.
        index.put(path: "c.md", title: "ادب", body: "لطفاً مؤدّب باش، کتـــاب")
        for query in ["مودب", "مؤدب", "مؤدّب", "لطفا", "لطفاً"] {
            #expect(index.search(query, limit: 10).map(\.path) == ["c.md"], "\(query)")
        }
        #expect(Set(index.search("کتاب", limit: 10).map(\.path)) == ["a.md", "c.md"])
        // The snippet is the note's own text.
        #expect(index.search("خواهم", limit: 10).first?.snippet.unicodeScalars.contains("\u{200C}") == true)
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

    @Test func aFoldersLogoIsItsIcon() {
        let files: Set<String> = ["Companies/Acme/Acme.md", "Companies/Acme/logo.png", "Companies/Acme/Logo.SVG", "Companies/Acme/Notes.md", "Companies/Beta/b.md", "logo.svg"]
        let tree = Vault.tree(of: files)
        let acme = tree.first { $0.name == "Companies" }?.children?.first { $0.name == "Acme" }
        // A drawing wins over a picture, whatever the case of its name.
        #expect(acme?.logo == "Companies/Acme/Logo.SVG")
        #expect(acme?.children?.map(\.name) == ["Notes"])
        #expect(tree.first { $0.name == "Companies" }?.children?.first { $0.name == "Beta" }?.logo == nil)
        #expect(Vault.logo(of: "Companies/Acme", in: files) == "Companies/Acme/Logo.SVG")
        #expect(Vault.logo(of: "Companies/Beta", in: files) == nil)
        // The vault's own logo.svg at the top is an ordinary file in the tree.
        #expect(tree.contains { $0.path == "logo.svg" })
    }

    @Test func findsAFolderInTheTree() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = Vault.index(root)
        #expect(index.folder("")?.map(\.name) == ["Notes", "Projects", "uploads"])
        #expect(index.folder("Projects/Alpha")?.map(\.name) == ["Plan"])
        #expect(index.folder("Projects")?.first?.folderNote == "Projects/Alpha/Alpha.md")
        #expect(index.folder("Nowhere") == nil)
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
        #expect(file.int("appearance.text_size") == 14)
        #expect(file.string("appearance.font") == "SF Pro")
        #expect(file.string("appearance.code_font") == "SF Mono")
        #expect(file.bool("git.pull_on_launch") == true)
        #expect(file.string("notifications.digest_time") == "09:00")
        #expect(file.bool("editor.cursor_trail") == true)
        #expect(file.string("editor.cursor_effect") == "none")
        #expect(file.string("editor.option_as_meta") == "none")
        #expect(file.bool("editor.blur_panels") == true)
        #expect(file.string("export.logo") == "")
        #expect(file.string("export.footer") == "")
        #expect(file.bool("appearance.remote_images") == true)
        #expect(file.bool("appearance.persian_calendar") == false)
        #expect(file.string("calendar.place") == "")
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

@Suite struct HighlighterTests {
    func kinds(_ text: String) -> [MarkdownHighlighter.Kind: [String]] {
        let ns = text as NSString
        var out: [MarkdownHighlighter.Kind: [String]] = [:]
        for span in MarkdownHighlighter.spans(in: text) { out[span.kind, default: []].append(ns.substring(with: span.range)) }
        return out
    }

    @Test func boldAndItalicWithHighlights() {
        let inside = kinds("==a **bold** and *it* word==")
        #expect(inside[.highlight] == ["==a **bold** and *it* word=="])
        #expect(inside[.bold] == ["**bold**"])
        #expect(inside[.italic] == ["*it*"])
        let both = kinds("***==both==*** and **==mark==**")
        #expect(both[.bold] == ["***==both==***", "**==mark==**"])
        #expect(both[.italic] == ["***==both==***"])
        #expect(both[.highlight] == ["==both==", "==mark=="])
        #expect(both[.markup]?.filter { $0 == "***" }.count == 2)
        #expect(kinds("___under___")[.italic] == ["___under___"])
        // Code inside a highlight; marks inside code are not marks.
        #expect(kinds("==the `x` flag==")[.highlight] == ["==the `x` flag=="])
        #expect(kinds("`a*b` and `c*d`")[.italic] == nil)
        #expect(kinds("`==a` b==")[.highlight] == nil)
    }

    @Test func headingsAndInline() {
        let found = kinds("## Title **bold** and *it* with `co**de**` and [[Note|label]] #tag")
        #expect(found[.heading(2)] == ["## Title **bold** and *it* with `co**de**` and [[Note|label]] #tag"])
        #expect(found[.bold] == ["**bold**"])
        #expect(found[.italic] == ["*it*"])
        #expect(found[.code] == ["`co**de**`"])
        #expect(found[.link] == ["[[Note|label]]"])
        #expect(found[.tag] == ["#tag"])
        #expect(found[.markup]?.contains("Note|") == true)
    }

    @Test func tasksAndMetadata() {
        let found = kinds("- [x] Done thing ✅ 2026-10-05\n    - [ ] Open ⏳ 2026-10-06")
        #expect(found[.taskDone]?.first == "[x]")
        #expect(found[.taskOpen] == ["[ ]"])
        #expect(found[.metadata] == ["✅ 2026-10-05", "⏳ 2026-10-06"])
        #expect(found[.listMarker] == ["- ", "    - "])
    }

    @Test func blocksCarryState() {
        let text = "---\ntags: [a]\n---\n```swift\nlet **x** = 1\n```\n%%\nhidden\n%%\nafter"
        let found = kinds(text)
        #expect(found[.frontMatter] == ["---", "tags: [a]", "---"])
        #expect(found[.codeBlock] == ["let **x** = 1"])
        #expect(found[.fence] == ["```swift", "```"])
        #expect(found[.comment] == ["%%", "hidden", "%%"])
        #expect(found[.bold] == nil)
        let ns = text as NSString
        #expect(MarkdownHighlighter.blockState(before: ns.range(of: "let").location, in: ns) == .fence("```"))
        #expect(MarkdownHighlighter.blockState(before: ns.range(of: "after").location, in: ns) == .normal)
    }

    @Test func calloutAndQuote() {
        let found = kinds("> [!warning] Careful\n> body")
        #expect(found[.calloutTitle] == ["[!warning] Careful"])
        #expect(found[.quote]?.count == 2)
    }
}

@Suite struct EditorCommandTests {
    @Test func returnContinuesLists() {
        #expect(EditorCommands.onReturn(after: "- item") == .insert("\n- "))
        #expect(EditorCommands.onReturn(after: "    - [x] done") == .insert("\n    - [ ] "))
        #expect(EditorCommands.onReturn(after: "9. ninth") == .insert("\n10. "))
        #expect(EditorCommands.onReturn(after: "> - quoted") == .insert("\n> - "))
        #expect(EditorCommands.onReturn(after: "- ") == .endList)
        #expect(EditorCommands.onReturn(after: "- [ ] ") == .endList)
        #expect(EditorCommands.onReturn(after: "plain") == nil)
    }

    @Test func toggleMakesTasks() {
        let day = Day("2026-10-05")!
        #expect(EditorCommands.toggleTask("    - item", today: day) == ["    - [ ] item"])
        #expect(EditorCommands.toggleTask("  text", today: day) == ["  - [ ] text"])
        #expect(EditorCommands.toggleTask("- [ ] a", today: day) == ["- [x] a ✅ 2026-10-05"])
    }

    @Test func indentByFour() {
        #expect(EditorCommands.indent("- a") == "    - a")
        #expect(EditorCommands.outdent("        - a") == "    - a")
        #expect(EditorCommands.outdent("  - a") == "- a")
    }

    @Test func linkQuery() {
        let text = "See [[Kube and [[done]] here" as NSString
        #expect(EditorCommands.linkQuery(in: text, at: 10).map { text.substring(with: $0) } == "Kube")
        #expect(EditorCommands.linkQuery(in: text, at: text.length) == nil)
    }

    @Test func pastedName() {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 10; parts.day = 25; parts.hour = 9; parts.minute = 5; parts.second = 7
        let date = Calendar.current.date(from: parts)!
        #expect(EditorCommands.pastedImageName(at: date) == "Pasted image 20261025090507.png")
    }
}

@Suite struct TasksQueryTests {
    let today = Day("2026-10-21")!  // a Wednesday
    let tasks = [
        QueryTask(text: "Ship the plan #work", state: .todo, path: "Tasks/Work.md", section: "Alpha", scheduled: "2026-10-20"),
        QueryTask(text: "Half way", state: .inProgress, path: "Tasks/Work.md", section: "Beta"),
        QueryTask(text: "Book flights", state: .todo, path: "Tasks/Home.md", section: "", due: "2026-10-28"),
        QueryTask(text: "Old one", state: .done, path: "Tasks/Home.md", section: "Done", done: "2026-10-01"),
        QueryTask(text: "Reading", state: .todo, path: "Books/Reading.md", section: "", scheduled: "2026-10-22"),
        QueryTask(text: "Dropped", state: .cancelled, path: "Tasks/Work.md", section: "Alpha"),
    ]

    func run(_ source: String, file: String = "Tasks/Tasks.md") -> [String] {
        TasksQuery.parse(source, file: file).run(tasks, today: today) { $0 }.map(\.text)
    }

    @Test func andBindsBeforeOrAsInThePlugin() {
        // NOT, then XOR, then AND, then OR: this is "plan", or both "one" and "old".
        #expect(Set(run("(description includes plan) OR (description includes one) AND (description includes old)")) == ["Ship the plan #work", "Old one"])
        #expect(Set(run("(description includes one) AND (description includes old) OR (description includes plan)")) == ["Ship the plan #work", "Old one"])
        // Brackets still say otherwise.
        #expect(run("((description includes plan) OR (description includes one)) AND (description includes old)") == ["Old one"])
        // XOR before AND: done, and exactly one of the two words.
        #expect(run("(done) AND (description includes old) XOR (description includes dropped)") == ["Old one", "Dropped"])
        #expect(run("(done) AND NOT (description includes old)") == ["Dropped"])
        #expect(run("(path includes Home) AND NOT (done) OR (description includes Reading)") == ["Reading", "Book flights"])
        #expect(TasksQuery.parse("(done) OR (not done) AND").notUnderstood.count == 1)
    }

    @Test func inSomeDaysIsADay() {
        // The `in` belongs to the date, as in `due before in 7 days`.
        #expect(TasksQuery.parse("due in 7 days\nscheduled in 1 day\nhappens in 2 days\ndue on in 7 days").notUnderstood.isEmpty)
        #expect(run("due in 7 days") == ["Book flights"])
        #expect(run("scheduled in 1 day") == ["Reading"])
        #expect(run("due in 6 days").isEmpty)
        // `in` before a range is still the relation.
        #expect(run("due in 2026-10-26 2026-11-01") == ["Book flights"])
        #expect(TasksQuery.parse("due in a while").notUnderstood == ["due in a while"])
    }

    @Test func theVaultsInProgressQuery() {
        let source = """
            folder includes {{query.file.folder}}
            filter by function task.status.type === "IN_PROGRESS" && task.file.filenameWithoutExtension != "Books"
            group by function task.file.filenameWithoutExtension
            group by function task.hasHeading ? task.heading : ''
            show tree
            short mode
            """
        let query = TasksQuery.parse(source, file: "Tasks/Tasks.md")
        #expect(query.notUnderstood.isEmpty)
        let found = query.run(tasks, today: today) { $0 }
        #expect(found.map(\.text) == ["Half way"])
        #expect(query.groups(of: found[0]) == ["Work", "Beta"])
    }

    @Test func datesAndRanges() {
        #expect(run("scheduled on or before this week\nnot done") == ["Ship the plan #work", "Reading"])
        #expect(run("due next week") == ["Book flights"])
        #expect(run("scheduled before today") == ["Ship the plan #work"])
        #expect(run("no due date\nnot done\nfolder includes Tasks/") == ["Ship the plan #work", "Half way"])
        #expect(run("done on 2026-10-01") == ["Old one"])
    }

    @Test func booleansAndText() {
        #expect(Set(run("(due next week) OR (scheduled tomorrow)")) == ["Book flights", "Reading"])
        #expect(run("NOT (done)\nheading includes alpha") == ["Ship the plan #work"])
        #expect(run("tags include work") == ["Ship the plan #work"])
        #expect(run("description does not include o\nnot done") == ["Reading", "Half way"])
    }

    @Test func doneMeansFinished() {
        #expect(Set(run("done")) == ["Old one", "Dropped"])
    }

    @Test func sortAndLimit() {
        #expect(run("not done\nsort by description\nlimit 2") == ["Book flights", "Half way"])
        #expect(run("not done\nsort by path reverse\nlimit 1") == ["Ship the plan #work"])
    }

    @Test func unknownLinesAreReported() {
        let query = TasksQuery.parse("priority is high\nfilter by function task.urgency > 3\nfolder includes {{query.file.unknown}}", file: "A.md")
        #expect(query.notUnderstood.count == 3)
        #expect(TasksQuery.parse("folder includes {{query.file.folder}}").notUnderstood.count == 1)
    }

    @Test func expressions() throws {
        let task = tasks[0]
        #expect(try #require(TaskExpression.parse("task.description.toLowerCase().includes('ship')")).test(task))
        #expect(try #require(TaskExpression.parse("['Work', 'Home'].includes(task.file.filenameWithoutExtension)")).test(task))
        #expect(try #require(TaskExpression.parse("!task.isDone && task.file.folder === 'Tasks/'")).test(task))
        #expect(TaskExpression.parse("task.urgency") == nil)
        #expect(TaskExpression.parse("1 + 2") == nil)
    }
}
