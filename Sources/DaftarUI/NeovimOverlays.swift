import AppKit
import DaftarCore

/// Neovim's own completion menu -- `<C-n>`, `<C-p>`, a dictionary, an
/// omnifunc -- drawn by the editor under the word, as Neovide draws it.
/// Neovim keeps the menu: its keys move the selection and it says which
/// item is selected; the view only shows the list. A click goes through
/// to the text.
final class NeovimMenu: FloatingPanel {
    struct Item: Equatable {
        let word: String
        /// Neovim's kind letter (`v`, `f`) or the source, as `[ID]`.
        let detail: String
    }

    static let visibleRows = 8

    private(set) var items: [Item] = []
    /// The selected item, or -1 while none is.
    private(set) var selected = -1
    /// The first item in sight; the list scrolls to keep the selection in it.
    private(set) var first = 0
    var font = NSFont.systemFont(ofSize: 14)

    init() { super.init(radius: 8) }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var rowHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) + 8 }
    private var detailFont: NSFont { NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.75, weight: .regular) }

    func show(_ items: [Item], selected: Int) {
        self.items = items
        first = 0
        select(selected)
        setFrameSize(fittingSize)
    }

    func select(_ index: Int) {
        selected = index
        if index >= 0 {
            if index < first { first = index }
            if index >= first + Self.visibleRows { first = index - Self.visibleRows + 1 }
        }
        redraw()
    }

    override var fittingSize: NSSize {
        let words = items.map { ($0.word as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let details = items.map { ($0.detail as NSString).size(withAttributes: [.font: detailFont]).width }.max() ?? 0
        let width = min(420, ceil(words + (details > 0 ? details + 24 : 0) + 24))
        return NSSize(width: max(120, width), height: CGFloat(min(items.count, Self.visibleRows)) * rowHeight + 8)
    }

    override func drawContent() {
        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        fill.setFill()
        panel.fill()
        NSColor.separatorColor.setStroke()
        panel.stroke()
        let shown = items.indices.dropFirst(first).prefix(Self.visibleRows)
        for (row, index) in shown.enumerated() {
            let rect = NSRect(x: 4, y: 4 + CGFloat(row) * rowHeight, width: bounds.width - 8, height: rowHeight)
            if index == selected {
                NSPalette.named("orange", alpha: 0.28).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            }
            let item = items[index]
            let word = NSAttributedString(string: item.word, attributes: [
                .font: font, .foregroundColor: index == selected ? NSPalette.text : NSPalette.text.withAlphaComponent(0.85),
            ])
            let height = word.size().height
            let detail = NSAttributedString(string: item.detail, attributes: [.font: detailFont, .foregroundColor: NSPalette.faint])
            let detailWidth = item.detail.isEmpty ? 0 : detail.size().width
            word.draw(with: NSRect(x: rect.minX + 8, y: rect.midY - height / 2, width: rect.width - detailWidth - 24, height: height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            if detailWidth > 0 {
                let size = detail.size()
                detail.draw(at: NSPoint(x: rect.maxX - 8 - size.width, y: rect.midY - size.height / 2))
            }
        }
        // More items below or above: a thin bar along the right edge.
        if items.count > Self.visibleRows {
            let track = bounds.height - 16
            let bar = NSRect(
                x: bounds.width - 5, y: 8 + track * CGFloat(first) / CGFloat(items.count),
                width: 2.5, height: max(12, track * CGFloat(Self.visibleRows) / CGFloat(items.count)))
            NSPalette.faint.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.25, yRadius: 1.25).fill()
        }
    }
}

extension NoteTextView {
    /// Neovim shows its menu for the word that ends at the cursor; [row]
    /// is -1 for the command line's, which shows above the status bar.
    func showNeovimMenu(_ items: [NeovimMenu.Item], selected: Int, forCommandLine: Bool) {
        guard !items.isEmpty else { return hideNeovimMenu() }
        let menu = extras.menu ?? {
            let menu = NeovimMenu()
            addSubview(menu)
            extras.menu = menu
            return menu
        }()
        menu.font = Fonts.text(size: CGFloat(controller?.store.settings.textSize ?? 14))
        menu.blurred = controller?.store.settings.blurPanels ?? true
        menu.show(items, selected: selected)
        placeNeovimMenu(menu, forCommandLine: forCommandLine)
        menu.redraw()
    }

    func selectNeovimMenu(_ selected: Int) { extras.menu?.select(selected) }

    func hideNeovimMenu() {
        extras.menu?.removeFromSuperview()
        extras.menu = nil
    }

    /// Under the word the cursor is in, or above it where there is no room
    /// below; in the view's sight either way.
    private func placeNeovimMenu(_ menu: NeovimMenu, forCommandLine: Bool) {
        let size = menu.frame.size
        let visible = visibleRect
        if forCommandLine {
            // Under the floating command line, at its left edge.
            if let panel = controller?.container?.commandPanel {
                let rect = convert(panel.bounds, from: panel)
                menu.setFrameOrigin(NSPoint(x: max(visible.minX + 4, rect.minX + 8), y: rect.maxY + 4))
            } else {
                menu.setFrameOrigin(NSPoint(x: visible.minX + 12, y: visible.maxY - size.height - 6))
            }
            return
        }
        let text = string as NSString
        var start = min(selectedRange().location, text.length)
        while start > 0 {
            let previous = text.rangeOfComposedCharacterSequence(at: start - 1)
            let character = text.substring(with: previous)
            guard character.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }) else { break }
            start = previous.location
        }
        guard let caret = letterCaret(at: start), let line = lineRect(at: start) else { return }
        var origin = NSPoint(x: caret.minX - 12, y: line.maxY + 2)
        if origin.y + size.height > visible.maxY, line.minY - size.height - 2 >= visible.minY {
            origin.y = line.minY - size.height - 2
        }
        origin.x = max(visible.minX + 4, min(origin.x, visible.maxX - size.width - 4))
        menu.setFrameOrigin(origin)
    }
}

