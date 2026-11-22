import AppKit
import DaftarCore

/// The link preview in the editor: resting the pointer on a `[[link]]`
/// shows a small card with the note's title and its first lines
/// (`appearance.link_preview`, docs/specs/look.md in notes-linux, part 2).
/// What the card says is `LinkCard` (core); its body is drawn by the
/// editor's own styling, with the marks hidden. The card never has the
/// keys, and nothing in its body is live.
final class LinkCardView: NSView {
    weak var textView: NoteTextView?
    let card: LinkCard
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static let width: CGFloat = 360
    static let most: CGFloat = 240
    static let headHeight: CGFloat = 36

    private let head = LinkCardHead()
    private let scroll: NSScrollView
    /// The body's own editor: it styles the first lines as a note is styled.
    private let body: EditorController?
    /// What the card says where there are no lines.
    private let words: NSTextField?

    /// [most] is the room the card has when that is less than its 240 px.
    init(card: LinkCard, store: VaultStore, width: CGFloat, most: CGFloat = LinkCardView.most) {
        self.card = card
        scroll = NoteTextView.scrollableNoteView()
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        let width = min(Self.width, width)
        var bodyHeight: CGFloat = 0
        if case .lines(let lines) = card.body, let view = scroll.documentView as? NoteTextView {
            let controller = EditorController(store: store)
            controller.isPreview = true
            controller.textScale = 0.9
            controller.view = view
            view.controller = controller
            view.isEditable = false
            view.isSelectable = false
            view.drawsBackground = false
            scroll.frame = NSRect(x: 0, y: 0, width: width - 2, height: Self.most)
            view.frame = NSRect(x: 0, y: 0, width: width - 2, height: Self.most)
            controller.showPreview(lines)
            if let layout = view.textLayoutManager {
                layout.ensureLayout(for: layout.documentRange)
                bodyHeight = ceil(layout.usageBoundsForTextContainer.maxY) + view.textContainerInset.height * 2
            }
            body = controller
            words = nil
        } else {
            body = nil
            // "No note yet." and "The note is empty.", in italic.
            let label = NSTextField(labelWithString: card.body.words ?? "")
            label.font = NSFontManager.shared.convert(.systemFont(ofSize: 14), toHaveTrait: .italicFontMask)
            label.textColor = NSPalette.muted
            words = label
            bodyHeight = 44
        }
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: min(Self.most, most, Self.headHeight + bodyHeight)))
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        // 0 14px 40px black at 35%, as the reader's card. No ring and no border in the accent.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 40
        shadow.shadowOffset = NSSize(width: 0, height: -14)
        self.shadow = shadow
        let inner = NSView(frame: bounds.insetBy(dx: 1, dy: 1))
        inner.wantsLayer = true
        inner.layer?.cornerRadius = 11
        inner.layer?.masksToBounds = true
        addSubview(inner)
        head.card = card
        head.frame = NSRect(x: 0, y: inner.bounds.height - Self.headHeight, width: inner.bounds.width, height: Self.headHeight)
        let below = NSRect(x: 0, y: 0, width: inner.bounds.width, height: inner.bounds.height - Self.headHeight)
        if let words {
            words.frame = NSRect(x: 14, y: below.midY - 10, width: below.width - 28, height: 20)
            inner.addSubview(words)
        } else {
            scroll.frame = below
            inner.addSubview(scroll)
        }
        inner.addSubview(head)
        setAccessibilityLabel("Preview of \(card.title)")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The body's editor is the store's no more.
    func close() {
        guard let body else { return }
        body.store.flushers[ObjectIdentifier(body)] = nil
        body.store.unsaved[ObjectIdentifier(body)] = nil
        body.store.followers[ObjectIdentifier(body)] = nil
        body.store.checks.editors[ObjectIdentifier(body)] = nil
    }

    override func updateLayer() {
        layer?.backgroundColor = NSPalette.background.cgColor
        layer?.borderColor = NSPalette.tableHairline.cgColor
    }

    /// The body's text as it is styled, for a test.
    var bodyText: NSTextStorage? { (scroll.documentView as? NSTextView)?.textStorage }
    var bodyWords: String? { words?.stringValue }

    /// Every click and every turn of the wheel in the card is the card's:
    /// nothing in the body is live.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    /// Whether [point] of the card is in its head.
    func isHead(_ point: NSPoint) -> Bool { point.y >= 0 && point.y <= Self.headHeight + 1 && point.x >= 0 && point.x <= bounds.width }

    /// A click on the head opens the note, as a click on the link does; a click in the body does nothing.
    override func mouseDown(with event: NSEvent) {
        guard isHead(convert(event.locationInWindow, from: nil)) else { return }
        textView?.openLinkCard()
    }

    /// The wheel scrolls a body longer than the card.
    override func scrollWheel(with event: NSEvent) {
        guard words == nil else { return }
        scroll.scrollWheel(with: event)
    }
}

