import AppKit
import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// Neovim's block and bar on Persian lines and on lines where Persian and
/// English meet, off screen. The block's place does not need Neovim.
@MainActor
@Suite(.serialized) struct RtlCursorTests {
    let root: URL
    let view: NoteTextView
    let window: NSWindow
    let controller: EditorController

    /// Each line with its first offset.
    static let lines = ["abc", "hi سلام you", "- [ ] خرید نان", "سلام abc دنیا"]
    static func start(_ line: Int) -> Int { lines[..<line].reduce(0) { $0 + ($1 as NSString).length + 1 } }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-rtl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The note ends in a newline: the last line's caret was on the wrong side.
        try (Self.lines.joined(separator: "\n") + "\n").write(to: root.appending(path: "Rtl.md"), atomically: true, encoding: .utf8)
        let store = VaultStore(settings: AppSettings(url: root.appending(path: "config/config.toml")), openVault: false)
        store.openSynchronously(root)
        controller = EditorController(store: store)
        let scroll = NoteTextView.scrollableNoteView()
        view = scroll.documentView as! NoteTextView
        view.controller = controller
        controller.view = view
        window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        controller.load("Rtl.md")
    }

    func block(at offset: Int) throws -> NSRect {
        view.setSelectedRange(NSRange(location: offset, length: 0))
        return try #require(view.blockRect())
    }

    /// Each block is over its own letter: never as wide as a word where
    /// the direction changes, and no two letters of a line share one.
    @Test func eachLetterHasItsOwnBlock() throws {
        for line in 1..<Self.lines.count {
            let start = Self.start(line)
            let length = (Self.lines[line] as NSString).length
            let blocks = try (start..<start + length).map { try block(at: $0) }
            for (index, one) in blocks.enumerated() {
                let letter = try #require(view.letterBox(NSRange(location: start + index, length: 1)))
                #expect(abs(one.minX - letter.minX) < 0.5 && abs(one.width - letter.width) < 0.5, "line \(line), letter \(index)")
                for other in blocks[(index + 1)...] {
                    #expect(one.intersection(other).width < 0.5, "line \(line), letter \(index)")
                }
            }
        }
    }

    /// At the end of a Persian line the block is to the left of the last
    /// letter, not over it; after an English one it is to the right.
    @Test func theBlockAtALinesEndIsAfterItsLastLetter() throws {
        let english = Self.start(1) - 1
        let lastEnglish = try #require(view.letterBox(NSRange(location: english - 1, length: 1)))
        #expect(try block(at: english).minX >= lastEnglish.maxX - 1)
        for line in [2, 3] {
            let end = Self.start(line + 1) - 1
            let last = try #require(view.letterBox(NSRange(location: end - 1, length: 1)))
            #expect(try block(at: end).maxX <= last.minX + 1, "line \(line)")
        }
    }

    /// The bar on the note's last line is where its letters are: on the
    /// right for a Persian line, as on every other line.
    @Test func theCaretOnTheLastLineIsOnItsSide() throws {
        let first = Self.start(3)
        let caret = try #require(view.letterCaret(at: first))
        let letter = try #require(view.letterBox(NSRange(location: first, length: 1)))
        #expect(abs(caret.minX - letter.maxX) < 2)
    }
}
