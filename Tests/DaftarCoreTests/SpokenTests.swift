import Testing

@testable import DaftarCore

@Suite struct SpokenTests {
    let today = Day(year: 2026, month: 10, day: 25)

    func task(_ raw: String, section: String = "Kit") -> ParsedTask {
        TaskLine.parse(raw, line: 0, section: section)!
    }

    @Test func aTaskRowReadsAsItLooks() {
        #expect(Spoken.task(task("- [ ] Call [[Sara Ahmadi|Sara]] ⏫ 🔁 every week 📅 2026-10-25"), note: "Work", today: today)
            == "Call Sara, open, due today, high priority, repeats every week, in Work › Kit")
        #expect(Spoken.task(task("- [/] Build the shelf", section: ""), today: today) == "Build the shelf, in progress")
        #expect(Spoken.task(task("- [x] Shipped ✅ 2026-10-20", section: ""), note: "Inbox", today: today) == "Shipped, done, in Inbox")
    }

    @Test func aLateDayIsSaidNotOnlyColoured() {
        #expect(Spoken.when(task("- [ ] Pay 📅 2026-10-20"), today: today) == "due 2026-10-20, overdue")
        // A closed task is not late.
        #expect(Spoken.when(task("- [x] Pay 📅 2026-10-20"), today: today) == "due 2026-10-20")
        #expect(Spoken.when(task("- [ ] Pay 📅 2026-10-26"), today: today) == "due tomorrow")
        #expect(Spoken.when(task("- [ ] Plan ⏳ 2026-10-24"), today: today) == "scheduled yesterday")
        #expect(Spoken.when(task("- [ ] Plan"), today: today) == nil)
    }

    @Test func everyStatusAndPriorityHasWords() {
        #expect([" ", "/", "x", "X", "-", "?"].map { Spoken.status(Character($0)) } == ["open", "in progress", "done", "done", "cancelled", "status ?"])
        #expect(["🔺", "⏫", "🔼", "🔽", "⏬"].compactMap(Spoken.priority).count == 5)
        #expect(Spoken.priority(nil) == nil)
        #expect(Spoken.priority("x") == nil)
    }

    @Test func smallWords() {
        #expect(Spoken.heading(level: 2, text: "Plans") == "Heading level 2, Plans")
        #expect(Spoken.count(1, "note") == "1 note")
        #expect(Spoken.count(3, "match", plural: "matches") == "3 matches")
        #expect(Spoken.plain("See [[A]] and [[B|bee]]") == "See A and bee")
    }
}
