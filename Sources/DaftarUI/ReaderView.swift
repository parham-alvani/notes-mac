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
    var onEditTask: (String, Int) -> Void = { _, _ in }
    /// A click on a link to a note that is not there yet: make it.
    var onCreate: ((_ target: String, _ from: String) -> Void)?
    var findText: String?
    var findCommand = ReaderFind(action: .none, count: 0)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let schemes = SchemeHandler(store: store)
        configuration.setURLSchemeHandler(schemes, forURLScheme: "daftar")
        configuration.setURLSchemeHandler(schemes, forURLScheme: "vault")
        let controller = configuration.userContentController
        controller.add(context.coordinator, name: "daftar")
        controller.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "embed")
        controller.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "tasks")
        controller.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "base")
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
        private var shownSize = ""
        private var lastFind: String?
        private var lastFindCommand = 0
        /// The note on screen has a ` ```tasks ` block or a base.
        private var hasQuery = false
        /// Grows with each show, so a base that finishes late is dropped.
        private var showCount = 0

        init(_ parent: ReaderView) { self.parent = parent }

        /// Shows the requested note when it is new, or again when its file
        /// changed on disk, keeping the place the person was reading.
        func update() {
            guard ready, let request = parent.request else { return }
            let store = parent.store
            // A note with a tasks query shows tasks from every note, so any
            // change to a note can change it.
            let changedOnDisk = store.revision != shownRevision
                && (store.lastChanged.contains(request.path) || (hasQuery && store.lastChanged.contains(where: Vault.isNote)))
            let sizeChanged = "\(store.settings.textSize)|\(store.settings.font)|\(store.settings.codeFont)" != shownSize
            if request != shown {
                show(request, keepScroll: false)
            } else if changedOnDisk || sizeChanged || (shownRevision == -1) {
                show(request, keepScroll: true)
            }
            if store.revision != shownRevision { shownRevision = store.revision }
            if parent.findCommand.count != lastFindCommand {
                lastFindCommand = parent.findCommand.count
                if parent.findCommand.action != .none {
                    view?.window?.makeFirstResponder(view)
                    view?.callAsyncJavaScript(
                        "daftar.findCommand(action)", arguments: ["action": parent.findCommand.action.rawValue], in: nil, in: .page)
                }
            }
            if let find = parent.findText, find != lastFind {
                lastFind = find
                view?.callAsyncJavaScript("daftar.find(text)", arguments: ["text": find], in: nil, in: .page)
            }
        }

        private func show(_ request: ReaderRequest, keepScroll: Bool) {
            let store = parent.store
            hasQuery = false
            shown = request
            shownRevision = store.revision
            shownSize = "\(store.settings.textSize)|\(store.settings.font)|\(store.settings.codeFont)"
            showCount += 1
            guard let text = store.text(of: request.path) else { return }
            if Base.isBase(request.path) {
                showBase(request, source: text, keepScroll: keepScroll)
                return
            }
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
                "fontText": Fonts.css.text,
                "fontCode": Fonts.css.code,
            ]
            if !keepScroll {
                if let heading = request.heading { note["heading"] = heading }
                if let line = request.line { note["line"] = line }
            }
            view?.callAsyncJavaScript("await daftar.show(note)", arguments: ["note": note], in: nil, in: .page)
        }

        /// A `.base` file: its views in place of a note's text.
        private func showBase(_ request: ReaderRequest, source: String, keepScroll: Bool) {
            hasQuery = true
            let count = showCount
            let store = parent.store
            Task {
                let base = await runBase(source, context: request.path)
                guard count == showCount else { return }
                let note: [String: Any] = [
                    "path": request.path, "title": Vault.title(of: request.path), "text": "", "links": [String: String](),
                    "properties": [[String]](), "keepScroll": keepScroll, "base": base,
                    "textSize": store.settings.textSize, "fontText": Fonts.css.text, "fontCode": Fonts.css.code,
                ]
                _ = try? await view?.callAsyncJavaScript("await daftar.show(note)", arguments: ["note": note], in: nil, in: .page)
            }
        }

        /// Front matter the reader does not print: the plugins' own keys.
        private static let hidden: Set<String> = ["cssclasses", "cssclass", "icon", "iconColor", "position"]

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {}

        /// The page stays the reader: a note's `<meta http-equiv=refresh>` or
        /// `<form>` cannot take the window to a web page, which would then
        /// talk to the app. Links go out through the click handler instead.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            let scheme = action.request.url?.scheme ?? ""
            if action.targetFrame?.isMainFrame ?? true { return scheme == "daftar" ? .allow : .cancel }
            return scheme == "vault" || scheme == "about" ? .allow : .cancel
        }

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
                // The page is drawn from notes, so a path from it is checked:
                // only a note in the index can be written.
                // A task in a query result is in its own note.
                let path = (body["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? request.path
                parent.store.toggleTask(path: path, line: line, status: status)
            case "open":
                let path = body["path"] as? String ?? ""
                let anchor = (body["anchor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let newWindow = body["newTab"] as? Bool ?? false
                // A markdown link, `[x](Notes/a.md)`, names its note by path.
                let target = body["target"] as? String ?? ""
                if path.isEmpty, let from = shown?.path, let found = parent.store.index.resolve(target, from: from) {
                    parent.onOpen(found, anchor, newWindow)
                } else if path.isEmpty {
                    if let onCreate = parent.onCreate, let from = shown?.path, !target.isEmpty {
                        onCreate(target, from)
                    } else {
                        NSSound.beep()
                        parent.store.notice = "“\(target)” is not in the vault yet."
                    }
                } else if parent.store.index.files.contains(path) {
                    parent.onOpen(path, anchor, newWindow)
                }
            case "tag":
                if let tag = body["tag"] as? String { parent.onTag(tag) }
            case "editTask":
                guard let request = shown, let line = body["line"] as? Int else { return }
                let path = (body["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? request.path
                parent.onEditTask(path, line)
            case "copy":
                if let text = body["text"] as? String {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            case "external":
                // Web and mail only: a note's `file:`, `smb:` or
                // `shortcuts:` link would start an app or a script.
                guard let text = body["url"] as? String, let url = URL(string: text) else { return }
                if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(url)
                } else {
                    NSSound.beep()
                    parent.store.notice = "Daftar opens only web and mail links, not “\(url.scheme ?? text):” links."
                }
            default:
                break
            }
        }

        /// `![[note]]`: the embedded note's text and links, for the page to
        /// render; and a ` ```tasks ` block, answered from the index.
        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) async -> (Any?, String?) {
            guard let body = message.body as? [String: Any] else { return (nil, nil) }
            if message.name == "tasks" {
                hasQuery = true
                return (runQuery(body["source"] as? String ?? "", in: body["path"] as? String ?? ""), nil)
            }
            if message.name == "base" {
                // ` ```base ` in a note, or `![[file.base]]`; `this` is the note.
                hasQuery = true
                let context = body["context"] as? String ?? ""
                if let path = body["path"] as? String, !path.isEmpty {
                    guard parent.store.index.files.contains(path), let source = parent.store.text(of: path) else { return (nil, nil) }
                    return (await runBase(source, context: context), nil)
                }
                return (await runBase(body["source"] as? String ?? "", context: context), nil)
            }
            guard let path = body["path"] as? String, parent.store.index.files.contains(path), let text = parent.store.text(of: path)
            else { return (nil, nil) }
            let parsed = NoteParser.parse(text)
            return (["text": text, "links": parent.store.index.resolvedLinks(in: parsed, from: path)], nil)
        }
    }
}

extension ReaderView.Coordinator {
    /// The query's result as the page draws it: each task with the groups it
    /// is under, its note, its line, and the links its text needs.
    func runQuery(_ source: String, in path: String) -> [String: Any] {
        let index = parent.store.index
        let query = TasksQuery.parse(source, file: path)
        let found = query.run(index.tasks.sorted { ($0.path, $0.task.line) < ($1.path, $1.task.line) }, today: .today()) { QueryTask($0) }
        var links: [String: String] = [:]
        let tasks: [[String: Any]] = found.map { task in
            for link in NoteParser.parse(task.task.text).links where links[link.target] == nil {
                if let target = index.resolve(link.target, from: task.path) { links[link.target] = target }
            }
            var row: [String: Any] = [
                "path": task.path, "line": task.task.line, "status": String(task.task.status),
                "text": task.task.text, "title": Vault.title(of: task.path), "groups": query.groups(of: QueryTask(task)),
            ]
            row["due"] = task.task.due
            row["scheduled"] = task.task.scheduled
            row["done"] = task.task.done
            return row
        }
        return ["tasks": tasks, "notUnderstood": query.notUnderstood, "links": links]
    }
}

extension ReaderView.Coordinator {
    /// Every view of a base, as the page draws it.
    func runBase(_ source: String, context: String) async -> [String: Any] {
        let index = parent.store.index
        guard let root = parent.store.root else { return [:] }
        let (tables, problems) = await Task.detached {
            let engine = BaseEngine(index: index, types: BaseEngine.types(in: root)) { path in
                guard let values = try? root.appending(path: path).resourceValues(
                    forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
                else { return nil }
                return BaseEngine.Stat(
                    created: values.creationDate ?? .distantPast, modified: values.contentModificationDate ?? .distantPast,
                    size: values.fileSize ?? 0)
            }
            let tables = engine.run(Base.parse(source), context: context)
            return (tables, engine.problems)
        }.value
        let views: [[String: Any]] = tables.map { table in
            [
                "name": table.name, "type": table.type, "columns": table.columns, "count": table.count,
                "groups": table.groups.map { group -> [String: Any] in
                    var out: [String: Any] = [
                        "rows": group.rows.map { row -> [String: Any] in
                            ["path": row.path, "cells": row.cells.map(Self.json)]
                        }
                    ]
                    out["name"] = group.name
                    return out
                },
            ]
        }
        return ["views": views, "problems": problems]
    }

    private static func json(_ cell: BaseCell) -> [String: Any] {
        var out: [String: Any] = [
            "parts": cell.parts.map { part -> [String: Any] in
                var item: [String: Any] = ["text": part.text]
                item["path"] = part.path
                return item
            },
            "numeric": cell.numeric,
        ]
        out["check"] = cell.check
        return out
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
            // The page's own files; `url.path` is decoded already.
            file = Resources.reader.flatMap { VaultStore.file(url.path.removingPrefixSlash, in: $0) }
        case "vault":
            file = store.root.flatMap { VaultStore.file(url.path.removingPrefixSlash, in: $0) }
        default:
            file = nil
        }
        guard let file, let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        // A video or a sound is read in parts: `Range: bytes=start-end`.
        // A page or a picture with script in it runs with no rights of its own.
        let sandbox = ["text/html", "image/svg+xml", "application/xhtml+xml", "text/xml", "application/xml"].contains(type)
        let policy = url.scheme == "vault" && sandbox ? ["Content-Security-Policy": "sandbox; default-src 'none'; img-src vault: data:; style-src 'unsafe-inline'"] : [:]
        if let range = task.request.value(forHTTPHeaderField: "Range") {
            guard let (start, end) = Self.bytes(range, size: data.count) else {
                let headers = ["Content-Range": "bytes */\(data.count)"]
                task.didReceive(HTTPURLResponse(url: url, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: headers)!)
                task.didFinish()
                return
            }
            let headers = [
                "Content-Type": type, "Content-Length": String(end - start + 1), "Accept-Ranges": "bytes",
                "Content-Range": "bytes \(start)-\(end)/\(data.count)",
            ].merging(policy) { a, _ in a }
            task.didReceive(HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!)
            task.didReceive(data.subdata(in: start..<(end + 1)))
        } else {
            let headers = ["Content-Type": type, "Content-Length": String(data.count), "Accept-Ranges": "bytes"].merging(policy) { a, _ in a }
            task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
            task.didReceive(data)
        }
        task.didFinish()
    }

    /// `bytes=0-`, `bytes=100-199` or `bytes=-500`, inside a file of [size].
    static let chunk = 4 << 20

    static func bytes(_ header: String, size: Int) -> (Int, Int)? {
        guard size > 0, let match = header.wholeMatch(of: /bytes=(\d*)-(\d*)/) else { return nil }
        let first = Int(match.1), last = Int(match.2)
        let start: Int, end: Int
        switch (first, last) {
        case (let a?, let b?): (start, end) = (a, min(b, size - 1))
        // An open end is sent in parts: a whole film is not copied at once.
        case (let a?, nil): (start, end) = (a, min(size - 1, a + chunk - 1))
        case (nil, let b?): (start, end) = (max(0, size - b), size - 1)
        default: return nil
        }
        return start <= end && start < size ? (start, end) : nil
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

enum Resources {
    /// The package's resource folder. In the app it is in
    /// `Contents/Resources`; under `swift run` it is next to the executable.
    static let folder: URL? = {
        let name = "Daftar_DaftarUI.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appending(path: name),
            Bundle.main.executableURL?.deletingLastPathComponent().appending(path: name),
            // Under `swift test`, next to the test bundle.
            Bundle(for: VaultStore.self).bundleURL.deletingLastPathComponent().appending(path: name),
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
