import AppKit
import DaftarCore
import WebKit

/// The app timing itself, for the paths a person waits on that need real
/// windows: a new tab, a switch of tabs, a note opened, a file that changed.
/// `DAFTAR_PERF=/path/to/script` runs the script's lines after launch and
/// writes, for each, how long the main thread did not answer in the two and
/// a half seconds after it, to `/path/to/script.log`. Nothing runs without
/// the variable. The lines:
///
/// ```text
/// wait 3                 seconds
/// full                   the window in front enters or leaves full screen
/// menu File>New Tab      a menu item, by its titles
/// open Diet/Diary.md     a note, as daftar://open does
/// tab 2                  the tab at that place in the window's tabs, from 0
/// touch Books/Books.md   a line added to a file -- never in a git repository
/// shot /tmp/window.png   the window in front, as a picture
/// key j                 a key to the window, or cmd+w; esc, return, tab and space by name
/// state after ⌘T         the tabs, the tab in front (*), each one's line, who has the keys, the pages and the windows
/// page after a change    how much text the page in front shows, and its end
/// append Note.md words   words at the end of a file, as another app writes them -- never in a git repository
/// quit
/// ```
///
/// An accessibility client that presses the menus measures the same, but
/// needs the Accessibility permission, which a shell in tmux does not have.
@MainActor
enum PerfScript {
    /// How long the main thread did not answer, in all, as a thread that asks it every 2 ms saw.
    private final class Watch: @unchecked Sendable {
        private let lock = NSLock()
        private var total = 0.0
        private var worst = 0.0
        private var first: Double?

        func start() {
            Thread.detachNewThread { [self] in
                while true {
                    let asked = DispatchTime.now().uptimeNanoseconds
                    DispatchQueue.main.sync {}
                    let waited = Double(DispatchTime.now().uptimeNanoseconds - asked) / 1e6
                    if waited > 8 {
                        lock.lock()
                        total += waited
                        worst = max(worst, waited)
                        if first == nil { first = waited }
                        lock.unlock()
                    }
                    usleep(2000)
                }
            }
        }

        /// The time since the last call, the longest single wait in it, and
        /// the first: how long after a step the window could draw again.
        func take() -> (total: Double, worst: Double, first: Double) {
            lock.lock()
            defer { total = 0; worst = 0; first = nil; lock.unlock() }
            return (total, worst, first ?? 0)
        }
    }

    /// How often and for how long AppKit laid out the parts a window is made
    /// of, since the last `take`: `layout` of each class is wrapped, and the
    /// time is with what it calls, so a class holds the classes inside it.
    private final class Layouts: @unchecked Sendable {
        static let shared = Layouts()
        private var calls: [String: (count: Int, ms: Double)] = [:]

        /// Wraps `-[Class selector]`, a method that takes nothing or one object and gives nothing back.
        func wrap(_ methods: [String]) {
            for entry in methods {
                let parts = entry.split(separator: " ").map(String.init)
                let selector = NSSelectorFromString(parts[1])
                guard let type = NSClassFromString(parts[0]), let method = class_getInstanceMethod(type, selector) else { continue }
                let name = parts[0].replacingOccurrences(of: "NS", with: "") + "." + parts[1]
                let old = method_getImplementation(method)
                let record: (UInt64) -> Void = { [self] began in
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e6
                    let had = calls[name] ?? (0, 0)
                    calls[name] = (had.count + 1, had.ms + ms)
                }
                let new: IMP
                if parts[1].hasSuffix(":") {
                    typealias One = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
                    let call = unsafeBitCast(old, to: One.self)
                    let block: @convention(block) (AnyObject, AnyObject?) -> Void = { object, argument in
                        let began = DispatchTime.now().uptimeNanoseconds
                        call(object, selector, argument)
                        record(began)
                    }
                    new = imp_implementationWithBlock(block)
                } else {
                    typealias None = @convention(c) (AnyObject, Selector) -> Void
                    let call = unsafeBitCast(old, to: None.self)
                    let block: @convention(block) (AnyObject) -> Void = { object in
                        let began = DispatchTime.now().uptimeNanoseconds
                        call(object, selector)
                        record(began)
                    }
                    new = imp_implementationWithBlock(block)
                }
                // Its own method on the class, so the wrap is not on a parent class for every view.
                if !class_addMethod(type, selector, new, method_getTypeEncoding(method)) {
                    method_setImplementation(method, new)
                }
            }
        }

        func take() -> String {
            defer { calls = [:] }
            return calls.sorted { $0.value.ms > $1.value.ms }.filter { $0.value.ms >= 1 }.map { String(format: "%@ %dx %.0f", $0.key, $0.value.count, $0.value.ms) }.joined(separator: ", ")
        }
    }

