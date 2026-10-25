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