/// Neovim's command line -- `:`, `/`, `?`, an `input()` prompt -- as a
/// panel floating near the top of the editor, with its own cursor.
final class CommandLinePanel: FloatingPanel {
    var line = NeovimSession.CommandLine(prefix: ":", text: "", position: 0) {
        didSet { if line != oldValue { redraw() } }
    }

    init() { super.init(radius: 9) }

    required init?(coder: NSCoder) { nil }

    private var font: NSFont { Fonts.code(size: 14) }

    /// What a cursor at UTF-8 byte [position] of [text] is before, in UTF-16.
    static func offset(of position: Int, in text: String) -> Int {
        let bytes = Array(text.utf8.prefix(max(0, position)))
        return (String(decoding: bytes, as: UTF8.self) as NSString).length
    }

    override func drawContent() {
        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        fill.setFill()
        panel.fill()
        NSPalette.named("orange", alpha: 0.6).setStroke()
        panel.lineWidth = 1
        panel.stroke()
        let prefix = NSAttributedString(string: line.prefix, attributes: [.font: font, .foregroundColor: NSPalette.accent])
        let text = NSAttributedString(string: line.text, attributes: [.font: font, .foregroundColor: NSPalette.text])
        let height = text.size().height == 0 ? prefix.size().height : text.size().height
        let y = bounds.midY - height / 2
        prefix.draw(at: NSPoint(x: 14, y: y))
        let start = 14 + prefix.size().width + 6
        // The end of a long line in sight: the text slides left past the edge.
        let before = NSAttributedString(
            string: (line.text as NSString).substring(to: min((line.text as NSString).length, Self.offset(of: line.position, in: line.text))),
            attributes: [.font: font])
        let room = bounds.width - start - 16
        let shift = max(0, before.size().width - room)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: start, y: 0, width: max(0, room + 4), height: bounds.height)).addClip()
        text.draw(at: NSPoint(x: start - shift, y: y))
        NSPalette.accent.setFill()
        NSRect(x: start - shift + before.size().width, y: y + 1, width: 2, height: height - 2).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A panel that floats over the editor -- Neovim's menu, its command line --
/// over a blur of the note behind it, as Neovide's floating windows. It is
/// solid with `blur_panels` off or with "Reduce transparency" on.
class FloatingPanel: NSView {
    private let blur = NSVisualEffectView()
    private let canvas = PanelCanvas()
    private let radius: CGFloat

    var blurred = true {
        didSet { if blurred != oldValue { blur.isHidden = !isBlurred; redraw() } }
    }

    /// The blur shows: the setting is on and macOS does not ask for solid panels.
    var isBlurred: Bool { blurred && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }

