import Foundation
import Testing

@testable import DaftarCore

/// The `[reason:: …]` field and the vault's own statuses: the rules the
/// three apps share (the spec's list of tests, in the same order).
@Suite struct TaskReasonTests {
    let today = Day(year: 2026, month: 10, day: 28)

    /// The Tasks plugin's settings of a vault with `[r]` "In Review".
    static let settings = Data("""
        {"statusSettings":{"coreStatuses":[{"symbol":" ","name":"Todo","nextStatusSymbol":"x","availableAsCommand":true,"type":"TODO"},\
        {"symbol":"x","name":"Done","nextStatusSymbol":" ","availableAsCommand":true,"type":"DONE"}],"customStatuses":[\
        {"symbol":"/","name":"In Progress","nextStatusSymbol":"x","availableAsCommand":true,"type":"IN_PROGRESS"},\
        {"symbol":"-","name":"Cancelled","nextStatusSymbol":" ","availableAsCommand":true,"type":"CANCELLED"},\
        {"symbol":"r","name":"In Review","nextStatusSymbol":"x","availableAsCommand":false,"type":"IN_PROGRESS"}]}}
        """.utf8)
    let statuses = TaskStatuses(json: settings)

    // MARK: Reading

    @Test func readsTheReasonBeforeTheSignifiers() throws {
        let task = try #require(TaskLine.parse("- [-] Deploy [reason:: no budget] ➕ 2025-05-17 ❌ 2025-11-16", line: 0, section: ""))
        #expect(task.text == "Deploy")
        #expect(task.reason == "no budget")
        #expect(task.cancelled == "2025-11-16")
        #expect(task.created == "2025-05-17")
    }

    @Test func aWikilinkStaysInTheReason() throws {
        let task = try #require(TaskLine.parse("- [r] Ship [reason:: waiting on [[Amir]]] 📅 2026-11-02 ^imp", line: 0, section: ""))
        #expect(task.text == "Ship")
        #expect(task.reason == "waiting on [[Amir]]")
        #expect(task.due == "2026-11-02")
    }

    @Test func aFieldInTheMiddleLeavesTheTextWhole() throws {
        let task = try #require(TaskLine.parse("- [ ] Call [reason:: busy] the bank", line: 0, section: ""))
        #expect(task.text == "Call the bank")
        #expect(task.reason == "busy")
    }

    func split(_ description: String) -> [String?] {
        let parts = TaskReason.split(description)
        return [parts.text, parts.reason]
    }

    @Test func onlyTheFirstFieldIsTheReason() {
        #expect(split("a [Reason ::x] b [reason:: y]") == ["a b [reason:: y]", "x"])
        // An empty field is no reason, and leaves the text all the same.
        #expect(split("a [reason:: ] b") == ["a b", nil])
        // A field that never closes is text.
        #expect(split("a [reason:: open") == ["a [reason:: open", nil])
        #expect(split("a [reasons:: x]") == ["a [reasons:: x]", nil])
    }

    // MARK: Writing

    @Test func theReasonIsWrittenBeforeTheSignifiers() throws {
        let raw = "- [ ] T 📅 2026-11-02"
        var fields = try #require(TaskLine.fields(raw))
        fields.reason = "a ] b"
        let written = try #require(TaskLine.edited(raw, fields))
        #expect(written == "- [ ] T [reason:: a ) b] 📅 2026-11-02")
        // Cleared, it is gone.
        var cleared = try #require(TaskLine.fields(written))
        #expect(cleared.reason == "a ) b")
        cleared.reason = "  "
        #expect(TaskLine.edited(written, cleared) == raw)
        // The block id stays last.
        var named = try #require(TaskLine.fields("- [ ] T 📅 2026-11-02 ^abc"))
        named.reason = "on\nhold\t[[Amir]]"
        #expect(TaskLine.edited("- [ ] T 📅 2026-11-02 ^abc", named) == "- [ ] T [reason:: on hold [[Amir]]] 📅 2026-11-02 ^abc")
    }

    @Test func theFieldsOfAReasonReadBack() throws {
        let raw = "- [r] Ship [reason:: waiting on [[Amir]]] 📅 2026-11-02 ^imp"
        let fields = try #require(TaskLine.fields(raw))
        #expect(fields.text == "Ship")
        #expect(fields.reason == "waiting on [[Amir]]")
        #expect(TaskLine.edited(raw, fields) == raw)
    }

