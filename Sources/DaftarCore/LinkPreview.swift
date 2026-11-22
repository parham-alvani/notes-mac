import Foundation

/// The first lines of a note, for the card a link shows when the pointer
/// rests on it. One pure rule, the same in every app
/// (`docs/specs/look.md` in notes-linux, "Link preview").
public enum LinkPreview {
    /// At most this many lines.
    public static let maxLines = 12
    /// At most this many characters.
    public static let maxCharacters = 600
    /// What the card says of a link to no note.
    public static let missing = "No note yet."
    /// What the card says of a note with no text.
    public static let empty = "The note is empty."

    /// The first lines of [text], the note named [title].
    ///
    /// The front matter is left out, and so is a first heading whose text is
    /// the note's title. The lines start at the first one that is not blank
    /// and end after 12 lines or 600 characters, whichever comes first: at a
    /// line's end when one is in reach, with `…` when text was left out. A
    /// code block that is cut is closed, and an embed is written as its
    /// link, so nothing is followed.
    ///
    /// With [anchor] a heading (`Next`, `A#B`), the lines are those of its
    /// section without the heading itself; with a block id (`^id`), that
    /// block alone. An anchor that names nothing gives no lines.
    public static func excerpt(of text: String, title: String, anchor: String? = nil) -> String {
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        var part: ArraySlice<String>
        if let anchor, !anchor.isEmpty {
            if anchor.hasPrefix("^") {
                guard let block = BlockRefs.block(id: anchor, in: text), block.end < lines.count else { return "" }
                part = lines[block.start...block.end]
            } else {
                let headings = Sections.headings(lines: lines)
                guard let found = HeadingRename.resolve(anchor, in: headings)?.last else { return "" }
                let end = Sections.end(of: found, in: headings, lineCount: lines.count)
                part = lines[min(headings[found].line + 1, end)..<end]
            }
        } else {
            part = lines[min(FrontMatter.parse(lines).lineCount, lines.count)...]
            part = part.drop(while: isBlank)
            // The card's head says the title already.
            if let first = part.first, let (_, heading) = NoteParser.heading(first), same(heading, title) { part = part.dropFirst() }
        }
        part = part.drop(while: isBlank)
        while let last = part.last, isBlank(last) { part = part.dropLast() }
        return cut(Array(part))
    }

    private static func isBlank(_ line: String) -> Bool { line.allSatisfy(\.isWhitespace) }

    private static func same(_ heading: String, _ title: String) -> Bool {
        heading.trimmingCharacters(in: .whitespaces).compare(title.trimmingCharacters(in: .whitespaces), options: .caseInsensitive) == .orderedSame
    }

    /// [lines] up to the limits, with what closes them.
    private static func cut(_ lines: [String]) -> String {
        var kept = Array(lines.prefix(maxLines))
        var more = lines.count > kept.count
        // Cut inside a line: no line's end was in reach.
        var inLine = false
        var count = 0
        for (index, line) in kept.enumerated() {
            // A line break is a character too.
            let length = line.count + (index > 0 ? 1 : 0)
            if count + length <= maxCharacters {
                count += length
                continue
            }
            more = true
            if index == 0 {
                kept = [String(line.prefix(maxCharacters))]
                inLine = true
            } else {
                kept = Array(kept[..<index])
            }
            break
        }
        while let last = kept.last, isBlank(last) { kept.removeLast() }
        var out = embedsAsLinks(kept)
        // A code block the cut left open is closed with its own marks.
        let open = openFence(kept)
        if let open { out.append(open) }
        guard more else { return out.joined(separator: "\n") }
        if inLine, open == nil { return out.joined(separator: "\n") + "…" }
        return out.joined(separator: "\n") + "\n\n…"
    }

    /// The marks that close the code block [lines] end in, or nil when they end outside one.
    private static func openFence(_ lines: [String]) -> String? {
        var open: String?
        for line in lines {
            guard let mark = NoteParser.fenceMark(line) else { continue }
            if let marks = open {
                if mark.first == marks.first, mark.count >= marks.count { open = nil }
            } else {
                open = String(mark)
            }
        }
        return open
    }

    /// `![[x]]` written as `[[x]]`, outside code blocks.
    private static func embedsAsLinks(_ lines: [String]) -> [String] {
        var open: String?
        return lines.map { line in
            if let mark = NoteParser.fenceMark(line) {
                if let marks = open {
                    if mark.first == marks.first, mark.count >= marks.count { open = nil }
                } else {
                    open = String(mark)
                }
                return line
            }
            guard open == nil, line.contains("![[") else { return line }
            return line.replacingOccurrences(of: "![[", with: "[[")
        }
    }
}