    /// The panel's own colour, thin over the blur so the note shows through.
    var fill: NSColor { isBlurred ? NSPalette.panel.withAlphaComponent(0.72) : NSPalette.panel }

    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
        blur.blendingMode = .withinWindow
        blur.material = .popover
        blur.state = .active
        blur.maskImage = Self.mask(radius: radius)
        blur.isHidden = !isBlurred
        canvas.panel = self
        addSubview(blur)
        addSubview(canvas)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        blur.frame = bounds
        canvas.frame = bounds
    }

    /// Draws what the panel shows, over the blur.
    func drawContent() {}

    func redraw() { canvas.needsDisplay = true }

    /// The blur's rounded corners: a mask that stretches between them.
    private static func mask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

private final class PanelCanvas: NSView {
    weak var panel: FloatingPanel?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { panel?.drawContent() }
}

/// The four corners of a cursor that moves with a trail, as Neovide's: the
/// corners in front go fast, the ones behind follow, and the cursor
/// stretches over the way between.
struct CursorTrail {
    /// How long the last corner takes, and a short move, as one letter typed.
    static let length = 0.15
    static let short = 0.04
    /// The corners' times, from the one most in front, as parts of [length].
    static let shares = [0.35, 0.5, 0.9, 1.0]

    /// Top left, top right, bottom right, bottom left.
    private(set) var corners: [CGPoint]
    private(set) var target: NSRect
    private var from: [CGPoint]
    private var lengths = [0.0, 0, 0, 0]
    private var started: Double = 0

    init(_ rect: NSRect) {
        target = rect
        corners = Self.points(rect)
        from = corners
    }

