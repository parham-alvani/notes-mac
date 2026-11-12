import Foundation
import Testing

@testable import DaftarCore

/// The job search, with the cases of `job_search.rs`, `jobs.rs` and the
/// `memory-quiet` rule of `memory.rs` in notes-linux, and the board's own.
@Suite struct JobSearchTests {
    static func index(_ notes: [(String, String)], files: [String] = []) -> VaultIndex {
        var index = VaultIndex()
        for (path, text) in notes {
            index.notes[path] = NoteEntry(path: path, modified: Date(), parsed: NoteParser.parse(text))
            index.files.insert(path)
        }
        for file in files { index.files.insert(file) }
        index.derive()
        return index
    }

    static func search() -> JobSearch {
        let index = index([
            ("Companies/Acme/Acme.md",
             "---\njob_stage: interviewing\njob_applied: 2026-10-01\njob_roles:\n  - \"Platform Engineer\"\njob_next: 2026-11-10T15:30\njob_next_step: \"Second round\"\njob_channel: \"Kulturo (Someone, LinkedIn)\"\n---\n# Acme"),
            ("Companies/Acme/Interview Preparation.md", "# Prep"),
            ("Companies/Globex/Globex.md", "---\njob_stage: screening\njob_next: 2026-11-09T14:00\njob_channel: LinkedIn\n---\n"),
            ("Companies/Initech/Initech.md", "---\njob_stage: applied\njob_channel: \"LinkedIn\"\n---\n"),
            ("Companies/Hooli/Hooli.md", "---\njob_stage: Rejected\njob_channel: \"Ashby (hooli)\"\n---\n"),
            ("Companies/Hooli/Interview Preparation.md", "# Prep"),
            ("Companies/Umbrella/Umbrella.md", "---\njob_stage: rejected\njob_channel: Ashby\njob_next: 2026-11-01\n---\n"),
            ("Companies/Stark/Stark.md", "---\naliases: [Stark Industries]\njob_stage: applied\n---\n"),
            ("Companies/Wayne/Wayne.md", "---\nindustry: bats\n---\n"),
        ], files: ["Companies/Acme/logo.svg", "Companies/Globex/logo.png", "Companies/Globex/LOGO.svg"])
        return JobSearch(index: index)
    }

    static func at(_ text: String) -> LocalTime { LocalTime.read(text)!.time }

    @Test func aChannelIsTheTextBeforeItsParenthesis() {
        #expect(JobSearch.channel("Kulturo (Someone, LinkedIn)") == "Kulturo")
        #expect(JobSearch.channel("  Wellfound → Ashby ") == "Wellfound → Ashby")
        #expect(JobSearch.channel("") == "unknown")
        #expect(JobSearch.channel(" (nobody)") == "unknown")
    }

    @Test func everyNoteWithAStageIsAnApplication() {
        let search = Self.search()
        #expect(search.applications.map(\.company) == ["Acme", "Globex", "Hooli", "Initech", "Stark", "Umbrella"])
        let acme = search.applications[0]
        #expect(acme.roles == ["Platform Engineer"])
        #expect(acme.applied == "2026-10-01")
        #expect(acme.prep == "Companies/Acme/Interview Preparation.md")
        #expect(acme.channel == "Kulturo")
        #expect(search.applications[1].prepOrNote == "Companies/Globex/Globex.md")
        // The logo the sidebar draws: an SVG before a PNG, in any case.
        #expect(acme.logo == "Companies/Acme/logo.svg")
        #expect(search.applications[1].logo == "Companies/Globex/LOGO.svg")
        #expect(search.applications[2].logo == nil)
    }

    @Test func stagesAreCountedInASearchsOrder() {
        let stages = Self.search().stages()
        #expect(stages.map(\.stage) == ["applied", "screening", "interviewing", "rejected"])
        #expect(stages.map(\.count) == [2, 1, 1, 2])
    }

    @Test func aClosedApplicationGotPastAppliedOnlyWithAPrepNote() {
        let search = Self.search()
        #expect(search.applications.filter(\.pastApplied).map(\.company) == ["Acme", "Globex", "Hooli"])
        let channels = search.channels()
        let row = { (name: String) in channels.first { $0.channel == name }! }
        #expect(row("LinkedIn") == ChannelCount(channel: "LinkedIn", applications: 2, pastApplied: 1))
        #expect(row("Ashby") == ChannelCount(channel: "Ashby", applications: 2, pastApplied: 1))
        #expect(row("unknown").applications == 1)
        #expect(abs(row("LinkedIn").rate - 50) < 1e-9)
        #expect(channels[0].channel == "Ashby")
    }

