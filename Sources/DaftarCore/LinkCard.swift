import Foundation

/// The card of one link: what its head and its body say
/// (`docs/specs/look.md` in notes-linux, "Link preview"). The first lines
/// are `LinkPreview.excerpt`; how the card is drawn is each view's.
public struct LinkCard: Sendable, Equatable {
    public enum Body: Sendable, Equatable {
        /// The first lines, as Markdown.
        case lines(String)
        /// The note has no text.
        case empty
        /// No note has the name.
        case missing

        /// What the card says where there are no lines to show.
        public var words: String? {
            switch self {
            case .lines: nil
            case .empty: LinkPreview.empty
            case .missing: LinkPreview.missing
            }
        }
    }

    /// The pointer rests this long on a link before its card shows, and the
    /// card stays this long after the pointer left it, in seconds.
    public static let rest = 0.35
    public static let linger = 0.25

    /// The note's title, or the link's name when there is no such note.
    public var title: String
    /// The heading the link names, when the note has it.
    public var heading: String?
    /// The note's folder, as `A › B`; empty at the vault's root.
    public var folder: String
    public var body: Body
    /// The note the link opens; nil when no note has the name.
    public var path: String?

    /// The `[[link]]` of [line] that holds UTF-16 offset [offset], brackets
    /// counted, as its place in the line and what it names. Nil on an embed
    /// (`![[…]]`), on a link that names nothing, and where the line has no link.
    public static func link(at offset: Int, in line: NSString) -> (range: NSRange, link: Wikilink)? {
        var from = 0
        while from + 4 <= line.length {
            let open = line.range(of: "[[", options: .literal, range: NSRange(location: from, length: line.length - from))
            guard open.location != NSNotFound, open.location <= offset else { return nil }
            let rest = NSRange(location: NSMaxRange(open), length: line.length - NSMaxRange(open))
            let close = line.range(of: "]]", options: .literal, range: rest)
            guard close.location != NSNotFound else { return nil }
            let range = NSRange(location: open.location, length: NSMaxRange(close) - open.location)
            guard NSLocationInRange(offset, range) else {
                from = NSMaxRange(close)
                continue
            }
            let inner = line.substring(with: NSRange(location: NSMaxRange(open), length: close.location - NSMaxRange(open)))
            let embed = open.location > 0 && line.character(at: open.location - 1) == 0x21
            let link = Wikilink(inner)
            guard !embed, !inner.contains("[["), !inner.contains("\n"), !link.target.isEmpty || link.anchor?.isEmpty == false else { return nil }
            return (range, link)
        }
        return nil
    }

    /// The card of [link]: [path] is the note it resolves to and [text]
    /// that note's text, both nil when no note has the name. A heading or a
    /// block the note does not have is left out, and the card shows the note.
    public init(link: Wikilink, path: String?, text: String?) {
        guard let path, let text else {
            self.init(title: link.target, heading: nil, folder: "", body: .missing, path: nil)
            return
        }
        let title = Vault.title(of: path)
        var heading: String?
        var anchor: String?
        if let named = link.anchor?.trimmingCharacters(in: .whitespaces), !named.isEmpty {
            if named.hasPrefix("^") {
                if BlockRefs.block(id: named, in: text) != nil { anchor = named }
            } else {
                let headings = Sections.headings(in: text)
                if let found = HeadingRename.resolve(named, in: headings)?.last {
                    anchor = named
                    heading = headings[found].text
                }
            }
        }
        let lines = LinkPreview.excerpt(of: text, title: title, anchor: anchor)
        let folder = path.split(separator: "/").dropLast().joined(separator: " › ")
        self.init(title: title, heading: heading, folder: folder, body: lines.allSatisfy(\.isWhitespace) ? .empty : .lines(lines), path: path)
    }

    public init(title: String, heading: String?, folder: String, body: Body, path: String?) {
        self.title = title
        self.heading = heading
        self.folder = folder
        self.body = body
        self.path = path
    }
}
