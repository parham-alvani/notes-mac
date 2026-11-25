import Foundation
import Testing

@testable import DaftarCore

/// `docs/specs/notification-rules.md` in notes-linux, section 4, by name.
@Suite struct NotificationRuleTests {
    static let diary = "[notifications.rules.diary]\nnote = \"Diet/Diary.md\"\nheading = \"D MMM YYYY · dddd\"\nat = \"21:00\"\n"
    static let day = Day(year: 2026, month: 11, day: 25)

    func rules(_ computer: String, vault: String = "") -> [NotificationRule] {
        NotificationRule.all(ResolvedSettings.resolved(vault: vault, computer: computer))
    }

    func diary() throws -> NotificationRule { try #require(rules(Self.diary).first) }

    @Test func aRuleIsReadFromItsSection() throws {
        let rules = rules(Self.diary)
        #expect(rules.count == 1)
        let rule = try #require(rules.first)
        #expect(rule.id == "diary")
        #expect(rule.note == "Diet/Diary.md")
        #expect(rule.at == 21 * 60)
        #expect(rule.alertTitle == "Diary")
        #expect(rule.message == nil)
        #expect(rule.alertId == "rule.diary")
    }

    @Test func aRuleThatDoesNotFitIsIgnored() {
        let good = "[notifications.rules.log]\nnote = \"Log.md\"\nheading = \"YYYY-MM-DD\"\nat = \"08:30\"\n"
        for bad in [
            "[notifications.rules.a]\nnote = \"A.md\"\nheading = \"D\"\n",
            "[notifications.rules.a]\nnote = \"A.md\"\nheading = \"D\"\nat = \"25:00\"\n",
            "[notifications.rules.a]\nnote = \"../x.md\"\nheading = \"D\"\nat = \"21:00\"\n",
            "[notifications.rules.my diary]\nnote = \"A.md\"\nheading = \"D\"\nat = \"21:00\"\n",
        ] {
            #expect(rules(bad + "\n" + good).map(\.id) == ["log"], "\(bad)")
        }
    }

    @Test func theExpectedHeadingIsTheDayInTheFormat() throws {
        #expect(try diary().expected(Self.day) == "25 Nov 2026 · Wednesday")
        var rule = try diary()
        rule.heading = "[Day] YYYY-MM-DD"
        #expect(rule.expected(Self.day) == "Day 2026-11-25")
    }

    @Test func todaysHeadingIsFound() throws {
        let rule = try diary()
        #expect(rule.isMissing(text: "## 24 Nov 2026 · Tuesday\n", day: Self.day))
        #expect(!rule.isMissing(text: "### 25 Nov 2026 · Wednesday\n", day: Self.day))
        #expect(!rule.isMissing(text: "## 25 Nov 2026 · Wednesday (fasting)\n", day: Self.day))
        #expect(rule.isMissing(text: "25 Nov 2026 · Wednesday\n", day: Self.day))
        #expect(rule.isMissing(text: "```markdown\n### 25 Nov 2026 · Wednesday\n```\n", day: Self.day))
        #expect(rule.isMissing(text: "", day: Self.day))
        // A note that is not there has no heading.
        #expect(rule.isMissing(text: nil, day: Self.day))
    }

    @Test func theAlertSaysWhatIsMissing() throws {
        let rule = try diary()
        #expect(rule.body(Self.day) == "No heading for today yet: 25 Nov 2026 · Wednesday")
        #expect(rule.alertTitle == "Diary")
        let said = try #require(rules(Self.diary + "title = \"Food\"\nmessage = \"Nothing is logged in the diary today.\"\n").first)
        #expect(said.alertTitle == "Food")
        #expect(said.body(Self.day) == "Nothing is logged in the diary today.")
    }

    @Test func aVaultMaySetARule() throws {
        let settings = ResolvedSettings.resolved(vault: Self.diary, computer: "")
        #expect(NotificationRule.all(settings) == [try diary()])
        for key in ["note", "heading", "at"] {
            #expect(settings.source(of: "notifications.rules.diary.\(key)") == .vault)
        }
        #expect(settings.refused.isEmpty)
        // The vault's rules come first, and a key the vault sets wins over the computer's.
        let computer = "[notifications.rules.journal]\nnote = \"Journal.md\"\nheading = \"YYYY-MM-DD\"\nat = \"22:00\"\n\n"
            + Self.diary.replacingOccurrences(of: "21:00", with: "20:00")
        let both = NotificationRule.all(ResolvedSettings.resolved(vault: Self.diary, computer: computer))
        #expect(both.map(\.id) == ["diary", "journal"])
        #expect(both.first?.at == 21 * 60)
        // A note that leaves the vault is no rule.
        #expect(NotificationRule.all(ResolvedSettings.resolved(vault: Self.diary.replacingOccurrences(of: "Diet/Diary.md", with: "/etc/x.md"), computer: "")).isEmpty)
    }

    @Test func theAlertIsPlannedForTheNextDayThatLacksItsHeading() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Madrid"))
        let rule = try diary()
        let noon = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 12)))
        let evening = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 22)))
        let today = try #require(rule.next(now: noon, calendar: calendar, text: ""))
        #expect(today.day == Self.day)
        #expect(calendar.component(.hour, from: today.at) == 21)
        // Written today: tomorrow's.
        #expect(rule.next(now: noon, calendar: calendar, text: "### 25 Nov 2026 · Wednesday\n")?.day == Self.day.adding(days: 1))
        // Past the time: tomorrow's.
        #expect(rule.next(now: evening, calendar: calendar, text: "")?.day == Self.day.adding(days: 1))
        // Tomorrow's written too: none.
        #expect(rule.next(now: evening, calendar: calendar, text: "## 26 Nov 2026 · Thursday\n") == nil)
    }
}
