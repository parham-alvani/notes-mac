import AppKit
import DaftarCore
import Foundation
import SwiftUI
import Testing
import WebKit

@testable import DaftarUI

/// `appearance.remote_images` (`docs/specs/remote-images.md` in notes-linux):
/// read from the config file, `true` when absent or unknown, and sent to the
/// page as `remoteImages`, which then asks no site for a picture.
@MainActor
@Suite(.serialized) struct RemoteImagesTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "daftar-remote-\(UUID().uuidString)")
    var url: URL { root.appending(path: "config/config.toml") }

    /// Settings read from [text], or from the template when there is no file.
    private func settings(_ text: String?) throws -> AppSettings {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let text {
            try Data(text.utf8).write(to: url)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
        return AppSettings(url: url)
    }

    @Test func theSettingIsReadAndSentToThePage() throws {
        #expect(ConfigFile(text: ConfigFile.template).bool("appearance.remote_images") == true)
        #expect(try settings(nil).remoteImages)
        #expect(try settings("[appearance]\ntheme = \"dark\"\n").remoteImages)
        #expect(try settings("[appearance]\nremote_images = \"no\"\n").remoteImages)
        #expect(try settings("[appearance]\nremote_images = 0\n").remoteImages)
        let on = try settings("[appearance]\nremote_images = true\n")
        #expect(ReaderView.appearance(on)["remoteImages"] as? Bool == true)
        let off = try settings("[appearance]\nremote_images = false\n")
        #expect(!off.remoteImages)
        #expect(ReaderView.appearance(off)["remoteImages"] as? Bool == false)
    }

    @Test func aChangeIsWrittenAndDrawsTheNoteAgain() throws {
        let settings = try settings(nil)
        let before = ReaderView.shownKey(settings)
        settings.remoteImages = false
        #expect(ReaderView.shownKey(settings) != before)
        #expect(ConfigFile(text: try String(contentsOf: url, encoding: .utf8)).bool("appearance.remote_images") == false)
        #expect(AppSettings(url: url).remoteImages == false)
    }

    /// The note in a real web view, with the setting as [remote] says.
    private func page(remote: Bool) async throws -> (WKWebView, NSWindow) {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[appearance]\nremote_images = \(remote)\n".utf8).write(to: url)
        try "# Pictures\n\n![chart](https://example.org/chart.png)\n\n[a page](https://example.org)\n"
            .write(to: root.appending(path: "Pictures.md"), atomically: true, encoding: .utf8)
        let store = VaultStore(settings: AppSettings(url: url), openVault: false)
        store.openSynchronously(root)
        var web: WKWebView?
        let reader = ReaderView(request: ReaderRequest(path: "Pictures.md"), store: store, onOpen: { _, _, _ in }, onTag: { _ in }, onView: { web = $0 })
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: reader.environment(store))
        window.orderBack(nil)
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(150))
            if let web, try await web.evaluateJavaScript("!!document.querySelector('#note h1')") as? Bool == true { return (web, window) }
        }
        throw CancellationError()
    }

    @Test func offThePageAsksNoSiteUntilAClick() async throws {
        let (web, window) = try await page(remote: false)
        defer { window.orderOut(nil) }
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('#note img').length") as? Int == 0)
        #expect(try await web.evaluateJavaScript("document.querySelector('#note .remote-image')?.dataset.src ?? ''") as? String
            == "https://example.org/chart.png")
        // A link stays a link.
        #expect(try await web.evaluateJavaScript("document.querySelector('#note a[href=\"https://example.org\"]') !== null") as? Bool == true)
        _ = try await web.evaluateJavaScript("document.querySelector('#note .remote-image').click(); 1")
        #expect(try await web.evaluateJavaScript("document.querySelector('#note img')?.getAttribute('src') ?? ''") as? String
            == "https://example.org/chart.png")
    }

    @Test func onThePictureIsShown() async throws {
        let (web, window) = try await page(remote: true)
        defer { window.orderOut(nil) }
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('#note .remote-image').length") as? Int == 0)
        #expect(try await web.evaluateJavaScript("document.querySelector('#note img')?.getAttribute('src') ?? ''") as? String
            == "https://example.org/chart.png")
    }
}
