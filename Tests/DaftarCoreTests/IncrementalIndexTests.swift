import Foundation
import Testing

@testable import DaftarCore

// Every fixture here is made up. The repository is public; the vault is not.

/// A save derives only what the changed notes gave: the backlinks, tags and
/// tag tree must be what the whole vault read again would give.
@Suite struct IncrementalIndexTests {
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test func savedNotesDeriveAsTheWholeVaultWould() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "daftar-incremental-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var random = Seeded(state: 42)
        let names = (0..<40).map { "Note \($0)" }
        let folders = ["A", "B", "A/C"]
        var paths: [String] = []
        for folder in folders { try FileManager.default.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true) }
        for (number, name) in names.enumerated() { paths.append(folders[number % folders.count] + "/" + name + ".md") }
        func text() -> String {
            var out = ""
            if Bool.random(using: &random) { out += "---\ntags: [" + ["x", "y/z", "Y"].shuffled(using: &random).prefix(Int.random(in: 0...2, using: &random)).joined(separator: ", ") + "]\n---\n" }
            for _ in 0..<Int.random(in: 0...6, using: &random) {
                let target = Bool.random(using: &random) ? names.randomElement(using: &random)! : "Missing \(Int.random(in: 0..<3, using: &random))"
                out += "Line [[\(target)]] #\(["x", "w/v", "y"].randomElement(using: &random)!)\n"
            }
            return out
        }
        for path in paths { try Data(text().utf8).write(to: root.appending(path: path)) }
        var index = Vault.index(root)
        for _ in 0..<60 {
            let changed = Set(paths.shuffled(using: &random).prefix(Int.random(in: 1...4, using: &random)))
            for path in changed { try Data(text().utf8).write(to: root.appending(path: path)) }
            index = Vault.update(index, changed: changed, in: root)
            let whole = Vault.index(root)
            #expect(index.backlinks == whole.backlinks)
            #expect(index.tags == whole.tags)
            #expect(index.tagTree == whole.tagTree)
        }
    }
}
