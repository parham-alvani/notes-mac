import AppKit
import DaftarCore
import ObjectiveC
import Observation
import SwiftUI

/// The tabs of one window. A tab is a `WindowModel`: what it shows, where it
/// has been, its panes and its panels. The window has one sidebar, one
/// toolbar and one inspector, which act on the tab in front.
///
/// The tabs are Daftar's own, not AppKit's window tabs. As window tabs, each
/// tab was a window with a sidebar, a toolbar and a SwiftUI root of its own:
/// a new tab made and laid out all of that (about 320 ms in full screen), a
/// switch of tabs showed another window (about 95 ms), and every tab that
/// was open, shown or not, kept its own copy in memory.
@MainActor @Observable
final class WindowTabs {
    private(set) var tabs: [WindowModel]
    /// The tab in front: its note is what the window shows.
    private(set) var current: WindowModel
    /// The tab the window's sidebar, toolbar, inspector and title show:
    /// [current], a turn of the run loop later. The note of the tab comes
    /// first, in about 25 ms; what stands around it (60 ms more: the
    /// inspector's rows, the sidebar's selection, the title) is drawn in
    /// the next frame, not before the note can be seen.
    private(set) var chrome: WindowModel
    /// What a tab needs from the vault when it is made, and what is undone
    /// when it is closed: the window gives both (`ContentView`).
    @ObservationIgnored var adopt: (WindowModel) -> Void = { _ in } {
        didSet { tabs.forEach(adopt) }
    }
    @ObservationIgnored var release: (WindowModel) -> Void = { _ in }
    /// The window the tabs are in, for the keys' focus (`TabbedWindow`).
    @ObservationIgnored weak var window: NSWindow? {
        didSet { if let window { WindowTabs.byWindow.setObject(self, forKey: window) } }
    }

    init() {
        let first = WindowModel()
        tabs = [first]
        current = first
        chrome = first
        first.tabs = self
    }

    /// A new tab after the one in front, which it replaces there. [fill]
    /// opens its note before it is shown.
    @discardableResult func add(_ fill: (WindowModel) -> Void = { _ in }) -> WindowModel {
        let tab = WindowModel()
        tab.tabs = self
        // A new tab has the panels of the one it was opened from.
        tab.inspector = current.inspector
        adopt(tab)
        fill(tab)
        let place = (tabs.firstIndex { $0 === current } ?? tabs.count - 1) + 1
        tabs.insert(tab, at: place)
        select(tab)
        return tab
    }

    func select(_ tab: WindowModel) {
        guard tab !== current, tabs.contains(where: { $0 === tab }) else { return }
        let old = current
        // The keys go to the tab on screen, never to the one left: its views
        // stay in the window, unseen, and would keep the first responder.
        if let window {
            old.responder = window.firstResponder.flatMap { $0 is NSWindow ? nil : $0 }
            window.makeFirstResponder(nil)
        }
        current = tab
        if ActiveWindow.shared.model === old { ActiveWindow.shared.model = tab }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.chrome !== self.current else { return }
            self.chrome = self.current
        }
        // After SwiftUI has shown the tab: a view that is not seen refuses the focus.
        DispatchQueue.main.async { [weak self, weak tab] in
            guard let self, let tab, self.current === tab, let window = self.window else { return }
            // Only when nothing took the focus meanwhile (the home page's field, a sheet).
            guard window.firstResponder === window || window.firstResponder == nil else { return }
            // Else the page takes them when it comes back (`ReaderView`), or the home page's field.
            if let view = tab.responder as? NSView, view.window === window { window.makeFirstResponder(view) }
        }
    }

    /// Closes [tab]; the last tab stays, since the window closes instead.
    /// The tab after it comes to the front, or the one before the last.
    func close(_ tab: WindowModel) {
        guard tabs.count > 1, let place = tabs.firstIndex(where: { $0 === tab }) else { return }
        if tab === current { select(tabs[place + 1 < tabs.count ? place + 1 : place - 1]) }
        tabs.remove(at: place)
        release(tab)
    }

    /// Closes every tab but [tab].
    func closeOthers(than tab: WindowModel) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        select(tab)
        for other in tabs where other !== tab { release(other) }
        tabs = [tab]
    }

    /// The tab [step] places after the one in front, around the ends.
    func step(_ step: Int) {
        guard tabs.count > 1, let place = tabs.firstIndex(where: { $0 === current }) else { return }
        select(tabs[((place + step) % tabs.count + tabs.count) % tabs.count])
    }

    /// Moves [tab] to [place] among the tabs.
    func move(_ tab: WindowModel, to place: Int) {
        guard let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        let to = min(max(place, 0), tabs.count - 1)
        guard from != to else { return }
        tabs.remove(at: from)
        tabs.insert(tab, at: to)
    }

    /// Every tab is given back, when the window goes.
    func releaseAll() { tabs.forEach(release) }

    // MARK: The window's tabs

    @ObservationIgnored private static let byWindow = NSMapTable<NSWindow, WindowTabs>.weakToWeakObjects()

    /// The tabs of [window], when it is a Daftar window.
    static func of(_ window: NSWindow?) -> WindowTabs? { window.flatMap { byWindow.object(forKey: $0) } }
}

