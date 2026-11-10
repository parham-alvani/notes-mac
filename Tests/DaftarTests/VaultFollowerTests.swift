import AppKit
import CoreSpotlight
import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// The badge, the alerts and Spotlight follow the vault for the app, with no
/// window: on a made-up vault, with the three replaced by counters.
@MainActor
@Suite(.serialized) struct VaultFollowerTests {
    let root: URL
    let store: VaultStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-follow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# Tasks\n\n- [ ] pay 📅 \(Day.today().description)\n- [ ] later\n".write(to: root.appending(path: "Tasks.md"), atomically: true, encoding: .utf8)
        store = VaultStore(settings: AppSettings(url: root.appending(path: "config/config.toml")), openVault: false)
        store.openSynchronously(root)
    }

    final class Seen {
        var badges: [String?] = []
        var plans = 0
        var spotlight = 0
    }

    private func follower(_ seen: Seen) -> VaultFollower {
        let follower = VaultFollower()
        follower.delay = .milliseconds(40)
        follower.badge = { seen.badges.append($0) }
        follower.plan = { _ in seen.plans += 1 }
        follower.spotlight = { _ in seen.spotlight += 1 }
        return follower
    }

    @Test func aChangeIsFollowedOnceWithNoWindow() async throws {
        let seen = Seen()
        let follower = follower(seen)
        follower.follow(store)
        // Asked again, as each window and the menu bar icon do: still one follower.
        follower.follow(store)
        for _ in 0..<100 where seen.plans < 1 { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(seen.plans == 1)
        #expect(seen.badges.last == "1")
        let spotlight = seen.spotlight

        // The vault changes with no window open: a task ticked by the store.
        store.toggleTask(path: "Tasks.md", line: 2, status: " ")
        for _ in 0..<100 where seen.plans < 2 { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(seen.plans == 2)
        #expect(seen.badges.last == String?.none)
        #expect(seen.spotlight > spotlight)
    }

    @Test func theBadgesSwitchShowsAtOnce() async throws {
        let seen = Seen()
        let follower = follower(seen)
        follower.delay = .seconds(30)
        follower.follow(store)
        #expect(seen.badges == ["1"])
        store.settings.dockBadge = false
        for _ in 0..<20 where seen.badges.count < 2 { try await Task.sleep(for: .milliseconds(25)) }
        #expect(seen.badges == ["1", nil])
    }

    /// An index that refuses is not asked again for every change of the vault.
    @Test func spotlightStopsAfterItsFirstFailure() async throws {
        let spotlight = Spotlight()
        var sent = 0
        spotlight.send = { _, _ in
            sent += 1
            throw CocoaError(.featureUnsupported)
        }
        spotlight.follow(store)
        for _ in 0..<40 where !spotlight.failed { try await Task.sleep(for: .milliseconds(25)) }
        #expect(spotlight.failed)
        spotlight.follow(store)
        spotlight.follow(store)
        try await Task.sleep(for: .milliseconds(150))
        #expect(sent == 1)
    }
}
