import AppKit
import DaftarCore
import Foundation
import ImageIO
import Testing
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@testable import DaftarUI

/// Pictures on their own page and in the editor, on a made-up vault in a
/// temporary folder with its own settings file.
@MainActor
@Suite(.serialized) struct ImageViewTests {
    let root: URL
    let store: VaultStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "uploads"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "Notes"), withIntermediateDirectories: true)
        try Self.gif(colors: [.red, .blue]).write(to: root.appending(path: "uploads/moving.gif"))
        try Self.gif(colors: [.green]).write(to: root.appending(path: "uploads/still.gif"))
        try #"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50"><rect width="100" height="50" fill="green"/></svg>"#
            .write(to: root.appending(path: "uploads/shape.svg"), atomically: true, encoding: .utf8)
        try "Top\n![[moving.gif]]\n![[still.gif]]\n![[shape.svg]]\nSee [[shape.svg]].\n"
            .write(to: root.appending(path: "Notes/Pictures.md"), atomically: true, encoding: .utf8)
        store = VaultStore(settings: AppSettings(url: root.appending(path: "config/config.toml")), openVault: false)
        store.openSynchronously(root)
    }

    /// A GIF of 120 × 60 with a frame of each colour, half a second each.
    static func gif(colors: [NSColor]) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, colors.count, nil)!
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for color in colors {
            let context = CGContext(
                data: nil, width: 120, height: 60, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
            CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.5]] as CFDictionary)
        }
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    @Test func aPictureOpensInThePaneAndIsNeverEdited() {
        let model = WindowModel()
        model.open("Notes/Pictures.md", store: store)
        model.editing = true
        #expect(model.editing && model.showsText && !model.showsImage)
        // The mode stays edit for the notes, but a picture is read.
        model.open("uploads/shape.svg", store: store)
        #expect(model.path == "uploads/shape.svg" && model.showsImage && !model.showsText)
        #expect(!model.editing && !model.focused.canEdit)
        model.editing = true
        #expect(!model.editing)
        // Back is the note, in the editor again.
        model.goBack()
        #expect(model.path == "Notes/Pictures.md" && model.editing)
        // A link that asks for the editor shows the picture in the reader.
        model.handle(URL(string: "daftar://open?path=uploads/moving.gif&mode=edit")!, store: store)
        #expect(model.path == "uploads/moving.gif" && !model.editing)
        #expect(model.recent.prefix(2) == ["uploads/moving.gif", "uploads/shape.svg"])
    }

    @Test func thePaletteOffersZoomNotTheNotesCommands() {
        let ids = PaletteCommands.image(model: WindowModel(), store: store).map(\.id)
        #expect(ids == ["image-in", "image-out", "image-fit", "image-actual", "image-external"])
        #expect(PaletteCommands.textOnly.isSuperset(of: ["edit", "find", "pdf", "read-aloud", "history"]))
    }

    @Test func anAnimatedGIFMovesInTheEditorAndAStillOneDoesNot() throws {
        // With Reduce Motion nothing moves: the first frame stays.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let controller = EditorController(store: store)
        let scroll = NoteTextView.scrollableNoteView()
        let view = try #require(scroll.documentView as? NoteTextView)
        view.controller = controller
        controller.view = view
        controller.load("Notes/Pictures.md")
        defer { controller.animator.stop() }
        let text = view.string as NSString
        let image = { (embed: String) in view.textStorage?.attribute(.daftarImage, at: text.range(of: embed).location, effectiveRange: nil) as? EmbeddedImage }
        let moving = try #require(image("![[moving.gif]]"))
        let animation = try #require(moving.animation)
        #expect(animation.delays == [0.5, 0.5])
        #expect(animation.frame(at: 0.2) == 0 && animation.frame(at: 0.7) == 1 && animation.frame(at: 1.2) == 0)
        controller.animator.advance(to: 0.7)
        #expect(animation.frame == 1)
        let pixels = try #require(animation.image())
        #expect(pixels.width == 120)
        #expect(image("![[still.gif]]")?.animation == nil)
        // An SVG is drawn too, at its own size.
        #expect(image("![[shape.svg]]")?.size == NSSize(width: 100, height: 50))
        #expect(view.string.hasPrefix("Top\n![[moving.gif]]"))
    }
}

