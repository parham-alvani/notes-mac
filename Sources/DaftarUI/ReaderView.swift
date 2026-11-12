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
    /// Markdown to show in place of the note's text, with the note's links
    /// and pictures: a drill card's answer, or a preview of a note not
    /// written yet (the weekly review). Its lines are not the file's, so the
    /// page ticks no task of the note, keeps no folds and takes no keys.
    var text: String?
}

/// The reading view: the note rendered by `web/src` in a web view, the same
/// renderer for every note, with Mermaid, KaTeX and code colours.
///
/// The page is served from two URL schemes and nothing else: `daftar:` for
/// the reader's own files in the app bundle, and `vault:` for the vault's
/// files, which is how an embedded image is loaded. The page cannot reach the
/// network or the rest of the disk.
struct ReaderView: NSViewRepresentable {
    /// What every `daftar.show(note)` carries from the settings: the text's
    /// size, fonts and measure, the reading band, and whether pictures from
    /// the web are asked for (`docs/specs/remote-images.md` in notes-linux).
    @MainActor static func appearance(_ settings: AppSettings) -> [String: Any] {
        [
            "textSize": settings.textSize, "fontText": Fonts.css.text, "fontCode": Fonts.css.code,
            "readingLine": settings.readingLine, "textWidth": settings.textWidth, "remoteImages": settings.remoteImages,
        ]
    }

    /// The settings the note on screen was drawn with: a change to one draws it again.
    @MainActor static func shownKey(_ settings: AppSettings) -> String {
        "\(settings.textSize)|\(settings.font)|\(settings.codeFont)|\(settings.readingLine)|\(settings.textWidth)|\(settings.remoteImages)"
    }

    /// The reader's one page.
    static let page = URL(string: "daftar://reader/index.html")!

    var request: ReaderRequest?
    var store: VaultStore
    /// The store's revision, read where the view is made: a change of it
    /// is what calls `updateNSView` when a note changes on disk. Read only
    /// inside `updateNSView`, it did not on macOS 27.
    var revision = 0
    var onOpen: (_ path: String, _ anchor: String?, _ newWindow: Bool) -> Void
    /// ⌥-click on a link: the note opens in the other pane.
    var onOpenBeside: ((_ path: String, _ anchor: String?) -> Void)?
    var onTag: (String) -> Void
    var onEditTask: (String, Int) -> Void = { _, _ in }
    /// A click on a link to a note that is not there yet: make it.
    var onCreate: ((_ target: String, _ from: String) -> Void)?
    var findText: String?
    var findCommand = ReaderFind(action: .none, count: 0)
    /// The reading cursor moved to a source line.
    var onCursor: ((Int) -> Void)?
    /// `e` on a block: edit the note there.
    var onEdit: ((Int) -> Void)?
    /// The heading at the top of the window, by its line; nil above the first.
    var onSection: ((Int?) -> Void)?
    /// The web view, for the window's commands that act on the page.
    var onView: ((WKWebView) -> Void)?
    /// False while the pane's editor is over the reader: the page stays
    /// loaded, so going back to reading draws the note with no blank page,
    /// but it shows nothing new and takes no keys until it is back.
    var active = true
    /// The page drew the note it was given on coming back from the editor.
    var onShown: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        // A page loaded ahead when there is one: the reader shows its note
        // without waiting for WebKit's process and the page's script.
        let page = ReaderPages.shared.take(store: store)
        let coordinator = context.coordinator
        coordinator.remote = page.remote
        coordinator.loads = page.spare ? 0 : 1
        coordinator.loadedRemoteImages = page.remoteImages
        page.view.navigationDelegate = coordinator
        coordinator.view = page.view
        onView?(page.view)
        page.bridge.attach(coordinator)
        return page.view
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
        /// The editor was over the page at the last update.
        private var paused = false
        /// Back from the editor, the pane waits for the page's next drawing.
        private var revealing = false
        /// A `daftar.show` of a note is running.
        private var drawing = false
        /// Back from the editor, the editors are saving before the page draws.
        private var flushing = false
        /// The text of the note drawn last, to tell a change made while the
        /// editor was over the page.
        private var shownText: String?
        /// The addresses and numbers found in the text drawn last.
        private var lastDetected: (text: String, items: [Detected.Item])?
        private var shownSize = ""
        private var lastFind: String?
        private var lastFindCommand = 0
        /// The note on screen has a ` ```tasks ` block or a base.
        private var hasQuery = false
        /// Grows with each show, so a base that finishes late is dropped.
        private var showCount = 0
        /// What the page may name in a message, from what the app gave it for the note on screen.
        private(set) var trust = PageTrust()
        /// The pictures from the web the person asked for, in the note on screen.
        var remote = RemotePictures()
        /// `appearance.remote_images` when the page was loaded: its policy
        /// for pictures comes with the page, so a change loads it again.
        var loadedRemoteImages = true
        /// The loads of the page the app itself asked for and WebKit has not
        /// started yet: the first, and one for each time the page is loaded
        /// again. The main frame gets no other navigation.
        var loads = 1