/// The head of a link's card: the title in the accent at weight 700, then
/// `› Heading` in the heading 3 colour, and the folder at the end side in
/// the faint colour, on the panel colour with a hairline under it.
private final class LinkCardHead: NSView {
    var card: LinkCard?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let card else { return }
        NSPalette.panel.setFill()
        bounds.fill()
        NSPalette.tableHairline.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        let em: CGFloat = 14
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        // A link to no note: its name in the faint colour.
        let missing = card.body == .missing
        let title = NSMutableAttributedString(
            string: card.title,
            attributes: [.font: NSFont.systemFont(ofSize: em, weight: .bold), .foregroundColor: missing ? NSPalette.faint : NSPalette.accent, .paragraphStyle: paragraph])
        if let heading = card.heading {
            title.append(NSAttributedString(
                string: "  › " + heading,
                attributes: [.font: NSFont.systemFont(ofSize: em * 0.9, weight: .medium), .foregroundColor: NSPalette.heading3, .paragraphStyle: paragraph]))
        }
        let folder = NSAttributedString(string: card.folder, attributes: [.font: NSFont.systemFont(ofSize: em * 0.82), .foregroundColor: NSPalette.faint, .paragraphStyle: paragraph])
        // The folder has at most 40% of the head; the title has the rest.
        let folderWidth = card.folder.isEmpty ? 0 : min(ceil(folder.size().width), (bounds.width - 28) * 0.4)
        let titleHeight = title.size().height
        title.draw(in: NSRect(x: 14, y: (bounds.height - titleHeight) / 2, width: bounds.width - 28 - (folderWidth > 0 ? folderWidth + 10 : 0), height: titleHeight))
        guard folderWidth > 0 else { return }
        let folderHeight = folder.size().height
        folder.draw(in: NSRect(x: bounds.maxX - 14 - folderWidth, y: (bounds.height - folderHeight) / 2 + 0.5, width: folderWidth, height: folderHeight))
    }
}

extension EditorController {
    /// The first lines of a note in a card's body: styled as a note is, at
    /// the card's text size, with every mark hidden and no cursor to show one.
    func showPreview(_ lines: String) {
        guard let view, let storage = view.textStorage else { return }
        replacing = true
        storage.setAttributedString(NSAttributedString(string: lines, attributes: base))
        revealed = NSRange(location: NSNotFound, length: 0)
        replacing = false
        restyle(all: true)
    }
}

/// The link the pointer rests on, and its card once it shows.
@MainActor
final class LinkHover {
    /// The link's place in the text, brackets counted, and what it names.
    let range: NSRange
    let link: Wikilink
    var view: LinkCardView?
    /// The card shows after the rest, and goes after the linger.
    var rest: DispatchWorkItem?
    var hide: DispatchWorkItem?
    var observers: [NSObjectProtocol] = []

    init(range: NSRange, link: Wikilink) {
        self.range = range
        self.link = link
    }
}

