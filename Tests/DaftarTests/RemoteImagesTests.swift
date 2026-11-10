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
    private func page(remote: Bool, note: String? = nil) async throws -> (WKWebView, NSWindow, VaultStore) {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[appearance]\nremote_images = \(remote)\n".utf8).write(to: url)
        try (note ?? "# Pictures\n\n![chart](https://example.org/chart.png)\n\n[a page](https://example.org)\n")
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
            if let web, try await web.evaluateJavaScript("!!document.querySelector('#note h1')") as? Bool == true { return (web, window, store) }
        }
        throw CancellationError()
    }

    /// [script]'s value, asked for until it is [wanted] or two seconds pass.
    private func until(_ web: WKWebView, _ script: String, is wanted: String) async throws -> String {
        var last = ""
        for _ in 0..<20 {
            last = "\(try await web.evaluateJavaScript(script) ?? "")"
            if last == wanted { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        return last
    }

    @Test func offThePageAsksNoSiteUntilAClick() async throws {
        let (web, window, _) = try await page(remote: false)
        defer { window.orderOut(nil) }
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('#note img').length") as? Int == 0)
        #expect(try await web.evaluateJavaScript("document.querySelector('#note .remote-image')?.dataset.src ?? ''") as? String
            == "https://example.org/chart.png")
        // A link stays a link.
        #expect(try await web.evaluateJavaScript("document.querySelector('#note a[href=\"https://example.org\"]') !== null") as? Bool == true)
        // The click asks the app, which allows this one address and says how the page reaches it.
        _ = try await web.evaluateJavaScript("document.querySelector('#note .remote-image').click(); 1")
        let route = "daftar-remote://picture/?url=https://example.org/chart.png"
        #expect(try await until(web, "document.querySelector('#note img')?.getAttribute('src') ?? ''", is: route) == route)
        #expect(try await web.evaluateJavaScript("document.querySelector('#note img').alt") as? String == "chart")
    }

    /// What the page's policy does with a picture at [address] put in the document by script: "loaded", "refused" or "error".
    private func outcome(_ web: WKWebView, _ address: String) async throws -> String {
        let script = """
            return await new Promise((resolve) => {
              const refused = (event) => { if (event.blockedURI.startsWith(address.split('?')[0].slice(0, 20))) resolve('refused') };
              document.addEventListener('securitypolicyviolation', refused);
              const img = new Image();
              img.onload = () => resolve('loaded');
              img.onerror = () => setTimeout(() => resolve('error'), 200);
              img.src = address;
              document.body.appendChild(img);
              setTimeout(() => resolve('nothing'), 4000);
            })
            """
        return "\(try await web.callAsyncJavaScript(script, arguments: ["address": address], in: nil, contentWorld: .page) ?? "")"
    }

    /// The renderer's rule is backed by the page's policy: with the setting
    /// off, a picture the renderer missed is refused before any site is asked.
    @Test func offThePolicyRefusesAPictureTheRendererMissed() async throws {
        let (web, window, _) = try await page(remote: false)
        defer { window.orderOut(nil) }
        #expect(try await outcome(web, "https://example.org/missed.png") == "refused")
        // Nobody clicked this address: the route for clicked pictures does not serve it.
        #expect(try await outcome(web, "daftar-remote://picture/?url=https://example.org/unasked.png") == "error")
    }

    @Test func onlyAnAllowedHttpsAddressIsServed() {
        let pictures = RemotePictures()
        let target = URL(string: "https://example.org/a.png?x=1&y=2")!
        #expect(pictures.allow(URL(string: "http://example.org/a.png")!) == nil)
        #expect(pictures.allow(URL(string: "file:///etc/passwd")!) == nil)
        #expect(!pictures.allows(target))
        let address = pictures.allow(target)
        #expect(address?.scheme == RemotePictures.scheme)
        #expect(address.flatMap(RemotePictures.target(of:)) == target)
        #expect(pictures.allows(target))
        #expect(RemotePictures.target(of: URL(string: "daftar-remote://picture/?url=file:///etc/passwd")!) == nil)
        pictures.forget()
        #expect(!pictures.allows(target))
    }

    /// A diagram's picture shape names a site too: off, it is not in the page.
    @Test func offADiagramDrawsNoPictureFromTheWeb() async throws {
        let note = "# Diagram\n\n```mermaid\nflowchart TD\n  A@{ img: \"https://example.org/shape.png\", label: \"Shape\", w: 60, h: 60 }\n  A --> B\n```\n"
        let (web, window, _) = try await page(remote: false, note: note)
        defer { window.orderOut(nil) }
        var drawn = false
        for _ in 0..<60 where !drawn {
            try await Task.sleep(for: .milliseconds(150))
            drawn = try await web.evaluateJavaScript("!!document.querySelector('#note pre.mermaid svg')") as? Bool == true
        }
        #expect(drawn)
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('#note pre.mermaid image, #note pre.mermaid img').length") as? Int == 0)
        // Mermaid asks for a shape's picture itself, before the diagram is in the page: the source the
        // renderer did not clean is stopped by the page's policy.
        let probe = """
            return await new Promise(async (resolve) => {
              document.addEventListener('securitypolicyviolation', (event) => { if (event.blockedURI.includes('example.org')) resolve('refused') });
              setTimeout(() => resolve('nothing'), 3000);
              try { await window.mermaid.render('probe', source) } catch (error) {}
            })
            """
        let source = "flowchart TD\n  A@{ img: \"https://example.org/shape.png\", label: \"Shape\", w: 60, h: 60 }\n"
        #expect("\(try await web.callAsyncJavaScript(probe, arguments: ["source": source], in: nil, contentWorld: .page) ?? "")" == "refused")
    }

    /// The policy is the page's: a change of the setting loads the page again, and the note with it.
    @Test func aChangeOfTheSettingLoadsThePageAgain() async throws {
        let (web, window, store) = try await page(remote: true)
        defer { window.orderOut(nil) }
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('#note img').length") as? Int == 1)
        store.settings.remoteImages = false
        #expect(try await until(web, "document.querySelectorAll('#note .remote-image').length", is: "1") == "1")
        #expect(try await outcome(web, "https://example.org/missed.png") == "refused")
    }

    @Test func onThePictureIsShown() async throws {
        let (web, window, _) = try await page(remote: true)
        defer { window.orderOut(nil) }
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('#note .remote-image').length") as? Int == 0)
        #expect(try await web.evaluateJavaScript("document.querySelector('#note img')?.getAttribute('src') ?? ''") as? String
            == "https://example.org/chart.png")
    }
}
