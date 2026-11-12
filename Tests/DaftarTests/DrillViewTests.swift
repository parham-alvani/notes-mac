import AppKit
import DaftarCore
import Foundation
import SwiftUI
import Testing

@testable import DaftarUI

/// Review Cards on a made-up vault: the deck is read off the main thread,
/// the counts follow the state file, and a rating is written to the file
/// the command line reads, kept beside the test's own settings.
@MainActor
@Suite(.serialized) struct DrillViewTests {
    let root: URL
    let store: VaultStore
    let file: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-drill-\(UUID().uuidString)")
        let deck = root.appending(path: "vault/\(Drill.folder)")
        try FileManager.default.createDirectory(at: deck, withIntermediateDirectories: true)
        try "## Part 1\n\n### Q1. What is a goroutine?\n\nA function run on its own.\n\n### Q2. What is a channel?\n\nA typed pipe.\n"
            .write(to: deck.appending(path: "Go.md"), atomically: true, encoding: .utf8)
        try "## پرسش‌ها\n\n### گوروتین چیست؟\n\nیک **تابع** که جدا اجرا می‌شود.\n".write(to: deck.appending(path: "پرسش.md"), atomically: true, encoding: .utf8)
        try "## Elsewhere\n\nText.\n".write(to: root.appending(path: "vault/Other.md"), atomically: true, encoding: .utf8)
        let settings = AppSettings(url: root.appending(path: "config/config.toml"))
        store = VaultStore(settings: settings, openVault: false)
        store.openSynchronously(root.appending(path: "vault"))
        file = DrillState.file(root: store.root!, in: settings.drillFolder)
        // Q1 was due yesterday: one card due, two never asked.
        let yesterday = Day.today().adding(days: -1)
        let q1 = "\(Drill.folder)/Go.md#Part 1#Q1. What is a goroutine?"
        try DrillState(reviews: [q1: DrillReview(ease: 2.5, interval: 6, reps: 2, lapses: 0, due: yesterday, last: yesterday.adding(days: -6))]).save(file)
    }

    func ready() async throws {
        store.drill.follow(store)
        for _ in 0..<100 where !store.drill.ready { try await Task.sleep(for: .milliseconds(20)) }
        #expect(store.drill.ready)
    }

    @Test func aTestKeepsTheStateBesideItsSettings() {
        #expect(file.path(percentEncoded: false).hasPrefix(root.appending(path: "config/state").path(percentEncoded: false)))
        #expect(file.lastPathComponent.hasPrefix("drill-") && file.lastPathComponent.hasSuffix(".json"))
    }

    @Test func theDeckCountsWhatIsDue() async throws {
        try await ready()
        #expect(store.drill.cards.count == 3)
        #expect(store.drill.counts == DrillDeck.Counts(due: 1, fresh: 2, next: nil))
        let session = store.drill.session()
        #expect(session.total == 3)
        #expect(session.current?.card.question == "Q1. What is a goroutine?")
    }

    @Test func aRatingIsWrittenAndKeepsAnotherAppsRating() async throws {
        try await ready()
        let q1 = try #require(store.drill.cards.first)
        // The command line rates Q2 after the app read the file.
        let q2 = "\(Drill.folder)/Go.md#Part 1#Q2. What is a channel?"
        var other = DrillState.load(file)
        other.rate(q2, .easy, today: .today())
        try other.save(file)
        store.drill.rate(q1, .good, store: store)
        #expect(store.drill.counts.due == 0)
        var written = DrillState()
        for _ in 0..<100 {
            written = DrillState.load(file)
            if written.reviews[q1.id]?.reps == 3 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        // The app takes the state it wrote once the write is done.
        for _ in 0..<100 where store.drill.state != written { try await Task.sleep(for: .milliseconds(20)) }
        #expect(written.reviews[q1.id]?.interval == 15)
        #expect(written.reviews[q2] != nil)
        #expect(store.drill.state == written)
        #expect(store.drill.counts.next == Day.today().adding(days: 1))
    }

    @Test func thePageShowsTheCardAndItsContext() async throws {
        try await ready()
        let model = WindowModel()
        model.showsDrill = true
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: DrillView(model: model).environment(store))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        // A picture to look at, when asked for.
        if let path = ProcessInfo.processInfo.environment["DAFTAR_DRILL_SHOT"], let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
        }
        window.orderOut(nil)
        #expect(DrillView.when(Day.today().adding(days: 1)) == "tomorrow")
        #expect(DrillView.when(Day.today().adding(days: 3)).hasSuffix("in 3 days"))
        #expect(String(DrillView.inline("Q1. What is **`go`**?").characters) == "Q1. What is go?")
    }
}
