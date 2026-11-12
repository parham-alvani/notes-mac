import Foundation
import Testing

@testable import DaftarCore

@Suite struct WeeklyReviewTests {
    private func day(_ text: String) -> Day { Day(text)! }

    @Test func thisWeeksReviewIsWrittenOnTheLastSaturday() {
        // 2026-11-07 is a Saturday.
        #expect(WeeklyReview.day(for: day("2026-11-07")) == day("2026-11-07"))
        #expect(WeeklyReview.day(for: day("2026-11-08")) == day("2026-11-07"))
        #expect(WeeklyReview.day(for: day("2026-11-12")) == day("2026-11-07"))
        #expect(WeeklyReview.day(for: day("2026-11-13")) == day("2026-11-07"))
        #expect(WeeklyReview.day(for: day("2026-11-14")) == day("2026-11-14"))
        // Across a year.
        #expect(WeeklyReview.day(for: day("2027-01-01")) == day("2026-12-26"))
    }

    @Test func aReviewCoversTheSevenDaysBefore() {
        #expect(WeeklyReview.path(writtenOn: day("2026-11-07")) == "Reviews/2026-10-31 to 2026-11-06.md")
        #expect(WeeklyReview.path(writtenOn: day("2026-03-07"), folder: "Weekly") == "Weekly/2026-02-28 to 2026-03-06.md")
        #expect(WeeklyReview.path(writtenOn: day("2026-03-07"), folder: "") == "2026-02-28 to 2026-03-06.md")
    }

    @Test func thisWeeksFileIsFoundWhenItIsThere() {
        let files = ["Reviews/2026-10-24 to 2026-10-30.md", "Reviews/2026-10-31 to 2026-11-06.md", "Tasks/Work.md"]
        #expect(WeeklyReview.thisWeek(today: day("2026-11-12"), in: files) == "Reviews/2026-10-31 to 2026-11-06.md")
        // On Saturday, before CI wrote it, there is none yet.
        #expect(WeeklyReview.thisWeek(today: day("2026-11-14"), in: files) == nil)
        // Another case is the same note.
        #expect(WeeklyReview.thisWeek(today: day("2026-11-12"), in: ["reviews/2026-10-31 to 2026-11-06.md"]) == "reviews/2026-10-31 to 2026-11-06.md")
    }

    @Test func theNewestReviewIsTheOneThatEndsLast() {
        let files = [
            "Reviews/2026-10-31 to 2026-11-06.md", "Reviews/2026-10-24 to 2026-10-30.md",
            "Reviews/Old/2027-01-01 to 2027-01-07.md", "Reviews/Notes.md", "Reviews/2026-13-01 to 2026-13-07.md",
            "Elsewhere/2027-02-01 to 2027-02-07.md", "Reviews/2026-11-06 to 2026-10-31.md",
        ]
        #expect(WeeklyReview.newest(in: files) == "Reviews/2026-10-31 to 2026-11-06.md")
        #expect(WeeklyReview.newest(in: ["Reviews/Notes.md"]) == nil)
        #expect(WeeklyReview.newest(in: []) == nil)
    }

    @Test func theCommandIsGivenTheDay() {
        let vault = URL(filePath: "/v")
        #expect(WeeklyReview.arguments(vault: vault, day: day("2026-11-07")) == ["--vault", "/v", "review", "--day", "2026-11-07"])
        #expect(WeeklyReview.arguments(vault: vault, day: day("2026-11-07"), write: true) == ["--vault", "/v", "review", "--day", "2026-11-07", "--write"])
    }

    @Test func thePathWrittenIsMadeAVaultPath() {
        let vault = URL(filePath: "/Users/someone/vault")
        #expect(WeeklyReview.writtenPath("/Users/someone/vault/Reviews/2026-10-31 to 2026-11-06.md\n", vault: vault) == "Reviews/2026-10-31 to 2026-11-06.md")
        #expect(WeeklyReview.writtenPath("Reviews/2026-10-31 to 2026-11-06.md", vault: vault) == "Reviews/2026-10-31 to 2026-11-06.md")
        #expect(WeeklyReview.writtenPath("\n", vault: vault) == nil)
    }
}
