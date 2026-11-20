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

    /// [made] in the place of every tab the window has, [front] in front:
    /// a change of vault. The tabs that go are given back.
    func replace(with made: [WindowModel], front: WindowModel) {
        let old = tabs
        if let window {
            window.makeFirstResponder(nil)
        }
        tabs = made
        if ActiveWindow.shared.model.map({ model in old.contains { $0 === model } }) ?? false { ActiveWindow.shared.model = front }
        current = front
        chrome = front
        for tab in old {
            release(tab)
            tab.tabs = nil
            tab.responder = nil
        }
    }

    /// Every tab is given back, when the window goes.
    func releaseAll() { tabs.forEach(release) }

    // MARK: A tab between windows

    /// Takes [tab] out of this window with what it shows, for another
    /// window. A window always has a tab: the last one leaves an empty one.
    private func detach(_ tab: WindowModel) {
        guard let place = tabs.firstIndex(where: { $0 === tab }) else { return }
        if tabs.count == 1 {
            let blank = WindowModel()
            blank.tabs = self
            adopt(blank)
            tabs.append(blank)
        }
        if tab === current { select(tabs[place + 1 < tabs.count ? place + 1 : place - 1]) }
        tabs.remove(at: place)
        release(tab)
        tab.tabs = nil
        tab.responder = nil
    }

    /// Puts [tab], which is in no window, at [place] here, or after the tab in front, and shows it.
    private func attach(_ tab: WindowModel, at place: Int?) {
        tab.tabs = self
        adopt(tab)
        let after = (tabs.firstIndex { $0 === current } ?? tabs.count - 1) + 1
        tabs.insert(tab, at: min(max(place ?? after, 0), tabs.count))
        select(tab)
    }

    /// [tab] dropped at [place] of this window's bar: moved among the tabs
    /// when it is this window's, else taken from its window, which closes
    /// when it was its last tab.
    func take(_ tab: WindowModel, at place: Int?) {
        guard let from = tab.tabs else { return attach(tab, at: place) }
        if from === self {
            if let place { move(tab, to: place) }
            return
        }
        let last = from.tabs.count == 1
        from.detach(tab)
        attach(tab, at: place)
        if last { from.window?.close() }
        window?.makeKeyAndOrderFront(nil)
    }

    /// Window › Move Tab to New Window: [tab] leaves this window, and the
    /// window [open] makes takes it as its only tab (`takeHandoff`).
    func moveToNewWindow(_ tab: WindowModel, open: () -> Void) {
        guard tabs.count > 1, tabs.contains(where: { $0 === tab }) else { return }
        detach(tab)
        WindowTabs.handoff = tab
        open()
    }

    /// A new window's first act: the tab another window gave it is its only tab.
    func takeHandoff() {
        guard let tab = WindowTabs.handoff else { return }
        WindowTabs.handoff = nil
        let first = tabs
        attach(tab, at: 0)
        for other in first { close(other) }
    }

    /// Window › Merge All Windows: every other window's tabs come to this one, after its own.
    func mergeAll() {
        let keep = current
        for other in WindowTabs.all where other !== self {
            for tab in other.tabs {
                other.detach(tab)
                attach(tab, at: tabs.count)
            }
            other.window?.close()
        }
        select(keep)
    }

    /// The tab a new window is to take.
    @ObservationIgnored private static var handoff: WindowModel?

    // MARK: The window's tabs

    @ObservationIgnored private static let byWindow = NSMapTable<NSWindow, WindowTabs>.weakToWeakObjects()

    /// The tabs of [window], when it is a Daftar window.
    static func of(_ window: NSWindow?) -> WindowTabs? { window.flatMap { byWindow.object(forKey: $0) } }

    /// The tabs of every Daftar window that is open.
    static var all: [WindowTabs] {
        (byWindow.keyEnumerator().allObjects as? [NSWindow] ?? []).filter(\.isVisible).compactMap { byWindow.object(forKey: $0) }
    }

    /// The tab that is dragged as [id], in any window.
    static func tab(dragged id: UUID) -> WindowModel? {
        for tabs in all { if let tab = tabs.tabs.first(where: { $0.tabID == id }) { return tab } }
        return nil
    }
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

    /// The keys go to [pane]'s page when the tab is on screen and nothing in
    /// the window has them. The home page's field gives them up when its
    /// page goes, which can be after the note that replaced it took them:
    /// the home page asks for this as it goes.
    func claimKeys(_ pane: NotePane) {
        guard isShown, focused === pane, !pane.editing, !showsPage, let view = pane.readerView, let window = view.window, window.attachedSheet == nil else { return }
        guard window.firstResponder == nil || window.firstResponder === window else { return }
        window.makeFirstResponder(view)
    }

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

