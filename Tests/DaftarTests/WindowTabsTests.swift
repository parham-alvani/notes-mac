import AppKit
import DaftarCore
import Foundation
import SwiftUI
import Testing

@testable import DaftarUI

/// The tabs of a window: which one is in front after a tab is made, shown,
/// moved or closed, and what the app's commands act on.
@MainActor
@Suite(.serialized) struct WindowTabsTests {
    @Test func aWindowStartsWithOneTab() {
        let tabs = WindowTabs()
        #expect(tabs.tabs.count == 1)
        #expect(tabs.current === tabs.tabs[0])
        #expect(tabs.current.tabs === tabs)
        #expect(tabs.current.isShown)
    }

    @Test func aNewTabIsAfterTheOneInFrontAndTakesItsPlace() {
        let tabs = WindowTabs()
        let first = tabs.current
        let second = tabs.add()
        #expect(tabs.tabs.map(\.id) == [first.id, second.id])
        #expect(tabs.current === second)
        #expect(!first.isShown)
        // A tab made from the first of two goes between them.
        tabs.select(first)
        let third = tabs.add()
        #expect(tabs.tabs.map(\.id) == [first.id, third.id, second.id])
        #expect(tabs.current === third)
    }

    @Test func aNewTabIsFilledBeforeItIsShownAndHasTheInspectorOfTheOneItCameFrom() {
        let tabs = WindowTabs()
        tabs.current.inspector = false
        var adopted: [ObjectIdentifier] = []
        tabs.adopt = { adopted.append($0.id) }
        let tab = tabs.add { $0.page = .today }
        #expect(tab.showsToday)
        #expect(!tab.inspector)
        // The window's first tab is adopted when the window says how, and each new one as it is made.
        #expect(adopted == [tabs.tabs[0].id, tab.id])
    }

    @Test func closingTheTabInFrontShowsTheNextOrTheOneBeforeTheLast() {
        let tabs = WindowTabs()
        let first = tabs.current
        let second = tabs.add()
        let third = tabs.add()
        var released: [ObjectIdentifier] = []
        tabs.release = { released.append($0.id) }
        tabs.select(second)
        tabs.close(second)
        #expect(tabs.tabs.map(\.id) == [first.id, third.id])
        #expect(tabs.current === third)
        tabs.close(third)
        #expect(tabs.current === first)
        #expect(released == [second.id, third.id])
        // The last tab stays: the window closes instead.
        tabs.close(first)
        #expect(tabs.tabs.count == 1)
        #expect(tabs.current === first)
    }

    @Test func closingATabBehindLeavesTheOneInFront() {
        let tabs = WindowTabs()
        let first = tabs.current
        let second = tabs.add()
        tabs.close(first)
        #expect(tabs.tabs.map(\.id) == [second.id])
        #expect(tabs.current === second)
    }

    @Test func closeOthersLeavesOneTab() {
        let tabs = WindowTabs()
        let first = tabs.current
        _ = tabs.add()
        _ = tabs.add()
        var released = 0
        tabs.release = { _ in released += 1 }
        tabs.closeOthers(than: first)
        #expect(tabs.tabs.map(\.id) == [first.id])
        #expect(tabs.current === first)
        #expect(released == 2)
    }

    @Test func nextAndPreviousGoAroundTheEnds() {
        let tabs = WindowTabs()
        let first = tabs.current
        let second = tabs.add()
        let third = tabs.add()
        tabs.step(1)
        #expect(tabs.current === first)
        tabs.step(-1)
        #expect(tabs.current === third)
        tabs.step(-1)
        #expect(tabs.current === second)
        // One tab: nothing to step to.
        let alone = WindowTabs()
        alone.step(1)
        #expect(alone.current === alone.tabs[0])
    }