    // MARK: Status changes

    @Test func cancellingWithAReason() {
        #expect(TaskLine.settingStatus("- [ ] Write ⏳ 2026-10-04", to: "-", reason: "no time", today: today, statuses: statuses)
            == ["- [-] Write [reason:: no time] ⏳ 2026-10-04 ❌ 2026-10-28"])
    }

    @Test func aTickTakesTheReasonAway() {
        #expect(TaskLine.toggled("- [-] Write [reason:: no time] ⏳ 2026-10-04 ❌ 2026-10-28", today: "2026-10-29", statuses: statuses)
            == ["- [ ] Write ⏳ 2026-10-04"])
        #expect(TaskLine.toggled("- [r] Ship [reason:: review] 📅 2026-11-02 ^imp", today: "2026-10-28", statuses: statuses)
            == ["- [x] Ship 📅 2026-11-02 ✅ 2026-10-28 ^imp"])
    }

    @Test func aRepeatingTaskLeavesItsReasonBehind() throws {
        let lines = try #require(TaskLine.toggled("- [/] Water [reason:: no can] 🔁 every week 📅 2026-10-25", today: "2026-10-28", statuses: statuses))
        #expect(lines == ["- [ ] Water 🔁 every week 📅 2026-11-01", "- [x] Water 🔁 every week 📅 2026-10-25 ✅ 2026-10-28"])
    }

    @Test func settingAStatusFollowsItsType() {
        let set = { (raw: String, status: Character, reason: String?) in
            TaskLine.settingStatus(raw, to: status, reason: reason, today: self.today, statuses: self.statuses)
        }
        // Open to a status of the vault's own: the old reason goes, unless a new one is given.
        #expect(set("- [/] Ship [reason:: coding]", "r", nil) == ["- [r] Ship"])
        #expect(set("- [/] Ship [reason:: coding]", "r", "Amir reads it") == ["- [r] Ship [reason:: Amir reads it]"])
        // The same status with a new reason changes only the reason.
        #expect(set("- [r] Ship", "r", "later") == ["- [r] Ship [reason:: later]"])
        #expect(set("- [r] Ship", "r", nil) == nil)
        // Done from open is the tick; cancelled to done sets ✅ and takes ❌ away.
        #expect(set("- [r] Ship", "x", nil) == ["- [x] Ship ✅ 2026-10-28"])
        #expect(set("- [-] Ship ❌ 2026-10-20", "x", nil) == ["- [x] Ship ✅ 2026-10-28"])
        #expect(set("- [x] Ship ✅ 2026-10-20", "X", nil) == ["- [X] Ship ✅ 2026-10-20"])
    }

    @Test func aBoardColumnKeepsACardOfItsType() {
        #expect(TaskBoard.moved("- [r] Ship", to: .status("/"), today: today, statuses: statuses) == nil)
        #expect(TaskBoard.moved("- [ ] Ship [reason:: x]", to: .status("/"), today: today, statuses: statuses) == ["- [/] Ship"])
        #expect(TaskBoard.moved("- [r] Ship", to: .status("-", reason: "dropped"), today: today, statuses: statuses)
            == ["- [-] Ship [reason:: dropped] ❌ 2026-10-28"])
        let review = VaultTask(path: "Work.md", task: TaskLine.parse("- [r] Ship", line: 0, section: "")!)
        let columns = TaskBoard.columns([review], by: .status, today: today, statuses: statuses)
        #expect(columns[1].tasks.map(\.task.text) == ["Ship"])
    }

    @Test func theFormSetsANewStatusAsAMenuDoes() throws {
        let before = try #require(TaskLine.fields("- [ ] Write ⏳ 2026-10-04"))
        var after = before
        after.status = "-"
        after.reason = "no time"
        #expect(try VaultEdits.editTask(in: "- [ ] Write ⏳ 2026-10-04\n", line: 0, before: before, fields: after, today: today, statuses: statuses)
            == "- [-] Write [reason:: no time] ⏳ 2026-10-04 ❌ 2026-10-28\n")
        // Only the reason: the status and the dates stay.
        var reason = before
        reason.reason = "waiting"
        #expect(try VaultEdits.editTask(in: "- [ ] Write ⏳ 2026-10-04", line: 0, before: before, fields: reason, today: today, statuses: statuses)
            == "- [ ] Write [reason:: waiting] ⏳ 2026-10-04")
    }

    // MARK: Statuses

    @Test func theSettingsAddTheirStatuses() {
        #expect(statuses.all.map(\.symbol) == [" ", "x", "/", "-", "r"])
        let review = statuses.status("r")
        #expect(review.name == "In Review")
        #expect(review.type == .inProgress)
        #expect(review.next == "x")
        #expect(!review.isClosed && !review.isDefault)
        #expect(statuses.isClosed("X") && statuses.isClosed("-"))
    }

    @Test func noSettingsAreTheFourDefaults() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "daftar-statuses-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = TaskStatuses.load(root)
        #expect(missing.all.map(\.name) == ["Todo", "Done", "In Progress", "Cancelled"])
        #expect(missing == TaskStatuses(json: Data("not json".utf8)))
        let unknown = missing.status(">")
        #expect(unknown.name == "[>]")
        #expect(unknown.type == .todo)
        // A symbol listed twice is the first; one of two characters is left out.
        let odd = TaskStatuses(json: Data(#"{"statusSettings":{"customStatuses":[{"symbol":"r","name":"A","type":"DONE"},{"symbol":"r","name":"B","type":"TODO"},{"symbol":"ab","name":"C","type":"DONE"},{"symbol":"~","name":"Note","type":"NON_TASK"}]}}"#.utf8))
        // The defaults the settings leave out go where they would be among the core ones.
        #expect(odd.all.map(\.symbol) == [" ", "x", "/", "-", "r", "~"])
        #expect(odd.status("r").name == "A")
        #expect(odd.isClosed("~"))
    }

    @Test func theIndexReadsTheSettingsAgainWhenTheyChange() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "daftar-statuses-\(UUID().uuidString)")
        let file = root.appending(path: TaskStatuses.file)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("- [r] Ship\n".utf8).write(to: root.appending(path: "Work.md"))
        let before = Vault.index(root)
        #expect(before.statuses == .defaults)
        try Self.settings.write(to: file)
        let after = Vault.update(before, changed: [TaskStatuses.file], in: root)
        #expect(after.statuses.status("r").name == "In Review")
        // A broken file is the defaults again, never a failure.
        try Data("{".utf8).write(to: file)
        #expect(Vault.update(after, changed: [TaskStatuses.file], in: root).statuses == .defaults)
    }

    // MARK: Queries

    var queried: [QueryTask] {
        [
            "- [-] Deploy [reason:: no budget left] ❌ 2026-10-01",
            "- [r] Ship [reason:: waiting on [[Amir]]] 📅 2026-11-02",
            "- [/] Build",
            "- [ ] Plan",
        ].enumerated().map { line, raw in
            QueryTask(VaultTask(path: "Tasks/Work.md", task: TaskLine.parse(raw, line: line, section: "")!), statuses: statuses)
        }
    }

    func run(_ source: String) -> [String] {
        TasksQuery.parse(source).run(queried, today: today) { $0 }.map(\.text)
    }

    @Test func queriesSeeReasonsAndStatusNames() {
        #expect(Set(run("has reason")) == ["Deploy", "Ship"])
        #expect(Set(run("no reason")) == ["Build", "Plan"])
        #expect(run("reason includes BUDGET") == ["Deploy"])
        #expect(Set(run("reason does not include budget")) == ["Ship", "Build", "Plan"])
        #expect(run("status.name is In Review") == ["Ship"])
        #expect(Set(run("status.name is not in review\nnot done")) == ["Build", "Plan"])
        #expect(run("status.name includes review") == ["Ship"])
        #expect(Set(run("status.type is in_progress")) == ["Ship", "Build"])
        #expect(run("done") == ["Deploy"])
        // The description is the text without the field.
        #expect(run("description includes budget").isEmpty)
        #expect(run("filter by function task.reason && task.reason.includes('Amir')") == ["Ship"])
        #expect(Set(run("filter by function task.reason === null")) == ["Build", "Plan"])
        #expect(run("filter by function task.status.symbol === 'r' && task.status.name === 'In Review'") == ["Ship"])
        #expect(run("filter by function task.isDone") == [])
        let query = TasksQuery.parse("not done\ngroup by status.name")
        #expect(query.notUnderstood.isEmpty)
        #expect(Set(queried.filter { !$0.state.isFinished }.map { query.groups(of: $0) }) == [["In Review"], ["In Progress"], ["Todo"]])
    }
}
