import Foundation
import Testing

@testable import DaftarCore

@Suite struct TaskBoardTests {
    let today = Day(year: 2026, month: 10, day: 25)

    func task(_ raw: String, path: String = "Tasks/Work.md", line: Int = 0) -> VaultTask {
        VaultTask(path: path, task: TaskLine.parse(raw, line: line, section: "Kit")!)
    }

    @Test func statusColumnsKeepRecentlyClosedOnly() {
        let tasks = [
            task("- [ ] Write 📅 2026-10-27", line: 0),
            task("- [ ] Urgent ⏫ 📅 2026-10-27", line: 1),
            task("- [/] Build", line: 2),
            task("- [x] Shipped ✅ 2026-10-20", line: 3),
            task("- [x] Long ago ✅ 2026-01-01", line: 4),
            task("- [-] Dropped ❌ 2026-10-24", line: 5),
        ]
        let columns = TaskBoard.columns(tasks, by: .status, today: today)
        #expect(columns.map(\.id) == ["todo", "doing", "done", "cancelled"])
        // The same day: the higher priority first.
        #expect(columns[0].tasks.map(\.task.text) == ["Urgent", "Write"])
        #expect(columns[1].tasks.map(\.task.text) == ["Build"])
        #expect(columns[2].tasks.map(\.task.text) == ["Shipped"])
        #expect(columns[3].tasks.map(\.task.text) == ["Dropped"])
        #expect(TaskBoard.columns(tasks, by: .status, today: today, closedWithin: nil)[2].tasks.count == 2)
    }

    @Test func dayColumns() {
        let tasks = [
            task("- [ ] Late 📅 2026-10-20"), task("- [ ] Now ⏳ 2026-10-25"), task("- [ ] Next 📅 2026-10-26"),
            task("- [ ] Soon 📅 2026-11-01"), task("- [ ] Far 📅 2026-12-01"), task("- [ ] Whenever"), task("- [x] Done 📅 2026-10-25"),
        ]
        let columns = TaskBoard.columns(tasks, by: .day, today: today)
        #expect(columns.map { $0.tasks.map(\.task.text) } == [["Late"], ["Now"], ["Next"], ["Soon"], ["Far"], ["Whenever"]])
        #expect(columns[0].drop == nil && columns[4].drop == nil)
        #expect(columns[1].drop == .due("2026-10-25") && columns[5].drop == .due(nil))
    }

    @Test func fileColumns() {
        let tasks = [task("- [ ] B", path: "Tasks/Zeta.md"), task("- [ ] A", path: "Tasks/Alpha.md"), task("- [x] C", path: "Tasks/Beta.md")]
        #expect(TaskBoard.columns(tasks, by: .file, today: today).map(\.title) == ["Alpha", "Zeta"])
    }

    @Test func aDropWritesTheLine() {
        let date = today.description
        #expect(TaskBoard.moved("- [ ] Write 📅 2026-10-27", to: .status("/"), today: today) == ["- [/] Write 📅 2026-10-27"])
        #expect(TaskBoard.moved("- [/] Write", to: .status("x"), today: today) == ["- [x] Write ✅ \(date)"])
        #expect(TaskBoard.moved("- [ ] Write", to: .status("-"), today: today) == ["- [-] Write ❌ \(date)"])
        #expect(TaskBoard.moved("- [x] Write ✅ 2026-10-20", to: .status(" "), today: today) == ["- [ ] Write"])
        #expect(TaskBoard.moved("- [x] Write ✅ 2026-10-20", to: .status("/"), today: today) == ["- [/] Write"])
        #expect(TaskBoard.moved("- [ ] Write", to: .status(" "), today: today) == nil)
        #expect(TaskBoard.moved("- [ ] Write 📅 2026-10-27", to: .due("2026-10-25"), today: today) == ["- [ ] Write 📅 2026-10-25"])
        #expect(TaskBoard.moved("- [ ] Write 📅 2026-10-27", to: .due(nil), today: today) == ["- [ ] Write"])
        // A recurring task is ticked as a click ticks it: the next one comes above.
        let recurring = TaskBoard.moved("- [ ] Water 🔁 every week 📅 2026-10-25", to: .status("x"), today: today)
        #expect(recurring == ["- [ ] Water 🔁 every week 📅 2026-11-01", "- [x] Water 🔁 every week 📅 2026-10-25 ✅ \(date)"])
    }

    @Test func aDropRefusesALineThatChanged() throws {
        let text = "# Kit\n- [ ] Write\n- [ ] Read\n"
        let shown = task("- [ ] Write").task
        #expect(try VaultEdits.moveTask(in: text, line: 1, task: shown, to: .status("/"), today: today) == "# Kit\n- [/] Write\n- [ ] Read\n")
        #expect(throws: VaultEdits.Failure.taskMoved) { try VaultEdits.moveTask(in: text, line: 2, task: shown, to: .status("/"), today: today) }
    }
}

@Suite struct PostponeTests {
    let today = Day(year: 2026, month: 10, day: 26)

    func postponed(_ raw: String, _ amount: TaskLine.Postpone) -> String? {
        TaskBoard.moved(raw, to: .postpone(amount), today: today)?.first
    }

    @Test func theDueDateMovesOnFromItselfOrFromToday() {
        #expect(postponed("- [ ] Report 📅 2026-10-30", .day) == "- [ ] Report 📅 2026-10-31")
        #expect(postponed("- [ ] Report 📅 2026-10-30", .month) == "- [ ] Report 📅 2026-11-30")
        // Overdue: from today, so it is not overdue again at once.
        #expect(postponed("- [ ] Report 📅 2026-10-01", .week) == "- [ ] Report 📅 2026-11-02")
        #expect(postponed("- [ ] Report 📅 2026-10-26", .twoDays) == "- [ ] Report 📅 2026-10-28")
    }

    @Test func withoutADueDateTheScheduledThenTheStartDateMoves() {
        #expect(postponed("- [ ] Plan ⏳ 2026-10-27 🛫 2026-10-20", .threeDays) == "- [ ] Plan 🛫 2026-10-20 ⏳ 2026-10-30")
        #expect(postponed("- [/] Plan 🛫 2026-10-20 ^id-1", .twoWeeks) == "- [/] Plan 🛫 2026-11-09 ^id-1")
    }

    @Test func aTaskWithNoDateOrClosedStays() {
        #expect(postponed("- [ ] No date", .day) == nil)
        #expect(postponed("- [x] Done 📅 2026-10-30 ✅ 2026-10-25", .day) == nil)
        #expect(postponed("- [-] Dropped 📅 2026-10-30", .day) == nil)
        #expect(postponed("- [ ] Bad date 📅 2026-13-40", .day) == nil)
    }
}
