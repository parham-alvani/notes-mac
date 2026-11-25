import AppKit
import DaftarCore

/// The parts the editor draws in place of their text: a task's box, the
/// date chips, a callout's icon and a code block's language word
/// (docs/specs/look.md in notes-linux, part 2). The styling marks where
/// each one is with the `part` attribute and makes its room; the view draws
/// it behind the text. The text is never changed here, except by a click on
/// a box, which is the task toggle.

/// The Lucide icons the reader draws, for the editor: `editor-icons.json`
/// is written by `just web` beside the reader's own `tasks.css`.
@MainActor enum EditorIcons {
    /// Each icon's SVG, by its Lucide name.
    static let svgs: [String: String] = {
        guard let url = Resources.reader?.appending(path: "editor-icons.json"), let data = try? Data(contentsOf: url),
            let icons = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return icons
    }()

    private static var shapes: [String: NSImage] = [:]
    private static var tinted: [String: NSImage] = [:]

    /// The icon's shape, in black: a mask for one colour.
    static func shape(_ name: String) -> NSImage? {
        if let known = shapes[name] { return known }
        guard let svg = svgs[name], let image = NSImage(data: Data(svg.replacingOccurrences(of: "currentColor", with: "#000000").utf8)) else { return nil }
        shapes[name] = image
        return image
    }

    /// The icon filled with [colour], as many pixels as [side] points are at [scale].
    static func image(_ name: String, colour: NSColor, side: CGFloat, scale: CGFloat) -> NSImage? {
        guard let rgb = colour.usingColorSpace(.sRGB), let shape = shape(name) else { return nil }
        let pixels = max(1, Int((side * scale).rounded(.up)))
        let key = "\(name)|\(pixels)|\(rgb.redComponent)|\(rgb.greenComponent)|\(rgb.blueComponent)|\(rgb.alphaComponent)"
        if let known = tinted[key] { return known }
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let all = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        shape.draw(in: all, from: .zero, operation: .sourceOver, fraction: 1)
        rgb.setFill()
        all.fill(using: .sourceIn)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(bitmap)
        // The colours of two palettes and a few sizes: it never grows far.
        if tinted.count > 400 { tinted = [:] }
        tinted[key] = image
        return image
    }

    /// Draws the icon in [rect], in [colour]; a square's outline when the icon is not there.
    static func draw(_ name: String, in rect: NSRect, colour: NSColor, scale: CGFloat) {
        guard let image = image(name, colour: colour, side: rect.width, scale: scale) else {
            colour.setStroke()
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: rect.width * 0.14, dy: rect.height * 0.14), xRadius: 2, yRadius: 2)
            path.lineWidth = max(1, rect.width / 12)
            path.stroke()
            return
        }
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

extension NSPalette {
    /// A drawn part's colour, by the name the core's rules give it.
    static func part(_ name: String, alpha: CGFloat = 1) -> NSColor {
        switch name {
        case "listMarker", "accent": alpha == 1 ? accent : named("orange", alpha: alpha)
        case "done": done
        case "muted": named("grey", alpha: alpha)
        default: named(name, alpha: alpha)
        }
    }
}

/// One drawn part, as the styling wrote it into the `part` attribute. The
/// value is a string, so a part styled twice is the same attribute.
enum DrawnPart: Equatable {
    /// A task's box, with its status.
    case box(Character)
    /// A date chip, in its colour; on a closed task it is drawn at 75%.
    case chip(colour: String, closed: Bool)
    /// A callout's icon, and the kind's name when the line has no title.
    case icon(kind: String, name: String)
    /// A code block's language word.
    case word(String)

    var value: String {
        switch self {
        case .box(let status): "box:\(status)"
        case .chip(let colour, let closed): "chip:\(colour)\(closed ? "/closed" : "")"
        case .icon(let kind, let name): "icon:\(kind)|\(name)"
        case .word(let word): "word:\(word)"
        }
    }

