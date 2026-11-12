import AppKit
import ObjectiveC

/// Escape does not take a Daftar window out of full screen. Escape is a key
/// the editor, Neovim and the reader use all the time, and AppKit leaves full
/// screen with any Escape no view used, by two ways: `NSWindow.cancelOperation(_:)`,
/// and `exitFullScreenMode:`, which SwiftUI's hosting view calls on its window
/// for an Escape that comes back to it unused (the reader's web view gives back
/// every Escape its page does not take). SwiftUI's window class has its own
/// `exitFullScreenMode:`, which does not call NSWindow's, so the two classes
/// are changed. `exitFullScreenMode:` is also the action of View > Exit Full
/// Screen (and of its key, fn-F), so it is refused only for an Escape. Every
/// other window, and a window not in full screen, keeps AppKit's way.
enum FullScreenEscape {
    /// The window class SwiftUI makes for a `WindowGroup`.
    static let swiftUIWindow = "SwiftUI.AppKitWindow"

    @MainActor static func install() {
        guard !installed else { return }
        installed = true
        guardWindows(NSWindow.self)
        if let window = NSClassFromString(swiftUIWindow) { guardWindows(window) }
    }

    /// Changes the ways out of full screen that `windowClass` itself has; an
    /// inherited one is changed in the class that has it, once.
    @MainActor static func guardWindows(_ windowClass: AnyClass) {
        for selector in [cancel, exit] {
            guard let method = ownMethod(windowClass, selector) else { continue }
            typealias Original = @convention(c) (NSWindow, Selector, Any?) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
            let replacement: @convention(block) (NSWindow, Any?) -> Void = { window, sender in
                // AppKit and SwiftUI send both on the main thread, where a window is read.
                if MainActor.assumeIsolated({ stays(window, selector, during: NSApp?.currentEvent) }) { return }
                original(window, selector, sender)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
    }

    /// A Daftar window in full screen stays there.
    @MainActor static func keeps(_ window: NSWindow) -> Bool {
        window.tabbingIdentifier == "daftar.main" && window.styleMask.contains(.fullScreen)
    }

    static let cancel = #selector(NSResponder.cancelOperation(_:))
    static let exit = NSSelectorFromString("exitFullScreenMode:")

    /// Whether `window` ignores `selector`, sent while AppKit handles `event`:
    /// `cancelOperation(_:)` always, `exitFullScreenMode:` for the Escape key.
    @MainActor static func stays(_ window: NSWindow, _ selector: Selector, during event: NSEvent?) -> Bool {
        guard keeps(window) else { return false }
        return selector == cancel || (event?.type == .keyDown && event?.keyCode == 53)
    }

    /// The class's own method, not an inherited one: changing an inherited
    /// method changes it for every class that inherits it.
    private static func ownMethod(_ type: AnyClass, _ selector: Selector) -> Method? {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(type, &count) else { return nil }
        defer { free(methods) }
        return (0..<Int(count)).map { methods[$0] }.first { method_getName($0) == selector }
    }

    @MainActor private static var installed = false
}
