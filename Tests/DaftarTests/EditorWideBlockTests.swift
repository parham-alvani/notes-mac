import AppKit
import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// Where `EditorWideBlockTests.picture` writes the editor as a picture, when asked:
/// `DAFTAR_WIDE_PICTURE=/tmp/wide swift test --filter EditorWideBlockTests/picture`.
private let widePicture = ProcessInfo.processInfo.environment["DAFTAR_WIDE_PICTURE"]

/// A picture alone on its line grows past the measure in the editor,
/// centred in the view (`docs/specs/wide-blocks.md` in
/// notes-linux): the text size 16, `text_width = 35` and `block_width = 60`.
@MainActor
@Suite(.serialized) struct EditorWideBlockTests {
    let root: URL
    let store: VaultStore
    let controller: EditorController
    let view: NoteTextView
    let window: NSWindow

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-wide-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Notes"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "uploads"), withIntermediateDirectories: true)
        let svg = ##"<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="240" viewBox="0 0 1200 240"><rect width="1200" height="240" fill="#36c"/></svg>"##
        try svg.write(to: root.appending(path: "uploads/wide.svg"), atomically: true, encoding: .utf8)
        let settings = AppSettings(url: root.appending(path: "config/config.toml"))
        store = VaultStore(settings: settings, openVault: false)
        store.openSynchronously(root)
        controller = EditorController(store: store)
        let scroll = NoteTextView.scrollableNoteView()
        view = scroll.documentView as! NoteTextView
        view.controller = controller
        controller.view = view
        window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1400, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        scroll.layoutSubtreeIfNeeded()
    }

    var text: NSString { view.string as NSString }

    func open(_ note: String) throws {
        try note.write(to: root.appending(path: "Notes/Wide.md"), atomically: true, encoding: .utf8)
        store.openSynchronously(root)
        controller.load("Notes/Wide.md")
        view.setSelectedRange(NSRange(location: text.length, length: 0))
        controller.restyle(all: true)
    }

    func at(_ word: String) -> Int { text.range(of: word).location }

    func picture(at word: String) -> EmbeddedImage? {
        view.textStorage?.attribute(.daftarImage, at: at(word), effectiveRange: nil) as? EmbeddedImage
    }

    /// The measure's width and its centre, in the view.
    var measure: (width: CGFloat, centre: CGFloat) {
        let container = view.textContainer!
        return (container.size.width, view.textContainerOrigin.x + container.size.width / 2)
    }

    @Test func blockWidthZeroKeepsAPictureInTheMeasure() throws {
        store.settings.blockWidth = 0
        try open("Top\n\n![[wide.svg]]\n")
        let alone = try #require(picture(at: "![[wide.svg]]"))
        #expect(alone.size.width <= measure.width && alone.x == 0)
    }

    @Test func aPictureAloneOnItsLineGrowsPastTheMeasureCentred() throws {
        try open("Top\n\n![[wide.svg]]\n\nSee ![[wide.svg]] here\n")
        let alone = try #require(picture(at: "![[wide.svg]]"))
        #expect(alone.size.width == 960)
        // `x` is from the container's left edge.
        #expect(abs(view.textContainerOrigin.x + alone.x + alone.size.width / 2 - measure.centre) < 1)
        let inline = try #require(picture(at: "See"))
        #expect(inline.size.width <= measure.width && inline.x == 0)
    }

    /// The editor with wide blocks in it, as a picture, to look at.
    @Test(.enabled(if: widePicture != nil)) func picture() throws {
        try open(
            "Some prose that keeps to the measure, about seventy letters on each line of the editor.\n\n![[wide.svg]]\n\nIn a sentence ![[wide.svg|200]] it keeps the measure.\n\nThe end.\n")
        window.appearance = NSAppearance(named: .darkAqua)
        controller.restyle(all: true)
        let scroll = try #require(view.enclosingScrollView)
        scroll.layoutSubtreeIfNeeded()
        scroll.displayIfNeeded()
        let bitmap = try #require(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
        scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(filePath: "\(widePicture ?? "").png"))
    }
}