    init?(_ value: String) {
        guard let colon = value.firstIndex(of: ":") else { return nil }
        let rest = String(value[value.index(after: colon)...])
        switch value[..<colon] {
        case "box": self = .box(rest.first ?? " ")
        case "chip": self = .chip(colour: rest.replacingOccurrences(of: "/closed", with: ""), closed: rest.hasSuffix("/closed"))
        case "icon":
            let parts = rest.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            self = .icon(kind: parts.first ?? "note", name: parts.count > 1 ? parts[1] : "")
        case "word": self = .word(rest)
        default: return nil
        }
    }
}

extension String {
    /// The line that holds UTF-16 [offset], with its line break.
    fileprivate func lineRange(at offset: Int) -> NSRange {
        (self as NSString).lineRange(for: NSRange(location: offset, length: 0))
    }
}

extension NoteTextView {
    /// Where a drawn part is, and which (`DrawnPart.value`).
    static let part = NSAttributedString.Key("DaftarPart")

    private var em: CGFloat { controller?.em ?? 16 }

    /// The baseline of the line of text at [offset], in the view.
    func baseline(at offset: Int) -> CGFloat? {
        guard let layout = textLayoutManager, let content = layout.textContentManager else { return nil }
        let documentStart = content.documentRange.location
        guard let location = content.location(documentStart, offsetBy: offset) ?? (offset == 0 ? documentStart : nil) else { return nil }
        if layout.textLayoutFragment(for: location)?.state != .layoutAvailable { layout.ensureLayout(for: NSTextRange(location: location)) }
        guard let fragment = layout.textLayoutFragment(for: location) else { return nil }
        let inParagraph = offset - content.offset(from: documentStart, to: fragment.rangeInElement.location)
        let lines = fragment.textLineFragments
        guard let line = lines.first(where: { NSLocationInRange(inParagraph, $0.characterRange) }) ?? lines.last else { return nil }
        return fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y + textContainerOrigin.y
    }

