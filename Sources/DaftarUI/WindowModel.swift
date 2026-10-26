import AppKit
import DaftarCore
import Observation
import SwiftUI
import WebKit

/// What one window is showing, and where it has been.
@MainActor @Observable
final class WindowModel {
    /// What the detail column shows: a page, Today or the board, or else
    /// the note in [request].
    var page: Page?
    var showsToday: Bool {
        get { page == .today }
        set { page = newValue ? .today : (page == .today ? nil : page) }
    }
    var showsBoard: Bool {
        get { page == .board }
        set { page = newValue ? .board : (page == .board ? nil : page) }
    }
    /// A page, not a note, is on screen.
    var showsPage: Bool { page != nil }
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
    /// Where each note was being read, for the next time it opens: the
    /// store's, once the window shows (`ContentView`), kept across launches.
    @ObservationIgnored var places = PlaceBook()
    /// The sidebar's search field; while it holds text the sidebar lists hits.
    var query = ""
    var quickOpen = false {
        didSet {
            if quickOpen { quickOpenRequests += 1 } else { stopHoldingKeys() }
        }
    }
    /// Grows with each ⌘P, so a press while the panel is open can refocus it.
    var quickOpenRequests = 0
    /// The switcher's text. It lives here, not in the panel, so the keys
    /// typed before the panel's field has the focus are kept in it.
    var switcherQuery = ""
    /// Return was pressed before the field had the focus.
    var switcherSubmit = false
    @ObservationIgnored var switcherFieldFocused = false
    @ObservationIgnored private var keyMonitor: Any?

