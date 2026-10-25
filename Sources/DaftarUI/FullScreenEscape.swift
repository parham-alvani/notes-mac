import AppKit
import ObjectiveC

/// Escape does not take a Daftar window out of full screen. AppKit's
/// `NSWindow.cancelOperation(_:)` does that with any Escape no view used,
/// and Escape is a key the editor, Neovim and the reader use all the time.
/// Every other window, and a window not in full screen, keeps AppKit's way.
enum FullScreenEscape {
    @MainActor static func install() {
        guard !installed, let method = class_getInstanceMethod(NSWindow.self, #selector(NSResponder.cancelOperation(_:))) else { return }
        installed = true
        typealias Original = @convention(c) (NSWindow, Selector, Any?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (NSWindow, Any?) -> Void = { window, sender in
            if keeps(window) { return }
            original(window, #selector(NSResponder.cancelOperation(_:)), sender)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    /// A Daftar window in full screen stays there.
    nonisolated static func keeps(_ window: NSWindow) -> Bool {
        window.tabbingIdentifier == "daftar.main" && window.styleMask.contains(.fullScreen)
    }

    @MainActor private static var installed = false
}