/// The picture page and the picture opened large, in a real web view: the
/// zoom keys, the bar, and a click on the picture that does not close it.
@MainActor
@Suite(.serialized) struct ImagePageTests {
    let root: URL
    let store: VaultStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-image-page-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "uploads"), withIntermediateDirectories: true)
        try ImageViewTests.gif(colors: [.red, .blue]).write(to: root.appending(path: "uploads/moving.gif"))
        try "# Pictures\n\n![[moving.gif]]\n".write(to: root.appending(path: "Pictures.md"), atomically: true, encoding: .utf8)
        store = VaultStore(settings: AppSettings(url: root.appending(path: "config/config.toml")), openVault: false)
        store.openSynchronously(root)
    }

    /// The page of [path] in an off-screen window, once [ready] (a script) says true.
    func page(_ path: String, ready: String) async throws -> (WKWebView, NSWindow) {
        var web: WKWebView?
        let reader = ReaderView(request: ReaderRequest(path: path), store: store, onOpen: { _, _, _ in }, onTag: { _ in }, onView: { web = $0 })
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: reader.environment(store))
        window.orderBack(nil)
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(150))
            if let web, try await web.evaluateJavaScript(ready) as? Bool == true { return (web, window) }
        }
        throw CancellationError()
    }

    /// What [script] gives, as text.
    func run(_ web: WKWebView, _ script: String) async throws -> String {
        "\(try await web.evaluateJavaScript(script) ?? "")"
    }

    @Test func aPictureFileFitsAndZooms() async throws {
        let (web, window) = try await page("uploads/moving.gif", ready: "!!document.querySelector('.image-file.is-loaded')")
        defer { window.orderOut(nil) }
        let state = "[document.querySelector('.image-percent').textContent, document.querySelector('.image-file').style.width, document.querySelector('.image-info').textContent].join('|')"
        // 120 × 60 is smaller than the window: it is shown at its own size.
        let first = try await run(web, state)
        #expect(first.hasPrefix("100 %|120px|120 × 60 · ") && first.hasSuffix(" · GIF image"))
        _ = try await run(web, "daftar.imageCommand('in')")
        #expect(try await run(web, state).hasPrefix("125 %|150px|"))
        _ = try await run(web, "document.dispatchEvent(new KeyboardEvent('keydown', { key: '+' })); document.dispatchEvent(new KeyboardEvent('keydown', { key: '0' }))")
        #expect(try await run(web, state).hasPrefix("100 %|120px|"))
        // A pinch zooms; the limit is 1600 %.
        _ = try await run(
            web, "for (let i = 0; i < 50; i++) document.querySelector('.image-stage').dispatchEvent(new WheelEvent('wheel', { deltaY: -200, ctrlKey: true, bubbles: true, cancelable: true })); 1")
        #expect(try await run(web, state).hasPrefix("1600 %|1920px|"))
        // A picture has no reading cursor.
        #expect(try await run(web, "!document.querySelector('#reading-cursor.is-on')") == "1")
    }

    @Test func anEmbeddedPictureOpensLargeAndAClickOnItKeepsItOpen() async throws {
        let (web, window) = try await page("Pictures.md", ready: "!!document.querySelector('#note img')?.complete")
        defer { window.orderOut(nil) }
        _ = try await run(web, "document.querySelector('#note img').click(); 1")
        let state = "[!!document.querySelector('.zoom'), document.querySelector('.zoom')?.getAttribute('role'), document.querySelector('.zoom .image-percent')?.textContent].join('|')"
        #expect(try await run(web, state) == "true|dialog|100 %")
        _ = try await run(web, "document.dispatchEvent(new KeyboardEvent('keydown', { key: '+' })); 1")
        #expect(try await run(web, state) == "true|dialog|125 %")
        // A click on the picture leaves it open; one on the backdrop closes it.
        let click = "(el) => { el.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true })); el.dispatchEvent(new PointerEvent('pointerup', { bubbles: true })); el.click(); return 1; }"
        _ = try await run(web, "(\(click))(document.querySelector('.zoom > img'))")
        #expect(try await run(web, state) == "true|dialog|125 %")
        _ = try await run(web, "(\(click))(document.querySelector('.zoom'))")
        #expect(try await run(web, "!document.querySelector('.zoom')") == "1")
        // Escape closes it too.
        _ = try await run(web, "document.querySelector('#note img').click(); document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' })); 1")
        #expect(try await run(web, "!document.querySelector('.zoom')") == "1")
    }
}
