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
        guard Vault.isNote(path) else {
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

    func searchTag(_ tag: String) {
        query = "#" + tag
    }
}

/// The colours of Daftar on the phone: naz on dark, Daylight on light.
enum Palette {
    static let accent = dynamic(dark: 0xFFB040, light: 0xA85200)
    static let link = dynamic(dark: 0x80E5FF, light: 0x00707A)
    static let red = dynamic(dark: 0xFF7088, light: 0xC01030)
    static let blue = dynamic(dark: 0x40D0FF, light: 0x0070A0)
    static let green = dynamic(dark: 0x20FFA0, light: 0x0A7A48)
    static let muted = dynamic(dark: 0xA8A8A0, light: 0x6A6A62)
    static let yellow = dynamic(dark: 0xF0E890, light: 0x8A6A00)
    static let mint = dynamic(dark: 0xB8FFD0, light: 0x0A7A48)
    static let purple = dynamic(dark: 0xF0A0F0, light: 0x8040A0)
    static let pink = dynamic(dark: 0xFF69B4, light: 0xB02A70)
    static let chartreuse = dynamic(dark: 0xA0FF40, light: 0x5A7A00)
    static let background = dynamic(dark: 0x323232, light: 0xFAF9F5)
    static let panel = dynamic(dark: 0x282826, light: 0xEFEDE6)

    private static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        })
    }

    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
