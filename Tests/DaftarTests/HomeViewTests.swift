import AppKit
import DaftarCore
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import DaftarUI

/// The home page of a pane with no note, drawn off screen on a made-up
/// vault, with a picture made in the test and with none.
@MainActor
@Suite(.serialized) struct HomeViewTests {
    let root: URL
    let store: VaultStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: ".obsidian/plugins/beautitab"), withIntermediateDirectories: true)
        try "# A\n".write(to: root.appending(path: "A.md"), atomically: true, encoding: .utf8)
        try #"{"showTime": true, "timeFormat": "24-hour", "greetingText": "Hello, Tester.", "showQuote": true, "quoteSource": "My quotes", "customQuotes": [{"text": "Less, but better.", "author": "Rams"}]}"#
            .write(to: root.appending(path: ".obsidian/plugins/beautitab/data.json"), atomically: true, encoding: .utf8)
        store = VaultStore(settings: AppSettings(url: root.appending(path: "config/config.toml")), openVault: false)
        store.openSynchronously(root)
    }

    /// A picture of one colour, [width] by [height], made here: no real
    /// photo goes into the repository.
    static func picture(at url: URL, red: CGFloat, green: CGFloat, blue: CGFloat, width: Int = 2000, height: Int = 1200) throws {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// The home page off screen, in Daylight, and the colour of a pixel near its top left corner.
    /// [until] lets a test wait for the picture: it is decoded off the main
    /// thread, and a slow machine (CI) draws the plain page first.
    func corner(until: (NSColor) -> Bool = { _ in true }) async throws -> NSColor {
        let model = WindowModel()
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: HomeView(model: model, pane: model.focused).environment(store))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        var color = try pixel(of: host)
        for _ in 0..<50 where !until(color) {
            try await Task.sleep(for: .milliseconds(100))
            color = try pixel(of: host)
        }
        return color
    }

    func pixel(of host: NSView) throws -> NSColor {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        return try #require(bitmap.colorAt(x: Int(12 * scale), y: Int(12 * scale))?.usingColorSpace(.sRGB))
    }

    @Test func thePictureFillsThePageUnderAThinScrim() async throws {
        let file = root.appending(path: "Attachments/red.png")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.picture(at: file, red: 0.9, green: 0.05, blue: 0.05)
        // A path in the vault.
        store.settings.homeImage = "Attachments/red.png"
        let image = try #require(await HomePictures.shared.image(file))
        #expect(image.size.width == 2000)
        // Decoded once: the second ask is the same image.
        #expect(await HomePictures.shared.image(file) === image)
        // With Reduce Transparency or Increase Contrast on, as on the CI
        // runner, the scrim is 60% Daylight rather than 15%.
        let workspace = NSWorkspace.shared
        let strong = workspace.accessibilityDisplayShouldReduceTransparency || workspace.accessibilityDisplayShouldIncreaseContrast
        let most = strong ? 0.75 : 0.4
        let red: (NSColor) -> Bool = { $0.redComponent > 0.75 && $0.blueComponent < most && $0.redComponent - $0.blueComponent > 0.2 }
        let color = try await corner(until: red)
        #expect(red(color), "\(color)")
    }

    @Test func withNoPictureThePageIsPlain() async throws {
        store.settings.homeImage = ""
        let color = try await corner()
        // Daylight's background, FAF9F5.
        #expect(abs(color.redComponent - 0xFA / 255) < 0.03 && abs(color.blueComponent - 0xF5 / 255) < 0.03, "\(color)")
    }

    @Test func aBigPictureIsDecodedNoLargerThanTheScreen() throws {
        let file = root.appending(path: "big.png")
        try Self.picture(at: file, red: 0, green: 0, blue: 1, width: 6000, height: 3000)
        let image = try #require(HomePictures.decode(file))
        #expect(max(image.width, image.height) == HomePictures.maxPixels)
    }

    /// ImageIO reads WebP on macOS 26 (it does not write it, so the file is
    /// a made-up 8×8 green square, 38 bytes, written by cwebp).
    @Test func webpIsRead() throws {
        let file = root.appending(path: "green.webp")
        try Data(base64Encoded: "UklGRh4AAABXRUJQVlA4TBEAAAAvB8ABAAfQzGp0pv+BiOh/AAA=")!.write(to: file)
        let image = try #require(HomePictures.decode(file))
        #expect(image.width == 8 && image.height == 8)
        #expect(NSImage(contentsOf: file)?.isValid == true)
    }

    @Test func thePictureIsASetting() throws {
        let settings = store.settings
        #expect(settings.homeImage == "")
        #expect(ConfigFile(text: ConfigFile.template).string("home.image") == "")
        settings.homeImage = "~/.config/daftar/home.webp"
        let file = ConfigFile(text: try String(contentsOf: settings.url, encoding: .utf8))
        #expect(file.string("home.image") == "~/.config/daftar/home.webp")
        // The file is the record: a new reader of it has the same picture.
        #expect(AppSettings(url: settings.url).homeImage == "~/.config/daftar/home.webp")
    }

    @Test func aNewTabOpensWhatTheSettingSays() throws {
        let settings = store.settings
        #expect(settings.newTab == .home)
        #expect(ConfigFile(text: ConfigFile.template).string("home.new_tab") == "home")
        settings.newTab = .note
        let file = ConfigFile(text: try String(contentsOf: settings.url, encoding: .utf8))
        #expect(file.string("home.new_tab") == "note")
        #expect(AppSettings(url: settings.url).newTab == .note)
        // A value the app does not know is the home page.
        try Data("[home]\nnew_tab = \"elsewhere\"\n".utf8).write(to: settings.url)
        #expect(AppSettings(url: settings.url).newTab == .home)
    }

    @Test func beautitabIsReadWithTheVault() {
        #expect(store.beautitab.greetingText == "Hello, Tester.")
        #expect(store.beautitab.twentyFourHour == true && store.beautitab.showQuote)
        #expect(HomeView.time(Date(timeIntervalSince1970: 0), twentyFourHour: true).count == 5)
    }
}
