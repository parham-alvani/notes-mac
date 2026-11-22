import AppKit
import DaftarCore
import SwiftUI

/// Typewriter mode, focus mode and spelling: the editor's ways of writing,
/// each a setting in the config file's `[editor]` section. None of them
/// changes the text: focus dims as the view draws, and spelling marks are
/// the text view's own.
extension EditorController {
    /// The settings, as they are now: from `updateNSView`, which runs when they change.
    func followWritingModes() {
        guard let view else { return }
        let spelling = store.settings.spellCheck
        if view.isContinuousSpellCheckingEnabled != spelling { view.isContinuousSpellCheckingEnabled = spelling }
        if !store.settings.typewriter { endTypewriter() }
        dim()
    }

    /// The selection moved or the text changed.
    func followCursor() {
        guard let view else { return }
        view.showCarets()
        guard !view.extras.moving else { return }
        dim()
        if store.settings.typewriter, session == nil { centerCursor() }
    }

    // MARK: Focus

    /// Focus mode: which paragraphs stay bright, kept for the view, which
    /// dims the rest as it draws (`drawDim`). Nothing of the text storage or
    /// of its layout changes, so the text, its styles and undo do not, and a
    /// key that leaves the cursor in its paragraph costs only this look.
    func dim() {
        guard let view else { return }
        guard store.settings.focusMode else {
            if view.extras.focused != nil { view.focus(nil) }
            return
        }
        let text = view.string as NSString
        let bright = FocusParagraph.ranges(for: view.cursorRanges, in: text)
        if let focused = view.extras.focused, focused.ranges == bright, focused.length == text.length { return }
        view.focus((bright, text.length))
    }

    // MARK: Typewriter

    /// The cursor's line in the middle of the editor, with room under the
    /// last line so it can get there too. A glide, or a jump with Reduce Motion.
    func centerCursor() {
        guard let view, let scroll = view.enclosingScrollView, view.selectedRange().length == 0,
            NSEvent.pressedMouseButtons == 0, let line = caretLine(view)
        else { return }
        let clip = scroll.contentView
        let height = clip.bounds.height
        guard height > 0 else { return }
        if view.extras.insets == nil {
            view.extras.insets = scroll.contentInsets
            scroll.automaticallyAdjustsContentInsets = false
        }
        let own = view.extras.insets ?? NSEdgeInsets()
        let room = NSEdgeInsets(top: own.top, left: own.left, bottom: own.bottom + (height - own.top) / 2, right: own.right)
        if scroll.contentInsets.bottom != room.bottom || scroll.contentInsets.top != room.top { scroll.contentInsets = room }
        let middle = own.top + (height - own.top) / 2
        let y = max(-own.top, min(line.midY - middle, view.frame.height - height + room.bottom))
        guard abs(y - clip.bounds.origin.y) > 0.5 else { return }
        let target = NSPoint(x: clip.bounds.origin.x, y: y)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || view.window?.isVisible != true {
            clip.setBoundsOrigin(target)
            scroll.reflectScrolledClipView(clip)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            clip.animator().setBoundsOrigin(target)
        } completionHandler: {
            // AppKit ends an animation on the main thread.
            MainActor.assumeIsolated { scroll.reflectScrolledClipView(clip) }
        }
    }

    /// The cursor's line; at the very end, the last line, or the empty one under it.
    private func caretLine(_ view: NoteTextView) -> NSRect? {
        let text = view.string as NSString
        let offset = view.selectedRange().location
        if let line = view.lineRect(at: offset) { return line }
        guard offset == text.length, offset > 0, let last = view.lineRect(at: offset - 1) else { return nil }
        return text.character(at: offset - 1) == 10 ? last.offsetBy(dx: 0, dy: last.height) : last
    }

    /// Typewriter mode is off: the scroll view's insets are its own again.
    func endTypewriter() {
        guard let view, let insets = view.extras.insets, let scroll = view.enclosingScrollView else { return }
        view.extras.insets = nil
        scroll.contentInsets = insets
        scroll.automaticallyAdjustsContentInsets = true
    }

