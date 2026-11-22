import AppKit
import SwiftUI

/// The soft change between reading and editing: the view that leaves fades
/// out as the one that comes fades in, in 120 ms, at the same line, with no
/// movement (`docs/specs/look.md` in notes-linux, "A soft change"). The
/// reader's page makes the same change between two notes by itself
/// (`softly` in `web/src/reader.js`).
///
/// The view that comes is in the window from the start of the change and has
/// the keys from then, so a key during the fade is never lost; only what is
/// seen fades. With Reduce Motion the change is made at once.
@MainActor
enum SoftChange {
    /// The fade's time, in seconds.
    static let duration = 0.12
    /// How long the view that comes may take to draw; after it the change is made at once.
    static let patience = 0.4

    /// The fade's time, or nil when the change is made at once.
    static func fade(reduced: Bool = Motion.reduced) -> Double? { reduced ? nil : duration }

    /// The editor that is over [reader] in its window: the pane's own, since
    /// the panes of a split window are side by side.
    static func editor(over reader: NSView) -> NSView? {
        guard let host = reader.window?.contentView else { return nil }
        let place = reader.convert(reader.bounds, to: nil)
        func find(in view: NSView) -> NSView? {
            if view is EditorContainer {
                let frame = view.convert(view.bounds, to: nil)
                let shared = frame.intersection(place)
                return !view.isHiddenOrHasHiddenAncestor && shared.width * shared.height * 2 > frame.width * frame.height ? view : nil
            }
            for child in view.subviews { if let found = find(in: child) { return found } }
            return nil
        }
        return find(in: host)
    }

    /// Leaves a picture of [view] over it, which fades out: what comes under
    /// it is seen through the view that leaves. The picture takes no click
    /// and no key, and is gone after the fade. Nil when no picture was left:
    /// with Reduce Motion, or for a view that is not in a window.
    @discardableResult
    static func leave(_ view: NSView, reduced: Bool = Motion.reduced) -> NSView? {
        guard let fade = fade(reduced: reduced), let host = view.window?.contentView, view.bounds.width >= 1, view.bounds.height >= 1,
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        let ghost = Ghost(frame: host.convert(view.bounds, from: view))
        ghost.image = image
        ghost.imageScaling = .scaleAxesIndependently
        ghost.setAccessibilityElement(false)
        ghost.wantsLayer = true
        host.addSubview(ghost)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fade
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ghost.animator().alphaValue = 0
        }
        // By the clock, not by the animation's end: a window that draws no
        // frame ends no animation, and the picture must never stay over the page.
        DispatchQueue.main.asyncAfter(deadline: .now() + fade + 0.03) { ghost.removeFromSuperview() }
        return ghost
    }

    /// The picture of a view that left: seen, never clicked.
    final class Ghost: NSImageView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { false }
    }
}

/// The reader under the editor: it stays seen while the editor fades in over
/// it and goes when the fade is over, so the two cross; back from the
/// editor it is seen at once, under the editor's fading picture.
private struct CoveredReader: ViewModifier {
    var covered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        content
            .opacity(covered ? 0 : 1)
            .animation(covered && !reduce ? .linear(duration: 0.01).delay(SoftChange.duration) : nil, value: covered)
    }
}

extension View {
    /// The reader of a pane whose editor is over it when [covered].
    func coveredReader(_ covered: Bool) -> some View { modifier(CoveredReader(covered: covered)) }
}
