import AppKit
import DaftarCore

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
                        lock.unlock()
                    }
                    usleep(2000)
                }
            }
        }

        /// The time since the last call, and the longest single wait in it.
        func take() -> (total: Double, worst: Double) {
            lock.lock()
            defer { total = 0; worst = 0; lock.unlock() }
            return (total, worst)
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
        if word == "quit" { return NSApp.terminate(nil) }
        _ = watch.take()
        _ = Layouts.shared.take()
        let done = run(word, rest, store: store())
        DispatchQueue.main.asyncAfter(deadline: .now() + (word == "full" ? 5 : 2.5)) {
            MainActor.assumeIsolated {
                let (total, worst) = watch.take()
                let window = front
                let seen = window?.occlusionState.contains(.visible) == true
                let full = window?.styleMask.contains(.fullScreen) == true
                let tabs = window?.tabbedWindows?.count ?? 1
                let text = String(format: "%6.0f ms  worst %5.0f  %@%@  tabs %d  %@%@\n          %@\n", total, worst, seen ? "seen" : "hidden", full ? " full" : "", tabs, line, done ? "" : "  (NOT DONE)", Layouts.shared.take())
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
        let window = NSApp.windows.first { $0.tabbingIdentifier == "daftar.main" }
        return window?.tabGroup?.selectedWindow ?? window
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
            guard let window = front, let tabs = window.tabbedWindows, let place = Int(rest), tabs.indices.contains(place) else { return false }
            window.tabGroup?.selectedWindow = tabs[place]
            return true
        case "shot":
            // The window as its views draw it; glass, which the window server draws, is left white.
            guard let frame = front?.contentView?.superview, let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return false }
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
            return (try? data.write(to: URL(filePath: rest))) != nil
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