    // MARK: Spelling

    /// The dictionaries this Mac has, of English and Persian. macOS 27 has
    /// none for Persian (`fa`): Persian lines are then left alone, not marked
    /// wrong in every word by the Arabic dictionary.
    static let dictionaries = Spelling.dictionaries(NSSpellChecker.shared.availableLanguages)

    /// Latin letters are English, Arabic letters Persian.
    func textView(
        _ textView: NSTextView, willCheckTextIn range: NSRange, options: [NSSpellChecker.OptionKey: Any] = [:],
        types checkingTypes: UnsafeMutablePointer<NSTextCheckingTypes>
    ) -> [NSSpellChecker.OptionKey: Any] {
        var options = options
        options[.orthography] = NSOrthography(dominantScript: "Latn", languageMap: ["Latn": ["en"], "Arab": ["fa"]])
        return options
    }

    /// Only the words of prose in a language with a dictionary are marked:
    /// not code, a link's target, a web address, a tag or the front matter.
    func textView(
        _ view: NSTextView, didCheckTextIn range: NSRange, types checkingTypes: NSTextCheckingTypes,
        options: [NSSpellChecker.OptionKey: Any] = [:], results: [NSTextCheckingResult], orthography: NSOrthography, wordCount: Int
    ) -> [NSTextCheckingResult] {
        let marked = results.filter { $0.resultType == .spelling || $0.resultType == .grammar }
        guard !marked.isEmpty else { return results }
        let parts = Spelling.parts(in: view.string as NSString, range: range)
        return results.filter { result in
            guard result.resultType == .spelling || result.resultType == .grammar else { return true }
            return Spelling.marks(result.range, in: parts, dictionaries: Self.dictionaries)
        }
    }
}

/// Edit › Select Next Occurrence (⌥⌘E, as in Xcode) and Select All
/// Occurrences (⌃⌘G, as in Sublime Text and BBEdit); View › Typewriter
/// Mode and Focus Mode. ⌘D is Bookmark, so it is not Select Next.
struct EditorModeCommands: Commands {
    var window: WindowModel?
    var store: VaultStore

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Select Next Occurrence") { NSApp.sendAction(#selector(NoteTextView.selectNextOccurrence(_:)), to: nil, from: nil) }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(window?.editing != true || window?.showsPage == true)
            Button("Select All Occurrences") { NSApp.sendAction(#selector(NoteTextView.selectAllOccurrences(_:)), to: nil, from: nil) }
                .keyboardShortcut("g", modifiers: [.command, .control])
                .disabled(window?.editing != true || window?.showsPage == true)
        }
        CommandGroup(after: .sidebar) {
            Divider()
            Toggle("Typewriter Mode", isOn: Bindable(store.settings).typewriter)
            Toggle("Focus Mode", isOn: Bindable(store.settings).focusMode)
            Toggle("Check Spelling While Typing", isOn: Bindable(store.settings).spellCheck)
        }
    }
}