    /// ⌘P. The panel is a sheet, which takes about 300 ms to appear; the
    /// keys typed in that time went to the window behind it -- lost in the
    /// reader, typed into the note in the editor -- and a fast "kub" was
    /// searched as "b". Until the field has the focus, the keys are held
    /// for it: letters go into its text, Escape closes it, Return opens the
    /// first result once there is one.
    func openSwitcher() {
        // ⌘P again while the panel is open starts a new search there, as a
        // fresh panel would; the focus goes back to its field.
        if quickOpen {
            switcherQuery = ""
            quickOpen = true
            return
        }
        switcherQuery = ""
        switcherSubmit = false
        switcherFieldFocused = false
        quickOpen = true
        stopHoldingKeys()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread, with the event loop.
            nonisolated(unsafe) let event = event
            let held = MainActor.assumeIsolated { self?.hold(event) ?? .pass }
            return held == .pass ? event : nil
        }
    }

    enum Held { case pass, kept }

    private func hold(_ event: NSEvent) -> Held {
        guard quickOpen, !switcherFieldFocused else { return .pass }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) { return .pass }
        switch event.keyCode {
        case 53:
            quickOpen = false
        case 36, 76:
            switcherSubmit = true
        case 51:
            if !switcherQuery.isEmpty { switcherQuery.removeLast() }
        default:
            let text = event.characters ?? ""
            // Letters only: arrows and the function keys are in the private area.
            if !text.isEmpty, text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }) {
                switcherQuery += text
            }
        }
        return .kept
    }

    func stopHoldingKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        switcherFieldFocused = false
    }
    /// ⇧⌘P, the command palette, and the commands used last, first.
    var palette = false
    var recentCommands: [String] = []
    /// The graph of the open note and its neighbours.
    var graph = false
    /// ⌥⌘A: Apple Intelligence on the open note.
    var assistant = false
    /// The open note's history in the vault's repository.
    var history = false
    /// "Rename Tag…": the tag whose sheet is open.
    var tagRename: TagTarget?
    /// "Set Icon…": the note or folder the icon picker is open on.
    var iconTarget: IconTarget?
    /// ⌃⌘T: the text the system's translation panel shows.
    var translation: String?

    /// The selection in the editor or the reader, or else the whole note,
    /// for the translation panel.
    func translate(store: VaultStore) {
        Task {
            if let selected = await Self.selectedText(), !selected.isEmpty {
                translation = selected
            } else if let path, let text = store.text(of: path) {
                translation = Self.withoutProperties(text)
            }
        }
    }

    /// A note's text without its properties block.
    static func withoutProperties(_ text: String) -> String {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) else {
            return text
        }
        return String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func selectedText() async -> String? {
        var view = NSApp.keyWindow?.firstResponder as? NSView
        if let text = view as? NSTextView {
            let range = text.selectedRange()
            return range.length > 0 ? (text.string as NSString).substring(with: range) : nil
        }
        while let current = view, !(current is WKWebView) { view = current.superview }
        guard let web = view as? WKWebView else { return nil }
        return try? await web.evaluateJavaScript("getSelection().toString()") as? String
    }
    /// The task whose edit form is open.
    var taskEdit: TaskRef?
    /// After an extract: puts the new note's link where the selection was.
    @ObservationIgnored var extractReplace: ((String) -> Void)?
    var inspector = true
    /// The terminal pane under the note.
    var terminal = false
    @ObservationIgnored let terminalSession = TerminalSession()
    /// Set to select the text in the reader after a search hit opens.
    var findText: String?
    /// The file command whose sheet is open: a new note, a rename, a move.
    var fileAction: FileAction?
    /// The last Find command for the reader; it grows with each one.
    var readerFind = ReaderFind(action: .none, count: 0)
    /// The line of the heading the reader is in, for the outline.
    var section: Int?
    /// The reader's page, for read aloud and Export as PDF.
    @ObservationIgnored weak var readerView: WKWebView?

    private var back: [ReaderRequest] = []
    private var forward: [ReaderRequest] = []
    private(set) var recent: [String] = []

    var path: String? { request?.path }
    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    func open(_ path: String, heading: String? = nil, line: Int? = nil, store: VaultStore) {
        guard Vault.opensInApp(path) else {
            // An attachment opens in the app the system gives it to.
            if let url = store.url(of: path) { NSWorkspace.shared.open(url) }
            return
        }
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
        page = nil
        recent.removeAll { $0 == path }
        recent.insert(path, at: 0)
        if recent.count > 30 { recent.removeLast() }
    }

    /// The open note read aloud, or the voice stopped.
    func readAloud() {
        guard let path, !showsPage, let view = readerView else { return }
        if editing { editing = false }
        ReadAloud.shared.toggle(path, in: view)
    }

    /// The open note as a PDF on A4, Daylight and unfolded, where the person chooses.
    func exportPDF() {
        guard let path, !showsPage, !editing, let view = readerView, let window = view.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = Vault.title(of: path) + ".pdf"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            info.paperSize = NSSize(width: 595.28, height: 841.89)
            info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
            let operation = view.printOperation(with: info)
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            operation.view?.frame = view.bounds
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        }
    }

    /// The periodic note of [day]'s period, made when it is not there yet.
    /// The open note's tasks sorted as the vault's Task Sorter plugin does:
    /// in the editor as a step to undo, else in the file.
    func sortTasks(store: VaultStore) {
        guard let path, !showsPage else { return }
        if editing {
            NSApp.sendAction(#selector(NoteTextView.sortTasks(_:)), to: nil, from: nil)
        } else if !store.sortTasks(path) {
            store.notice = "The tasks are in order already."
        }
    }

    func openPeriodicNote(for day: Day = .today(), store: VaultStore) {
        do {
            open(try store.periodicNote(for: day), store: store)
        } catch {
            store.notice = (error as? VaultMoves.Failure)?.description ?? error.localizedDescription
        }
    }

    /// The periodic note nearest to the open one in the direction of [step], when there is one.
    func periodicNeighbour(_ step: Int, store: VaultStore) -> String? {
        guard !showsPage, let path else { return nil }
        return store.periodic.nearest(store.index.files, from: path, step: step)
    }

    func goBack() {
        guard let previous = back.popLast() else { return }
        if let request { forward.append(request) }
        request = returning(to: previous)
        page = nil
    }

    func goForward() {
        guard let next = forward.popLast() else { return }
        if let request { back.append(request) }
        request = returning(to: next)
        page = nil
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

    /// `daftar://open?path=Folder/Note.md[&mode=edit]`, which the
    /// notifications use, `daftar://open?path=today`, and `daftar://terminal`.
    func handle(_ url: URL, store: VaultStore) {
        guard url.scheme == "daftar" else { return }
        if url.host == "terminal" {
            terminal = true
            return
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard url.host == "open", let path = items.first(where: { $0.name == "path" })?.value else { return }
        if path == "today" || path == "board" {
            page = path == "today" ? .today : .board
            return
        }
        open(path, store: store)
        editing = items.contains { $0.name == "mode" && $0.value == "edit" }
    }

    func searchTag(_ tag: String) {
        query = "#" + tag
    }

    /// Edit › Find: the editor's own find bar, or the reader's.
    func find(_ action: NSTextFinder.Action) {
        guard !showsPage, path != nil else { return }
        if editing {
            let item = NSMenuItem()
            item.tag = action.rawValue
            NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: item)
        } else {
            let kind: ReaderFind.Action = switch action {
            case .nextMatch: .next
            case .previousMatch: .previous
            default: .open
            }
            readerFind = ReaderFind(action: kind, count: readerFind.count + 1)
        }
    }

    /// The folder a new note goes in: the open note's, as Obsidian's
    /// "new file location: current" does.
    var currentFolder: String {
        guard let path, !showsPage else { return "" }
        return path.split(separator: "/").dropLast().joined(separator: "/")
    }

    /// After files moved: the note on screen, the history and the recent
    /// list follow them.
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
        recent = recent.map { moves[$0] ?? $0 }
    }

    /// A move or a delete, made in this window or another one.
    func follow(_ change: VaultChange) {
        switch change {
        case .moved(let moves, _): follow(moves)
        case .deleted(let path): forget(path)
        }
    }

    /// After a delete: a note that is gone is no longer shown.
    func forget(_ path: String) {
        let gone = { (other: String) in other == path || other.hasPrefix(path + "/") }
        back.removeAll { gone($0.path) }
        forward.removeAll { gone($0.path) }
        recent.removeAll(where: gone)
        if let current = request, gone(current.path) {
            request = nil
            editing = false
        }
    }
}

