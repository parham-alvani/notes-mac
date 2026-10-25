import Foundation
import Testing

@testable import DaftarCore

@Suite struct MessagePackTests {
    @Test func roundTrips() throws {
        let values: [MessagePackValue] = [
            nil, true, false, 0, 127, 128, 65_535, 70_000, -1, -33, -200, -40_000, .int(-3_000_000_000),
            .uint(UInt64(UInt32.max) + 5), .double(1.5), "", "short", .string(String(repeating: "x", count: 300)),
            "فارسی", .binary(Data([1, 2, 3])), [1, "two", [3]], ["key": "value", "n": 2], .ext(0, Data([5])),
            .array(Array(repeating: 1, count: 20)),
        ]
        // A positive number is sent in the unsigned form: the same value.
        func unsigned(_ value: MessagePackValue) -> MessagePackValue {
            switch value {
            case .int(let n) where n >= 0: .uint(UInt64(n))
            case .array(let items): .array(items.map(unsigned))
            case .map(let map): .map(Dictionary(uniqueKeysWithValues: map.map { (unsigned($0.key), unsigned($0.value)) }))
            default: value
            }
        }
        for value in values {
            #expect(try MessagePack.decode(MessagePack.encode(value)) == unsigned(value))
        }
    }

    @Test func streamWaitsForWholeValues() {
        var stream = MessagePack.Stream()
        let data = MessagePack.encode(["a", 1]) + MessagePack.encode("b")
        #expect(stream.feed(data.prefix(3)).isEmpty)
        let rest = stream.feed(data.dropFirst(3))
        #expect(rest.count == 2)
        #expect(rest.last == "b")
    }

    @Test func handlesAreIntegers() {
        #expect(MessagePackValue.ext(0, MessagePack.encode(3)).intValue == 3)
    }
}

@Suite struct BufferMirrorTests {
    @Test func applyReturnsTheSmallestEdit() {
        var mirror = BufferMirror(lines: ["one", "two", "three"])
        let edit = mirror.apply(first: 1, last: 2, replacement: ["TWO"])
        #expect(mirror.text == "one\nTWO\nthree\n")
        #expect(edit.range == NSRange(location: 4, length: 3))
        #expect(edit.text == "TWO")
        let added = mirror.apply(first: 3, last: 3, replacement: ["four"])
        #expect(mirror.text == "one\nTWO\nthree\nfour\n")
        #expect(added.text == "four\n")
        _ = mirror.apply(first: 0, last: -1, replacement: [])
        #expect(mirror.text == "\n")
    }

    @Test func positionsCountBytesInNeovimAndUnitsInTheView() {
        let mirror = BufferMirror(lines: ["abc", "سلام x", "😀b"])
        #expect(mirror.offset(row: 1, byteColumn: 2) == 2)
        // "سلام " is 4 letters of 2 bytes and a space: byte 9 is the "x".
        #expect(mirror.offset(row: 2, byteColumn: 9) == 4 + 5)
        // The emoji is 4 bytes and 2 UTF-16 units.
        #expect(mirror.offset(row: 3, byteColumn: 4) == 4 + 7 + 2)
        #expect(mirror.position(of: 4 + 5) == (2, 9))
        #expect(mirror.position(of: 4 + 7 + 2) == (3, 4))
    }
}

@Suite struct VimKeysTests {
    @Test func notation() {
        #expect(VimKeys.notation(characters: "a", modifiers: []) == "a")
        #expect(VimKeys.notation(characters: "A", modifiers: [.shift]) == "A")
        #expect(VimKeys.notation(characters: "w", modifiers: [.control]) == "<C-w>")
        #expect(VimKeys.notation(characters: "<", modifiers: [.shift]) == "<LT>")
        #expect(VimKeys.notation(characters: "\r", modifiers: []) == "<CR>")
        #expect(VimKeys.notation(characters: "\u{1B}", modifiers: []) == "<Esc>")
        #expect(VimKeys.notation(characters: "\u{F700}", modifiers: [.shift]) == "<S-Up>")
        #expect(VimKeys.notation(characters: " ", modifiers: [.control]) == "<C-Space>")
        #expect(VimKeys.notation(characters: "ش", modifiers: []) == "ش")
        #expect(VimKeys.escape("a<b") == "a<LT>b")
    }
}

/// Against a real Neovim, when there is one: CI has none, and skips these.
@Suite(.enabled(if: NeovimClient.locate() != nil)) struct NeovimClientTests {
    @Test func editsAFileAndReportsTheBuffer() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "daftar-nvim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "note.md")
        try "one\ntwo\n".write(to: file, atomically: true, encoding: .utf8)

        let client = NeovimClient(executable: NeovimClient.locate()!, arguments: ["--clean"], directory: folder)
        try client.start()
        defer { client.stop() }
        try await client.request("nvim_ui_attach", [80, 24, ["ext_linegrid": true, "ext_messages": true]])
        try await client.request("nvim_command", ["edit note.md"])
        let lines = try await client.request("nvim_buf_get_lines", [0, 0, -1, false])
        #expect(lines.arrayValue?.compactMap(\.stringValue) == ["one", "two"])

        try await client.request("nvim_buf_attach", [0, false, [:]])
        try await client.request("nvim_input", ["ggAX<Esc>"])
        var changed: [String]?
        for await note in client.notifications where note.method == "nvim_buf_lines_event" {
            changed = note.params[4].arrayValue?.compactMap(\.stringValue)
            break
        }
        #expect(changed == ["oneX"])
        try await client.request("nvim_command", ["write"])
        #expect(try String(contentsOf: file, encoding: .utf8) == "oneX\ntwo\n")
    }
}

/// Random edits: the mirror and a plain copy of the text never differ.
@Suite struct BufferMirrorFuzzTests {
    @Test func everyEditTheMirrorReturnsMakesItsText() {
        struct Seeded: RandomNumberGenerator {
            var state: UInt64
            mutating func next() -> UInt64 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return state
            }
        }
        var random = Seeded(state: 1995)
        let words = ["", "a", "سلام", "x y", "😀z", "# h", "- [ ] t"]
        for eol in [true, false] {
            var mirror = BufferMirror(lines: ["one", "دو", "three"], endsWithNewline: eol)
            var shown = mirror.text as NSString
            for _ in 0..<3000 {
                let count = mirror.lines.count
                let first = Int.random(in: 0...count, using: &random)
                let last = Bool.random(using: &random) ? -1 : Int.random(in: first...count, using: &random)
                let replacement = (0..<Int.random(in: 0...3, using: &random)).map { _ in words.randomElement(using: &random)! }
                let edit = mirror.apply(first: first, last: last, replacement: replacement)
                shown = shown.replacingCharacters(in: edit.range, with: edit.text) as NSString
                #expect(shown as String == mirror.text, "first \(first) last \(last) \(replacement)")
                if shown as String != mirror.text { return }
                // A row and column there and back again.
                let row = Int.random(in: 1...mirror.lines.count, using: &random)
                let offset = mirror.offset(row: row, byteColumn: 0)
                #expect(mirror.position(of: offset).row == row)
            }
        }
    }
}
