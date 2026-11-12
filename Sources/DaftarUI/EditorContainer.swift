import AppKit
import DaftarCore

/// The editor and a bar under it: the words and characters of the note or
/// of the selection, and in Neovim mode the mode and the command line, as
/// Neovim's own status and command lines are.
final class EditorContainer: NSView {
    let scroll: NSScrollView
    private let bar = NSView()
    private let mode = NSTextField(labelWithString: "")
    private let message = NSTextField(labelWithString: "")
    private let counts = NSTextField(labelWithString: "")
    private var barHeight: NSLayoutConstraint!
    var onLayout: (() -> Void)?

    init(scroll: NSScrollView) {
        self.scroll = scroll
        super.init(frame: .zero)
        for view in [scroll, bar, mode, message, counts] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(scroll)
        addSubview(bar)
        bar.addSubview(mode)
        bar.addSubview(message)
        bar.addSubview(counts)
        counts.alignment = .right
        counts.setContentCompressionResistancePriority(.required, for: .horizontal)
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSPalette.panel.cgColor
        mode.font = Fonts.code(size: 11)
        mode.textColor = NSPalette.background
        mode.wantsLayer = true
        mode.layer?.cornerRadius = 4
        mode.alignment = .center
        message.font = Fonts.code(size: 12)
        message.textColor = NSPalette.text
        message.lineBreakMode = .byTruncatingTail
        barHeight = bar.heightAnchor.constraint(equalToConstant: 24)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            barHeight,
            mode.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            mode.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            mode.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            message.leadingAnchor.constraint(equalTo: mode.trailingAnchor, constant: 10),
            message.trailingAnchor.constraint(lessThanOrEqualTo: counts.leadingAnchor, constant: -12),
            message.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            counts.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            counts.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        mode.isHidden = true
    }

    /// "1,204 words · 6,880 characters", or "12 of 1,204 words" over a
    /// selection, the numbers in the accent colours.
    func setCounts(words: Int, characters: Int, selectedWords: Int?, selectedCharacters: Int?) {
        let number = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let label = NSFont.systemFont(ofSize: 11)
        let out = NSMutableAttributedString()
        func add(_ text: String, _ color: NSColor, _ font: NSFont) {
            out.append(NSAttributedString(string: text, attributes: [.foregroundColor: color, .font: font]))
        }
        func part(_ selected: Int?, _ total: Int, _ unit: String, _ color: NSColor) {
            if let selected {
                add(selected.formatted(), color, number)
                add(" of ", NSPalette.muted, label)
            }
            add(total.formatted(), selected == nil ? color : NSPalette.muted, number)
            add(" " + unit + (total == 1 ? "" : "s"), NSPalette.muted, label)
        }
        part(selectedWords, words, "word", NSPalette.accent)
        add("  ·  ", NSPalette.faint, label)
        part(selectedCharacters, characters, "character", NSPalette.link)
        counts.attributedStringValue = out
    }

    required init?(coder: NSCoder) { nil }

    /// Neovim's command line, floating near the top of the editor while it
    /// is open, as Neovide setups show it; nil hides it.
    func setCommandLine(_ line: NeovimSession.CommandLine?, blurred: Bool = true) {
        guard let line else {
            commandPanel?.removeFromSuperview()
            commandPanel = nil
            return
        }
        let panel = commandPanel ?? {
            let panel = CommandLinePanel()
            panel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(panel, positioned: .above, relativeTo: scroll)
            let wide = panel.widthAnchor.constraint(equalTo: scroll.widthAnchor, multiplier: 0.8)
            wide.priority = .defaultHigh
            NSLayoutConstraint.activate([
                panel.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 28),
                panel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
                wide,
                panel.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
                panel.heightAnchor.constraint(equalToConstant: 38),
            ])
            commandPanel = panel
            return panel
        }()
        panel.blurred = blurred
        panel.line = line
    }

    private(set) var commandPanel: CommandLinePanel?

    /// Nil hides the mode: the editor is not in Neovim mode.
    func setStatus(_ text: String?, mode name: String?) {
        guard let name else {
            mode.isHidden = true
            message.stringValue = ""
            return
        }
        mode.isHidden = false
        mode.stringValue = " \(name) "
        let color: NSColor = switch name {
        case "INSERT": NSPalette.link
        case "VISUAL", "V-LINE", "V-BLOCK": NSPalette.purple
        case "REPLACE": NSPalette.red
        default: NSPalette.accent
        }
        mode.layer?.backgroundColor = color.cgColor
        message.stringValue = text ?? ""
    }

    override func layout() {
        super.layout()
        if let view = scroll.documentView as? NoteTextView, let offset = view.extras.pendingCenter, scroll.contentView.bounds.height >= 1,
            view.selectedRange().length == 0, view.selectedRange().location == offset
        {
            // The scroll view and the text are laid out after this view: lay
            // them out now, or they would clamp the scroll back to the top.
            scroll.layoutSubtreeIfNeeded()
            view.center(offset)
        }
        onLayout?()
    }

    /// A layer's colour is fixed when it is set: the bar takes the theme again.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bar.layer?.backgroundColor = NSPalette.panel.cgColor
        }
    }
}
