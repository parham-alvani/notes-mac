import AppKit
import DaftarCore

/// The editor's styling: what an edit restyles, the attributes of each
/// kind of markdown, live preview, and the pictures a note embeds. The
/// text is never changed here; `MarkdownHighlighter` (core) finds the spans.
extension EditorController {
    // MARK: Styling

    nonisolated func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        // The text view edits its storage on the main thread only.
        nonisolated(unsafe) let textStorage = textStorage
        MainActor.assumeIsolated {
            guard !replacing else { return }
            let text = textStorage.string as NSString
            let lines = text.lineRange(for: editedRange)
            // A fence, a comment or the front matter that came or went
            // changes the lines after it too; any other edit, only its own.
            let now = Self.structure(of: text)
            let rest = now != structure
            structure = now
            if rest { hiddenFront = frontMatterToHide() }
            style(textStorage, range: rest ? NSRange(location: lines.location, length: text.length - lines.location) : lines)
        }
    }

    func restyle(all: Bool) {
        guard let storage = view?.textStorage else { return }
        styling?.cancel()
        structure = Self.structure(of: storage.string as NSString)
        hiddenFront = frontMatterToHide()
        storage.beginEditing()
        style(storage, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        view?.typingAttributes = base
    }

    /// The first screens at once, the rest a part at a time between frames:
    /// a long note opens without a pause, and its end is styled a moment later.
    func restyleProgressively() {
        guard let storage = view?.textStorage else { return }
        styling?.cancel()
        structure = Self.structure(of: storage.string as NSString)
        hiddenFront = frontMatterToHide()
        view?.typingAttributes = base
        let part = 12_000
        func next(after start: Int) -> NSRange? {
            let length = storage.length
            guard start < length else { return nil }
            let text = storage.string as NSString
            let end = NSMaxRange(text.paragraphRange(for: NSRange(location: min(start + part, length - 1), length: 0)))
            return NSRange(location: start, length: end - start)
        }
        guard let first = next(after: 0) else { return style(storage, range: NSRange(location: 0, length: 0)) }
        style(storage, range: first)
        var done = NSMaxRange(first)
        guard done < storage.length else { return }
        styling = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1))
                guard !Task.isCancelled, let storage = self.view?.textStorage, let range = next(after: done) else { return }
                storage.beginEditing()
                self.style(storage, range: range)
                storage.endEditing()
                done = NSMaxRange(range)
            }
        }
    }

    /// The lines that open or close a block, as written. It runs on every
    /// key, so it reads no line on its own: it finds `$$` and `%%` anywhere,
    /// and ```` ``` ````, `~~~` and `---` at a line's start (after spaces and
    /// `>`), with one search each over the whole text.
    static func structure(of text: NSString) -> [String] {
        let length = text.length
        // The letters copied out once and searched here: `range(of:)` took
        // about half a millisecond for each of the five marks in a long note.
        var units = [unichar](repeating: 0, count: length)
        text.getCharacters(&units, range: NSRange(location: 0, length: length))
        /// Where [count] of [mark] in a row are first, at or after [from]: a literal search.
        func find(_ mark: unichar, count: Int, from: Int) -> Int? {
            var at = from
            while at + count <= length {
                guard units[at] == mark else {
                    at += 1
                    continue
                }
                var same = 1
                while same < count, units[at + same] == mark { same += 1 }
                if same == count { return at }
                at += same
            }
            return nil
        }
        var marks: [(Int, String)] = []
        for mark: unichar in [36, 37] {  // `$$`, `%%`
            var from = 0
            while from < length {
                guard let found = find(mark, count: 2, from: from) else { break }
                let line = text.lineRange(for: NSRange(location: found, length: 2))
                marks.append((line.location, text.substring(with: line)))
                from = NSMaxRange(line)
            }
        }
        for mark: unichar in [96, 126, 45] {  // ```` ``` ````, `~~~`, `---`
            var from = 0
            while from < length {
                guard let found = find(mark, count: 3, from: from) else { break }
                var start = 0, end = 0, contents = 0
                text.getLineStart(&start, end: &end, contentsEnd: &contents, for: NSRange(location: found, length: 0))
                var at = start
                while at < contents, [32, 9, 62].contains(units[at]) { at += 1 }
                // Only where the line's text begins.
                if at == found {
                    let rest = text.substring(with: NSRange(location: at, length: contents - at))
                    if mark != 45 {
                        marks.append((start, rest))
                    } else if rest.allSatisfy({ $0 == "-" || $0 == " " }) {
                        marks.append((start, "---"))
                    }
                }
                from = end
            }
        }
        // In the order of the lines; where they are does not count, so a
        // new line above a fence keeps the structure as it was.
        return marks.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private var fontSize: CGFloat { CGFloat(store.settings.textSize) }

    var base: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        // Obsidian's line height, 1.6.
        paragraph.lineHeightMultiple = 1.6
        paragraph.paragraphSpacing = fontSize * 0.2
        // Each paragraph takes the direction of its first strong letter.
        paragraph.baseWritingDirection = .natural
        return [.font: Fonts.text(size: fontSize), .foregroundColor: NSPalette.text, .paragraphStyle: paragraph]
    }

    /// A table's lines in the code font, so that the columns a formatter
    /// padded line up, with the pipes faint. Not in a code block.
    private func lineUpTables(in range: NSRange, of storage: NSTextStorage, text: NSString, mono: NSFont) {
        text.enumerateSubstrings(in: text.lineRange(for: range), options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            guard line.length > 1, storage.attribute(NoteTextView.codeBlock, at: line.location, effectiveRange: nil) == nil else { return }
            var at = line.location
            while at < NSMaxRange(line), [32, 9].contains(text.character(at: at)) { at += 1 }
            guard at < NSMaxRange(line), text.character(at: at) == 124,
                text.range(of: "|", options: .literal, range: NSRange(location: at + 1, length: NSMaxRange(line) - at - 1)).location != NSNotFound
            else { return }
            storage.addAttribute(.font, value: mono, range: line)
            var from = line.location
            while from < NSMaxRange(line) {
                let pipe = text.range(of: "|", options: .literal, range: NSRange(location: from, length: NSMaxRange(line) - from))
                guard pipe.location != NSNotFound else { break }
                storage.addAttribute(.foregroundColor, value: NSPalette.faint, range: pipe)
                from = NSMaxRange(pipe)
            }
        }
    }

    /// The colours of a code line, by the language its fence names; when
    /// the fence is above what is being styled, it is found once.
    private func colourCode(_ r: NSRange, in storage: NSTextStorage, text: NSString, language: inout String?) {
        if language == nil {
            // Up from the line to its fence.
            var start = text.lineRange(for: NSRange(location: r.location, length: 0)).location
            var found = ""
            var lines = 0
            while start > 0, lines < 5000 {
                let above = text.lineRange(for: NSRange(location: start - 1, length: 0))
                let line = text.substring(with: above).trimmingCharacters(in: CharacterSet(charactersIn: "> \t\n"))
                if line.hasPrefix("```") || line.hasPrefix("~~~") {
                    found = line.trimmingCharacters(in: CharacterSet(charactersIn: "`~ ")).split(separator: " ").first.map(String.init) ?? ""
                    break
                }
                start = above.location
                lines += 1
            }
            language = found
        }
        let colours: [CodeTokens.Kind: NSColor] = [
            .comment: NSPalette.faint, .string: NSPalette.named("chartreuse"), .number: NSPalette.named("purple"), .keyword: NSPalette.named("pink"),
        ]
        for token in CodeTokens.tokens(in: text.substring(with: r), language: language ?? "") {
            let at = NSRange(location: r.location + token.range.location, length: token.range.length)
            guard NSMaxRange(at) <= storage.length, let colour = colours[token.kind] else { continue }
            storage.addAttribute(.foregroundColor, value: colour, range: at)
        }
    }

    /// A quote's line, marked for its bar; a callout's, for its panel in
    /// the callout's colour. A callout is a quote whose first line is `> [!kind]`.
    private func markQuote(_ line: NSRange, in storage: NSTextStorage, text: NSString) {
        var first = line
        var lines = 0
        while first.location > 0, lines < 2000 {
            let above = text.lineRange(for: NSRange(location: first.location - 1, length: 0))
            guard text.substring(with: above).drop(while: { $0 == " " || $0 == "\t" }).hasPrefix(">") else { break }
            first = above
            lines += 1
        }
        let head = text.substring(with: first)
        if let kind = head.firstMatch(of: /^\s*>\s*\[!([A-Za-z-]+)\]/).map({ String($0.1) }) {
            let color = NSPalette.calloutColor(kind)
            storage.addAttributes([NoteTextView.quoteBar: color, NoteTextView.calloutPanel: color], range: line)
        } else {
            storage.addAttribute(NoteTextView.quoteBar, value: "quote", range: line)
        }
    }

    /// A code block's lines: closer than prose, in from the panel's edge,
    /// and left to right whatever language a comment is in.
    private var codeParagraph: NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.3
        paragraph.firstLineHeadIndent = 12
        paragraph.headIndent = 12
        paragraph.tailIndent = -12
        paragraph.baseWritingDirection = .leftToRight
        return paragraph
    }

    private func style(_ storage: NSTextStorage, range: NSRange) {
        guard range.length > 0 || storage.length == 0 else { return }
        storage.setAttributes(base, range: range)
        let mono = Fonts.code(size: fontSize * 0.86)
        let text = storage.string as NSString
        // A highlight goes on top of bold and italic, so its text colour wins
        // and they keep their weight and slant; the marks go on last and dim.
        func rank(_ kind: MarkdownHighlighter.Kind) -> Int {
            switch kind {
            case .highlight: 1
            case .markup, .blockId: 2
            default: 0
            }
        }
        let spans = MarkdownHighlighter.spans(in: text, range: range).enumerated()
            .sorted { (rank($0.element.kind), $0.offset) < (rank($1.element.kind), $1.offset) }.map(\.element)
        let highlights = spans.filter { $0.kind == .highlight }.map(\.range)
        // The language of the code block being styled, from its fence.
        var language: String?
        for span in spans {
            let r = span.range
            guard NSMaxRange(r) <= storage.length else { continue }
            switch span.kind {
            case .heading(let level):
                // Cupertino's sizes and weights: light large headings, medium small ones.
                let scale: [CGFloat] = [1.75, 1.5, 1.25, 1.0, 1.0, 0.875]
                storage.addAttributes([
                    .font: Fonts.text(size: fontSize * scale[min(level, 6) - 1], weight: level <= 3 ? .regular : .medium),
                    .foregroundColor: NSPalette.heading(level),
                ], range: r)
            case .markup, .blockId:
                // On a highlight the marks dim in the highlight's own text colour.
                let marked = highlights.contains { NSIntersectionRange($0, r).length == r.length }
                storage.addAttribute(.foregroundColor, value: marked ? NSPalette.markOnHighlight : NSPalette.faint, range: r)
            case .bold:
                storage.addAttributes([.font: Fonts.text(size: fontSize, weight: .bold), .foregroundColor: NSPalette.strong], range: r)
            case .italic:
                storage.addAttributes([.font: Fonts.text(size: fontSize, italic: true), .foregroundColor: NSPalette.italic], range: r)
            case .strike:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            case .highlight:
                // `==🔴 text==`: the circle picks the colour, as in Obsidian.
                let inner = text.substring(with: r).dropFirst(2)
                let color = NSPalette.highlightColor(inner.unicodeScalars.first.map { String($0) } ?? "")
                storage.addAttributes([.backgroundColor: NSPalette.named(color, alpha: 0.45), .foregroundColor: NSPalette.text], range: r)
            case .code:
                storage.addAttributes([.font: mono, .foregroundColor: NSPalette.raw, .backgroundColor: NSPalette.panel], range: r)
            case .codeBlock:
                storage.addAttribute(.font, value: mono, range: r)
                // The whole lines with their breaks: a block is one run, one panel.
                storage.addAttributes([.paragraphStyle: codeParagraph, NoteTextView.codeBlock: true], range: text.lineRange(for: r))
                colourCode(r, in: storage, text: text, language: &language)
            case .fence:
                // The fence line in its language's colour, as the reader's label.
                let name = text.substring(with: r).trimmingCharacters(in: CharacterSet(charactersIn: "`~> \t\n"))
                    .split(separator: " ").first.map(String.init) ?? ""
                language = name
                let color = NSPalette.named(NSPalette.languageColor(name))
                storage.addAttributes([.font: mono, .foregroundColor: color], range: r)
                storage.addAttributes([.paragraphStyle: codeParagraph, NoteTextView.codeBlock: true], range: text.lineRange(for: r))
            case .frontMatter:
                storage.addAttributes([.font: mono, .foregroundColor: NSPalette.muted], range: r)
            case .link:
                storage.addAttributes([
                    .foregroundColor: NSPalette.link, .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: NSPalette.named("aqua", alpha: 0.4),
                ], range: r)
            case .embed:
                storage.addAttributes([
                    .foregroundColor: NSPalette.pink, .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: NSPalette.named("pink", alpha: 0.4),
                ], range: r)
                embedImage(text.substring(with: r), line: text.lineRange(for: r), in: storage)
            case .url:
                storage.addAttributes([.foregroundColor: NSPalette.link.withAlphaComponent(0.7)], range: r)
            case .tag:
                // The same colour per tag as the reader's pills.
                let name = NSPalette.tagColor(String(text.substring(with: r).drop { $0 == "#" }))
                storage.addAttributes([
                    .foregroundColor: NSPalette.named(name), .backgroundColor: NSPalette.named(name, alpha: 0.16),
                ], range: r)
            case .taskOpen, .taskOther:
                storage.addAttributes([.font: mono, .foregroundColor: NSPalette.accent], range: r)
            case .taskDone, .taskCancelled:
                storage.addAttributes([.foregroundColor: NSPalette.faint, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: r)
            case .listMarker:
                // Each level of a list has its own colour, as in the reader.
                let line = text.lineRange(for: r)
                let before = text.substring(with: NSRange(location: line.location, length: r.location - line.location))
                let indent = before + text.substring(with: r).prefix { $0 == " " || $0 == "\t" }
                let depth = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : $1 == " " ? 1 : 0) } / 4
                let colors = ["orange", "aqua", "pink", "chartreuse"]
                storage.addAttributes([
                    .foregroundColor: NSPalette.named(colors[depth % colors.count]),
                    .font: Fonts.text(size: fontSize, weight: .bold),
                ], range: r)
            case .quote:
                // A bar beside the quote, as Obsidian draws it; a callout's
                // lines in its panel. No strip behind each line's letters.
                storage.addAttribute(.foregroundColor, value: NSPalette.quote, range: r)
                markQuote(text.lineRange(for: r), in: storage, text: text)
            case .calloutTitle:
                let title = text.substring(with: r)
                let kind = title.firstMatch(of: /\[!([A-Za-z-]+)\]/).map { String($0.1) } ?? "note"
                let color = NSPalette.calloutColor(kind)
                storage.addAttributes([.font: Fonts.text(size: fontSize, weight: .bold), .foregroundColor: NSPalette.named(color)], range: r)
                markQuote(text.lineRange(for: r), in: storage, text: text)
            case .comment, .rule:
                storage.addAttribute(.foregroundColor, value: NSPalette.faint, range: r)
            case .math:
                let line = text.lineRange(for: r)
                var content = 0
                text.getLineStart(nil, end: nil, contentsEnd: &content, for: line)
                if r.location == line.location, NSMaxRange(r) >= content {
                    // A `$$` block's line: a panel, as code has.
                    storage.addAttributes([.font: mono, .foregroundColor: NSPalette.purple], range: r)
                    storage.addAttributes([.paragraphStyle: codeParagraph, NoteTextView.codeBlock: true], range: line)
                } else {
                    storage.addAttributes([.font: mono, .foregroundColor: NSPalette.purple, .backgroundColor: NSPalette.named("purple", alpha: 0.08)], range: r)
                }
            case .metadata:
                storage.addAttributes([.foregroundColor: NSPalette.muted, .font: Fonts.text(size: fontSize * 0.85)], range: r)
            }
        }
        lineUpTables(in: range, of: storage, text: text, mono: mono)
        alignByText(storage, range: range, text: text)
        if store.settings.livePreview { hideMarks(spans, in: storage) }
        collapseFrontMatter(storage, range: range)
    }

    /// Each line on the side its text reads from, whatever its syntax starts
    /// with: AppKit takes a paragraph's direction from its first letter, and
    /// in `- [x] سلام` that is the `x`. Only the alignment changes, so the
    /// marks stay in the order they are written.
    private func alignByText(_ storage: NSTextStorage, range: NSRange, text: NSString) {
        var at = range.location
        let end = min(NSMaxRange(range), text.length)
        while at < end {
            let line = text.lineRange(for: NSRange(location: at, length: 0))
            at = NSMaxRange(line)
            let string = text.substring(with: line)
            guard TextDirection.containsRtl(string), let rtl = TextDirection.ofLine(string), TextDirection.firstStrong(string) != rtl else { continue }
            let paragraph = ((storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            paragraph.alignment = rtl ? .right : .left
            storage.addAttribute(.paragraphStyle, value: paragraph, range: line)
        }
    }

    // MARK: Live preview

    /// Next to nothing: a mark away from the cursor takes no room.
    /// The emoji that give a highlight its colour.
    private static let swatches: Set<Character> = ["🔴", "🟠", "🟡", "🟢", "🔵", "🟣"]
    private static let hidden: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear]

    /// Away from the cursor's lines the marks go -- `**`, `==`, `[[` and a
    /// link's target, a heading's `#` -- so the note reads as it will look.
    /// A quote's `>` and a callout's type stay: they say what the line is.
    private func hideMarks(_ spans: [MarkdownHighlighter.Span], in storage: NSTextStorage) {
        let text = storage.string as NSString
        // The cursor's line, or the lines a selection touches.
        let shown = { (line: NSRange) in
            self.revealed.length > 0 ? NSIntersectionRange(line, self.revealed).length > 0 : NSLocationInRange(self.revealed.location, line)
        }
        for (index, span) in spans.enumerated() where NSMaxRange(span.range) <= storage.length {
            let line = text.lineRange(for: span.range)
            guard !shown(line) else { continue }
            switch span.kind {
            case .markup:
                let mark = text.substring(with: span.range)
                if mark.hasPrefix(">") || mark.hasPrefix("[!") { continue }
                storage.addAttributes(Self.hidden, range: span.range)
            case .highlight:
                // `==🔴 text==`: the colour's emoji goes too, as in the reader.
                let inner = NSRange(location: span.range.location + 2, length: max(0, span.range.length - 4))
                let body = text.substring(with: inner)
                guard let first = body.first, Self.swatches.contains(first) else { continue }
                let width = (String(first) as NSString).length + (body.dropFirst().first == " " ? 1 : 0)
                storage.addAttributes(Self.hidden, range: NSRange(location: inner.location, length: width))
            case .link:
                // `[label](target)`: the brackets and the target go, the label reads.
                guard index + 1 < spans.count, spans[index + 1].kind == .url, spans[index + 1].range.location == NSMaxRange(span.range),
                    span.range.length >= 2 else { continue }
                storage.addAttributes(Self.hidden, range: NSRange(location: span.range.location, length: 1))
                storage.addAttributes(Self.hidden, range: NSRange(location: NSMaxRange(span.range) - 1, length: 1))
                storage.addAttributes(Self.hidden, range: spans[index + 1].range)
            default:
                continue
            }
        }
    }

    /// The selection moved to other lines: the old ones hide their marks
    /// again and the new ones show them.
    func revealSelection() {
        guard store.settings.livePreview, let view, let storage = view.textStorage else { return }
        let text = storage.string as NSString
        let now = text.lineRange(for: view.selectedRange())
        guard now != revealed else { return }
        let old = revealed
        revealed = now
        storage.beginEditing()
        for range in [old, now] where NSMaxRange(range) <= storage.length {
            style(storage, range: text.lineRange(for: range))
        }
        storage.endEditing()
    }

    // MARK: Images


    /// `![[picture.png]]` (or `![[picture.png|300]]`): the line keeps room
    /// for the picture under it, and `ImageLayoutFragment` draws it there.
    private func embedImage(_ embed: String, line: NSRange, in storage: NSTextStorage) {
        guard let path, embed.hasPrefix("![["), embed.hasSuffix("]]") else { return }
        let link = Wikilink(String(embed.dropFirst(3).dropLast(2)))
        guard let target = store.index.resolve(link.target, from: path), Vault.isImage(target), let url = store.url(of: target)
        else { return }
        let image = images[target] ?? NSImage(contentsOf: url)
        guard let image, image.size.width > 0 else { return }
        images[target] = image
        let available = min(CGFloat(store.settings.textSize) * 44, max(200, (view?.textContainer?.size.width ?? 600) - 20))
        var width = min(image.size.width, available)
        if let alias = link.alias, let requested = Double(alias.split(separator: "x").first ?? "") { width = min(CGFloat(requested), available) }
        let height = min(width * image.size.height / image.size.width, 480)
        width = height * image.size.width / image.size.height
        let size = NSSize(width: width, height: height)

        let paragraph = ((storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        paragraph.paragraphSpacing = height + EmbeddedImage.gap * 2
        animator.view = view
        let embedded = EmbeddedImage(image: image, size: size, animation: animator.animation(for: target, url: url))
        storage.addAttributes([.paragraphStyle: paragraph, .daftarImage: embedded], range: line)
    }
}
