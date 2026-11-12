import AppKit
import DaftarCore

/// The text view in Neovim mode: Neovim's edits applied as they are, the
/// scroll held through them and moved with Neovim's window, the selection
/// Neovim says, and the keys on their way to Neovim.
extension NoteTextView {
    // MARK: Neovim mode

    /// An edit Neovim made, applied as it is: no undo, no autosave.
    /// False when the edit does not fit the text: the view and Neovim's
    /// buffer have come apart, and the session takes the buffer again.
    @discardableResult
    func applyRemote(_ range: NSRange, _ text: String) -> Bool {
        guard let storage = textStorage, NSMaxRange(range) <= storage.length else { return false }
        holdScroll(editing: range, with: (text as NSString).length)
        // The letter under the cursor moves with the text (u, dd, O, p):
        // the cursor follows it at once. Neovim says where it is next.
        extras.applyingEdit = true
        defer { extras.applyingEdit = false }
        storage.replaceCharacters(in: range, with: text)
        redrawPanels()
        return true
    }

    /// A quote's bar and a block's panel span lines the edit did not touch:
    /// the background on screen is drawn again, not only the edited line's.
    func redrawPanels() { setNeedsDisplay(visibleRect, avoidAdditionalLayout: true) }

    // MARK: The scroll through an edit


    /// Notes the first letter on screen, before [range] becomes [length]
    /// letters, and moves it by the edit when the edit is above it.
    func holdScroll(editing range: NSRange, with length: Int) {
        guard let clip = enclosingScrollView?.contentView else { return }
        if Date() >= anchorUntil || anchor == nil { anchor = topLetter(at: clip.bounds.origin.y) }
        if var held = anchor, range.location < held.offset {
            held.offset = max(range.location + length, held.offset + length - range.length)
            anchor = held
        }
        anchorUntil = Date(timeIntervalSinceNow: 0.5)
    }

    private func topLetter(at y: CGFloat) -> (offset: Int, y: CGFloat, origin: CGFloat)? {
        let offset = characterIndexForInsertion(at: NSPoint(x: textContainerOrigin.x + 4, y: y + 1))
        guard offset != NSNotFound, let line = lineRect(at: offset) else { return nil }
        return (offset, line.minY - y, y)
    }