    static func runIfAsked(store: @escaping @MainActor () -> VaultStore?) {
        guard let path = ProcessInfo.processInfo.environment["DAFTAR_PERF"], let script = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let log = URL(filePath: path + ".log")
        try? "".write(to: log, atomically: true, encoding: .utf8)
        Layouts.shared.wrap([
            "NSToolbarView layout", "NSOutlineView layout", "NSSplitView layout", "NSThemeFrame layout",
            "NSWindow layoutIfNeeded", "NSWindow displayIfNeeded", "NSWindow updateConstraintsIfNeeded",
            "NSWindow makeKeyAndOrderFront:", "NSWindow orderOut:", "NSWindowStackController setSelectedWindow:",
            "NSToolbar _insertNewItemWithItemIdentifier:atIndex:propertyListRepresentation:notifyFlags:", "NSToolbar setItems:",
        ])
        let watch = Watch()
        watch.start()
        let lines = script.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        step(lines[...], watch: watch, log: log, store: store)
    }

    /// Runs the first line and, after its wait, the rest. From the main
    /// queue, not a task: full screen runs the run loop inside the call, and
    /// that is not for the inside of a task's job.
    private static func step(_ lines: ArraySlice<String>, watch: Watch, log: URL, store: @escaping @MainActor () -> VaultStore?) {
        guard let line = lines.first else { return }
        let word = line.split(separator: " ").first.map(String.init) ?? ""
        let rest = String(line.dropFirst(word.count)).trimmingCharacters(in: .whitespaces)
        let next: @MainActor () -> Void = { step(lines.dropFirst(), watch: watch, log: log, store: store) }
        if word == "wait" {
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(rest) ?? 1)) { MainActor.assumeIsolated(next) }
            return
        }
        // From the run loop, not from this block of the main queue: Quit waits
        // for the editors in a run loop of its own, and the main queue does
        // not run while one of its blocks is still open.
        if word == "quit" { return NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0) }
        _ = watch.take()
        _ = Layouts.shared.take()
        let done = run(word, rest, store: store())
        DispatchQueue.main.asyncAfter(deadline: .now() + (word == "full" ? 5 : ["key", "state", "page"].contains(word) ? 0.6 : 2.5)) {
            MainActor.assumeIsolated {
                let (total, worst, first) = watch.take()
                let window = front
                let seen = window?.occlusionState.contains(.visible) == true
                let full = window?.styleMask.contains(.fullScreen) == true
                let tabs = WindowTabs.of(window)?.tabs.count ?? 1
                let text = String(format: "%6.0f ms  first %4.0f  worst %4.0f  %@%@  tabs %d  %@%@\n          %@\n", total, first, worst, seen ? "seen" : "hidden", full ? " full" : "", tabs, line, done ? "" : "  (NOT DONE)", Layouts.shared.take())
                if let handle = try? FileHandle(forWritingTo: log) {
                    handle.seekToEndOfFile()
                    handle.write(Data(text.utf8))
                    try? handle.close()
                }
                next()
            }
        }
    }

    /// The Daftar window on screen: the one in front, or with another app in
    /// front, the tab that is selected.
    private static var front: NSWindow? {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow { return window }
        return NSApp.windows.first { $0.tabbingIdentifier == "daftar.main" }
    }

    private static func run(_ word: String, _ rest: String, store: VaultStore?) -> Bool {
        switch word {
        case "full":
            // In front, or the Space is not in view and nothing is drawn.
            NSApp.activate(ignoringOtherApps: true)
            // A window that is not seen (the screen is locked) never ends the
            // change, and AppKit throws at the next new tab.
            guard let window = front, window.occlusionState.contains(.visible) else { return false }
            window.toggleFullScreen(nil)
            return true
        case "menu":
            var menu = NSApp.mainMenu
            let parts = rest.split(separator: ">").map(String.init)
            for (place, part) in parts.enumerated() {
                // As when the menu opens: SwiftUI brings its items up to date then, not before.
                if let menu { menu.delegate?.menuNeedsUpdate?(menu) }
                menu?.update()
                guard let item = menu?.items.first(where: { $0.title == part }) else { return false }
                if place == parts.count - 1 {
                    guard item.isEnabled, let menu, let index = menu.items.firstIndex(of: item) else { return false }
                    menu.performActionForItem(at: index)
                    return true
                }
                menu = item.submenu
            }
            return false
        case "open":
            var address = URLComponents(string: "daftar://open")!
            address.queryItems = [URLQueryItem(name: "path", value: rest)]
            guard let url = address.url else { return false }
            DaftarServices.openInThisApp(url)
            return true
        case "tab":
            guard let tabs = WindowTabs.of(front), let place = Int(rest), tabs.tabs.indices.contains(place) else { return false }
            tabs.select(tabs.tabs[place])
            return true
        case "shot":
            // The window as the window server draws it, glass and all: an app
            // may take a picture of its own window with no permission. The
            // call is not in the SDK any more, so it is found by name.
            if let window = front, let found = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
                typealias Take = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
                let take = unsafeBitCast(found, to: Take.self)
                // This window only (8), its bounds without the shadow (1), at the screen's resolution (8).
                if let image = take(.null, 8, UInt32(window.windowNumber), 1 | 8)?.takeRetainedValue(), image.width > 1,
                    let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                    (try? data.write(to: URL(filePath: rest))) != nil
                {
                    return true
                }
            }
            // Else the window as its views draw it; glass, which the window server draws, is left white.
            guard let frame = front?.contentView?.superview, let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return false }
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
            return (try? data.write(to: URL(filePath: rest))) != nil
        case "key":
            // A key, as the keyboard sends it to the window: "j", or "cmd+w".
            guard let window = front else { return false }
            let parts = rest.split(separator: "+").map(String.init)
            guard let last = parts.last else { return false }
            var flags: NSEvent.ModifierFlags = []
            for part in parts.dropLast() {
                switch part {
                case "cmd": flags.insert(.command)
                case "shift": flags.insert(.shift)
                case "ctrl": flags.insert(.control)
                case "opt": flags.insert(.option)
                default: return false
                }
            }
            let named: [String: (String, UInt16)] = ["esc": ("\u{1B}", 53), "return": ("\r", 36), "tab": ("\t", 48), "space": (" ", 49)]
            let (characters, code) = named[last] ?? (last, 0)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
                else { return false }
                NSApp.sendEvent(event)
            }
            return true
        case "state":
            // What the window shows and who has the keys, into the log.
            guard let window = front, let tabs = WindowTabs.of(window), let path = ProcessInfo.processInfo.environment["DAFTAR_PERF"] else { return false }
            let names = tabs.tabs.map { tab -> String in
                let name = tab.showsPage ? "page" : (tab.path.map { Vault.title(of: $0) } ?? "home")
                let line = tab.cursorLine.map { " line \($0)" } ?? ""
                return (tab === tabs.current ? "*" : "") + name + (tab.editing ? " editing" : "") + line
            }
            var responder = "none"
            if let first = window.firstResponder {
                responder = String(describing: type(of: first))
                // Whose it is: the tab whose reader or pane holds it.
                if let view = first as? NSView {
                    let owner = tabs.tabs.first { tab in tab.panes.contains { pane in pane.readerView.map { view === $0 || view.isDescendant(of: $0) } ?? false } }
                    if let owner { responder += " of " + (owner.path.map { Vault.title(of: $0) } ?? "home") }
                }
            }
            // The pages in the window, seen or not, and the Daftar windows open.
            func pages(_ view: NSView) -> Int { (view is WKWebView ? 1 : 0) + view.subviews.reduce(0) { $0 + pages($1) } }
            let windows = NSApp.windows.filter { $0.isVisible && $0.tabbingIdentifier == "daftar.main" }.count
            let note = "state \(rest): [" + names.joined(separator: " | ") + "] keys: " + responder
                + "; pages \(window.contentView.map(pages) ?? 0), windows \(windows)\n"
            if let handle = try? FileHandle(forWritingTo: URL(filePath: path + ".log")) {
                handle.seekToEndOfFile()
                handle.write(Data(note.utf8))
                try? handle.close()
            }
            return true
        case "page":
            // What the page of the tab in front shows: how much text, and its end.
            guard let tabs = WindowTabs.of(front), let view = tabs.current.readerView, let path = ProcessInfo.processInfo.environment["DAFTAR_PERF"] else { return false }
            let script = "(function(){var n=document.getElementById('note');var t=n?n.innerText:'';return t.length+' letters, ends: '+t.slice(-48).replace(/\\s+/g,' ')})()"
            view.evaluateJavaScript(script) { result, _ in
                let note = "page \(rest): \(result as? String ?? "nothing")\n"
                if let handle = try? FileHandle(forWritingTo: URL(filePath: path + ".log")) {
                    handle.seekToEndOfFile()
                    handle.write(Data(note.utf8))
                    try? handle.close()
                }
            }
            return true
        case "append":
            // Text at the end of a file, as another app writes it -- never in a git repository.
            let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let store, let root = store.root, !store.isRepository,
                let handle = try? FileHandle(forWritingTo: root.appending(path: parts[0]))
            else { return false }
            handle.seekToEndOfFile()
            handle.write(Data(("\n" + parts[1] + "\n").utf8))
            try? handle.close()
            return true
        case "touch":
            // Never the person's vault: a change there is committed and pushed.
            guard let store, let root = store.root, !store.isRepository else { return false }
            let file = root.appending(path: rest)
            guard let handle = try? FileHandle(forWritingTo: file) else { return false }
            handle.seekToEndOfFile()
            handle.write(Data("\n".utf8))
            try? handle.close()
            return true
        default:
            return false
        }
    }
}