        init(_ parent: ReaderView) { self.parent = parent }

        /// The page's script runs: the note is drawn from the start.
        func pageReady() {
            ready = true
            shown = nil
            update()
        }

        /// Shows the requested note when it is new, or again when its file
        /// changed on disk, keeping the place the person was reading.
        func update() {
            guard ready else { return }
            guard parent.active else {
                paused = true
                return
            }
            // Back from the editor: what it holds is saved first, so the
            // page draws what was typed; then the page takes the keys again,
            // as a new page did.
            if paused {
                paused = false
                revealing = true
                flushing = true
                let store = parent.store
                Task { @MainActor [weak self] in
                    await store.flushEditors()
                    guard let self else { return }
                    self.flushing = false
                    self.update()
                    self.takeKeys()
                }
                return
            }
            guard !flushing else { return }
            defer {
                // Nothing new to draw: what is on the page is right already.
                if revealing, !drawing {
                    revealing = false
                    parent.onShown?()
                }
            }
            let store = parent.store
            if store.settings.remoteImages != loadedRemoteImages {
                // The page's policy lets `https:` pictures in or not: it is the page's, so the page loads again.
                loadedRemoteImages = store.settings.remoteImages
                reload()
                return
            }
            guard let request = parent.request else { return }
            // A note with a tasks query shows tasks from every note, so any
            // change to a note can change it.
            let changedOnDisk = store.revision != shownRevision
                && (store.lastChanged.contains(request.path) || (hasQuery && store.lastChanged.contains(where: Vault.isNote)))
            let sizeChanged = ReaderView.shownKey(store.settings) != shownSize
            // Back from the editor at the same place: what was saved there
            // since is drawn, though it is no longer the last change.
            let changedWhileAway = store.revision != shownRevision && !changedOnDisk && !Vault.isImage(request.path)
                && (request.text ?? store.text(of: request.path)) != shownText
            if request != shown {
                show(request, keepScroll: false)
            } else if changedOnDisk || changedWhileAway || sizeChanged || (shownRevision == -1) {
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

        /// The page from the start: its policy changed, or its process ended.
        private func reload() {
            ready = false
            loads += 1
            view?.load(URLRequest(url: ReaderView.page))
        }

        private func show(_ request: ReaderRequest, keepScroll: Bool) {
            let store = parent.store
            drawing = false
            hasQuery = false
            trust = PageTrust()
            // A picture asked for in one note is not asked for in the next.
            if shown?.path != request.path { remote.forget() }
            shown = request
            shownRevision = store.revision
            shownSize = ReaderView.shownKey(store.settings)
            showCount += 1
            if Vault.isImage(request.path) {
                showImage(request, keepScroll: keepScroll)
                return
            }
            guard let text = request.text ?? store.text(of: request.path) else { return }
            shownText = text
            if Base.isBase(request.path) {
                showBase(request, source: text, keepScroll: keepScroll)
                return
            }
            if Canvas.isCanvas(request.path) {
                showCanvas(request, source: text, keepScroll: keepScroll)
                return
            }
            let parsed = Self.parsed(text, of: request, in: store)
            // The addresses and numbers in the text are looked for off the
            // main thread, after the note is on screen (tens of ms in a long
            // note), and given to the page when found. Coming back from the
            // editor draws the same text again: they are not looked for again.
            var detected: [Detected.Item] = []
            if let last = lastDetected, last.text == text {
                detected = last.items
            } else {
                findDetected(in: text, path: request.path, show: showCount)
            }
            trust.detected = Set(detected.map { PageTrust.Found(kind: $0.kind.rawValue, value: $0.value) })
            var note: [String: Any] = [
                "path": request.path,
                "title": request.text == nil ? Vault.title(of: request.path) : "",
                "text": text,
                "links": store.index.resolvedLinks(in: parsed, from: request.path),
                "properties": parsed.properties.filter { !Vault.hiddenProperties.contains($0.key) }
                    .map { [$0.key, $0.values.joined(separator: ", ")] },
                "keepScroll": keepScroll,
                "folds": request.text == nil ? store.places.folds(request.path) : [],
                "detected": detected.map { ["kind": $0.kind.rawValue, "text": $0.text, "value": $0.value] },
            ]
            note.merge(ReaderView.appearance(store.settings)) { $1 }
            // Text that is not the file's has no reading place to mark.
            if request.text != nil { note["readingLine"] = 0 }
            if !keepScroll {
                if let heading = request.heading { note["heading"] = heading }
                if let line = request.line { note["line"] = line }
            }
            drawing = true
            let count = showCount
            view?.callAsyncJavaScript("await daftar.show(note)", arguments: ["note": note], in: nil, in: .page) { [weak self] _ in
                guard let self, count == self.showCount else { return }
                self.drawing = false
                if self.revealing {
                    self.revealing = false
                    self.parent.onShown?()
                }
            }
            if !keepScroll, request.text == nil { takeKeys() }
        }

        /// The note's parse: the index's, when the file is the one the index
        /// read (its date is the same), else the text's own. Parsing a long
        /// note again took 3 to 25 ms of each opening.
        static func parsed(_ text: String, of request: ReaderRequest, in store: VaultStore) -> ParsedNote {
            if request.text == nil, let entry = store.index.notes[request.path],
                let modified = (try? store.url(of: request.path)?.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                modified == entry.modified
            {
                return entry.parsed
            }
            return NoteParser.parse(text)
        }

        /// Looks for the addresses and numbers in [text] off the main thread,
        /// then links them in the page, unless another note was shown since.
        private func findDetected(in text: String, path: String, show: Int) {
            Task { [weak self] in
                let items = await Task.detached(priority: .userInitiated) { Detected.find(in: text) }.value
                guard let self, show == self.showCount else { return }
                self.lastDetected = (text, items)
                guard !items.isEmpty else { return }
                self.trust.detected = Set(items.map { PageTrust.Found(kind: $0.kind.rawValue, value: $0.value) })
                self.view?.callAsyncJavaScript(
                    "daftar.detect(path, items)",
                    arguments: ["path": path, "items": items.map { ["kind": $0.kind.rawValue, "text": $0.text, "value": $0.value] }],
                    in: nil, in: .page)
            }
        }

        /// A note just opened gets the keys, so `j` and `k` move the reading
        /// cursor at once -- unless the person walks the sidebar with the
        /// arrows, which keeps them there.
        private func takeKeys() {
            guard let view, let window = view.window else { return }
            let responder = window.firstResponder
            // The arrows walking the sidebar's list keep the keys there; a
            // click, ⌘P or a link gives them to the page.
            let event = NSApp.currentEvent
            let walking = event?.type == .keyDown && (123...126).contains(event?.keyCode ?? 0)
                && (responder is NSTableView || responder is NSOutlineView)
            if walking { return }
            window.makeFirstResponder(view)
        }

        /// A `.base` file: its views in place of a note's text.
        private func showBase(_ request: ReaderRequest, source: String, keepScroll: Bool) {
            hasQuery = true
            let count = showCount
            let store = parent.store
            Task {
                let base = await runBase(source, context: request.path)
                guard count == showCount else { return }
                var note: [String: Any] = [
                    "path": request.path, "title": Vault.title(of: request.path), "text": "", "links": [String: String](),
                    "properties": [[String]](), "keepScroll": keepScroll, "base": base,
                ]
                note.merge(ReaderView.appearance(store.settings)) { $1 }
                view?.callAsyncJavaScript("await daftar.show(note)", arguments: ["note": note], in: nil, in: .page)
            }
        }

        /// A `.canvas` file: its board in place of a note's text. A note on
        /// the board can change, so any change to a note draws it again.
        private func showCanvas(_ request: ReaderRequest, source: String, keepScroll: Bool) {
            hasQuery = true
            let store = parent.store
            let canvas = Canvas.parse(source)
            let files = canvas.files(in: store.index, from: request.path)
            let nodes: [[String: Any]] = canvas.nodes.map { node in
                var out: [String: Any] = [
                    "id": node.id, "type": node.type, "x": node.x, "y": node.y, "width": node.width, "height": node.height,
                ]
                out["color"] = Canvas.color(node.color)
                out["text"] = node.text
                out["file"] = node.file
                out["path"] = files[node.id]
                out["subpath"] = node.subpath
                out["url"] = node.url
                out["label"] = node.label
                return out
            }
            let edges: [[String: Any]] = canvas.edges.map { edge in
                var out: [String: Any] = [
                    "id": edge.id, "fromNode": edge.fromNode, "toNode": edge.toNode, "fromEnd": edge.fromEnd, "toEnd": edge.toEnd,
                ]
                out["fromSide"] = edge.fromSide
                out["toSide"] = edge.toSide
                out["color"] = Canvas.color(edge.color)
                out["label"] = edge.label
                return out
            }
            var note: [String: Any] = [
                "path": request.path, "title": Vault.title(of: request.path), "text": "",
                "links": canvas.links(in: store.index, from: request.path),
                "properties": [[String]](), "keepScroll": keepScroll, "canvas": ["nodes": nodes, "edges": edges],
            ]
            note.merge(ReaderView.appearance(store.settings)) { $1 }
            view?.callAsyncJavaScript("await daftar.show(note)", arguments: ["note": note], in: nil, in: .page)
            if !keepScroll { takeKeys() }
        }

        /// A picture file: the page loads it from `vault:` and shows it with
        /// zoom. The page reads its pixel size; its size on disk and its kind
        /// come from here, and its date makes a changed file load again.
        private func showImage(_ request: ReaderRequest, keepScroll: Bool) {
            let store = parent.store
            let values = store.url(of: request.path).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) }
            let kind = UTType(filenameExtension: (request.path as NSString).pathExtension)
            let image: [String: Any] = [
                "size": values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "",
                "type": kind?.localizedDescription ?? (request.path as NSString).pathExtension.uppercased(),
                "version": "\(Int((values?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000))-\(values?.fileSize ?? 0)",
            ]
            var note: [String: Any] = [
                "path": request.path, "title": Vault.title(of: request.path), "text": "", "links": [String: String](),
                "properties": [[String]](), "keepScroll": keepScroll, "image": image,
            ]
            note.merge(ReaderView.appearance(store.settings)) { $1 }
            view?.callAsyncJavaScript("await daftar.show(note)", arguments: ["note": note], in: nil, in: .page)
            if !keepScroll { takeKeys() }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {}

        /// The page stays the reader. The main frame loads `index.html` when
        /// the app asks for it and nothing else, ever: not a web page, which
        /// would then talk to the app, and not another file of the bundle
        /// (`daftar://reader/reader.css`), which would leave the pane with a
        /// page that has no reader in it. Links go out through the click
        /// handler instead.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.targetFrame?.isMainFrame ?? true {
                guard loads > 0, action.request.url == ReaderView.page else { return .cancel }
                loads -= 1
                return .allow
            }
            let scheme = action.request.url?.scheme ?? ""
            return scheme == "vault" || scheme == "about" ? .allow : .cancel
        }