/// ⌃Tab and ⇧⌘] show the next tab, ⌃⇧Tab and ⇧⌘[ the one before, as in
/// every app with tabs. The Window menu names the first two, but the keys
/// are taken here: to AppKit ⌃Tab moves the keys to the next view, and it
/// did that first.
enum TabKeys {
    /// Shows another tab of [window] for [event] and says so; false for any other key.
    @MainActor static func takes(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard let window, event.window === window else { return false }
        let flags = event.modifierFlags.intersection([.control, .shift, .command, .option])
        let step: Int
        switch (event.keyCode, flags) {
        case (48, .control), (30, [.command, .shift]): step = 1
        case (48, [.control, .shift]), (33, [.command, .shift]): step = -1
        default: return false
        }
        guard let tabs = WindowTabs.of(window), tabs.tabs.count > 1, window.attachedSheet == nil else { return false }
        tabs.step(step)
        return true
    }
}

/// The window's tabs, in a bar over the note: there when the window has more
/// than one, as AppKit's bar of window tabs is. A click shows a tab, the
/// cross (or the middle button) closes it, + opens a new one, and a tab is
/// dragged to another place in the bar or to the bar of another window.
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
                .background(Color(nsColor: .quaternarySystemFill), in: Capsule())
                // A tab comes, goes and moves in the bar, as in AppKit's.
                .motionAnimation(.snappy(duration: 0.2), value: tabs.tabs.map(\.id))
                Button {
                    tabs.current.openTab(store.settings.newTab == .note && !tabs.current.showsPage ? tabs.current.path : nil, store: store)
                } label: {
                    Image(systemName: "plus").font(.body.weight(.medium)).foregroundStyle(.secondary).frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .background(Color(nsColor: .quaternarySystemFill), in: Circle())
                .help("New Tab (⌘T)")
                .accessibilityLabel("New Tab")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            // The bar's own ground, as the toolbar has: the tabs read over any note or picture.
            .background(.bar)
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
    @Environment(\.openWindow) private var openWindow
    @ViewState private var hovered = false
    /// A dragged tab is over this one.
    @ViewState private var targeted = false

    private static let prefix = "daftar-tab:"

    /// The tab in front is lit, and the one under the pointer a little.
    private func fill(selected: Bool) -> AnyShapeStyle {
        // The control's own colour: white on a light bar, a lighter grey on a dark one, as AppKit's tab in front.
        if selected { return AnyShapeStyle(Color(nsColor: .controlColor)) }
        if hovered { return AnyShapeStyle(Color(nsColor: .quaternarySystemFill)) }
        return AnyShapeStyle(.clear)
    }

    /// A tab dropped on this one takes its place, from this window or another.
    private func drop(_ items: [String]) -> Bool {
        guard let item = items.first, item.hasPrefix(Self.prefix), let id = UUID(uuidString: String(item.dropFirst(Self.prefix.count))),
            let dragged = WindowTabs.tab(dragged: id), dragged !== tab, let place = tabs.tabs.firstIndex(where: { $0 === tab })
        else { return false }
        tabs.take(dragged, at: place)
        return true
    }

    private func move(by step: Int) {
        if let place = tabs.tabs.firstIndex(where: { $0 === tab }) { tabs.move(tab, to: place + step) }
    }

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
                .padding(.horizontal, 22)
                .frame(maxWidth: .infinity, minHeight: 24)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(fill(selected: selected), in: Capsule())
        .overlay { if targeted { Capsule().strokeBorder(Palette.accent, lineWidth: 2) } }
        .overlay(alignment: .leading) {
            if hovered {
                Button {
                    // ⌥ with the cross closes the others, as in AppKit's bar.
                    if NSEvent.modifierFlags.contains(.option) { tabs.closeOthers(than: tab) } else { tabs.close(tab) }
                } label: {
                    Image(systemName: "xmark").font(.caption2.weight(.bold)).frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .padding(.leading, 4)
                .help("Close Tab (⌘W); with ⌥, the other tabs")
                .accessibilityLabel("Close \(title)")
            }
        }
        .onHover { hovered = $0 }
        .help(tab.showsPage ? title : tab.path ?? title)
        // The middle button closes a tab, as in a browser.
        .background(PaneClicks(buttons: .otherMouseDown) { [weak tabs, weak tab] in
            if let tabs, let tab { tabs.close(tab) }
        })
        .draggable(Self.prefix + tab.tabID.uuidString)
        .dropDestination(for: String.self) { items, _ in drop(items) } isTargeted: { targeted = $0 }
        .contextMenu {
            Button("Close Tab") { tabs.close(tab) }
            Button("Close Other Tabs") { tabs.closeOthers(than: tab) }
            Button("Move Tab to New Window") { tabs.moveToNewWindow(tab) { openWindow(id: "main") } }
            Divider()
            Button("New Tab") { tab.openTab(nil, store: store) }
        }
        // A tab, and which one is in front, in words.
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Close Tab") { tabs.close(tab) }
        .accessibilityAction(named: "Move Left") { move(by: -1) }
        .accessibilityAction(named: "Move Right") { move(by: 1) }
    }
}
