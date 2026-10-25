import Foundation

/// What the editor colours in a note's source: one span per piece of
/// markdown, in UTF-16 ranges so that `NSTextStorage` can take them as they
/// are. The markup itself (`**`, `#`, `[[`) is a span of its own, so the
/// editor can dim it while the text it marks stands out.
///
/// Line based, like the parser: a fenced block, the front matter and a
/// multi-line comment are the only state carried from one line to the next,
/// and `blockState(before:)` finds that state for any line, so a paragraph
/// can be coloured again on its own after a keystroke.
public enum MarkdownHighlighter {
    public enum Kind: Hashable, Sendable {
        case heading(Int)
        case markup
        case bold, italic, strike, highlight
        case code, codeBlock, fence
        case link, url, tag, embed
        case taskOpen, taskDone, taskCancelled, taskOther
        case listMarker
        case quote, calloutTitle
        case frontMatter
        case comment
        case math
        case rule
        case blockId
        case metadata
    }

    public struct Span: Hashable, Sendable {
        public var kind: Kind
        public var range: NSRange
    }

    public enum BlockState: Equatable, Sendable {
        case normal
        case frontMatter
        case fence(String)
        case comment
        case math
    }

    /// The state the line starting at UTF-16 offset [location] begins in.
    public static func blockState(before location: Int, in text: NSString) -> BlockState {
        var state = BlockState.normal
        var start = 0
        var first = true
        while start < location, start < text.length {
            let lineRange = text.lineRange(for: NSRange(location: start, length: 0))
            let line = text.substring(with: lineRange).trimmingCharacters(in: .newlines)
            state = next(after: line, from: state, firstLine: first)
            first = false
            start = NSMaxRange(lineRange)
        }
        return state
    }

    static func next(after line: String, from state: BlockState, firstLine: Bool) -> BlockState {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        switch state {
        case .frontMatter:
            return trimmed == "---" || trimmed == "..." ? .normal : .frontMatter
        case .fence(let marker):
            let closes = trimmed.hasPrefix(String(marker.first!)) && trimmed.prefix { $0 == marker.first! }.count >= marker.count
                && trimmed.drop { $0 == marker.first! }.trimmingCharacters(in: .whitespaces).isEmpty
            return closes ? .normal : state
        case .comment:
            return line.components(separatedBy: "%%").count % 2 == 0 ? .normal : .comment
        case .math:
            return trimmed.hasSuffix("$$") ? .normal : .math
        case .normal:
            if firstLine && trimmed == "---" { return .frontMatter }
            let quoteless = trimmed.drop { $0 == ">" || $0 == " " }
            if let marker = fenceMarker(String(quoteless)) { return .fence(marker) }
            if trimmed.hasPrefix("$$") && !(trimmed.count > 2 && trimmed.dropFirst(2).hasSuffix("$$")) { return .math }
            if line.components(separatedBy: "%%").count % 2 == 0 { return .comment }
            return .normal
        }
    }

    private static func fenceMarker(_ line: String) -> String? {
        for ch in ["`", "~"] where line.hasPrefix(ch + ch + ch) {
            return String(line.prefix { String($0) == ch })
        }
        return nil
    }

    /// The spans of every line that overlaps [range].
    public static func spans(in text: NSString, range: NSRange) -> [Span] {
        let lines = text.lineRange(for: range)
        var state = blockState(before: lines.location, in: text)
        var out: [Span] = []
        var start = lines.location
        while start < NSMaxRange(lines) {
            let lineRange = text.lineRange(for: NSRange(location: start, length: 0))
            guard lineRange.length > 0 else { break }
            let raw = text.substring(with: lineRange)
            let line = raw.trimmingCharacters(in: .newlines)
            let content = NSRange(location: lineRange.location, length: (line as NSString).length)
            let first = lineRange.location == 0
            let before = state
            state = next(after: line, from: state, firstLine: first)
            style(line: line, at: content, before: before, after: state, into: &out)
            start = NSMaxRange(lineRange)
        }
        return out
    }

    public static func spans(in text: String) -> [Span] {
        let ns = text as NSString
        return spans(in: ns, range: NSRange(location: 0, length: ns.length))
    }

    // MARK: One line

