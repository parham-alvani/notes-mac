import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// A sync that stops on a conflict, through the store, on two made-up clones.
@MainActor
@Suite(.serialized) struct ConflictStoreTests {
    let base: URL
    let mac: Git
    let phone: Git

    init() async throws {
        base = FileManager.default.temporaryDirectory.appending(path: "daftar-store-conflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        mac = Git(root: base.appending(path: "mac"))
        phone = Git(root: base.appending(path: "phone"))
        try await Git(root: base).run(["init", "-q", "--bare", "-b", "main", "remote.git"])
        try await Git(root: base).run(["clone", "-q", "remote.git", "mac"])
        try await setUp(mac)
        try "# Plan\nline\n".write(to: mac.root.appending(path: "Plan.md"), atomically: true, encoding: .utf8)
        try await mac.run(["add", "-A"])
        try await mac.run(["commit", "-qm", "first"])
        try await mac.run(["push", "-q", "-u", "origin", "main"])
        try await Git(root: base).run(["clone", "-q", "remote.git", "phone"])
        try await setUp(phone)
        try "# Plan\nphone line\n".write(to: phone.root.appending(path: "Plan.md"), atomically: true, encoding: .utf8)
        try await phone.sync(message: "phone")
        try "# Plan\nmac line\n".write(to: mac.root.appending(path: "Plan.md"), atomically: true, encoding: .utf8)
    }

    func setUp(_ git: Git) async throws {
        try await git.run(["config", "user.email", "test@example.com"])
        try await git.run(["config", "user.name", "Test"])
    }

    func store() -> VaultStore {
        let store = VaultStore(settings: AppSettings(url: base.appending(path: "config/config.toml")), openVault: false)
        store.openSynchronously(mac.root)
        return store
    }

    @Test func aStoppedSyncWaitsForTheChoice() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let store = store()
        await store.sync()
        #expect(store.rebasing)
        #expect(store.conflicts.map(\.path) == ["Plan.md"])
        #expect(store.conflictStops == 1)
        // Another sync shows the conflicts again and commits nothing.
        let head = try await mac.run(["rev-parse", "HEAD"])
        await store.sync()
        #expect(store.conflictStops == 2)
        #expect(try await mac.run(["rev-parse", "HEAD"]) == head)

        let text = try String(contentsOf: mac.root.appending(path: "Plan.md"), encoding: .utf8)
        let resolved = ConflictText.resolve(ConflictText.parse(text), all: .both)
        #expect(await store.finishConflicts([(store.conflicts[0], .text(resolved))]))
        #expect(!store.rebasing && store.conflicts.isEmpty && store.syncError == nil)
        #expect(try String(contentsOf: mac.root.appending(path: "Plan.md"), encoding: .utf8) == "# Plan\nphone line\nmac line\n")
        #expect(try await mac.run(["rev-list", "--count", "@{upstream}..HEAD"]) == "0")
    }

    @Test func aRebaseLeftOpenIsFoundAndAborted() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try await mac.run(["commit", "-qam", "mac"])
        await #expect(throws: Git.Stopped.self) { try await mac.pull() }
        let store = store()
        await store.refreshConflicts(show: true)
        #expect(store.rebasing && store.conflictStops == 1)
        await store.abortConflicts()
        #expect(!store.rebasing && store.conflicts.isEmpty)
        #expect(try String(contentsOf: mac.root.appending(path: "Plan.md"), encoding: .utf8) == "# Plan\nmac line\n")
    }
}
