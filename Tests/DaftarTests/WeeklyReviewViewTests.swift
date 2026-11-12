import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// Go › Weekly Review on a made-up vault in a temporary folder.
@MainActor
@Suite struct WeeklyReviewViewTests {
    @Test func weeklyReviewOpensThisWeeksNoteOrItsPreview() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "daftar-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Reviews"), withIntermediateDirectories: true)
        try "# Week\n".write(to: root.appending(path: "Reviews/2026-10-31 to 2026-11-06.md"), atomically: true, encoding: .utf8)
        let store = VaultStore(settings: AppSettings(url: root.appending(path: "config/config.toml")), openVault: false)
        store.openSynchronously(root)
        let model = WindowModel()
        model.openWeeklyReview(store: store, today: Day("2026-11-12")!)
        #expect(model.path == "Reviews/2026-10-31 to 2026-11-06.md")
        #expect(model.weeklyReview == nil)
        // On Saturday, before CI wrote it: a preview of the one written today.
        model.openWeeklyReview(store: store, today: Day("2026-11-14")!)
        #expect(model.weeklyReview?.day == Day("2026-11-14")!)
        #expect(model.weeklyReview?.path == "Reviews/2026-11-07 to 2026-11-13.md")
    }

    @Test func aFailedReviewSaysWhy() {
        #expect(WeeklyReviewSheet.failure("daftar-cli: Reviews/2026-11-07 to 2026-11-13.md is there already\n") == "Reviews/2026-11-07 to 2026-11-13.md is there already")
        #expect(WeeklyReviewSheet.failure("error: unrecognized subcommand 'review'\n").hasPrefix("The weekly review needs daftar-cli 0.8.0 or later"))
    }
}
