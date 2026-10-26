import Foundation
import Testing

@testable import DaftarCore

@Suite struct ConflictTextTests {
    let text = """
        # Note
        <<<<<<< HEAD
        remote one
        remote two
        =======
        mine one
        >>>>>>> 6524752 (my change)
        middle
        <<<<<<< upstream
        r
        ||||||| base
        b
        =======
        m
        >>>>>>> abc

        """

    @Test func conflictsAreReadWithTheirBase() {
        let parts = ConflictText.parse(text)
        #expect(parts.count == 4)
        #expect(parts[0] == .plain("# Note\n"))
        #expect(parts[2] == .plain("middle\n"))
        let conflicts = ConflictText.conflicts(in: text)
        #expect(conflicts.map(\.remote) == ["remote one\nremote two\n", "r\n"])
        #expect(conflicts.map(\.mine) == ["mine one\n", "m\n"])
        #expect(conflicts.map(\.base) == [nil, "b\n"])
        #expect(conflicts.map(\.mineLabel) == ["6524752 (my change)", "abc"])
        #expect(conflicts[0].remoteLabel == "HEAD")
    }

    @Test func choicesMakeTheText() {
        let parts = ConflictText.parse(text)
        #expect(ConflictText.resolve(parts, all: .remote) == "# Note\nremote one\nremote two\nmiddle\nr\n")
        #expect(ConflictText.resolve(parts, all: .mine) == "# Note\nmine one\nmiddle\nm\n")
        #expect(ConflictText.resolve(parts, all: .both) == "# Note\nremote one\nremote two\nmine one\nmiddle\nr\nm\n")
        // A conflict with no choice keeps its marks, to the byte.
        #expect(ConflictText.resolve(parts, choices: [:]) == text)
        let half = ConflictText.resolve(parts, choices: [1: .mine])
        #expect(half.hasPrefix("# Note\n<<<<<<< HEAD\n") && half.hasSuffix("middle\nm\n"))
        #expect(ConflictText.conflicts(in: half).count == 1)
    }

    @Test func brokenMarksArePlainText() {
        for broken in [
            "<<<<<<< HEAD\na\n=======\nb\n", "<<<<<<< HEAD\na\n>>>>>>> x\n", "<<<<<<<< not a mark\n=======\n>>>>>>> x\n",
            "=======\n>>>>>>> x\n", "<<<<<<< a\n<<<<<<< b\n",
        ] {
            #expect(ConflictText.parse(broken) == [.plain(broken)])
        }
        #expect(ConflictText.parse("") == [.plain("")])
        // An inner start that never had a middle leaves the outer one broken and the inner one whole.
        let nested = "<<<<<<< a\n<<<<<<< b\nx\n=======\ny\n>>>>>>> c\n"
        #expect(ConflictText.parse(nested).count == 2)
        #expect(ConflictText.conflicts(in: nested).first?.remote == "x\n")
    }

    @Test func windowsLineEndsAndALastLineWithoutEnd() {
        let crlf = "a\r\n<<<<<<< HEAD\r\nr\r\n=======\r\nm\r\n>>>>>>> x"
        let parts = ConflictText.parse(crlf)
        #expect(ConflictText.conflicts(in: crlf).map(\.mine) == ["m\r\n"])
        #expect(ConflictText.resolve(parts, all: .remote) == "a\r\nr\r\n")
        #expect(ConflictText.resolve(parts, choices: [:]) == crlf)
    }
}

/// Two clones of one bare repository, as two computers syncing one vault.
@Suite struct GitConflictTests {
    struct Repos {
        var base: URL
        var mac: Git
        var phone: Git

