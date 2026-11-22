import AppKit

/// The format bar: bold, italic, highlight, code, strike and a link to a
/// note, over the selected text (`editor.format_bar`, docs/specs/look.md in
/// notes-linux). Its buttons run the editor's own commands, the ones ⌘B and
/// the others run, so a click is one undo step as a key is. It never takes
/// the keys from the text.
final class FormatBar: NSView {
    weak var textView: NoteTextView?
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    /// A button's title, what it says under the pointer, and the marker it
    /// wraps the selection in; nil is `[[ ]]`.
    static let items: [(title: String, help: String, marker: String?)] = [
        ("B", "Bold (⌘B)", "**"), ("I", "Italic (⌘I)", "*"), ("==", "Highlight", "=="), ("</>", "Code", "`"), ("S", "Strikethrough", "~~"),
        ("[[ ]]", "Link to a note (⌘K)", nil),
    ]

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 9
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        self.shadow = shadow
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        for (index, item) in Self.items.enumerated() {
            let button = NSButton(title: item.title, target: self, action: #selector(press))
            button.tag = index
            button.isBordered = false
            button.refusesFirstResponder = true
            button.toolTip = item.help
            button.setAccessibilityLabel(item.help)
            button.contentTintColor = NSPalette.text
            let size: CGFloat = 12
            button.font = switch item.title {
            case "B": .systemFont(ofSize: size, weight: .bold)
            case "I": NSFontManager.shared.convert(.systemFont(ofSize: size, weight: .medium), toHaveTrait: .italicFontMask)
            case "S": .systemFont(ofSize: size, weight: .medium)
            default: .monospacedSystemFont(ofSize: size - 1, weight: .medium)
            }
            if item.title == "S" {
                button.attributedTitle = NSAttributedString(
                    string: "S",
                    attributes: [
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue, .font: NSFont.systemFont(ofSize: size, weight: .medium),
                        .foregroundColor: NSPalette.text,
                    ])
            }
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
            stack.addArrangedSubview(button)
        }
        addSubview(stack)
        setFrameSize(stack.fittingSize)
        stack.frame = bounds
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The palette's colours, as the window's appearance has them now.
    override func updateLayer() {
        layer?.backgroundColor = NSPalette.panel.cgColor
        layer?.borderColor = NSPalette.selection.cgColor
    }

    @objc private func press(_ sender: NSButton) {
        guard let textView, Self.items.indices.contains(sender.tag) else { return }
        if let marker = Self.items[sender.tag].marker { textView.wrap(marker) } else { textView.insertLink() }
    }
}

extension NoteTextView {
    /// Whether the selection is one the bar formats: some text of one
    /// paragraph, in the plain editor (Neovim owns its own text), with one cursor.
    var formatsSelection: Bool {
        let range = selectedRange()
        guard range.length > 0, !vimActive, !hasManyCursors, controller?.store.settings.formatBar != false else { return false }
        return !(string as NSString).substring(with: range).contains("\n")
    }

    /// The bar over the start of the selection, or under its end when there
    /// is no room above; gone with the selection.
    func showFormatBar() {
        guard formatsSelection, let start = letterCaret(at: selectedRange().location) else {
            extras.formatBar?.isHidden = true
            return
        }
        let bar = extras.formatBar ?? {
            let bar = FormatBar()
            bar.textView = self
            addSubview(bar)
            extras.formatBar = bar
            return bar
        }()
        let visible = visibleRect
        var origin = NSPoint(x: start.minX, y: start.minY - bar.frame.height - 6)
        if origin.y < visible.minY + 2, let end = letterCaret(at: NSMaxRange(selectedRange())) { origin.y = end.maxY + 6 }
        origin.x = max(visible.minX + 4, min(origin.x, visible.maxX - bar.frame.width - 4))
        bar.setFrameOrigin(origin)
        bar.isHidden = false
    }
}
