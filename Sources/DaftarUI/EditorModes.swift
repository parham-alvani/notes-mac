import AppKit
import DaftarCore
import SwiftUI

/// Typewriter mode, focus mode and spelling: the editor's ways of writing,
/// each a setting in the config file's `[editor]` section. None of them
/// changes the text: focus dims with a rendering attribute, and spelling
/// marks are the text view's own.
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

    /// Every paragraph but the cursor's in the faint colour. A rendering
    /// attribute, so the text storage, its styles and undo do not change.
    func dim() {
        guard let view, let layout = view.textLayoutManager, let content = layout.textContentManager else { return }
        let text = view.string as NSString
        guard store.settings.focusMode else {
            if view.extras.focused != nil {
                view.extras.focused = nil
                layout.removeRenderingAttribute(.foregroundColor, for: content.documentRange)
            }
            return
        }
        let paragraph = FocusParagraph.range(at: view.selectedRange().location, in: text)
        if let focused = view.extras.focused, focused.0 == paragraph, focused.1 == text.length { return }
        view.extras.focused = (paragraph, text.length)
        layout.removeRenderingAttribute(.foregroundColor, for: content.documentRange)
        let start = content.documentRange.location
        for range in [NSRange(location: 0, length: paragraph.location), NSRange(location: NSMaxRange(paragraph), length: text.length - NSMaxRange(paragraph))]
        where range.length > 0 {
            guard let from = content.location(start, offsetBy: range.location), let to = content.location(start, offsetBy: NSMaxRange(range)),
                let textRange = NSTextRange(location: from, end: to)
            else { continue }
            layout.addRenderingAttribute(.foregroundColor, value: NSPalette.faint.withAlphaComponent(0.55), for: textRange)
        }
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
            scroll.reflectScrolledClipView(clip)
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
