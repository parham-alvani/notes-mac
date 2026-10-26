import Foundation
import Testing

@testable import DaftarCore

@Suite struct LineDiffTests {
    @Test func linesAreAddedRemovedOrTheSame() {
        let lines = LineDiff.lines(from: "a\nb\nc\n", to: "a\nB\nc\nd\n")
        #expect(lines.map(\.kind) == [.same, .removed, .added, .same, .added])
        #expect(lines.map(\.text) == ["a", "b", "B", "c", "d"])
        #expect(lines[1].old == 2 && lines[2].new == 2 && lines[4].new == 4)
        #expect(LineDiff.counts(lines) == (2, 1))
        #expect(LineDiff.lines(from: "", to: "x").map(\.kind) == [.added])
        #expect(LineDiff.lines(from: "x\r\ny", to: "x\ny").allSatisfy { $0.kind == .same })
        #expect(LineDiff.lines(from: "", to: "").isEmpty)
    }

    @Test func hunksKeepThreeLinesAround() {
        let old = (1...20).map(String.init).joined(separator: "\n")
        let new = old.replacingOccurrences(of: "\n2\n", with: "\ntwo\n").replacingOccurrences(of: "\n18\n", with: "\neighteen\n")
        let hunks = LineDiff.hunks(LineDiff.lines(from: old, to: new))
        #expect(hunks.count == 2)
        #expect(hunks[0].first?.text == "1" && hunks[0].last?.text == "5")
        #expect(hunks[1].first?.text == "15" && hunks[1].last?.text == "20")
        let near = old.replacingOccurrences(of: "\n5\n", with: "\nfive\n").replacingOccurrences(of: "\n9\n", with: "\nnine\n")
        #expect(LineDiff.hunks(LineDiff.lines(from: old, to: near)).count == 1)
        #expect(LineDiff.hunks(LineDiff.lines(from: old, to: old)).isEmpty)
    }
}

@Suite struct GitHistoryTests {
    @Test func theLogIsRead() {
        let output = "\u{1e}abc\u{1f}2026-10-25T09:30:00+02:00\u{1f}Parham\u{1f}update notes @ x\n\nNotes/A.md\n\u{1e}def\u{1f}2026-10-24T08:00:00Z\u{1f}P\u{1f}a | b\u{1f}c\n\nOld/A.md"
        let revisions = Git.revisions(output)
        #expect(revisions.map(\.hash) == ["abc", "def"])
        #expect(revisions.map(\.path) == ["Notes/A.md", "Old/A.md"])
        #expect(revisions[1].subject == "a | b\u{1f}c")
        #expect(revisions[0].date == ISO8601DateFormatter().date(from: "2026-10-25T07:30:00Z"))
        #expect(Git.revisions("").isEmpty)
        #expect(Git.revisions("\u{1e}broken").isEmpty)
    }

    @Test func aNoteHistoryFollowsItsRenames() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "daftar-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base.appending(path: "Old"), withIntermediateDirectories: true)
        let git = Git(root: base)
        try await git.run(["init", "-q", "-b", "main"])
        try await git.run(["config", "user.email", "test@example.com"])
        try await git.run(["config", "user.name", "Test"])
        try "one\n".write(to: base.appending(path: "Old/Nöte.md"), atomically: true, encoding: .utf8)
        try await git.run(["add", "-A"])
        try await git.run(["commit", "-qm", "first"])
        try "one\ntwo\n".write(to: base.appending(path: "Old/Nöte.md"), atomically: true, encoding: .utf8)
        try await git.run(["commit", "-qam", "second"])
        try await git.run(["mv", "Old", "New"])
        try await git.run(["commit", "-qm", "move"])

        let history = try await git.history(of: "New/Nöte.md")
        #expect(history.map(\.subject) == ["move", "second", "first"])
        #expect(history.map(\.path) == ["New/Nöte.md", "Old/Nöte.md", "Old/Nöte.md"])
        #expect(try await git.content(of: history[2].path, at: history[2].hash) == "one\n")
        #expect(try await git.content(of: history[1].path, at: history[1].hash) == "one\ntwo\n")
        #expect(try await git.history(of: "Missing.md").isEmpty)
    }
}