    /// Where the letters of [range] are, a rect for each line they are on.
    private func segments(_ range: NSRange) -> [NSRect] {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
            let from = content.location(content.documentRange.location, offsetBy: range.location),
            let to = content.location(from, offsetBy: range.length), let textRange = NSTextRange(location: from, end: to)
        else { return [] }
        layout.ensureLayout(for: textRange)
        var out: [NSRect] = []
        layout.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
            let rect = frame.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
            // The letters of one line, side by side, are one piece.
            if let last = out.last, abs(last.midY - rect.midY) < 1 { out[out.count - 1] = last.union(rect) } else { out.append(rect) }
            return true
        }
        return out
    }

    /// The square a task's box is drawn in, for the marks at [cover]: 1.1 em,
    /// its bottom 0.18 em under the baseline, where the hidden marks start.
    func boxRect(for cover: NSRange) -> NSRect? {
        guard let place = letterBox(cover), let baseline = baseline(at: cover.location) else { return nil }
        let side = em * 1.1
        // The marks take the box's width; in a line read from the right they are at its right.
        let x = place.width > side ? place.maxX - side : place.minX
        return NSRect(x: x, y: baseline + em * 0.18 - side, width: side, height: side)
    }

    /// The task box at [point], when one is drawn there: the marks it covers and its square.
    func taskBox(at point: NSPoint) -> (cover: NSRange, rect: NSRect)? {
        guard let storage = textStorage, storage.length > 0, controller?.store.settings.livePreview == true else { return nil }
        let at = characterIndexForInsertion(at: point)
        // The marks have no width: the place is just before them, in them or just after.
        for offset in [at, at - 1, at + 1] where offset >= 0 && offset < storage.length {
            // Asked first without its range: where there is no part, the longest range would be looked for far over the note at every move of the pointer.
            guard storage.attribute(Self.part, at: offset, effectiveRange: nil) != nil else { continue }
            var range = NSRange()
            guard let value = storage.attribute(Self.part, at: offset, longestEffectiveRange: &range, in: storage.string.lineRange(at: offset)) as? String,
                case .box = DrawnPart(value), let rect = boxRect(for: range)
            else { continue }
            return rect.insetBy(dx: -2, dy: -2).contains(point) ? (range, rect) : nil
        }
        return nil
    }

    /// The letters whose lines [rect] reaches; all on screen when it is not known.
    func offsets(in rect: NSRect) -> NSRange? {
        guard let visible = viewportOffsets(), let layout = textLayoutManager, let content = layout.textContentManager else { return nil }
        let start = content.documentRange.location
        func offset(at y: CGFloat, end: Bool) -> Int? {
            guard let fragment = layout.textLayoutFragment(for: CGPoint(x: 1, y: y - textContainerOrigin.y)) else { return nil }
            return content.offset(from: start, to: end ? fragment.rangeInElement.endLocation : fragment.rangeInElement.location)
        }
        let low = max(visible.location, offset(at: rect.minY, end: false) ?? visible.location)
        let high = min(NSMaxRange(visible), offset(at: rect.maxY, end: true) ?? NSMaxRange(visible))
        return high > low ? NSRange(location: low, length: high - low) : nil
    }

    /// The drawn parts of the lines [rect] reaches, behind the text.
    func drawParts(in rect: NSRect) {
        guard let storage = textStorage, storage.length > 0, let range = offsets(in: rect) else { return }
        let text = storage.string as NSString
        let lines = text.lineRange(for: range)
        let scale = window?.backingScaleFactor ?? 2
        let em = self.em
        storage.enumerateAttribute(Self.part, in: lines, options: []) { value, range, _ in
            guard let value = value as? String, let part = DrawnPart(value) else { return }
            switch part {
            case .box(let status):
                guard var box = boxRect(for: range), box.insetBy(dx: -3, dy: -3).intersects(rect) else { return }
                if hoveredBox == range.location, !Motion.reduced { box = box.insetBy(dx: -box.width * 0.06, dy: -box.height * 0.06) }
                let drawing = TaskBox.drawing(status)
                EditorIcons.draw(drawing.icon, in: box, colour: NSPalette.part(drawing.colour), scale: scale)
            case .chip(let colour, let closed):
                let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? Fonts.text(size: em * 0.92)
                let height = ceil(font.ascender - font.descender)
                let pieces = segments(range)
                // A pill stays within half an em of its segment: a chip outside the rect is not measured.
                guard pieces.contains(where: { $0.insetBy(dx: -em, dy: -2).intersects(rect) }) else { return }
                NSPalette.part(colour, alpha: closed ? 0.105 : 0.14).setFill()
                // The room made before a chip is counted in its segment: on one line, the pill is measured
                // back from the chip's end by the width of its own letters.
                var letters = CGFloat.greatestFiniteMagnitude
                if pieces.count == 1 {
                    let chip = storage.attributedSubstring(from: range)
                    if let kept = extras.chipWidths[chip] {
                        letters = kept
                    } else {
                        letters = ceil(chip.size().width)
                        if extras.chipWidths.count >= 2000 { extras.chipWidths.removeAll() }
                        extras.chipWidths[chip] = letters
                    }
                }
                for piece in pieces {
                    // Half an em of room at each side, which the styling left after the spaces around the chip.
                    let width = min(piece.width, letters)
                    let pill = NSRect(x: piece.maxX - width - em * 0.5, y: piece.maxY - height, width: width + em, height: height)
                    guard pill.intersects(rect) else { continue }
                    NSBezierPath(roundedRect: pill, xRadius: height / 2, yRadius: height / 2).fill()
                }
            case .icon(let kind, let name):
                guard let place = letterBox(range), let baseline = baseline(at: range.location) else { return }
                let side = em * 1.1
                let box = NSRect(x: place.minX, y: baseline + em * 0.18 - side, width: side, height: side)
                guard box.insetBy(dx: -em * 12, dy: 0).intersects(rect) else { return }
                let colour = NSPalette.named(NSPalette.calloutColor(kind))
                EditorIcons.draw(Callout.icon(of: kind), in: box, colour: colour, scale: scale)
                guard !name.isEmpty else { return }
                // The kind's name stands for a title that is not written: drawn, never text.
                let font = Fonts.text(size: em, weight: .semibold)
                (name as NSString).draw(at: NSPoint(x: box.maxX + em * 0.4, y: baseline - font.ascender), withAttributes: [.font: font, .foregroundColor: colour])
            case .word(let word):
                guard !word.isEmpty, let place = letterBox(range), let baseline = baseline(at: range.location), place.insetBy(dx: -em * 12, dy: -em).intersects(rect) else { return }
                let font = NSFontManager.shared.convert(Fonts.code(size: em * 0.72), toHaveTrait: .boldFontMask)
                let colour = NSPalette.named(NSPalette.languageColor(word))
                (word as NSString).draw(at: NSPoint(x: place.minX, y: baseline - font.ascender), withAttributes: [.font: font, .foregroundColor: colour])
            }
        }
    }

    // MARK: The pointer and the click

    /// The pointer is over a task's box: a pointing hand, and the box a little larger.
    func hover(at point: NSPoint?) {
        let hit = point.flatMap { taskBox(at: $0) }
        if hit?.cover.location != hoveredBox {
            if let old = hoveredBox, let storage = textStorage, old < storage.length {
                var range = NSRange()
                if storage.attribute(Self.part, at: old, effectiveRange: nil) != nil,
                    storage.attribute(Self.part, at: old, longestEffectiveRange: &range, in: storage.string.lineRange(at: old)) != nil,
                    let rect = boxRect(for: range)
                {
                    setNeedsDisplay(rect.insetBy(dx: -4, dy: -4))
                }
            }
            hoveredBox = hit?.cover.location
            if let hit { setNeedsDisplay(hit.rect.insetBy(dx: -4, dy: -4)) }
        }
        if hit != nil { NSCursor.pointingHand.set() }
    }

    /// A plain click on a task's box: the task toggle, and the click is used.
    /// With Shift, Control, Option or Command it is a click in the text.
    func boxClick(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
            let hit = taskBox(at: convert(event.locationInWindow, from: nil))
        else { return false }
        toggleTaskBox(at: hit.cover.location)
        return true
    }

    /// Whether [event] is a click on a task's box: such a click neither
    /// takes nor gives the keys.
    func isBoxClick(_ event: NSEvent) -> Bool {
        event.type == .leftMouseDown && event.window === window
            && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            && taskBox(at: convert(event.locationInWindow, from: nil)) != nil
    }

    /// The task of the line at [offset] is ticked or opened again, as ⌘↩
    /// does: one step to undo, and the cursor stays on the text it was on.
    /// A read-only vault changes nothing; in Neovim mode the change is
    /// Neovim's, of that line.
    func toggleTaskBox(at offset: Int) {
        guard let controller, !controller.store.readOnly else { return }
        let text = string as NSString
        guard offset <= text.length else { return }
        var start = 0, contents = 0
        text.getLineStart(&start, end: nil, contentsEnd: &contents, for: NSRange(location: offset, length: 0))
        let line = NSRange(location: start, length: contents - start)
        let old = text.substring(with: line)
        guard let lines = TaskBox.clicked(old, today: Day.today().description) else { return }
        if vimActive {
            let row = text.substring(to: start).reduce(0) { $1 == "\n" || $1 == "\r\n" ? $0 + 1 : $0 }
            vim?.change(line: row, from: old, to: lines)
            return
        }
        let selection = selectedRange()
        let from = TaskBox.moved(selection.location, line: line, lines: lines)
        let to = TaskBox.moved(NSMaxRange(selection), line: line, lines: lines)
        // The text under the many cursors moved: they end, as at any click.
        extras.cursors = []
        breakUndoCoalescing()
        replace(line, with: lines.joined(separator: "\n"), select: NSRange(location: from, length: max(0, to - from)))
        breakUndoCoalescing()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.userInfo?["daftar"] as? String == "parts" { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: ["daftar": "parts"]))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // Nothing in a card's body is live.
        guard controller?.isPreview != true else { return }
        hover(at: convert(event.locationInWindow, from: nil))
        hoverLink(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hover(at: nil)
        hoverLink(at: nil)
    }

    /// A click on a task's box leaves the keys where they are.
    override var acceptsFirstResponder: Bool {
        if let event = NSApp.currentEvent, window?.firstResponder !== self, isBoxClick(event) { return false }
        return super.acceptsFirstResponder
    }
}