    /// The view never edits its own text while Neovim owns it.
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard owner == .plain else { return false }
        guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else { return false }
        holdScroll(editing: affectedCharRange, with: ((replacementString ?? "") as NSString).length)
        DispatchQueue.main.async { [weak self] in self?.redrawPanels() }
        return true
    }

    /// After an edit, TextKit lays the lines above the screen out again,
    /// from estimates, and scrolls the view on its own: an undo in Neovim
    /// moved the view by a screen, or the text under it by a hundred
    /// points. The letter that was first on screen goes back to its place.
    /// A scroll by a person, or the editor's own to keep the cursor in
    /// sight, drops or renews the anchor first.
    ///
    /// NSTextView has the method from its viewport controller, but the SDK
    /// of some Xcode versions does not show it, and others do: it is added to
    /// this class at run time, once, and NSTextView's own runs first.
    static let viewportHook: Void = {
        let selector = NSSelectorFromString("textViewportLayoutControllerDidLayout:")
        guard let method = class_getInstanceMethod(NSTextView.self, selector) else { return }
        typealias DidLayout = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        let own = unsafeBitCast(method_getImplementation(method), to: DidLayout.self)
        let hook: @convention(block) (NoteTextView, AnyObject) -> Void = { view, controller in
            let entry = view.enclosingScrollView?.contentView.bounds.origin.y
            own(view, selector, controller)
            view.keepAnchor(from: entry)
        }
        class_addMethod(NoteTextView.self, selector, imp_implementationWithBlock(hook), method_getTypeEncoding(method))
    }()

    private func keepAnchor(from entry: CGFloat?) {
        guard let held = anchor, Date() < anchorUntil, let scroll = enclosingScrollView, let entry else { return }
        let clip = scroll.contentView
        // Scrolled since by someone else -- a person, the text view to show
        // the caret: that place stands.
        guard abs(entry - held.origin) < 0.5 else { anchor = nil; return }
        guard let line = lineRect(at: held.offset) else { return }
        let y = max(0, min(line.minY - held.y, max(0, frame.height - clip.bounds.height)))
        anchor?.origin = y
        guard abs(clip.bounds.origin.y - y) > 0.5 else { return }
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    func showSelection(_ range: NSRange) {
        let length = (string as NSString).length
        let clamped = NSRange(location: min(range.location, length), length: min(range.length, length - min(range.location, length)))
        placing { setSelectedRange(clamped) }
        if vimActive { scrollSoon() } else { scrollRangeToVisible(clamped) }
        updateInsertionPointStateAndRestartTimer(true)
    }

    /// A selection Neovim set: its lines are styled again on the way (live
    /// preview shows the marks of the cursor's line), so the cursor is
    /// placed once, after, where the restyled line has the letter. Placed
    /// on the way too, it went to the letter's old place and then jumped
    /// by up to a line, at every j.
    private func placing(_ select: () -> Void) {
        extras.placingSelection = true
        defer { extras.placingSelection = false }
        select()
    }

    /// [offset]'s line in the middle of the view, at once.
    func center(_ offset: Int) {
        guard let scroll = enclosingScrollView, let line = lineRect(at: offset) else { return scrollRangeToVisible(NSRange(location: offset, length: 0)) }
        let clip = scroll.contentView
        // Not laid out yet (the editor is made before its window sizes it):
        // the middle of a view 0 points high is its top, so the line is put
        // in the middle at the first layout that gives it a height.
        guard clip.bounds.height >= 1 else {
            extras.pendingCenter = offset
            return
        }
        extras.pendingCenter = nil
        let y = max(0, min(line.midY - clip.bounds.height / 2, max(0, frame.height - clip.bounds.height)))
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    /// Visual block mode: a range on each row, and the cursor's row in view.
    func showSelections(_ ranges: [NSRange], cursor: Int) {
        let length = (string as NSString).length
        let clamped = ranges.map { NSRange(location: min($0.location, length), length: min($0.length, length - min($0.location, length))) }
        guard !clamped.isEmpty else { return }
        placing { setSelectedRanges(clamped.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false) }
        moveNeovimCursor()
        scrollSoon()
    }

    // MARK: Scrolling with Neovim


    /// Neovim's window moved: `<C-e>`, `<C-d>`.
    func follow(top offset: Int) {
        neovimTop = offset
        scrollSoon()
    }

    /// Where `zz`, `zt` and `zb` put the cursor's line in the view.
    enum Place: String { case top, middle, bottom }

    func place(_ place: Place) {
        placing = place
        scrollSoon()
    }

    /// The cursor and the window move in the same Neovim update, as two
    /// messages: one scroll for both, a moment later, not two jumps. The
    /// moment is the end of this turn of the run loop, before the next
    /// frame: on the main queue, a frame was drawn in between, with the
    /// cursor at its new place and the view at its old one, and after `G`
    /// or `gg` that frame laid out and drew a screen nobody saw for 20 ms.
    private func scrollSoon() {
        guard !scrollPending else { return }
        scrollPending = true
        let loop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.scrollPending else { return }
                self.scrollPending = false
                self.scroll()
            }
        }
        CFRunLoopWakeUp(loop)
    }

    /// How long the view glides: to a place on screen or near (`<C-d>`,
    /// `zt`), and for the last screen of a jump of more than two (`G`).
    static let glide = 0.12
    static let farGlide = 0.15

    private func scroll() {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let height = clip.bounds.height
        // A line far off the screen is where TextKit guesses, from what it
        // guesses of the lines above: a code block or a heading is another
        // height, and once laid out the line was hundreds of points away,
        // the cursor off the screen after `/`, `n`, `G` or a mark. The text
        // around it is laid out first, so the view goes where it will stay.
        if let near = textLayoutManager?.textViewportLayoutController.viewportRange, let content = textLayoutManager?.textContentManager {
            let start = content.offset(from: content.documentRange.location, to: near.location)
            let end = content.offset(from: content.documentRange.location, to: near.endLocation)
            let cursor = selectedRange().location
            if cursor < start || cursor > end { layOutAround(cursor) }
        }
        var y = clip.bounds.origin.y
        if let top = neovimTop, let line = lineRect(at: top) { y = line.minY - textContainerOrigin.y }
        neovimTop = nil
        if let placing, let cursor = lineRect(at: selectedRange().location) {
            let margin = min(cursor.height * 2, height / 4)
            switch placing {
            case .top: y = cursor.minY - margin
            case .middle: y = cursor.midY - height / 2
            case .bottom: y = cursor.maxY + margin - height
            }
        }
        placing = nil
        // Whatever Neovim's window says, the cursor stays on screen: the view
        // fits fewer lines than Neovim thinks, under a heading.
        if let cursor = lineRect(at: selectedRange().location) {
            // A jump of more than a screen -- G, a search -- puts the line in
            // the middle, as Vim does, not at the edge.
            if cursor.maxY < y - height || cursor.minY > y + height * 2 { y = cursor.midY - height / 2 }
            let margin = min(cursor.height * 2, height / 4)
            if cursor.minY - margin < y { y = cursor.minY - margin } else if cursor.maxY + margin > y + height { y = cursor.maxY + margin - height }
        }
        y = max(0, min(y, max(0, frame.height - height)))
        glide += 1
        placed = lineRect(at: selectedRange().location).map { (selectedRange().location, $0.minY - y) }
        guard abs(y - clip.bounds.origin.y) > 0.5 else { return }
        let target = NSPoint(x: clip.bounds.origin.x, y: y)
        // The editor's own scroll is where an edit's layout keeps the view.
        if anchor != nil, Date() < anchorUntil { anchor = topLetter(at: y) }
        // A short glide. A window not on screen runs no animation: it would
        // never get there. A key held down scrolls at once: a glide at each
        // of thirty keys a second was cut short by the next, and the view
        // was always on its way, behind the cursor.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || window?.isVisible != true
            || extras.keys.held(at: ProcessInfo.processInfo.systemUptime)
        {
            // A glide on its way stops where this puts the view.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                clip.animator().setBoundsOrigin(target)
            }
            clip.setBoundsOrigin(target)
            scroll.reflectScrolledClipView(clip)
            redrawCursorLine()
            return
        }
        // A jump of more than two screens, as `G`, starts a screen short of
        // the place and glides the rest, as Neovide's far scrolls do.
        let far = abs(y - clip.bounds.origin.y) > height * 2
        if far {
            clip.setBoundsOrigin(NSPoint(x: target.x, y: y > clip.bounds.origin.y ? y - height : y + height))
            scroll.reflectScrolledClipView(clip)
        }
        let duration = far ? Self.farGlide : Self.glide
        // A cursor gliding to its new place goes with the view, in the same
        // time and curve: on its own it went faster, and on screen it ran
        // down past its row and came back as the view caught up (<C-d>, zt, n).
        if !far { extras.neovimCursor?.glide(over: duration) }
        let glide = self.glide
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CursorTrail.curve
            clip.animator().setBoundsOrigin(target)
        } completionHandler: { [weak self] in
            // AppKit ends an animation on the main thread.
            MainActor.assumeIsolated {
                // The last glide ends where it was going, and the cursor's
                // line where it was put: a glide AppKit did not run left the
                // view a screen short, and lines laid out on the way moved it.
                self?.settle(glide, at: target)
            }
        }
        // AppKit may end a glide only when the next one starts, or never
        // (a window it does not animate): the view gets there all the same.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.settle(glide, at: target) }
        }
    }


    /// The view at [target], or where it puts the cursor's line as the
    /// scroll put it, when the lines under it were laid out again.
    /// Only the last glide, once: a later scroll took its place.
    private func settle(_ glide: Int, at target: NSPoint) {
        guard glide == self.glide, let scroll = enclosingScrollView else { return }
        self.glide += 1
        let clip = scroll.contentView
        var y = target.y
        if let placed, placed.offset == selectedRange().location, let line = lineRect(at: placed.offset) { y = line.minY - placed.y }
        y = max(0, min(y, max(0, frame.height - clip.bounds.height)))
        if abs(clip.bounds.origin.y - y) > 0.5 {
            // A glide still on its way stops here.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
            }
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
        }
        scroll.reflectScrolledClipView(clip)
        // The clip copies what was drawn while it moves: the cursor's
        // line, drawn in the same moment, is drawn again where it is.
        redrawCursorLine()
    }

    /// The text a few screens around [offset] laid out for real, so its
    /// lines are where they will stay.
    private func layOutAround(_ offset: Int) {
        guard let layout = textLayoutManager, let content = layout.textContentManager else { return }
        let text = string as NSString
        let reach = 3000
        let low = text.paragraphRange(for: NSRange(location: max(0, min(offset, text.length) - reach), length: 0)).location
        let high = NSMaxRange(text.paragraphRange(for: NSRange(location: min(text.length, offset + reach), length: 0)))
        guard let from = content.location(content.documentRange.location, offsetBy: low),
            let to = content.location(content.documentRange.location, offsetBy: high),
            let range = NSTextRange(location: from, end: to)
        else { return }
        layout.ensureLayout(for: range)
    }

    override func keyDown(with event: NSEvent) {
        guard let vim, vimActive else {
            // ⌥↑ and ⌥↓ move the line, or the selected lines.
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if flags == .option, event.keyCode == 126 || event.keyCode == 125 { return moveLines(up: event.keyCode == 126) }
            // ⇧⌥↑ and ⇧⌥↓ copy them above or below.
            if flags == [.option, .shift], event.keyCode == 126 || event.keyCode == 125 { return duplicateLines(up: event.keyCode == 126) }
            return super.keyDown(with: event)
        }
        extras.keys.key(event.keyCode, at: event.timestamp, isRepeat: event.isARepeat)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: VimKeys.Modifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.command) { modifiers.insert(.command) }
        // ⌥ as Meta, by the side the setting names. The left and the right
        // key are bits under AppKit's flags; an event with neither, as a
        // made-up one, counts as both.
        if flags.contains(.option) {
            let device = event.modifierFlags.rawValue
            let left = device & 0x20 != 0, right = device & 0x40 != 0
            let setting = controller?.store.settings.optionAsMeta ?? VimKeys.OptionKey.none
            if setting.isMeta(left: left || !right, right: right || !left) { modifiers.insert(.option) }
        }
        let raw = event.charactersIgnoringModifiers ?? ""
        if modifiers.contains(.option) || flags.contains(.control) || flags.contains(.command) || VimKeys.isSpecial(raw) {
            // A chord is named by its key on the Latin layout, whatever layout is on.
            if let keys = VimKeys.notation(characters: chordCharacters(event), modifiers: modifiers) { vim.input(keys) }
            return
        }
        // Text goes through the input system, so an input method and the
        // Persian layout type what they type; `insertText` sends it.
        interpretKeyEvents([event])
    }

    /// What a chord's key types on the Latin layout: with the Persian
    /// layout on, `charactersIgnoringModifiers` is the Persian letter.
    func chordCharacters(_ event: NSEvent) -> String {
        let raw = event.charactersIgnoringModifiers ?? ""
        guard raw.unicodeScalars.first.map({ !$0.isASCII }) == true, !VimKeys.isSpecial(raw) else { return raw }
        return VimKeys.chord(raw, latin: NeovimSession.latinCharacter(keycode: event.keyCode, shift: event.modifierFlags.contains(.shift)))
    }
}