    @Test func aTabMovesAmongTheOthersAndStaysInFront() {
        let tabs = WindowTabs()
        let first = tabs.current
        let second = tabs.add()
        let third = tabs.add()
        tabs.move(third, to: 0)
        #expect(tabs.tabs.map(\.id) == [third.id, first.id, second.id])
        #expect(tabs.current === third)
        tabs.move(third, to: 99)
        #expect(tabs.tabs.map(\.id) == [first.id, second.id, third.id])
    }

    /// The menus act on the tab in front of the window in front.
    @Test func theMenusFollowTheTabInFront() {
        let tabs = WindowTabs()
        let first = tabs.current
        ActiveWindow.shared.model = first
        let second = tabs.add()
        #expect(ActiveWindow.shared.model === second)
        tabs.close(second)
        #expect(ActiveWindow.shared.model === first)
        // Another window's tabs do not take the menus.
        let other = WindowTabs()
        _ = other.add()
        #expect(ActiveWindow.shared.model === first)
        ActiveWindow.shared.model = nil
    }

    /// ⌘W closes a tab while there is more than one; the red button, and the
    /// last tab, close the window.
    @Test func closeClosesATabUntilOneIsLeft() {
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let tabs = WindowTabs()
        tabs.window = window
        #expect(WindowTabs.of(window) === tabs)
        #expect(!TabClose.closesTab(window, sender: nil))
        let second = tabs.add()
        #expect(!TabClose.closesTab(window, sender: NSButton()))
        #expect(tabs.tabs.count == 2)
        #expect(TabClose.closesTab(window, sender: NSMenuItem()))
        #expect(tabs.tabs.count == 1)
        #expect(tabs.current !== second)
        #expect(!TabClose.closesTab(window, sender: NSMenuItem()))
        // A window that is not Daftar's closes as ever.
        let plain = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        plain.isReleasedWhenClosed = false
        #expect(!TabClose.closesTab(plain, sender: NSMenuItem()))
    }