/// A Find command for the page.
struct ReaderFind: Equatable {
    enum Action: String { case none, open, next, previous }
    var action: Action
    var count: Int
}

/// A tag to rename, everywhere in the vault.
struct TagTarget: Identifiable, Equatable {
    var tag: String
    var id: String { tag }
}

/// A file command, and the file or folder it acts on.
enum FileAction: Identifiable, Equatable {
    case newNote(folder: String)
    case newFolder(parent: String)
    case rename(String)
    case move(String)
    case delete(String)
    /// The editor's selection, to become a note of its own.
    case extract(folder: String, text: String)

    var id: String {
        switch self {
        case .newNote(let folder): "note:" + folder
        case .newFolder(let parent): "folder:" + parent
        case .rename(let path): "rename:" + path
        case .move(let path): "move:" + path
        case .delete(let path): "delete:" + path
        case .extract(let folder, let text): "extract:\(folder):\(text.hashValue)"
        }
    }
}

/// The colours of Daftar on the phone: naz on dark, Daylight on light.
enum Palette {
    static let accent = color(dark: 0xFFB040, light: 0xA85200)
    static let link = color(dark: 0x80E5FF, light: 0x00707A)
    static let red = color(dark: 0xFF7088, light: 0xC01030)
    static let blue = color(dark: 0x40D0FF, light: 0x0070A0)
    static let green = color(dark: 0x20FFA0, light: 0x0A7A48)
    static let muted = color(dark: 0xA8A8A0, light: 0x6A6A62)
    static let yellow = color(dark: 0xF0E890, light: 0x8A6A00)
    static let mint = color(dark: 0xB8FFD0, light: 0x0A7A48)
    static let purple = color(dark: 0xF0A0F0, light: 0x8040A0)
    static let pink = color(dark: 0xFF69B4, light: 0xB02A70)
    static let chartreuse = color(dark: 0xA0FF40, light: 0x5A7A00)
    static let background = color(dark: 0x323232, light: 0xFAF9F5)
    static let panel = color(dark: 0x282826, light: 0xEFEDE6)

    static let aqua = color(dark: 0x80E5FF, light: 0x00707A)

    /// A colour of the palette by name, as `NSPalette.named` has them.
    static func named(_ name: String) -> Color { Color(nsColor: NSPalette.named(name)) }

    /// The heading colours of the reader, for the outline.
    static func heading(_ level: Int) -> Color { Color(nsColor: NSPalette.heading(level)) }

    private static func color(dark: UInt32, light: UInt32) -> Color { Color(nsColor: NSPalette.dynamic(dark: dark, light: light)) }
}

/// The same palette for AppKit: the editor's text attributes. The markdown
/// roles are naz's `@markup.*` groups (`Markup.kt` on the phone).
enum NSPalette {
    static let text = dynamic(dark: 0xF5F5F0, light: 0x2A2A28)
    static let faint = dynamic(dark: 0x707080, light: 0x9A9A92)
    static let muted = dynamic(dark: 0xA8A8A0, light: 0x6A6A62)
    static let background = dynamic(dark: 0x323232, light: 0xFAF9F5)
    static let panel = dynamic(dark: 0x282826, light: 0xEFEDE6)
    static let accent = dynamic(dark: 0xFFB040, light: 0xA85200)
    static let heading1 = dynamic(dark: 0xFFE0A0, light: 0xA85200)
    static let heading2 = dynamic(dark: 0xFFFF88, light: 0x8A6A00)
    static let heading3 = dynamic(dark: 0x60D8FF, light: 0x0070A0)
    static let heading4 = dynamic(dark: 0xE0FFD8, light: 0x0A7A48)
    static let strong = dynamic(dark: 0xFFB070, light: 0xA85200)
    static let italic = dynamic(dark: 0xB8FFD0, light: 0x0A7A48)
    static let raw = dynamic(dark: 0xFFD850, light: 0x8A6A00)
    static let link = dynamic(dark: 0x80E5FF, light: 0x00707A)
    static let quote = dynamic(dark: 0xFFB040, light: 0xA85200)
    static let blue = dynamic(dark: 0x40D0FF, light: 0x0070A0)
    static let purple = dynamic(dark: 0xF0A0F0, light: 0x8040A0)
    static let highlightBackground = dynamic(dark: 0xF0E890, light: 0x8A6A00)
    static let highlightText = dynamic(dark: 0x323232, light: 0xFAF9F5)
    static let red = dynamic(dark: 0xFF7088, light: 0xC01030)
    static let selection = dynamic(dark: 0x4A4A4A, light: 0xD8D5CC)
    static let pink = dynamic(dark: 0xFF69B4, light: 0xB02A70)
    /// `**` and `*` on a highlight: the text colour, dimmed.
    static let markOnHighlight = dynamic(dark: 0xF5F5F0, light: 0x2A2A28, alpha: 0.4)
    static let chartreuse = dynamic(dark: 0xA0FF40, light: 0x5A7A00)
    static let green = dynamic(dark: 0x20FFA0, light: 0x0A7A48)
    static let vividYellow = dynamic(dark: 0xFFE040, light: 0x8A6A00)
    static let yellow = dynamic(dark: 0xF0E890, light: 0x8A6A00)
    static let mint = dynamic(dark: 0xB8FFD0, light: 0x0A7A48)
    static let warmGrey = dynamic(dark: 0xB09070, light: 0x7A5A3A)