        /// The page's process ended (memory, a crash): the page loads again and shows the note.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            reload()
        }

        /// The app listens to the reader's page only: a frame holds a file of
        /// the vault (a PDF, a page someone saved), which has nothing to ask.
        func hears(mainFrame: Bool) -> Bool { mainFrame }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard hears(mainFrame: message.frameInfo.isMainFrame) else { return }
            guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
            switch kind {
            case "ready":
                pageReady()
            case "toggleTask":
                guard let request = shown, let line = body["line"] as? Int,
                    let status = (body["status"] as? String)?.first
                else { return }
                // The page is drawn from notes, so what it names is checked: the
                // note on screen, or a task a query of this show answered with.
                let path = (body["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? request.path
                guard trust.mayName(task: path, line: line, shown: request.path), request.text == nil || path != request.path else { return }
                parent.store.toggleTask(path: path, line: line, status: status)
            case "open":
                let path = body["path"] as? String ?? ""
                let anchor = (body["anchor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let newWindow = body["newTab"] as? Bool ?? false
                let beside = body["otherPane"] as? Bool ?? false
                let open = { (path: String) in
                    if beside, !newWindow, let onOpenBeside = self.parent.onOpenBeside {
                        onOpenBeside(path, anchor)
                    } else {
                        self.parent.onOpen(path, anchor, newWindow)
                    }
                }
                // A markdown link, `[x](Notes/a.md)`, names its note by path.
                let target = body["target"] as? String ?? ""
                if path.isEmpty, let from = shown?.path, let found = parent.store.index.resolve(target, from: from) {
                    open(found)
                } else if path.isEmpty {
                    if let onCreate = parent.onCreate, let from = shown?.path, !target.isEmpty {
                        onCreate(target, from)
                    } else {
                        NSSound.beep()
                        parent.store.notice = "“\(target)” is not in the vault yet."
                    }
                } else if parent.store.index.files.contains(path) {
                    open(path)
                }
            case "tag":
                if let tag = body["tag"] as? String { parent.onTag(tag) }
            case "detected":
                // Only a number or an address the app itself found in the note on screen.
                guard let kind = body["type"] as? String, let value = body["value"] as? String,
                    trust.detected.contains(PageTrust.Found(kind: kind, value: value))
                else { return }
                Detected.open(kind: kind, value: value)
            case "section":
                if let line = body["line"] as? Int { parent.onSection?(line < 0 ? nil : line) }
            case "stopSpeaking":
                ReadAloud.shared.stop()
            case "openExternal":
                // The picture on screen, never a path the page names.
                guard let path = shown?.path, Vault.isImage(path), let url = parent.store.url(of: path) else { return }
                NSWorkspace.shared.open(url)
            case "folds":
                if let shown, shown.text == nil, let folds = body["folds"] as? [String] { parent.store.places.setFolds(shown.path, folds) }
            case "cursor":
                if let line = body["line"] as? Int { parent.onCursor?(line) }
                if let path = shown?.path { WakaTime.shared.heartbeat(path, store: parent.store) }
            case "edit":
                if let line = body["line"] as? Int { parent.onEdit?(line) }
            case "editTask":
                guard let request = shown, let line = body["line"] as? Int else { return }
                let path = (body["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? request.path
                guard trust.mayName(task: path, line: line, shown: request.path), request.text == nil || path != request.path else { return }
                parent.onEditTask(path, line)
            case "copy":
                if let text = body["text"] as? String {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            case "external":
                // Web, mail and phone only (`Vault.outsideSchemes`).
                guard let text = body["url"] as? String, let url = URL(string: text) else { return }
                if Vault.leavesTheApp(url) {
                    NSWorkspace.shared.open(url)
                } else {
                    NSSound.beep()
                    parent.store.notice = "Daftar opens only web, mail and phone links, not “\(url.scheme ?? text):” links."
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
            guard hears(mainFrame: message.frameInfo.isMainFrame) else { return (nil, nil) }
            guard let body = message.body as? [String: Any] else { return (nil, nil) }
            if message.name == "remoteImage" {
                // A click on a placeholder: this one address may be asked for, by the way the page's policy lets in.
                guard let text = body["url"] as? String, let url = URL(string: text) else { return (nil, nil) }
                return (remote.allow(url)?.absoluteString, nil)
            }
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
        let statuses = index.statuses
        let found = query.run(index.tasksInOrder, today: .today()) { QueryTask($0, statuses: statuses) }
        var links: [String: String] = [:]
        let tasks: [[String: Any]] = found.map { task in
            trust.tasks.insert(PageTrust.Task(path: task.path, line: task.task.line))
            for link in NoteParser.parse(task.task.text).links where links[link.target] == nil {
                if let target = index.resolve(link.target, from: task.path) { links[link.target] = target }
            }
            var row: [String: Any] = [
                "path": task.path, "line": task.task.line, "status": String(task.task.status),
                "text": task.task.text, "title": Vault.title(of: task.path), "groups": query.groups(of: QueryTask(task, statuses: statuses)),
                "closed": statuses.isClosed(task.task.status),
            ]
            // A status of the vault's own is named; the reason follows the text.
            let status = statuses.status(task.task.status)
            if !status.isDefault { row["statusName"] = status.name }
            row["reason"] = task.task.reason
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
                "name": table.name, "type": table.type, "kind": table.kind, "layout": Self.json(table.layout),
                "columns": table.columns, "count": table.count,
                "groups": table.groups.map { group -> [String: Any] in
                    var out: [String: Any] = [
                        "rows": group.rows.map { row -> [String: Any] in
                            var out: [String: Any] = ["path": row.path, "cells": row.cells.map(Self.json)]
                            switch row.image {
                            case .file(let path): out["image"] = ["file": path]
                            case .url(let url): out["image"] = ["url": url]
                            case .color(let color): out["image"] = ["color": color]
                            case nil: break
                            }
                            return out
                        }
                    ]
                    out["name"] = group.name
                    return out
                },
            ]
        }
        return ["views": views, "problems": problems]
    }

    private static func json(_ layout: BaseLayout) -> [String: Any] {
        [
            "imageFit": layout.imageFit, "imageAspectRatio": layout.imageAspectRatio, "cardSize": layout.cardSize,
            "markers": layout.markers, "indentProperties": layout.indentProperties, "separator": layout.separator,
        ]
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

/// The reader's pages, each a web view with the page loaded: the next
/// reader takes one made ahead, while the app had nothing to do, so a second
/// pane, a drill card or the weekly review shows its note without waiting for
/// WebKit's process and the page's script (about 150 to 300 ms). One is
/// kept, for the store it was made for, with the policy for pictures from
/// the web it was loaded with; a test makes its pages as it needs them.
@MainActor
final class ReaderPages {
    static let shared = ReaderPages()

    struct Page {
        let view: WKWebView
        let bridge: ReaderBridge
        let remote: RemotePictures
        let remoteImages: Bool
        /// Made ahead and loaded already.
        var spare = false
    }

    /// Pages are made ahead in the app only, not under `swift test`.
    var ahead = Bundle.main.bundlePath.hasSuffix(".app")
    private var spare: (page: Page, store: VaultStore)?
    private var filling: Task<Void, Never>?

    /// A page for a reader of [store]: the one made ahead when it fits, else a new one.
    func take(store: VaultStore) -> Page {
        defer { fill(store) }
        if let spare, spare.store === store, spare.page.bridge.ready, spare.page.remoteImages == store.settings.remoteImages {
            self.spare = nil
            return spare.page
        }
        return make(store: store)
    }

    /// One page made ahead, once the app is idle for a moment.
    private func fill(_ store: VaultStore) {
        guard ahead, filling == nil else { return }
        filling = Task { [weak self, weak store] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, let store else { return }
            self.filling = nil
            if let spare = self.spare, spare.store === store, spare.page.remoteImages == store.settings.remoteImages { return }
            var page = self.make(store: store)
            page.spare = true
            self.spare = (page, store)
        }
    }

    private func make(store: VaultStore) -> Page {
        let configuration = WKWebViewConfiguration()
        let remote = RemotePictures()
        let schemes = SchemeHandler(store: store, remote: remote)
        configuration.setURLSchemeHandler(schemes, forURLScheme: "daftar")
        configuration.setURLSchemeHandler(schemes, forURLScheme: "vault")
        configuration.setURLSchemeHandler(schemes, forURLScheme: RemotePictures.scheme)
        let bridge = ReaderBridge()
        let controller = configuration.userContentController
        controller.add(bridge, name: "daftar")
        for name in ["embed", "tasks", "base", "remoteImage"] {
            controller.addScriptMessageHandler(bridge, contentWorld: .page, name: name)
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = bridge
        view.setValue(false, forKey: "drawsBackground")
        #if DEBUG
        view.isInspectable = true
        #endif
        let remoteImages = store.settings.remoteImages
        view.load(URLRequest(url: ReaderView.page))
        return Page(view: view, bridge: bridge, remote: remote, remoteImages: remoteImages)
    }
}

/// The page's messages, to the reader that took the page. Until one does,
/// it notes only that the page is ready, which it tells the reader when it
/// comes. It holds the reader weakly: WebKit keeps its handlers.
@MainActor
final class ReaderBridge: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    private weak var coordinator: ReaderView.Coordinator?
    private(set) var ready = false

    /// A page made ahead whose process ended is not given to a reader.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
    }

    func attach(_ coordinator: ReaderView.Coordinator) {
        self.coordinator = coordinator
        if ready { coordinator.pageReady() }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let coordinator { return coordinator.userContentController(controller, didReceive: message) }
        guard message.frameInfo.isMainFrame, (message.body as? [String: Any])?["kind"] as? String == "ready" else { return }
        ready = true
        // Nobody waits for this page yet: it draws a made-up note, so the first real one is drawn warm.
        message.webView?.callAsyncJavaScript("daftar.warm()", arguments: [:], in: nil, in: .page)
    }

    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        guard let coordinator else { return (nil, nil) }
        return await coordinator.userContentController(controller, didReceive: message)
    }
}

/// What the page may name when it asks the app to act. The page is drawn
/// from notes, so a path, a line or a phone number in a message is only
/// taken when the app itself gave it to the page for the note on screen: a
/// task of another note when a ` ```tasks ` query of this show answered with
/// it, a number or an address when `Detected` found it in the note.
struct PageTrust {
    struct Task: Hashable {
        var path: String
        var line: Int
    }

    struct Found: Hashable {
        var kind: String
        var value: String
    }

    /// The tasks the queries of this show answered with.
    var tasks: Set<Task> = []
    /// The phone numbers and addresses found in the note on screen.
    var detected: Set<Found> = []

    /// A task of the note on screen, or one a query of this show listed.
    func mayName(task path: String, line: Int, shown: String) -> Bool {
        path == shown || tasks.contains(Task(path: path, line: line))
    }
}

/// Serves `daftar://reader/…` from the app bundle and `vault:///…` from the
/// open vault. A vault path that leaves the vault is refused.
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    private let store: VaultStore
    private let remote: RemotePictures

    init(store: VaultStore, remote: RemotePictures) {
        self.store = store
        self.remote = remote
    }

    /// The policy `index.html` gets on top of its own while pictures from
    /// the web are off: no `https:` picture, so one the renderer missed is
    /// refused by the page before any site is asked. A picture the person
    /// clicked comes through `daftar-remote:`, which serves only what
    /// `RemotePictures` allowed.
    static let noRemotePictures = "img-src 'self' vault: data: \(RemotePictures.scheme):"

    @MainActor
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        if url.scheme == RemotePictures.scheme {
            remote.serve(task)
            return
        }
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
        let sandbox = Self.isDocument(type)
        var policy = url.scheme == "vault" && sandbox ? ["Content-Security-Policy": "sandbox; default-src 'none'; img-src vault: data:; style-src 'unsafe-inline'"] : [:]
        if url.scheme == "daftar", url.path == ReaderView.page.path, !store.settings.remoteImages {
            policy["Content-Security-Policy"] = Self.noRemotePictures
        }
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

    /// Whether WebKit shows a file of this type as a document, which can
    /// hold script: HTML, a web archive, and every kind of XML (a feed and
    /// an SVG are XML that may carry XHTML's `<script>`). By rule, not by a
    /// list of types: a type nobody listed is the one that gets through.
    static func isDocument(_ type: String) -> Bool {
        let type = type.lowercased()
        return type == "text/html" || type.contains("xml") || type.contains("webarchive") || type == "multipart/related"
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

    @MainActor
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        remote.stop(task)
    }
}

/// The pictures from the web a person asked for while `appearance.remote_images`
/// is off (`docs/specs/remote-images.md` in notes-linux). The page's policy
/// then lets no `https:` picture in, so a click on a placeholder asks the app:
/// the app notes that one address and gives back a `daftar-remote:` address
/// for it, which this serves by asking the site itself. An address nobody
/// clicked is refused here, so nothing the page holds can ask a site by
/// writing a `daftar-remote:` address of its own.
@MainActor
final class RemotePictures {
    nonisolated static let scheme = "daftar-remote"

    private var allowed: Set<URL> = []
    private var running: [ObjectIdentifier: URLSessionDataTask] = [:]
    /// No cookies, no cache on disk: a picture asked for tells the site one thing, that it was asked for.
    private lazy var session = URLSession(configuration: .ephemeral)

    /// The site address a `daftar-remote:` address stands for: `https:` only.
    nonisolated static func target(of url: URL) -> URL? {
        guard url.scheme == scheme,
            let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
            let target = URL(string: text), target.scheme?.lowercased() == "https", target.host != nil
        else { return nil }
        return target
    }

    /// The `daftar-remote:` address of [target], an `https:` picture.
    nonisolated static func address(for target: URL) -> URL? {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "picture"
        parts.path = "/"
        parts.queryItems = [URLQueryItem(name: "url", value: target.absoluteString)]
        return parts.url
    }

    /// The person clicked the placeholder of [target]: the address the page loads it from, or nil when it is no `https:` picture.
    func allow(_ target: URL) -> URL? {
        guard target.scheme?.lowercased() == "https", target.host != nil, let address = Self.address(for: target) else { return nil }
        allowed.insert(target)
        return address
    }

    func allows(_ target: URL) -> Bool { allowed.contains(target) }

    /// Another note is shown: what was asked for in the last one is not asked for again.
    func forget() { allowed = [] }

    func serve(_ task: any WKURLSchemeTask) {
        guard let url = task.request.url, let target = Self.target(of: url), allowed.contains(target) else {
            task.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        let id = ObjectIdentifier(task)
        nonisolated(unsafe) let task = task
        let load = session.dataTask(with: URLRequest(url: target)) { data, response, error in
            let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? response?.mimeType ?? ""
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            Task { @MainActor in
                // A task the page stopped must not be answered: WebKit throws.
                guard self.running.removeValue(forKey: id) != nil else { return }
                guard let data, error == nil, status == 200, type.lowercased().hasPrefix("image/") else {
                    task.didFailWithError(error ?? URLError(.badServerResponse))
                    return
                }
                let headers = ["Content-Type": type, "Content-Length": String(data.count)]
                task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
                task.didReceive(data)
                task.didFinish()
            }
        }
        running[id] = load
        load.resume()
    }

    func stop(_ task: any WKURLSchemeTask) {
        running.removeValue(forKey: ObjectIdentifier(task))?.cancel()
    }
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