    /// A window on screen with its tabs, as `TabbedWindow` gives a Daftar window its tabs.
    private func window(with tabs: WindowTabs) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        tabs.window = window
        window.orderBack(nil)
        return window
    }

    /// A tab dropped on another window's bar leaves its window for that one,
    /// with what it shows; a window whose last tab left closes.
    @Test func aTabGoesToAnotherWindow() {
        let here = WindowTabs(), there = WindowTabs()
        let hereWindow = window(with: here), thereWindow = window(with: there)
        defer { hereWindow.orderOut(nil); thereWindow.orderOut(nil) }
        let first = here.current
        let second = here.add { $0.page = .today }
        var released: [ObjectIdentifier] = [], adopted: [ObjectIdentifier] = []
        here.release = { released.append($0.id) }
        there.adopt = { adopted.append($0.id) }
        #expect(WindowTabs.tab(dragged: second.tabID) === second)
        there.take(second, at: 0)
        #expect(here.tabs.map(\.id) == [first.id])
        #expect(here.current === first)
        #expect(there.tabs.first === second)
        #expect(there.current === second)
        #expect(second.tabs === there)
        #expect(second.showsToday)
        #expect(released == [second.id])
        #expect(adopted.last == second.id)
        // The last tab of a window: the window goes.
        there.take(first, at: nil)
        #expect(!hereWindow.isVisible)
        #expect(there.tabs.contains { $0 === first })
        #expect(there.current === first)
        #expect(first.tabs === there)
    }

    /// A tab dropped in its own bar moves there and stays as it is.
    @Test func aTabDroppedInItsOwnBarMoves() {
        let tabs = WindowTabs()
        let first = tabs.current
        let second = tabs.add()
        tabs.take(second, at: 0)
        #expect(tabs.tabs.map(\.id) == [second.id, first.id])
        #expect(tabs.current === second)
    }

    /// Move Tab to New Window: the tab leaves, and the window that opens has it alone.
    @Test func aTabMovesToANewWindow() {
        let tabs = WindowTabs()
        let first = tabs.current
        let second = tabs.add { $0.page = .board }
        let made = WindowTabs()
        var opened = 0
        tabs.moveToNewWindow(second) {
            opened += 1
            // What the new window's view does when it appears.
            made.takeHandoff()
        }
        #expect(opened == 1)
        #expect(tabs.tabs.map(\.id) == [first.id])
        #expect(made.tabs.map(\.id) == [second.id])
        #expect(made.current === second)
        #expect(second.showsBoard)
        // The only tab of a window does not move: it is its window already.
        tabs.moveToNewWindow(first) { opened += 1 }
        #expect(opened == 1)
        // A window opened by New Window takes nothing.
        let plain = WindowTabs()
        let own = plain.current
        plain.takeHandoff()
        #expect(plain.tabs.map(\.id) == [own.id])
    }

    /// Merge All Windows: the other windows' tabs come after this one's, and those windows close.
    @Test func everyWindowsTabsComeToOne() {
        let here = WindowTabs(), there = WindowTabs()
        let hereWindow = window(with: here), thereWindow = window(with: there)
        defer { hereWindow.orderOut(nil); thereWindow.orderOut(nil) }
        let mine = here.current
        let theirs = there.current
        let more = there.add()
        here.mergeAll()
        #expect(here.tabs.prefix(1).map(\.id) == [mine.id])
        #expect(Set(here.tabs.map(\.id)) == [mine.id, theirs.id, more.id])
        #expect(here.current === mine)
        #expect(!thereWindow.isVisible)
        #expect(theirs.tabs === here && more.tabs === here)
    }

    /// ⌃Tab and ⇧⌘] show the next tab, ⌃⇧Tab and ⇧⌘[ the one before; other keys are left alone.
    @Test func theTabKeys() throws {
        let tabs = WindowTabs()
        let window = window(with: tabs)
        defer { window.orderOut(nil) }
        let first = tabs.current
        let second = tabs.add()
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: code))
        }
        #expect(TabKeys.takes(try key(48, .control), in: window))
        #expect(tabs.current === first)
        #expect(TabKeys.takes(try key(48, [.control, .shift]), in: window))
        #expect(tabs.current === second)
        #expect(TabKeys.takes(try key(30, [.command, .shift]), in: window))
        #expect(tabs.current === first)
        #expect(TabKeys.takes(try key(33, [.command, .shift]), in: window))
        #expect(tabs.current === second)
        // Tab alone, ⌘], and a key of another window are not the tabs' keys.
        #expect(!TabKeys.takes(try key(48, []), in: window))
        #expect(!TabKeys.takes(try key(30, .command), in: window))
        #expect(!TabKeys.takes(try key(48, .control), in: nil))
        #expect(tabs.current === second)
        // One tab: the keys go on to whoever wants them.
        tabs.close(second)
        #expect(!TabKeys.takes(try key(48, .control), in: window))
    }

    @Test func aTabIsNamedByItsPageOrItsNote() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "daftar-tabs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Work"), withIntermediateDirectories: true)
        try "# Plan\n".write(to: root.appending(path: "Work/Plan.md"), atomically: true, encoding: .utf8)
        let store = VaultStore(settings: AppSettings(url: root.appending(path: "config/config.toml")), openVault: false)
        store.openSynchronously(root)
        let tabs = WindowTabs()
        #expect(tabs.current.title(store: store) == root.lastPathComponent)
        tabs.current.openTab("Work/Plan.md", store: store)
        #expect(tabs.tabs.count == 2)
        #expect(tabs.current.path == "Work/Plan.md")
        #expect(tabs.current.title(store: store) == "Plan")
        tabs.current.page = .today
        #expect(tabs.current.title(store: store) == "Today")
        // A note that is not in the vault opens the home page in the new tab.
        tabs.current.openTab("Gone.md", store: store)
        #expect(tabs.tabs.count == 3)
        #expect(tabs.current.path == nil)
    }
}