    /// The colours of the palette as pairs, so a tint can be made of each.
    private static let pairs: [String: (UInt32, UInt32)] = [
        "orange": (0xFFB040, 0xA85200), "aqua": (0x80E5FF, 0x00707A), "pink": (0xFF69B4, 0xB02A70),
        "purple": (0xF0A0F0, 0x8040A0), "chartreuse": (0xA0FF40, 0x5A7A00), "blue": (0x40D0FF, 0x0070A0),
        "green": (0x20FFA0, 0x0A7A48), "vividYellow": (0xFFE040, 0x8A6A00), "red": (0xFF7088, 0xC01030),
        "yellow": (0xF0E890, 0x8A6A00), "mint": (0xB8FFD0, 0x0A7A48), "warmGrey": (0xB09070, 0x7A5A3A),
        "grey": (0xA8A8A0, 0x6A6A62),
    ]

    static func named(_ name: String, alpha: CGFloat = 1) -> NSColor {
        let pair = pairs[name] ?? pairs["orange"]!
        return dynamic(dark: pair.0, light: pair.1, alpha: alpha)
    }

    /// A tag's colour: the same one the reader gives it (`hue` in reader.js).
    static func tagColor(_ tag: String) -> String {
        let order = ["orange", "aqua", "pink", "purple", "chartreuse", "blue", "green", "vividYellow", "red"]
        var hash: UInt32 = 0
        for scalar in tag.unicodeScalars { hash = hash &* 31 &+ scalar.value }
        return order[Int(hash % UInt32(order.count))]
    }

    /// A highlight's colour from the circle at its start, as Obsidian has it.
    static func highlightColor(_ emoji: String) -> String {
        ["🔴": "red", "🟠": "orange", "🟡": "vividYellow", "🟢": "green", "🔵": "blue", "🟣": "purple"][emoji] ?? "vividYellow"
    }

    /// A callout kind's colour, as the reader has it.
    static func calloutColor(_ kind: String) -> String {
        switch kind.lowercased() {
        case "warning", "caution", "attention": "orange"
        case "danger", "error", "bug", "failure", "fail", "missing": "red"
        case "success", "check", "done": "green"
        case "tip", "hint", "important": "chartreuse"
        case "todo": "vividYellow"
        case "question", "help", "faq": "yellow"
        case "abstract", "summary", "tldr": "mint"
        case "example": "purple"
        case "quote", "cite": "warmGrey"
        case "figure": "pink"
        case "read": "aqua"
        default: "blue"
        }
    }

    /// A code block's language colour, as the reader has it.
    static func languageColor(_ language: String) -> String {
        switch language.lowercased() {
        case "go", "dockerfile": "aqua"
        case "python", "py", "javascript", "js": "vividYellow"
        case "bash", "sh", "shell", "zsh", "fish": "chartreuse"
        case "yaml", "yml", "toml", "css": "pink"
        case "sql", "hcl", "terraform", "kotlin": "purple"
        case "c", "cpp", "typescript", "ts", "powershell", "lua", "nix": "blue"
        case "java", "ruby": "red"
        case "diff": "green"
        case "markdown", "md", "text", "": "grey"
        default: "orange"
        }
    }

    static func heading(_ level: Int) -> NSColor {
        switch level {
        case 1: heading1
        case 2: heading2
        case 3: heading3
        case 4: heading4
        case 5: pink
        default: purple
        }
    }

    static func dynamic(dark: UInt32, light: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(isDark ? dark : light, alpha: alpha)
        }
    }

    private static func rgb(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }
}

/// A page the detail column shows in place of a note.
enum Page: Hashable {
    case today, board
}