extension PaletteCommands {
    /// The editor's commands and modes, for the palette.
    static func editor(model: WindowModel, store: VaultStore) -> [PaletteCommand] {
        let settings = store.settings
        var out = [
            PaletteCommand(id: "typewriter", title: settings.typewriter ? "Turn Off Typewriter Mode" : "Turn On Typewriter Mode", group: "View", symbol: "character.cursor.ibeam", color: Palette.accent) {
                settings.typewriter.toggle()
            },
            PaletteCommand(id: "focus-mode", title: settings.focusMode ? "Turn Off Focus Mode" : "Turn On Focus Mode", group: "View", symbol: "text.aligncenter", color: Palette.purple) {
                settings.focusMode.toggle()
            },
            PaletteCommand(id: "spelling", title: settings.spellCheck ? "Stop Checking Spelling" : "Check Spelling While Typing", group: "View", symbol: "textformat.abc.dottedunderline", color: Palette.red) {
                settings.spellCheck.toggle()
            },
        ]
        if model.path != nil, !model.showsPage {
            out += [
                PaletteCommand(id: "next-occurrence", title: "Select Next Occurrence", group: "Edit", symbol: "plus.rectangle.on.rectangle", color: Palette.aqua, shortcut: "⌥⌘E") {
                    Self.inEditor(model) { NSApp.sendAction(#selector(NoteTextView.selectNextOccurrence(_:)), to: nil, from: nil) }
                },
                PaletteCommand(id: "all-occurrences", title: "Select All Occurrences", group: "Edit", symbol: "square.stack.3d.up.fill", color: Palette.aqua, shortcut: "⌃⌘G") {
                    Self.inEditor(model) { NSApp.sendAction(#selector(NoteTextView.selectAllOccurrences(_:)), to: nil, from: nil) }
                },
            ]
        }
        return out
    }

    /// [action] once the editor is open and has the focus.
    private static func inEditor(_ model: WindowModel, _ action: @escaping @MainActor () -> Void) {
        if !model.editing { model.editing = true }
        DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
    }
}

/// Focus mode's dim (`docs/specs/look.md` in notes-linux, part 2): the
/// background's colour at 55% over everything but the bright paragraphs, so
/// the text, a tint, a panel, a box, a chip, a grid and a picture of a
/// dimmed paragraph all keep their hue at 45%. It is a view over the text
/// view's own text (TextKit draws the text in a view of its own, so nothing
/// the text view draws is over it), made of plain layers: nothing is drawn
/// again when it changes, and a scroll moves it with the text.
final class FocusDim: NSView {
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The bright bands shown now, in the text view's coordinates.
    private(set) var bands: [NSRect] = []
    private var slices: [CALayer] = []
    /// Wider and higher than any note: the view cuts the layers to itself.
    private static let far: CGFloat = 10_000_000

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The palette's colour, as the window's appearance has it now.
    override func updateLayer() {
        let colour = NSPalette.background.withAlphaComponent(1 - FocusParagraph.dimmed).cgColor
        for slice in slices { slice.backgroundColor = colour }
    }

    /// Everything dims but [bright]. With [fade], what was bright dims and
    /// what was dim brightens over 120 ms; else at once.
    func show(_ bright: [NSRect], fade: Bool) {
        guard bright != bands || slices.isEmpty else { return }
        let old = bands
        bands = bright
        let scale = window?.backingScaleFactor ?? 2
        // Slices from top to bottom, each wholly in or out of every band, on whole pixels: two layers that meet between pixels show a line.
        var edges: [CGFloat] = [0, Self.far]
        for band in old + bright { edges += [band.minY, band.maxY].map { ($0 * scale).rounded() / scale }.filter { $0 > 0 } }
        edges = Array(Set(edges)).sorted()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        while slices.count < edges.count - 1 {
            let slice = CALayer()
            layer?.addSublayer(slice)
            slices.append(slice)
        }
        while slices.count > edges.count - 1 { slices.removeLast().removeFromSuperlayer() }
        let colour = effectiveAppearance.performAsCurrentDrawingAppearance { NSPalette.background.withAlphaComponent(1 - FocusParagraph.dimmed).cgColor }
        for (slice, (top, bottom)) in zip(slices, zip(edges, edges.dropFirst())) {
            let middle = (top + bottom) / 2
            func dimmed(_ bands: [NSRect]) -> Float { bands.contains { $0.minY <= middle && middle < $0.maxY } ? 0 : 1 }
            let now = dimmed(bright), was = dimmed(old)
            slice.backgroundColor = colour
            slice.frame = CGRect(x: 0, y: top, width: Self.far, height: bottom - top)
            slice.removeAnimation(forKey: "fade")
            slice.opacity = now
            guard fade, was != now else { continue }
            let change = CABasicAnimation(keyPath: "opacity")
            change.fromValue = was
            change.toValue = now
            change.duration = FocusParagraph.change
            change.timingFunction = CAMediaTimingFunction(name: .easeOut)
            slice.add(change, forKey: "fade")
        }
    }
}

extension NSAppearance {
    /// What [body] gives with this appearance as the one colours are read in.
    fileprivate func performAsCurrentDrawingAppearance<T>(_ body: () -> T) -> T {
        var out: T?
        performAsCurrentDrawingAppearance { out = body() }
        return out!
    }
}

extension NoteTextView {
    /// The bright paragraphs changed, or focus mode went off (nil). A move
    /// to another paragraph dims the old one and brightens the new one over
    /// 120 ms; typing, a first show and Reduce Motion change at once.
    func focus(_ now: (ranges: [NSRange], length: Int)?) {
        let old = extras.focused
        extras.focused = now
        guard let now else {
            extras.dim?.removeFromSuperview()
            extras.dim = nil
            return
        }
        let dim = extras.dim ?? {
            let dim = FocusDim()
            dim.frame = bounds
            // Over the views TextKit draws the text and the selection in, under everything of the editor's own.
            if let text = subviews.last(where: { $0.className.hasPrefix("_NSText") }) {
                addSubview(dim, positioned: .above, relativeTo: text)
            } else {
                addSubview(dim, positioned: .below, relativeTo: nil)
            }
            extras.dim = dim
            return dim
        }()
        let moved = old.map { $0.length == now.length } ?? false
        dim.show(brightBands(), fade: moved && !Motion.reduced && window?.isVisible == true)
    }

    /// The layout moved: the dim follows the bright paragraphs, at once.
    /// [laidOut] is false inside a layout, where nothing more is laid out.
    func placeDim(laidOut: Bool = true) {
        guard let dim = extras.dim, extras.focused != nil else { return }
        if dim.frame != bounds { dim.frame = bounds }
        dim.show(brightBands(layingOut: laidOut), fade: false)
    }

    /// Where the bright paragraphs are in the view: each from the top of
    /// its first line to the bottom of its last, as wide as the view.
    func brightBands(layingOut: Bool = true) -> [NSRect] {
        guard let focused = extras.focused else { return [] }
        let shown = viewportOffsets()
        return focused.ranges.compactMap { range in
            var from = range.location, to = NSMaxRange(range)
            // A long paragraph is laid out only where it is on screen.
            if range.length > Self.laidOutWhole {
                guard let shown else { return nil }
                from = max(from, shown.location)
                to = min(to, NSMaxRange(shown))
                guard from < to else { return nil }
            }
            // An empty line at the end of the note is a line of the paragraph before it to TextKit.
            guard to > from else { return layingOut ? lineRect(at: from) : extras.dim?.bands.first }
            guard let top = paragraphFrame(at: from, layingOut: layingOut), let bottom = paragraphFrame(at: to - 1, layingOut: layingOut) else { return nil }
            return NSRect(x: 0, y: top.minY, width: bounds.width, height: bottom.maxY - top.minY)
        }
    }

    /// A bright paragraph of at most this many letters is asked for its two
    /// ends wherever they are; a longer one only for what is on screen.
    private static let laidOutWhole = 6000

    /// The frame of the paragraph that holds [offset], with the room over
    /// and under its lines, in the view.
    private func paragraphFrame(at offset: Int, layingOut: Bool) -> NSRect? {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
            let location = content.location(content.documentRange.location, offsetBy: offset)
        else { return nil }
        if layout.textLayoutFragment(for: location)?.state != .layoutAvailable {
            guard layingOut else { return nil }
            layout.ensureLayout(for: NSTextRange(location: location))
        }
        return layout.textLayoutFragment(for: location)?.layoutFragmentFrame.offsetBy(dx: 0, dy: textContainerOrigin.y)
    }
}