    private static func style(line: String, at range: NSRange, before: BlockState, after: BlockState, into out: inout [Span]) {
        guard range.length > 0 else { return }
        switch before {
        case .frontMatter:
            out.append(Span(kind: .frontMatter, range: range))
            return
        case .fence:
            out.append(Span(kind: after == .normal ? .fence : .codeBlock, range: range))
            return
        case .comment:
            out.append(Span(kind: .comment, range: range))
            return
        case .math:
            out.append(Span(kind: .math, range: range))
            return
        case .normal:
            break
        }
        if case .frontMatter = after {
            out.append(Span(kind: .frontMatter, range: range))
            return
        }
        if case .fence = after {
            out.append(Span(kind: .fence, range: range))
            return
        }
        if after == .math || line.trimmingCharacters(in: .whitespaces).hasPrefix("$$") {
            out.append(Span(kind: .math, range: range))
            return
        }
        let ns = line as NSString
        func at(_ local: NSRange) -> NSRange { NSRange(location: range.location + local.location, length: local.length) }
        if after == .comment {
            // A comment opens on this line and runs past it: from its `%%` on.
            let open = ns.range(of: "%%", options: .backwards)
            out.append(Span(kind: .comment, range: at(NSRange(location: open.location, length: ns.length - open.location))))
        }
        func each(_ pattern: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            pattern.enumerateMatches(in: line, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                if let match { body(match) }
            }
        }

        // Block-level: headings, quotes, lists, tasks, rules.
        if let match = Patterns.heading.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            let level = match.range(at: 1).length
            out.append(Span(kind: .heading(level), range: range))
            out.append(Span(kind: .markup, range: at(match.range(at: 1))))
        }
        if Patterns.rule.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil {
            out.append(Span(kind: .rule, range: range))
            return
        }
        var body = 0
        if let match = Patterns.quote.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            out.append(Span(kind: .quote, range: range))
            out.append(Span(kind: .markup, range: at(match.range)))
            body = match.range.length
            if let callout = Patterns.callout.firstMatch(in: line, range: NSRange(location: body, length: ns.length - body)) {
                out.append(Span(kind: .calloutTitle, range: at(NSRange(location: body, length: ns.length - body))))
                out.append(Span(kind: .markup, range: at(callout.range(at: 1))))
            }
        }
        if let match = Patterns.task.firstMatch(in: line, range: NSRange(location: body, length: ns.length - body)) {
            out.append(Span(kind: .listMarker, range: at(match.range(at: 1))))
            let status = ns.substring(with: match.range(at: 3))
            let kind: Kind = switch status {
            case " ": .taskOpen
            case "x", "X": .taskDone
            case "-": .taskCancelled
            default: .taskOther
            }
            out.append(Span(kind: kind, range: at(match.range(at: 2))))
            if kind == .taskDone || kind == .taskCancelled {
                let text = NSRange(location: NSMaxRange(match.range), length: ns.length - NSMaxRange(match.range))
                if text.length > 0 { out.append(Span(kind: kind, range: at(text))) }
            }
            each(Patterns.taskMetadata) { out.append(Span(kind: .metadata, range: at($0.range))) }
        } else if let match = Patterns.list.firstMatch(in: line, range: NSRange(location: body, length: ns.length - body)) {
            out.append(Span(kind: .listMarker, range: at(match.range(at: 1))))
        }

        // Inline: code first, so that markup inside code is code.
        var code: [NSRange] = []
        each(Patterns.inlineCode) { match in
            code.append(match.range)
            out.append(Span(kind: .code, range: at(match.range)))
            out.append(Span(kind: .markup, range: at(NSRange(location: match.range.location, length: match.range(at: 1).length))))
            out.append(Span(kind: .markup, range: at(NSRange(location: NSMaxRange(match.range) - match.range(at: 1).length, length: match.range(at: 1).length))))
        }
        func free(_ local: NSRange) -> Bool { !code.contains { NSIntersectionRange($0, local).length > 0 } }

        each(Patterns.comment) { match in if free(match.range) { out.append(Span(kind: .comment, range: at(match.range))) } }
        each(Patterns.wikilink) { match in
            guard free(match.range) else { return }
            let embed = match.range(at: 1).length > 0
            out.append(Span(kind: embed ? .embed : .link, range: at(match.range)))
            let open = NSRange(location: match.range.location, length: match.range(at: 1).length + 2)
            out.append(Span(kind: .markup, range: at(open)))
            out.append(Span(kind: .markup, range: at(NSRange(location: NSMaxRange(match.range) - 2, length: 2))))
            // `[[target|label]]`: the target is markup too; the label is what reads.
            let inner = match.range(at: 2)
            let text = ns.substring(with: inner) as NSString
            let bar = text.range(of: "|")
            if bar.location != NSNotFound {
                out.append(Span(kind: .markup, range: at(NSRange(location: inner.location, length: bar.location + 1))))
            }
        }
        each(Patterns.markdownLink) { match in
            guard free(match.range) else { return }
            out.append(Span(kind: .link, range: at(match.range(at: 1))))
            out.append(Span(kind: .url, range: at(match.range(at: 2))))
        }
        each(Patterns.autolink) { match in if free(match.range) { out.append(Span(kind: .url, range: at(match.range))) } }
        each(Patterns.bareURL) { match in if free(match.range) { out.append(Span(kind: .url, range: at(match.range))) } }
        for (pattern, kind, width) in [(Patterns.bold, Kind.bold, 2), (Patterns.strike, .strike, 2), (Patterns.highlight, .highlight, 2), (Patterns.italic, .italic, 1)] {
            each(pattern) { match in
                let whole = match.range(at: 1)
                guard free(whole) else { return }
                out.append(Span(kind: kind, range: at(whole)))
                out.append(Span(kind: .markup, range: at(NSRange(location: whole.location, length: width))))
                out.append(Span(kind: .markup, range: at(NSRange(location: NSMaxRange(whole) - width, length: width))))
            }
        }
        each(Patterns.inlineMath) { match in if free(match.range) { out.append(Span(kind: .math, range: at(match.range))) } }
        each(Patterns.tag) { match in if free(match.range(at: 1)) { out.append(Span(kind: .tag, range: at(match.range(at: 1)))) } }
        each(Patterns.blockId) { match in out.append(Span(kind: .blockId, range: at(match.range(at: 1)))) }
    }

    private enum Patterns {
        static func make(_ pattern: String) -> NSRegularExpression {
            try! NSRegularExpression(pattern: pattern)
        }

        nonisolated(unsafe) static let heading = make(#"^(#{1,6})[ \t]"#)
        nonisolated(unsafe) static let rule = make(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
        nonisolated(unsafe) static let quote = make(#"^(?:[ \t]*>)+[ \t]?"#)
        nonisolated(unsafe) static let callout = make(#"^(\[![\w-]+\][+-]?)"#)
        nonisolated(unsafe) static let task = make(#"\G([ \t]*(?:[-*+]|\d+[.)])[ \t]+)(\[([^\]])\])"#)
        nonisolated(unsafe) static let list = make(#"\G([ \t]*(?:[-*+]|\d+[.)]))[ \t]+"#)
        nonisolated(unsafe) static let taskMetadata = make(#"(?:✅|➕|⏳|❌|📅|🔁|⛔|🛫|🆔|🔺|⏫|🔼|🔽|⏬)(?:[ \t]*[0-9A-Za-z/,:.-]+(?:[ \t]+[a-z]+)*)?"#)
        nonisolated(unsafe) static let inlineCode = make(#"(`+)(?:(?!\1).)+?\1"#)
        nonisolated(unsafe) static let comment = make(#"%%.*?%%"#)
        nonisolated(unsafe) static let wikilink = make(#"(!?)\[\[([^\]\n]+?)\]\]"#)
        nonisolated(unsafe) static let markdownLink = make(#"!?(\[[^\]\n]*\])(\([^)\n]*\))"#)
        nonisolated(unsafe) static let autolink = make(#"<(?:https?|mailto):[^>\s]+>"#)
        nonisolated(unsafe) static let bareURL = make(#"(?<![<(])\bhttps?://[^\s<>)\]]+"#)
        nonisolated(unsafe) static let bold = make(#"((?:\*\*|__)(?=\S)(?:.+?)(?<=\S)(?:\*\*|__))"#)
        nonisolated(unsafe) static let italic = make(#"(?<![*_\w])((?:\*|_)(?=[^\s*_])(?:[^*_\n]+?)(?<=[^\s*_])(?:\*|_))(?![*_\w])"#)
        nonisolated(unsafe) static let strike = make(#"(~~(?=\S).+?(?<=\S)~~)"#)
        nonisolated(unsafe) static let highlight = make(#"(==(?=\S).+?(?<=\S)==)"#)
        nonisolated(unsafe) static let inlineMath = make(#"(?<![\\$])\$(?=\S)[^$\n]+?(?<=\S)\$(?!\d)"#)
        nonisolated(unsafe) static let tag = make(#"(?:^|\s)(#[\p{L}\p{N}_/-]*[\p{L}_/-][\p{L}\p{N}_/-]*)"#)
        nonisolated(unsafe) static let blockId = make(#"\s(\^[A-Za-z0-9-]+)\s*$"#)
    }
}
