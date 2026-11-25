import Foundation
import Testing

@testable import DaftarCore

/// `docs/specs/more-vault-settings.md` in notes-linux, section 7, by name.
@Suite struct MoreVaultSettingsTests {
    static let today = Day(year: 2026, month: 11, day: 25)

    static func settings(_ vault: String) -> ResolvedSettings { ResolvedSettings.resolved(vault: vault, computer: "") }

    static func task(_ line: String, in path: String) -> VaultTask {
        VaultTask(path: path, task: TaskLine.parse(line, line: 0, section: "")!)
    }

    @Test func theWorkingDayIsTheSetting() {
        let working = Timeline.workingDay(Self.settings("[calendar]\nworking_day = \"08:00-16:30\"\n").string("calendar.working_day"))
        #expect(working == 480..<990)
        let timeline = Timeline(day: Self.today, meetings: [], tasks: [], statuses: .defaults, zone: TimeZone(identifier: "UTC")!, workingDay: working)
        #expect(timeline.free.map { [$0.start, $0.end] } == [[480, 990]])
        #expect(Timeline.workingDay("18:00-09:00") == Timeline.workingDay)
        #expect(Timeline.workingDay("nine to five") == Timeline.workingDay)
        // With no key, the template's value, which is the default.
        #expect(Timeline.workingDay(Self.settings("").string("calendar.working_day")) == 540..<1080)
    }

    @Test func aNewTaskIsScheduled() {
        let three = TaskFields.new(today: Self.today, scheduled: 3)
        #expect(three.created == "2026-11-25" && three.scheduled == "2026-11-28")
        let none = TaskFields.new(today: Self.today, scheduled: 0)
        #expect(none.created == "2026-11-25" && none.scheduled == nil)
        #expect(Self.settings("[tasks]\ndefault_scheduled = 3\n").int("tasks.default_scheduled") == 3)
        #expect(Self.settings("[tasks]\ndefault_scheduled = 400\n").int("tasks.default_scheduled") == 0)
    }

    @Test func theDigestIsFiltered() {
        let filter = Self.settings("[notifications]\ndigest_filter = [\"path does not include Elaheh\"]\n").strings("notifications.digest_filter") ?? []
        let tasks = [
            Self.task("- [ ] Send the CV 📅 2026-11-25", in: "Tasks/Elaheh Interviews.md"),
            Self.task("- [ ] Pay the rent 📅 2026-11-25", in: "Tasks/Personal.md"),
        ]
        let kept = TasksQuery.filtered(tasks, by: filter, today: Self.today, statuses: .defaults)
        #expect(kept.map(\.path) == ["Tasks/Personal.md"])
        #expect(TasksQuery.filtered(tasks, by: [], today: Self.today, statuses: .defaults).count == 2)
    }

    @Test func theStagesAreTheSettings() {
        let keys = JobKeys(settings: Self.settings("[jobs]\nclosed = [\"rejected\", \"ghosted\"]\n"))
        #expect(keys.waiting == ["applied"])
        let index = JobSearchTests.index([
            ("Companies/A/A.md", "---\njob_stage: ghosted\n---\n"),
            ("Companies/B/B.md", "---\njob_stage: withdrawn\n---\n"),
        ])
        let search = JobSearch(index: index, keys: keys)
        let closed = Dictionary(uniqueKeysWithValues: search.applications.map { ($0.path, $0.closed) })
        #expect(closed["Companies/A/A.md"] == true)
        #expect(closed["Companies/B/B.md"] == false)
        #expect(search.board().closed.map(\.stage) == ["rejected", "ghosted"])
    }

    static func rule(_ body: String) -> NotificationRule? {
        NotificationRule.all(settings("[notifications.rules.r]\nat = \"21:00\"\n" + body)).first
    }

