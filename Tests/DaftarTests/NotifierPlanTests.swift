import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// The alerts are planned again at every change of the vault; a plan that
/// is the one before is not sent again, so a plan has to compare equal
/// when nothing it says changed.
@MainActor
@Suite struct NotifierPlanTests {
    @Test func theSamePlanComparesEqualAndAChangeDoesNot() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "daftar-notifier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 12)))
        let (at, day) = Notifier.nextDigest(minutes: 9 * 60, now: now)
        try "- [ ] Pay the rent 📅 \(day)\n".write(to: root.appending(path: "Tasks.md"), atomically: true, encoding: .utf8)
        let settings = AppSettings(url: root.appending(path: "config/config.toml"))
        settings.taskDigest = true
        settings.meetingAlerts = true
        settings.digestTime = 9 * 60
        let store = VaultStore(settings: settings, openVault: false)
        store.openSynchronously(root)
        let first = Notifier.plan(store: store, now: now)
        #expect(first.map(\.id) == ["digest"])
        #expect(first[0].title == "1 due today")
        #expect(first[0].at == Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at))
        #expect(!first[0].sound)
        #expect(Notifier.plan(store: store, now: now) == first)
        try "- [ ] Pay the rent 📅 \(day)\n- [ ] Call the bank 📅 \(day)\n".write(to: root.appending(path: "Tasks.md"), atomically: true, encoding: .utf8)
        store.openSynchronously(root)
        #expect(Notifier.plan(store: store, now: now) != first)
        settings.taskDigest = false
        #expect(Notifier.plan(store: store, now: now).isEmpty)
    }

    /// A rule's alert is planned for its time while today's heading is
    /// missing, and taken away once the heading is written; a click opens the note.
    @Test func aRuleIsPlannedUntilTodaysHeadingIsWritten() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "daftar-notifier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "config"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rule = "[notifications]\nmeetings = false\ndigest = false\n\n[notifications.rules.log]\nnote = \"Log.md\"\nheading = \"YYYY-MM-DD\"\nat = \"21:00\"\n"
        try rule.write(to: root.appending(path: "config/config.toml"), atomically: true, encoding: .utf8)
        let now = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 12)))
        try "# Log\n".write(to: root.appending(path: "Log.md"), atomically: true, encoding: .utf8)
        let settings = AppSettings(url: root.appending(path: "config/config.toml"))
        let store = VaultStore(settings: settings, openVault: false)
        store.openSynchronously(root)
        let plan = Notifier.plan(store: store, now: now)
        #expect(plan.map(\.id) == ["rule.log"])
        #expect(plan.first?.title == "Log")
        #expect(plan.first?.body == "No heading for today yet: 2026-03-02")
        #expect(plan.first?.userInfo == ["open": "Log.md"])
        #expect(plan.first?.at == DateComponents(year: 2026, month: 3, day: 2, hour: 21, minute: 0))
        try "# Log\n\n## 2026-03-02\n".write(to: root.appending(path: "Log.md"), atomically: true, encoding: .utf8)
        #expect(Notifier.plan(store: store, now: now).first?.at == DateComponents(year: 2026, month: 3, day: 3, hour: 21, minute: 0))
        #expect(Notifier.openURL("Diet/Food Diary.md")?.absoluteString == "daftar://open?path=Diet/Food%20Diary.md")
    }
}