    @Test func upcomingEventsAreTheBookedOnesAheadSoonestFirst() {
        let search = Self.search()
        #expect(search.upcoming(now: Self.at("2026-11-09T09:00")).map(\.company) == ["Globex", "Acme"])
        #expect(search.upcoming(now: Self.at("2026-11-09T15:00")).map(\.company) == ["Acme"])
        let until = Self.at("2026-11-10T00:00")
        #expect(search.upcoming(now: Self.at("2026-11-09T09:00"), until: until).count == 1)
        // A day alone is ahead all that day.
        #expect(search.upcoming(now: Self.at("2026-11-01T18:00"), until: until).first?.company == "Umbrella")
    }

    @Test func aMeetingIsMatchedByItsTimeOrTheCompanyItNames() {
        let search = Self.search()
        func meeting(_ start: String, _ end: String, _ title: String) -> String? {
            search.forMeeting(start: Self.at(start), end: Self.at(end), title: title)?.company
        }
        #expect(meeting("2026-11-10T15:30", "2026-11-10T16:15", "Interview · Google Meet") == "Acme")
        #expect(meeting("2026-11-12T10:00", "2026-11-12T11:00", "Interview with ACME - Backend") == "Acme")
        #expect(meeting("2026-11-12T10:00", "2026-11-12T11:00", "Call with Stark Industries") == "Stark")
        // A word inside another is not the name, and a closed company is not named.
        #expect(meeting("2026-11-12T10:00", "2026-11-12T11:00", "Acmeology") == nil)
        #expect(meeting("2026-11-12T10:00", "2026-11-12T11:00", "Coffee at Hooli") == nil)
        // A long block of busy time holds the event, but is not it.
        #expect(meeting("2026-11-09T06:30", "2026-11-09T15:30", "Busy") == nil)
        #expect(meeting("2026-11-09T13:50", "2026-11-09T15:00", "Call") == "Globex")
    }

    @Test func theKeysAreParameters() {
        let index = Self.index([("Leads/Acme.md", "---\nstate: talking\nvia: Email\n---\n")], files: ["Leads/Prep.md"])
        var keys = JobKeys()
        keys.stage = "state"
        keys.channel = "via"
        keys.prepNote = "Prep.md"
        let search = JobSearch(index: index, keys: keys)
        #expect(search.stages().map(\.stage) == ["talking"])
        #expect(search.applications[0].prep == "Leads/Prep.md")
        #expect(search.channels()[0].channel == "Email")
        #expect(JobSearch(index: index, keys: keys) { !$0.hasPrefix("Leads/") }.applications.isEmpty)
    }

    @Test func aPropertysLineIsFoundInTheFrontMatter() {
        let text = "---\njob_stage: applied\njob_next: 2026-11-10T15:30\n---\njob_next: no\n"
        #expect(JobSearch.propertyLine(text, key: "job_next") == 3)
        #expect(JobSearch.propertyLine(text, key: "job_band") == 1)
        #expect(JobSearch.propertyLine("# No front matter", key: "job_next") == 1)
    }

    @Test func aTimeIsReadWithOrWithoutItsClock() {
        #expect(LocalTime.read("2026-11-10T15:30")?.timed == true)
        #expect(LocalTime.read("2026-11-10 15:30:20")?.time.seconds == 15 * 3600 + 30 * 60 + 20)
        #expect(LocalTime.read("\"2026-11-10\"")?.timed == false)
        #expect(LocalTime.read("2026-11-10T25:00") == nil)
        #expect(LocalTime.read("2026-02-30") == nil)
        #expect(LocalTime.read("soon") == nil)
        // On Madrid's clock, whatever the Mac's zone: 15:30 in November is 14:30 UTC.
        let date = Self.at("2026-11-10T15:30").date()!
        #expect(date == ISO8601DateFormatter().date(from: "2026-11-10T14:30:00Z"))
        #expect(LocalTime(date: date) == Self.at("2026-11-10T15:30"))
        #expect(Self.at("2026-11-10T23:30").adding(seconds: 3600) == Self.at("2026-11-11T00:30"))
    }

    // The CLI's event line, from `jobs.rs`: its window of days ends at the
    // midnight after the last day.
    @Test func anEventWithinDaysEndsAtTheMidnightAfter() {
        let index = Self.index([
            ("Companies/Acme/Acme.md",
             "---\njob_stage: screening\njob_next: 2026-11-10T15:30\njob_next_step: \"Recruiter call\"\njob_channel: \"Ashby (acme)\"\n---\n"),
        ], files: ["Companies/Acme/Interview Preparation.md"])
        let search = JobSearch(index: index)
        #expect(search.stages().map(\.stage) == ["screening"])
        #expect(search.channels() == [ChannelCount(channel: "Ashby", applications: 1, pastApplied: 1)])
        let now = Self.at("2026-11-08T09:00")
        let within = { (days: Int) in search.upcoming(now: now, until: LocalTime(day: now.day.adding(days: days + 1))) }
        #expect(search.upcoming(now: now).first?.prep == "Companies/Acme/Interview Preparation.md")
        #expect(within(1).isEmpty)
        #expect(within(2).count == 1)
    }