    @Test func aRuleRingsOnItsDays() throws {
        let rule = try #require(Self.rule("note = \"Diary.md\"\nheading = \"YYYY-MM-DD\"\ndays = [\"mon\", \"Fri\"]\n"))
        #expect(rule.ringsOn(Day(year: 2026, month: 11, day: 23)))
        #expect(!rule.ringsOn(Day(year: 2026, month: 11, day: 24)))
        #expect(rule.ringsOn(Day(year: 2026, month: 11, day: 27)))
        #expect(Self.rule("note = \"Diary.md\"\nheading = \"YYYY-MM-DD\"\ndays = [\"someday\"]\n") == nil)
        #expect(Self.rule("note = \"Diary.md\"\nheading = \"YYYY-MM-DD\"\ndays = []\n") == nil)
        // Exactly one kind.
        #expect(Self.rule("note = \"Diary.md\"\nheading = \"YYYY-MM-DD\"\nquiet_days = 3\n") == nil)
        #expect(Self.rule("note = \"Diary.md\"\n") == nil)
    }

    @Test func aQueryRule() throws {
        let rule = try #require(Self.rule("query = [\"due before tomorrow\", \"not done\"]\n"))
        #expect(rule.kind == .query(["due before tomorrow", "not done"]))
        let notes = JobSearchTests.index([
            ("Tasks/Personal.md", "- [ ] Pay the rent 📅 2026-11-25\n- [ ] Call Ali 📅 2026-11-20\n- [x] Done already 📅 2026-11-25\n- [ ] Later 📅 2026-12-01\n"),
        ])
        let found = rule.tasks(in: notes, today: Self.today).map(\.task.text)
        #expect(Set(found) == ["Pay the rent", "Call Ali"])
        #expect(rule.alertTitle == "Tasks")
        let body = rule.body(tasks: found)
        #expect(body.hasPrefix("2 tasks: ") && body.contains("Pay the rent") && body.contains("Call Ali"))
        #expect(rule.body(tasks: ["One"]) == "1 tasks: One")
        #expect(rule.body(tasks: ["a", "b", "c", "d"]) == "4 tasks: a, b, c")
        let none = JobSearchTests.index([("Tasks/Personal.md", "- [ ] Later 📅 2026-12-01\n")])
        #expect(rule.tasks(in: none, today: Self.today).isEmpty)
    }

    @Test func aQuietRule() throws {
        let rule = try #require(Self.rule("note = \"Log.md\"\nquiet_days = 14\n"))
        #expect(rule.kind == .quiet(14))
        let calendar = Calendar(identifier: .gregorian)
        let day = { (back: Int) in Self.today.adding(days: -back).date.addingTimeInterval(12 * 3600) }
        #expect(rule.quietDays(lastChange: day(15), day: Self.today, calendar: calendar) == 15)
        #expect(rule.quietDays(lastChange: day(13), day: Self.today, calendar: calendar) == nil)
        #expect(rule.body(quietFor: 15) == "No change for 15 days")
        // A note that is not there rings, and says so.
        #expect(rule.quietDays(lastChange: nil, day: Self.today) != nil)
        #expect(rule.body(quietFor: nil) == "No such note: Log.md")
        // A message replaces the body of every kind.
        #expect(Self.rule("note = \"Log.md\"\nquiet_days = 14\nmessage = \"Write\"\n")?.body(quietFor: 15) == "Write")
        #expect(Self.rule("note = \"Log.md\"\nquiet_days = 0\n") == nil)
    }

    @Test func theNearestFolderWins() {
        let rules = FolderRules(Self.settings("[folders.\"Companies\"]\nfolded = false\ndirection = \"rtl\"\n\n[folders.\"Companies/Snapp\"]\ntemplate = \"T.md\"\ndirection = \"ltr\"\n"))
        let roles = rules.rule(for: "Companies/Snapp/Roles/Engineer.md")
        #expect(roles.folded == false && roles.template == "T.md" && roles.direction == .ltr)
        #expect(rules.rule(for: "Companies/Acme.md").direction == .rtl)
        #expect(rules.rule(for: "Personal/Diary.md") == FolderRules.Rule())
        // A value that does not fit is as not there.
        #expect(FolderRules(Self.settings("[folders.\"A\"]\ndirection = \"up\"\n")).rule(for: "A/x.md").direction == nil)
    }
}
