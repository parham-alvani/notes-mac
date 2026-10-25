import AppKit
import DaftarCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// What the reader should show: a note, and where in it.
struct ReaderRequest: Equatable {
    var path: String
    var heading: String?
    var line: Int?
    /// Grows when the same note should be shown again.
    var generation = 0
}

/// The reading view: the note rendered by `web/src` in a web view, the same
/// renderer for every note, with Mermaid, KaTeX and code colours.
///
/// The page is served from two URL schemes and nothing else: `daftar:` for
/// the reader's own files in the app bundle, and `vault:` for the vault's
/// files, which is how an embedded image is loaded. The page cannot reach the
/// network or the rest of the disk.
struct ReaderView: NSViewRepresentable {
    var request: ReaderRequest?
    var store: VaultStore
    var onOpen: (_ path: String, _ anchor: String?, _ newWindow: Bool) -> Void
    var onTag: (String) -> Void
    var findText: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let schemes = SchemeHandler(store: store)
        configuration.setURLSchemeHandler(schemes, forURLScheme: "daftar")
        configuration.setURLSchemeHandler(schemes, forURLScheme: "vault")
        let controller = configuration.userContentController
        controller.add(context.coordinator, name: "daftar")
        controller.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "embed")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        #if DEBUG
        view.isInspectable = true
        #endif
        context.coordinator.view = view
        view.load(URLRequest(url: URL(string: "daftar://reader/index.html")!))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
        var parent: ReaderView
        weak var view: WKWebView?
        private var ready = false
        private var shown: ReaderRequest?
        private var shownRevision = -1
        private var shownSize = 0
        private var lastFind: String?

        init(_ parent: ReaderView) { self.parent = parent }

        /// Shows the requested note when it is new, or again when its file
        /// changed on disk, keeping the place the person was reading.
        func update() {
            guard ready, let request = parent.request else { return }
            let store = parent.store
            let changedOnDisk = store.revision != shownRevision && store.lastChanged.contains(request.path)
            let sizeChanged = store.settings.textSize != shownSize
            if request != shown {
                show(request, keepScroll: false)
            } else if changedOnDisk || sizeChanged || (shownRevision == -1) {
                show(request, keepScroll: true)
            }
            if store.revision != shownRevision { shownRevision = store.revision }
            if let find = parent.findText, find != lastFind {
                lastFind = find
                view?.callAsyncJavaScript("daftar.find(text)", arguments: ["text": find], in: nil, in: .page)
            }
        }

        private func show(_ request: ReaderRequest, keepScroll: Bool) {
            let store = parent.store
            shown = request
            shownRevision = store.revision
            shownSize = store.settings.textSize
            guard let text = store.text(of: request.path) else { return }
            let parsed = NoteParser.parse(text)
            var note: [String: Any] = [
                "path": request.path,
                "title": Vault.title(of: request.path),
                "text": text,
                "links": store.index.resolvedLinks(in: parsed, from: request.path),
                "properties": parsed.properties.filter { !Self.hidden.contains($0.key) }
                    .map { [$0.key, $0.values.joined(separator: ", ")] },
                "keepScroll": keepScroll,
                "textSize": store.settings.textSize,
            ]
            if !keepScroll {
                if let heading = request.heading { note["heading"] = heading }
                if let line = request.line { note["line"] = line }
            }
            view?.callAsyncJavaScript("await daftar.show(note)", arguments: ["note": note], in: nil, in: .page)
        }

        /// Front matter the reader does not print: the plugins' own keys.
        private static let hidden: Set<String> = ["cssclasses", "cssclass", "icon", "iconColor", "position"]

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {}

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
            switch kind {
            case "ready":
                ready = true
                shown = nil
                update()
            case "toggleTask":
                guard let request = shown, let line = body["line"] as? Int,
                    let status = (body["status"] as? String)?.first
                else { return }
                parent.store.toggleTask(path: request.path, line: line, status: status)
            case "open":
                let path = body["path"] as? String ?? ""
                let anchor = (body["anchor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let newWindow = body["newTab"] as? Bool ?? false
                if path.isEmpty {
                    NSSound.beep()
                    parent.store.notice = "“\(body["target"] as? String ?? "")” is not in the vault yet."
                } else {
                    parent.onOpen(path, anchor, newWindow)
                }
            case "tag":
                if let tag = body["tag"] as? String { parent.onTag(tag) }
            case "external":
                if let text = body["url"] as? String, let url = URL(string: text) { NSWorkspace.shared.open(url) }
            default:
                break
            }
        }

        /// `![[note]]`: the embedded note's text and links, for the page to render.
        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) async -> (Any?, String?) {
            guard let body = message.body as? [String: Any], let path = body["path"] as? String,
                let text = parent.store.text(of: path)
            else { return (nil, nil) }
            let parsed = NoteParser.parse(text)
            return (["text": text, "links": parent.store.index.resolvedLinks(in: parsed, from: path)], nil)
        }
    }
}

/// Serves `daftar://reader/…` from the app bundle and `vault:///…` from the
/// open vault. A vault path that leaves the vault is refused.
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    private let store: VaultStore

    init(store: VaultStore) { self.store = store }

    @MainActor
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let file: URL?
        switch url.scheme {
        case "daftar":
            file = Resources.reader?.appending(path: url.path.removingPrefixSlash)
        case "vault":
            let path = (url.path.removingPercentEncoding ?? url.path).removingPrefixSlash
            if let root = store.root?.standardizedFileURL {
                let candidate = root.appending(path: path).standardizedFileURL
                file = candidate.path.hasPrefix(root.path + "/") ? candidate : nil
            } else {
                file = nil
            }
        default:
            file = nil
        }
        guard let file, let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

enum Resources {
    /// The package's resource folder. In the app it is in
    /// `Contents/Resources`; under `swift run` it is next to the executable.
    static let folder: URL? = {
        let name = "Daftar_Daftar.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appending(path: name),
            Bundle.main.executableURL?.deletingLastPathComponent().appending(path: name),
        ]
        for case let bundle? in candidates {
            for inner in [bundle, bundle.appending(path: "Contents/Resources")]
            where FileManager.default.fileExists(atPath: inner.appending(path: "Reader/index.html").path) {
                return inner
            }
        }
        return nil
    }()

    static var reader: URL? { folder?.appending(path: "Reader") }

    /// The panda from Daftar's monochrome launcher icon, as a template image
    /// the menu bar tints.
    @MainActor static let menuBarIcon: NSImage? = {
        guard let url = folder?.appending(path: "Images/MenuBar.png"), let image = NSImage(contentsOf: url) else { return nil }
        if let retina = folder.flatMap({ NSImage(contentsOf: $0.appending(path: "Images/MenuBar@2x.png")) }),
            let rep = retina.representations.first
        {
            rep.size = NSSize(width: 18, height: 18)
            image.addRepresentation(rep)
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()
}

extension String {
    var removingPrefixSlash: String {
        var text = self
        while text.hasPrefix("/") { text.removeFirst() }
        return text
    }
}
