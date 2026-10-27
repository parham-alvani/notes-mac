import AppKit
import DaftarCore
import Observation
import SwiftUI
import WebKit

/// One note pane of a window: the note, in the reader or the editor, and
/// where the pane has been. A window has one, or two after Split Right.
@MainActor @Observable
final class NotePane: Identifiable {
    var request: ReaderRequest? {
        // The note left, and the note shown, are both read as they are now.
        didSet {
            guard oldValue?.path != request?.path else { return }
            if let old = oldValue?.path { places.markRead(old) }
            if let path = request?.path { places.markRead(path) }
        }
    }
    /// The note is open in the editor rather than the reader.
    var editing = false {
        // Back to reading: the reader opens where the editor's cursor was.
        didSet {
            guard oldValue, !editing, let line = cursorLine, var next = request else { return }
            next.line = line
            next.heading = nil
            next.generation += 1
            request = next
        }
    }
    /// The source line the reading cursor or the editor's cursor is on, so
    /// the other one opens there.
    @ObservationIgnored var cursorLine: Int? {
        didSet { if let path, let cursorLine { places[path] = cursorLine } }
    }
    /// The window's reading places.
    @ObservationIgnored var places = PlaceBook()
    /// Set to select the text in the reader after a search hit opens.
    var findText: String?
    /// The last Find command for the reader; it grows with each one.
    var readerFind = ReaderFind(action: .none, count: 0)
    /// The line of the heading the reader or the editor's cursor is in, for the outline.
    var section: Int?
    /// Headings renamed in the editor, whose links the pane offers to update.
    var headingOffer: HeadingRename.Change?
    /// Set by a click in the outline: the editor's cursor goes to the line.
    var editorJump: EditorJump?
    /// The reader's page, for read aloud and Export as PDF.
    @ObservationIgnored weak var readerView: WKWebView?

    private var back: [ReaderRequest] = []
    private var forward: [ReaderRequest] = []

    var path: String? { request?.path }
    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    func open(_ path: String, heading: String? = nil, line: Int? = nil) {
        // A note opens where it was being read, unless a link names a place in it.
        let line = line ?? (heading == nil ? places[path] : nil)
        var next = ReaderRequest(path: path, heading: heading, line: line)
        if let current = request {
            if current.path == path { next.generation = current.generation + 1 }
            back.append(current)
        }
        forward.removeAll()
        request = next
        cursorLine = line
    }

    /// The home page: no note. Back returns to the note that was open.
    func goHome() {
        guard let current = request else { return }
        back.append(current)
        forward.removeAll()
        request = nil
        editing = false
    }

    /// The note of a new pane: [request], with no history.
    func show(_ request: ReaderRequest) {
        self.request = ReaderRequest(path: request.path, line: places[request.path] ?? request.line)
        cursorLine = self.request?.line
    }

    func goBack() {
        guard let previous = back.popLast() else { return }
        if let request { forward.append(request) }
        request = returning(to: previous)
    }

    func goForward() {
        guard let next = forward.popLast() else { return }
        if let request { back.append(request) }
        request = returning(to: next)
    }

    /// A note from the history, at the place it was left.
    private func returning(to request: ReaderRequest) -> ReaderRequest {
        var request = request
        if let place = places[request.path] {
            request.line = place
            request.heading = nil
        }
        cursorLine = request.line
        return request
    }

    /// After files moved: the note on screen and the history follow them.
    func follow(_ moves: [String: String]) {
        func moved(_ request: ReaderRequest) -> ReaderRequest {
            guard let new = moves[request.path] else { return request }
            var next = request
            next.path = new
            return next
        }
        if let request { self.request = moved(request) }
        back = back.map(moved)
        forward = forward.map(moved)
    }

    /// After a delete: a note that is gone is no longer shown.
    func forget(where gone: (String) -> Bool) {
        back.removeAll { gone($0.path) }
        forward.removeAll { gone($0.path) }
        if let current = request, gone(current.path) {
            request = nil
            editing = false
        }
    }
}

/// The window's note panes: one, or two side by side after View › Split Right.
///
/// Not `HSplitView`: its panes did not fill the window's height, and a pane's
/// size limits changed in a layout pass made AppKit throw and quit the app.
struct NotePanes: View {
    var model: WindowModel
    /// The first pane's share of the width; the divider drags it.
    @ViewState private var fraction = 0.5
    @ViewState private var dragStart: Double?

    private static let minWidth = 280.0

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            HStack(spacing: 0) {
                ForEach(Array(model.panes.enumerated()), id: \.element.id) { index, pane in
                    if index > 0 { divider(width: width) }
                    NotePaneView(model: model, pane: pane)
                        .frame(width: model.isSplit ? paneWidth(index, of: width) : nil)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func paneWidth(_ index: Int, of width: Double) -> Double {
        let room = max(width - 1, 0)
        let first = room * clamped(fraction, width: room)
        return index == 0 ? first : room - first
    }

    private func clamped(_ value: Double, width: Double) -> Double {
        guard width > 2 * Self.minWidth else { return 0.5 }
        return min(max(value, Self.minWidth / width), 1 - Self.minWidth / width)
    }

    private func divider(width: Double) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in inside ? NSCursor.columnResize.push() : NSCursor.pop() }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = dragStart ?? fraction
                                dragStart = start
                                fraction = clamped(start + drag.translation.width / max(width - 1, 1), width: width - 1)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
            .accessibilityHidden(true)
    }
}