        init() async throws {
            base = FileManager.default.temporaryDirectory.appending(path: "daftar-conflict-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try await Git(root: base).run(["init", "-q", "--bare", "-b", "main", "remote.git"])
            mac = Git(root: base.appending(path: "mac"))
            phone = Git(root: base.appending(path: "phone"))
            try await clone(mac)
        }

        func clone(_ git: Git) async throws {
            try await Git(root: base).run(["clone", "-q", "remote.git", git.root.lastPathComponent])
            try await git.run(["config", "user.email", "test@example.com"])
            try await git.run(["config", "user.name", "Test"])
        }

        func write(_ git: Git, _ path: String, _ text: String) throws {
            let file = git.root.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }

        func read(_ git: Git, _ path: String) -> String? { try? String(contentsOf: git.root.appending(path: path), encoding: .utf8) }

        func subjects(_ git: Git) async throws -> [String] {
            try await git.run(["log", "--format=%s"]).components(separatedBy: "\n")
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    /// The mac's first commit, then for each file the phone's text, pushed,
    /// and the mac's own, not committed yet.
    func diverge(_ repos: Repos, files: [String: (String, String, String)]) async throws {
        for (path, texts) in files { try repos.write(repos.mac, path, texts.0) }
        try await repos.mac.run(["add", "-A"])
        try await repos.mac.run(["commit", "-qm", "first"])
        try await repos.mac.run(["push", "-q", "-u", "origin", "main"])
        try await repos.clone(repos.phone)
        for (path, texts) in files { try repos.write(repos.phone, path, texts.1) }
        try await repos.phone.sync(message: "phone")
        for (path, texts) in files { try repos.write(repos.mac, path, texts.2) }
    }

    @Test func aStoppedPullIsKeptAndResolved() async throws {
        let repos = try await Repos()
        defer { repos.remove() }
        try await diverge(repos, files: ["N.md": ("a\nline\nz\n", "a\nphone line\nz\n", "a\nmac line\nz\n")])

        let stopped = await #expect(throws: Git.Stopped.self) { try await repos.mac.sync(message: "mac") }
        #expect(stopped?.conflicts == [Git.Conflicted(path: "N.md", remote: .changed, mine: .changed)])
        #expect(try await repos.mac.rebaseInProgress())
        // Another sync never commits the marks over the open rebase.
        await #expect(throws: Git.Stopped.self) { try await repos.mac.sync(message: "again") }
        await #expect(throws: Git.Stopped.self) { try await repos.mac.pull() }

        let text = try #require(repos.read(repos.mac, "N.md"))
        let conflicts = ConflictText.conflicts(in: text)
        #expect(conflicts.map(\.remote) == ["phone line\n"] && conflicts.map(\.mine) == ["mac line\n"])
        let resolved = ConflictText.resolve(ConflictText.parse(text), all: .both)
        let open = try await repos.mac.finishRebase([(stopped!.conflicts[0], .text(resolved))])
        #expect(open.isEmpty)
        #expect(try await !repos.mac.rebaseInProgress())
        #expect(repos.read(repos.mac, "N.md") == "a\nphone line\nmac line\nz\n")
        #expect(try await repos.subjects(repos.mac) == ["mac", "phone", "first"])
        // The resolution reached the remote.
        try await repos.phone.pull()
        #expect(repos.read(repos.phone, "N.md") == "a\nphone line\nmac line\nz\n")
    }

    @Test func eachReplayedCommitThatConflictsStopsAgain() async throws {
        let repos = try await Repos()
        defer { repos.remove() }
        try await diverge(repos, files: ["N.md": ("x\n", "phone\n", "mac one\n")])
        try await repos.mac.run(["commit", "-qam", "mac one"])
        try repos.write(repos.mac, "N.md", "mac two\n")
        let stopped = await #expect(throws: Git.Stopped.self) { try await repos.mac.sync(message: "mac two") }
        // The phone's line wins over "mac one", so "mac two" does not apply either.
        let next = try await repos.mac.finishRebase([(stopped!.conflicts[0], .keepRemote)])
        #expect(next.map(\.path) == ["N.md"])
        #expect(try await repos.mac.rebaseInProgress())
        #expect(ConflictText.conflicts(in: repos.read(repos.mac, "N.md") ?? "").map(\.mine) == ["mac two\n"])
        #expect(try await repos.mac.finishRebase([(next[0], .keepMine)]).isEmpty)
        #expect(try await repos.subjects(repos.mac) == ["mac two", "phone", "first"])
        #expect(repos.read(repos.mac, "N.md") == "mac two\n")
    }

    @Test func keepingTheRemoteEverywhereDropsTheEmptyCommit() async throws {
        let repos = try await Repos()
        defer { repos.remove() }
        try await diverge(repos, files: ["N.md": ("x\n", "phone\n", "mac\n")])
        let stopped = await #expect(throws: Git.Stopped.self) { try await repos.mac.sync(message: "mac") }
        #expect(try await repos.mac.finishRebase([(stopped!.conflicts[0], .keepRemote)]).isEmpty)
        #expect(try await repos.subjects(repos.mac) == ["phone", "first"])
        #expect(repos.read(repos.mac, "N.md") == "phone\n")
    }

    @Test func abortPutsTheBranchBack() async throws {
        let repos = try await Repos()
        defer { repos.remove() }
        try await diverge(repos, files: ["N.md": ("x\n", "phone\n", "mac\n")])
        await #expect(throws: Git.Stopped.self) { try await repos.mac.sync(message: "mac") }
        try await repos.mac.abortRebase()
        #expect(try await !repos.mac.rebaseInProgress())
        #expect(try await repos.subjects(repos.mac) == ["mac", "first"])
        #expect(repos.read(repos.mac, "N.md") == "mac\n")
    }

    @Test func otherFilesKeepOneSideAndADeletionIsASide() async throws {
        let repos = try await Repos()
        defer { repos.remove() }
        try await diverge(repos, files: ["data.json": ("{}\n", "{\"a\":1}\n", "{\"b\":2}\n"), "Gone.md": ("old\n", "phone\n", "old\n")])
        // The mac deletes a note the phone changed.
        try FileManager.default.removeItem(at: repos.mac.root.appending(path: "Gone.md"))
        let stopped = await #expect(throws: Git.Stopped.self) { try await repos.mac.sync(message: "mac") }
        let conflicts = try #require(stopped?.conflicts)
        #expect(conflicts.sorted { $0.path < $1.path } == [
            Git.Conflicted(path: "Gone.md", remote: .changed, mine: .deleted),
            Git.Conflicted(path: "data.json", remote: .changed, mine: .changed),
        ])
        #expect(conflicts.first { $0.path == "Gone.md" }?.hasMarks == false)
        let resolutions = conflicts.map { ($0, $0.path == "Gone.md" ? Git.Resolution.keepMine : .keepRemote) }
        #expect(try await repos.mac.finishRebase(resolutions).isEmpty)
        #expect(repos.read(repos.mac, "Gone.md") == nil)
        #expect(repos.read(repos.mac, "data.json") == "{\"a\":1}\n")
    }

    @Test func theStatusRecordsAreRead() {
        let output = "1 .M N... 100644 100644 100644 a b x.md\0u UD N... 100644 100644 000000 100644 h1 h2 h3 A note.md\0u AA N... 000000 100644 100644 100644 h1 h2 h3 b.png\0"
        #expect(Git.conflicted(output) == [
            Git.Conflicted(path: "A note.md", remote: .changed, mine: .deleted),
            Git.Conflicted(path: "b.png", remote: .added, mine: .added),
        ])
    }
}