extension NoteTextView {
    /// The `[[link]]` drawn at [point], raw or with its marks hidden: its
    /// place in the text and what it names. Nil on an embed, in code, in
    /// the front matter, and beside the link's letters.
    func link(at point: NSPoint) -> (range: NSRange, link: Wikilink)? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let text = storage.string as NSString
        let at = characterIndexForInsertion(at: point)
        for offset in [at, at - 1] where offset >= 0 && offset < text.length {
            let line = text.lineRange(for: NSRange(location: offset, length: 0))
            guard let found = LinkCard.link(at: offset - line.location, in: text.substring(with: line) as NSString) else { continue }
            let range = NSRange(location: line.location + found.range.location, length: found.range.length)
            // A link of the note's Markdown, not of a code block, inline code or the front matter.
            let state = controller?.blockStates.peek(before: line.location, in: text) ?? .normal
            guard MarkdownHighlighter.spans(in: text, range: line, startingIn: state).contains(where: { $0.kind == .link && NSIntersectionRange($0.range, range).length > 0 }),
                let box = letterBox(range), box.insetBy(dx: -2, dy: -2).contains(point)
            else { return nil }
            return (range, found.link)
        }
        return nil
    }

    /// The pointer moved to [point], or left the view (nil). On a link it
    /// rests 350 ms before the card shows; off the link and the card, the
    /// card goes 250 ms later.
    func hoverLink(at point: NSPoint?) {
        guard let controller, !controller.isPreview else { return }
        extras.keySincePointer = false
        if let point, let card = extras.linkHover?.view, card.frame.contains(point) {
            // On the card: it stays.
            extras.linkHover?.hide?.cancel()
            return
        }
        guard let point, controller.store.settings.linkPreview, NSEvent.pressedMouseButtons == 0, let found = link(at: point) else {
            return pointerLeftLink()
        }
        if let hover = extras.linkHover, hover.range == found.range, hover.link == found.link {
            hover.hide?.cancel()
            return
        }
        closeLinkCard()
        let hover = LinkHover(range: found.range, link: found.link)
        extras.linkHover = hover
        let rest = DispatchWorkItem { [weak self, weak hover] in
            guard let self, let hover, self.extras.linkHover === hover else { return }
            self.showLinkCard()
        }
        hover.rest = rest
        DispatchQueue.main.asyncAfter(deadline: .now() + LinkCard.rest, execute: rest)
        // A scroll of the note and a window that loses the focus close the card at once.
        let center = NotificationCenter.default
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            hover.observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.closeLinkCard() }
            })
        }
        if let window {
            hover.observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.closeLinkCard() }
            })
        }
    }

    /// The pointer is on no link and not on the card.
    private func pointerLeftLink() {
        guard let hover = extras.linkHover else { return }
        guard hover.view != nil else { return closeLinkCard() }
        guard hover.hide == nil || hover.hide?.isCancelled == true else { return }
        let hide = DispatchWorkItem { [weak self, weak hover] in
            guard let self, let hover, self.extras.linkHover === hover else { return }
            self.closeLinkCard()
        }
        hover.hide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + LinkCard.linger, execute: hide)
    }

    /// The card of the link the pointer rests on: under the link, 6 px
    /// away, its start edge on the link's; over it when there is no room
    /// below; inside the view by 8 px. Not when a key was pressed since the
    /// pointer last moved, with a mouse button down, for a file that is no
    /// note, or with the setting off.
    func showLinkCard() {
        guard let hover = extras.linkHover, hover.view == nil, let controller, controller.store.settings.linkPreview, !extras.keySincePointer,
            NSEvent.pressedMouseButtons == 0
        else { return closeLinkCard() }
        let store = controller.store
        let text = string as NSString
        guard NSMaxRange(hover.range) <= text.length, let box = letterBox(hover.range) else { return closeLinkCard() }
        let source = controller.path ?? ""
        // A link into this note (`[[#Heading]]`) shows the note as it is typed.
        let own = hover.link.target.isEmpty
        let path = own ? controller.path : store.index.resolve(hover.link.target, from: source)
        if let path, !Vault.isNote(path) { return closeLinkCard() }
        let card = LinkCard(link: hover.link, path: path, text: path.flatMap { own ? string : store.text(of: $0) })
        let visible = visibleRect
        // The room under the link and over it: a short pane makes the card lower, never puts it outside the view.
        let under = visible.maxY - 8 - (box.maxY + 6), over = box.minY - 6 - (visible.minY + 8)
        let view = LinkCardView(card: card, store: store, width: visible.width - 16, most: max(under, over, LinkCardView.headHeight + 44))
        view.textView = self
        var origin = NSPoint(x: box.minX, y: box.maxY + 6)
        if view.frame.height > under, over > under { origin.y = box.minY - 6 - view.frame.height }
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - view.frame.width - 8))
        view.setFrameOrigin(origin)
        addSubview(view)
        hover.view = view
        // It opens with a fade of 140 ms.
        guard !Motion.reduced, window?.isVisible == true else { return }
        view.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            view.animator().alphaValue = 1
        }
    }

    /// The card goes at once: a key, a scroll of the note, a click outside
    /// it, a change of the note, a window that lost the focus.
    func closeLinkCard() {
        guard let hover = extras.linkHover else { return }
        extras.linkHover = nil
        hover.rest?.cancel()
        hover.hide?.cancel()
        for observer in hover.observers { NotificationCenter.default.removeObserver(observer) }
        hover.view?.close()
        hover.view?.removeFromSuperview()
    }

    /// A click on the card's head: the note opens in the pane.
    func openLinkCard() {
        guard let path = extras.linkHover?.view?.card.path else { return }
        closeLinkCard()
        controller?.onOpen?(path)
    }
}