/// A pane on screen: the note in the editor or the reader, or the home
/// page when none is open. In a split window, the focused pane has an accent line
/// along its top, and each pane a button to close it.
struct NotePaneView: View {
    var model: WindowModel
    var pane: NotePane
    @Environment(VaultStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        content
            .overlay(alignment: .top) {
                if model.isSplit && model.focused === pane {
                    Rectangle().fill(Palette.accent).frame(height: 2).allowsHitTesting(false)
                }
            }
            // A click anywhere in the pane gives it the focus, before the
            // click itself does anything there.
            .background(PaneClicks { [weak model, weak pane] in
                if let model, let pane { model.focus(pane) }
            })
            .overlay(alignment: .bottom) {
                if let offer = pane.headingOffer {
                    HeadingLinksBanner(change: offer) { pane.headingOffer = nil }.id(offer)
                }
            }
            // The accent line is the focus for the eye; VoiceOver hears it.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(paneName)
    }

    /// "Left pane, focused" in a split window; the note's name otherwise.
    private var paneName: String {
        guard model.isSplit else { return pane.path.map(Vault.title(of:)) ?? "Home" }
        let side = model.panes.first === pane ? "Left pane" : "Right pane"
        return model.focused === pane ? side + ", focused" : side
    }

    private var onClose: (() -> Void)? {
        model.isSplit ? { [weak model, weak pane] in if let model, let pane { model.close(pane) } } : nil
    }

    @ViewBuilder private var content: some View {
        if let path = pane.path, pane.editing {
            EditorView(path: path, store: store, line: pane.cursorLine, onCursor: { line in
                pane.cursorLine = line
                // The outline marks the section the cursor is in.
                let headings = store.index.notes[path]?.parsed.headings ?? []
                pane.section = Sections.heading(at: line, in: headings).map { headings[$0].line }
            }, onExtract: { text, replace in
                model.focus(pane)
                model.extractReplace = replace
                model.fileAction = .extract(folder: model.currentFolder, text: text)
            }, onHeadingsRenamed: { pane.headingOffer = $0 }, jump: pane.editorJump)
            .safeAreaInset(edge: .top, spacing: 0) { PropertiesView(path: path) }
            .safeAreaInset(edge: .top, spacing: 0) { Breadcrumb(path: path, model: model, onClose: onClose) }
        } else if pane.request != nil {
            ReaderView(
                request: pane.request, store: store,
                onOpen: { path, anchor, newWindow in
                    if newWindow {
                        openWindow(value: TabRequest(path: path))
                    } else {
                        model.open(path, heading: anchor, in: pane, store: store)
                    }
                },
                onOpenBeside: { path, anchor in model.openInOtherPane(path, heading: anchor, from: pane, store: store) },
                onTag: { model.searchTag($0) },
                onEditTask: { model.taskEdit = TaskRef(path: $0, line: $1) },
                onCreate: { target, from in
                    do {
                        let path = try store.createNote(forLink: target, from: from)
                        model.open(path, in: pane, store: store)
                        model.setEditing(true, in: pane)
                    } catch {
                        store.notice = (error as? VaultMoves.Failure)?.description ?? error.localizedDescription
                    }
                },
                findText: pane.findText,
                findCommand: pane.readerFind,
                onCursor: { pane.cursorLine = $0 },
                onEdit: { line in
                    pane.cursorLine = line
                    model.focus(pane)
                    model.setEditing(true, in: pane)
                },
                onSection: { pane.section = $0 },
                onView: { pane.readerView = $0 })
            .safeAreaInset(edge: .top, spacing: 0) {
                if let path = pane.path { Breadcrumb(path: path, model: model, onClose: onClose) }
            }
        } else {
            HomeView(model: model, pane: pane, compact: model.isSplit)
            .overlay(alignment: .topTrailing) {
                if let onClose { PaneCloseButton(action: onClose).padding(8) }
            }
        }
    }
}

/// The small button that closes one pane of a split window.
struct PaneCloseButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Close this pane (⌘\\)")
            .accessibilityLabel("Close Pane")
    }
}

/// Calls [action] when a mouse button goes down inside this view's frame.
/// The view lies behind a pane, so the reader's web view and the editor
/// keep their clicks; a local monitor sees each click first.
struct PaneClicks: NSViewRepresentable {
    var action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.action = action
        context.coordinator.start()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { context.coordinator.action = action }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var action: () -> Void = {}
        private var monitor: Any?

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                // Local monitors run on the main thread, with the event loop.
                nonisolated(unsafe) let event = event
                MainActor.assumeIsolated { self?.clicked(event) }
                return event
            }
        }

        func clicked(_ event: NSEvent) {
            guard let view, let window = view.window, event.window === window else { return }
            if view.bounds.contains(view.convert(event.locationInWindow, from: nil)) { action() }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