    // MARK: The board

    @Test func theBoardHasAColumnForEachGoingStageAndTheClosedAfter() {
        let board = Self.search().board()
        #expect(board.going.map(\.stage) == ["applied", "screening", "interviewing", "offer", "accepted"])
        #expect(board.closed.map(\.stage) == ["rejected", "withdrawn", "declined", "closed"])
        #expect(board.going[0].applications.map(\.company) == ["Initech", "Stark"])
        #expect(board.closed[0].applications.map(\.company) == ["Umbrella", "Hooli"])
        // A stage the order does not know is a column after the known ones.
        var search = Self.search()
        search.applications[0].stage = "take-home"
        #expect(search.board().going.map(\.stage).last == "take-home")
        #expect(JobSearch.title("interviewing") == "Interviewing")
    }

    @Test func aStageIsWrittenAsTheFormWritesAProperty() throws {
        let note = "---\naliases: [Acme Inc]\njob_stage: \"applied\" \njob_roles:\n  - Engineer\n---\n# Acme\njob_stage: applied\n"
        let moved = try JobSearch.settingStage(in: note, from: "applied", to: "screening")
        #expect(moved == "---\naliases: [Acme Inc]\njob_stage: \"screening\"\njob_roles:\n  - Engineer\n---\n# Acme\njob_stage: applied\n")
        // A stage the card no longer shows is not written over.
        #expect(throws: JobSearch.StageFailure.moved) { try JobSearch.settingStage(in: moved, from: "applied", to: "rejected") }
        #expect(throws: JobSearch.StageFailure.moved) { try JobSearch.settingStage(in: "# Acme\n", from: "applied", to: "rejected") }
        // The key in any case, as the index reads it.
        #expect(try JobSearch.settingStage(in: "---\nJob_Stage: Applied\n---\n", from: "applied", to: "offer") == "---\nJob_Stage: offer\n---\n")
        // YAML the form cannot write back the same is left alone.
        #expect(throws: JobSearch.StageFailure.self) {
            try JobSearch.settingStage(in: "---\njob_stage: applied # waiting\nx: &a 1\n---\n", from: "applied", to: "offer")
        }
    }

    // MARK: Gone quiet, from `memory.rs`

    @Test func aGoingNoteWithNothingNewIsQuiet() {
        let rules = QuietRules(active: [("job_stage", "applied")], days: 30)
        let today = Day(year: 2026, month: 11, day: 6)
        let quiet = "---\njob_stage: applied\njob_applied: 2026-09-01\n---\n**2026-09-20:** No answer.\n"
        let found = rules.quiet(quiet, today: today)
        #expect(found?.line == 2)
        #expect(found?.newest == Day(year: 2026, month: 9, day: 20))
        #expect(found?.days == 47)
        #expect(found?.message.hasPrefix("job_stage: applied, and nothing in the note is dated after 2026-09-20 (47 days)") == true)
        // A recent entry, or a stage that is over, is not quiet.
        #expect(rules.quiet(quiet.replacingOccurrences(of: "**2026-09-20:**", with: "**2026-10-20:**"), today: today) == nil)
        #expect(rules.quiet(quiet.replacingOccurrences(of: "applied\n", with: "rejected\n"), today: today) == nil)
        // Nothing dated at all says nothing.
        #expect(rules.quiet("---\njob_stage: applied\n---\nText\n", today: today) == nil)
        #expect(QuietRules.pair("job_stage = screening")! == ("job_stage", "screening"))
        // The state paragraph is a date too, and a date inside a word is not an entry.
        #expect(rules.quiet(quiet + "**Where it stands (2026-11-01):** Waiting.\n", today: today) == nil)
        #expect(rules.quiet(quiet + "**2026-11-01x** no\n", today: today) != nil)
    }

    @Test func theRulesComeFromTheVaultsAuditFile() {
        #expect(QuietRules.read(nil) == .standard)
        let file = "[check]\nmemory = true\n\n[audit]\nactive = [\"job_stage=applied\", \"job_stage=screening\"]\nquiet_days = 21\n"
        let rules = QuietRules.read(file)
        #expect(rules.days == 21)
        #expect(rules.active.map(\.value) == ["applied", "screening"])
        #expect(QuietRules.read("[check]\nmemory = true\n") == .standard)
    }

    @Test func onlyGoingApplicationsAreReadForQuiet() {
        var search = Self.search()
        var read: [String] = []
        search.markQuiet(.standard, today: Day(year: 2026, month: 12, day: 30)) { path in
            read.append(path)
            return "---\njob_stage: applied\njob_applied: 2026-10-01\n---\n"
        }
        #expect(!read.contains("Companies/Hooli/Hooli.md"))
        #expect(search.applications.first { $0.company == "Stark" }?.quiet?.days == 90)
    }
}
