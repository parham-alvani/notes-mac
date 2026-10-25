import AppKit
import DaftarCore
import Observation
import SwiftUI

/// What one window is showing, and where it has been.
@MainActor @Observable
final class WindowModel {
    /// What the detail column shows: the Today page, or the note in [request].
    var showsToday = false
    var request: ReaderRequest?
    /// The note is open in the editor rather than the reader.
    var editing = false
    /// The sidebar's search field; while it holds text the sidebar lists hits.
    var query = ""
    var quickOpen = false
    /// ⇧⌘P, the command palette, and the commands used last, first.
    var palette = false
    var recentCommands: [String] = []
    /// The graph of the open note and its neighbours.
    var graph = false
    /// The task whose edit form is open.
    var taskEdit: TaskRef?
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
        var next = ReaderRequest(path: path, heading: heading, line: line)
        if let current = request {
            if current.path == path { next.generation = current.generation + 1 }
            back.append(current)
        }
        forward.removeAll()
        request = next
        showsToday = false
        recent.removeAll { $0 == path }
        recent.insert(path, at: 0)
        if recent.count > 30 { recent.removeLast() }
    }

    func goBack() {
        guard let previous = back.popLast() else { return }
        if let request { forward.append(request) }
        request = previous
        showsToday = false
    }

    func goForward() {
        guard let next = forward.popLast() else { return }
        if let request { back.append(request) }
        request = next
        showsToday = false
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
        if path == "today" {
            showsToday = true
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
        guard !showsToday, path != nil else { return }
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
        guard let path, !showsToday else { return "" }
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

/// A file command, and the file or folder it acts on.
enum FileAction: Identifiable, Equatable {
    case newNote(folder: String)
    case newFolder(parent: String)
    case rename(String)
    case move(String)
    case delete(String)

    var id: String {
        switch self {
        case .newNote(let folder): "note:" + folder
        case .newFolder(let parent): "folder:" + parent
        case .rename(let path): "rename:" + path
        case .move(let path): "move:" + path
        case .delete(let path): "delete:" + path
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
