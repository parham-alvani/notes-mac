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
    var inspector = true
    /// The terminal pane under the note.
    var terminal = false
    @ObservationIgnored let terminalSession = TerminalSession()
    /// Set to select the text in the reader after a search hit opens.
    var findText: String?

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

    static func heading(_ level: Int) -> NSColor {
        switch level {
        case 1: heading1
        case 2: heading2
        case 3: heading3
        case 4: heading4
        default: heading1
        }
    }

    static func dynamic(dark: UInt32, light: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        }
    }

    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