    static func points(_ rect: NSRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    /// Where the corners are now, as one rectangle around them.
    var bounds: NSRect {
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return NSRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Each corner sets out from where it is to [rect] at [time]; with
    /// [trail], those in front go first.
    mutating func move(to rect: NSRect, at time: Double, trail: Bool, short: Bool) {
        from = corners
        target = rect
        started = time
        let centre = CGPoint(x: (corners[0].x + corners[2].x) / 2, y: (corners[0].y + corners[2].y) / 2)
        let move = CGPoint(x: rect.midX - centre.x, y: rect.midY - centre.y)
        guard trail, !short, move.x != 0 || move.y != 0 else {
            lengths = Array(repeating: short ? Self.short : Self.length, count: 4)
            return
        }
        // How far each corner is in front: its place from the middle, along the move.
        let to = Self.points(rect)
        let lead = to.map { ($0.x - rect.midX) * move.x + ($0.y - rect.midY) * move.y }
        for (rank, index) in lead.indices.sorted(by: { lead[$0] > lead[$1] }).enumerated() {
            lengths[index] = Self.length * Self.shares[rank]
        }
    }

    /// The corners at [time]; true while one still moves.
    mutating func step(at time: Double) -> Bool {
        let to = Self.points(target)
        var moving = false
        for index in 0..<4 {
            let part = lengths[index] <= 0 ? 1 : min(1, max(0, (time - started) / lengths[index]))
            let eased = 1 - pow(1 - part, 3)
            corners[index] = CGPoint(
                x: from[index].x + (to[index].x - from[index].x) * eased,
                y: from[index].y + (to[index].y - from[index].y) * eased)
            if part < 1 { moving = true }
        }
        return moving
    }
}

/// Neovim mode's cursor: a block in normal mode, a bar while typing, that
/// slides to where it goes and stretches on the way, as Neovide's does. It
/// is behind the text, so the letter under the block reads; without the
/// keys it is an outline.
final class NeovimCursor: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var trail = CursorTrail(.zero)
    private var link: CADisplayLink?
    private var look = (block: true, focused: true)

    /// Where the cursor goes, or is.
    var target: NSRect { trail.target }

    func style(block: Bool, focused: Bool) {
        guard look != (block, focused) else { return }
        look = (block, focused)
        needsDisplay = true
    }

    /// To [rect], at once or over a moment.
    func move(to rect: NSRect, animated: Bool, trail withTrail: Bool, short: Bool) {
        guard animated, window != nil else {
            stop()
            trail = CursorTrail(rect)
            frame = rect
            needsDisplay = true
            return
        }
        trail.move(to: rect, at: CACurrentMediaTime(), trail: withTrail, short: short)
        if link == nil {
            let link = displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func tick() {
        if !trail.step(at: CACurrentMediaTime()) { stop() }
        frame = trail.bounds
        needsDisplay = true
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }

    override func removeFromSuperview() {
        stop()
        super.removeFromSuperview()
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSPalette.accent
        let path: NSBezierPath
        if link == nil {
            path = NSBezierPath(roundedRect: bounds.insetBy(dx: look.focused ? 0 : 0.5, dy: look.focused ? 0 : 0.5), xRadius: 2, yRadius: 2)
        } else {
            // On the way: the four corners, where each one is.
            path = NSBezierPath()
            for (index, corner) in trail.corners.enumerated() {
                let point = NSPoint(x: corner.x - frame.minX, y: corner.y - frame.minY)
                if index == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            path.close()
        }
        if look.focused {
            accent.withAlphaComponent(look.block ? 0.55 : 1).setFill()
            path.fill()
        } else {
            accent.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

/// Neovide's cursor effects (`vfx_mode`): particles and rings where the
/// cursor goes, that fade out. Positions are in the text view's frame.
struct CursorParticles {
    enum Shape: Equatable {
        case dot
        /// A rectangle that grows out from the cursor (sonicboom).
        case box(NSRect)
        /// A circle that grows from the cursor's middle (ripple).
        case circle(CGFloat)
    }

    struct Particle {
        var position: CGPoint
        var velocity: CGVector
        var age = 0.0
        let life: Double
        let radius: CGFloat
        let shape: Shape

        /// From 1 when it starts to 0 when it goes.
        var strength: Double { max(0, 1 - age / life) }
    }

    static let most = 60

    private(set) var particles: [Particle] = []
    var random: () -> Double = { Double.random(in: 0..<1) }

    mutating func spawn(_ effect: AppSettings.CursorEffect, from: NSRect, to: NSRect) {
        let start = CGPoint(x: from.midX, y: from.midY), end = CGPoint(x: to.midX, y: to.midY)
        let way = CGVector(dx: end.x - start.x, dy: end.y - start.y)
        let distance = hypot(way.dx, way.dy)
        let direction = distance > 0 ? CGVector(dx: way.dx / distance, dy: way.dy / distance) : CGVector(dx: 1, dy: 0)
        let cell = max(6, min(to.width, to.height))
        // About seven to a letter's width of the way, as Neovide's density.
        let count = min(Self.most / 2, max(4, Int(distance / cell * 7)))
        func along(_ index: Int) -> CGPoint {
            let part = CGFloat(index) / CGFloat(count)
            return CGPoint(x: start.x + way.dx * part, y: start.y + way.dy * part)
        }
        switch effect {
        case .none:
            return
        case .railgun:
            // Shot along the way, each turning a little more than the last.
            let angle = atan2(direction.dy, direction.dx)
            for index in 0..<count {
                let turn = angle + .pi / 2 + Double(index) / Double(count) * 1.5 * 2 * .pi
                add(Particle(position: along(index), velocity: CGVector(dx: cos(turn) * 40, dy: sin(turn) * 40),
                             life: 0.4 + random() * 0.3, radius: 1.5, shape: .dot))
            }
        case .torpedo:
            // Left behind, drifting back and to the sides.
            for index in 0..<count {
                let side = (random() - 0.5) * 50
                add(Particle(position: along(index), velocity: CGVector(dx: -direction.dx * 40 - direction.dy * side, dy: -direction.dy * 40 + direction.dx * side),
                             life: 0.4 + random() * 0.3, radius: 1.5, shape: .dot))
            }
        case .pixiedust:
            // Dust that falls from where the cursor went.
            for index in 0..<count {
                let point = along(index)
                add(Particle(position: CGPoint(x: point.x + (random() - 0.5) * to.width, y: point.y + (random() - 0.5) * to.height),
                             velocity: CGVector(dx: (random() - 0.5) * 30, dy: 20 + random() * 40),
                             life: 0.6 + random() * 0.4, radius: 1 + random(), shape: .dot))
            }
        case .sonicboom:
            add(Particle(position: end, velocity: CGVector(dx: 0, dy: 0), life: 0.35, radius: 14, shape: .box(to)))
        case .ripple:
            add(Particle(position: end, velocity: CGVector(dx: 0, dy: 0), life: 0.45, radius: to.height * 2, shape: .circle(to.height * 2)))
        }
    }

    private mutating func add(_ particle: Particle) {
        particles.append(particle)
        if particles.count > Self.most { particles.removeFirst(particles.count - Self.most) }
    }

    /// [seconds] later: each one moves, slows and ages, and the old go.
    mutating func step(by seconds: Double) {
        for index in particles.indices {
            particles[index].age += seconds
            particles[index].position.x += particles[index].velocity.dx * seconds
            particles[index].position.y += particles[index].velocity.dy * seconds
            particles[index].velocity.dx *= 0.96
            particles[index].velocity.dy *= 0.96
        }
        particles.removeAll { $0.age >= $0.life }
    }
}

/// The particles over the text, in the part of it in sight; a click goes
/// through to the text.
final class CursorEffectsView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private(set) var particles = CursorParticles()
    private var link: CADisplayLink?
    private var last: Double = 0

    func spawn(_ effect: AppSettings.CursorEffect, from: NSRect, to: NSRect) {
        particles.spawn(effect, from: from, to: to)
        guard !particles.particles.isEmpty, link == nil else { return }
        last = CACurrentMediaTime()
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        particles.step(by: min(0.05, now - last))
        last = now
        if particles.particles.isEmpty {
            link?.invalidate()
            link = nil
        }
        if let visible = superview?.visibleRect, frame != visible { frame = visible }
        needsDisplay = true
    }

    override func removeFromSuperview() {
        link?.invalidate()
        link = nil
        super.removeFromSuperview()
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSPalette.accent
        for particle in particles.particles {
            let strength = particle.strength
            let point = NSPoint(x: particle.position.x - frame.minX, y: particle.position.y - frame.minY)
            switch particle.shape {
            case .dot:
                accent.withAlphaComponent(0.8 * strength).setFill()
                NSBezierPath(ovalIn: NSRect(x: point.x - particle.radius, y: point.y - particle.radius, width: particle.radius * 2, height: particle.radius * 2)).fill()
            case .box(let rect):
                let grow = particle.radius * (1 - strength)
                let box = rect.offsetBy(dx: -frame.minX, dy: -frame.minY).insetBy(dx: -grow, dy: -grow)
                accent.withAlphaComponent(0.7 * strength).setStroke()
                let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
                path.lineWidth = 1.5
                path.stroke()
            case .circle(let most):
                let radius = most * (1 - strength)
                accent.withAlphaComponent(0.6 * strength).setStroke()
                let path = NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
                path.lineWidth = 1.5
                path.stroke()
            }
        }
    }
}

extension NoteTextView {
    /// Where Neovim's cursor is: the block over the letter in normal mode,
    /// a bar at the letters' height while typing; none over a selection.
    func moveNeovimCursor() {
        let visual = vim.map { $0.mode.first == "v" || $0.mode.first == "V" || $0.mode == "\u{16}" } ?? false
        guard vimActive, let vim, !visual, selectedRange().length == 0 else {
            extras.neovimCursor?.removeFromSuperview()
            extras.neovimCursor = nil
            if !vimActive {
                extras.cursorEffects?.removeFromSuperview()
                extras.cursorEffects = nil
            }
            return
        }
        let target: NSRect
        if vim.isNormal {
            guard let block = blockRect() else { return }
            target = block
        } else {
            guard let caret = letterCaret(at: selectedRange().location) else { return }
            target = NSRect(x: caret.minX, y: caret.minY, width: 2, height: caret.height)
        }
        let first = extras.neovimCursor == nil
        let cursor = extras.neovimCursor ?? {
            let cursor = NeovimCursor(frame: .zero)
            // Behind the text, over the editor's own background and tint.
            addSubview(cursor, positioned: .below, relativeTo: nil)
            extras.neovimCursor = cursor
            return cursor
        }()
        cursor.style(block: vim.isNormal, focused: window?.isKeyWindow == true && window?.firstResponder === self)
        let from = cursor.target
        guard first || from != target else { return }
        let settings = controller?.store.settings
        // A jump of a screen or more, or a first place, is at once; a window
        // not on screen runs no animation.
        let moves = !first && abs(from.midY - target.midY) < visibleRect.height && window?.isVisible == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // A letter typed, or one to the side: no trail, and quicker.
        let short = abs(from.midY - target.midY) < 1 && abs(from.midX - target.midX) <= max(from.width, target.width, 8) * 2
        cursor.move(to: target, animated: moves && settings?.animateCursor ?? true, trail: settings?.cursorTrail ?? true, short: short)
        let effect = settings?.cursorEffect ?? AppSettings.CursorEffect.none
        if moves, effect != .none {
            let effects = extras.cursorEffects ?? {
                let effects = CursorEffectsView(frame: visibleRect)
                addSubview(effects)
                extras.cursorEffects = effects
                return effects
            }()
            effects.spawn(effect, from: from, to: target)
        }
    }
}