extension WindowModel: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    /// The tab's name: its page, its note, or the vault's name on the home page.
    func title(store: VaultStore) -> String {
        if showsToday { return "Today" }
        if showsBoard { return "Board" }
        if showsDrill { return "Review Cards" }
        if showsJobs { return "Job Search" }
        return path.map(Vault.title(of:)) ?? store.name
    }

    /// The tab is the one its window shows. A model with no tabs is a window's only one.
    var isShown: Bool { tabs.map { $0.current === self } ?? true }

    /// [path], or the home page, in a new tab of this tab's window.
    func openTab(_ path: String?, store: VaultStore) {
        guard let tabs else { return }
        tabs.add { tab in
            if let path, store.index.files.contains(path) || store.loading { tab.open(path, store: store) }
        }
    }
}

/// ⌘W, and Close in the File menu, close the tab in front while the window
/// has more than one; with one tab, and from the window's red button, the
/// window closes as before. SwiftUI gives no say over its Close command, so
/// `performClose:` is changed, as `FullScreenEscape` changes the ways out of
/// full screen.
enum TabClose {
    @MainActor private static var installed = false

    @MainActor static func install() {
        guard !installed else { return }
        installed = true
        let selector = #selector(NSWindow.performClose(_:))
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else { return }
        typealias Original = @convention(c) (NSWindow, Selector, Any?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (NSWindow, Any?) -> Void = { window, sender in
            // AppKit sends it on the main thread, where a window is read.
            if MainActor.assumeIsolated({ closesTab(window, sender: sender) }) { return }
            original(window, selector, sender)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    /// Closes the tab in front of [window] and says so; false when the
    /// window itself is to close.
    @MainActor static func closesTab(_ window: NSWindow, sender: Any?) -> Bool {
        // The red button closes the window, tabs and all, as in a browser.
        if sender is NSButton { return false }
        guard let tabs = WindowTabs.of(window), tabs.tabs.count > 1, window.attachedSheet == nil else { return false }
        tabs.close(tabs.current)
        return true
    }
}

/// ⌃Tab shows the next tab and ⌃⇧Tab the one before, as in every app with
/// tabs. The Window menu names them, but the keys are taken here: to AppKit
/// ⌃Tab moves the keys to the next view, and it did that first.
enum TabKeys {
    /// Shows another tab of [window] for [event] and says so; false for any other key.
    @MainActor static func takes(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard let window, event.window === window, event.keyCode == 48 else { return false }
        let flags = event.modifierFlags.intersection([.control, .shift, .command, .option])
        guard flags == .control || flags == [.control, .shift] else { return false }
        guard let tabs = WindowTabs.of(window), tabs.tabs.count > 1, window.attachedSheet == nil else { return false }
        tabs.step(flags.contains(.shift) ? -1 : 1)
        return true
    }
}

/// The window's tabs, in a bar over the note: there when the window has more
/// than one. A click shows a tab, the cross closes it, and + opens a new one.
struct TabStrip: View {
    var tabs: WindowTabs
    @Environment(VaultStore.self) private var store

    var body: some View {
        if tabs.tabs.count > 1 {
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    ForEach(tabs.tabs) { tab in
                        TabButton(tabs: tabs, tab: tab)
                    }
                }
                .padding(3)
                .background(.quaternary.opacity(0.5), in: Capsule())
                Button {
                    tabs.current.openTab(store.settings.newTab == .note && !tabs.current.showsPage ? tabs.current.path : nil, store: store)
                } label: {
                    Image(systemName: "plus").font(.body.weight(.medium)).frame(width: 26, height: 26)
                }
                .buttonStyle(.borderless)
                .background(.quaternary.opacity(0.5), in: Circle())
                .help("New Tab (⌘T)")
                .accessibilityLabel("New Tab")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tabs")
        }
    }
}

/// One tab in the bar. Its own view, so a note opened in a tab draws that
/// tab's name again and not the bar.
private struct TabButton: View {
    var tabs: WindowTabs
    var tab: WindowModel
    @Environment(VaultStore.self) private var store
    @ViewState private var hovered = false

    var body: some View {
        let selected = tabs.current === tab
        let title = tab.title(store: store)
        Button {
            tabs.select(tab)
        } label: {
            Text(title)
                .lineLimit(1)
                .font(.callout.weight(selected ? .medium : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 26)
                .frame(maxWidth: .infinity, minHeight: 24)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(selected ? AnyShapeStyle(.background.opacity(0.9)) : AnyShapeStyle(.clear), in: Capsule())
        .overlay(alignment: .leading) {
            if hovered {
                Button {
                    tabs.close(tab)
                } label: {
                    Image(systemName: "xmark").font(.caption2.weight(.bold)).frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .padding(.leading, 4)
                .help("Close Tab (⌘W)")
                .accessibilityLabel("Close \(title)")
            }
        }
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Close Tab") { tabs.close(tab) }
            Button("Close Other Tabs") { tabs.closeOthers(than: tab) }
            Divider()
            Button("New Tab") { tab.openTab(nil, store: store) }
        }
        // A tab, and which one is in front, in words.
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Close Tab") { tabs.close(tab) }
    }
}
