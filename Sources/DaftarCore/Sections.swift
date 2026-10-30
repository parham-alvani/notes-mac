import Foundation

/// A note's sections: a heading, its body and the headings under it, to
/// the next heading of its level or above. The headings are the outline's,
/// found as the index finds them: `#` headings outside the front matter,
/// code fences and `%%` comments. A setext heading (a line over `===`) is
/// not one, in the outline or here.
public enum Sections {
    /// The note's lines, split on `\n`, without the empty one after a
    /// last line break; and whether there was that line break.
    public static func lines(_ text: String) -> (lines: [String], newline: Bool) {
        var lines = text.components(separatedBy: "\n")
        let newline = lines.count > 1 && lines.last == ""
        if newline { lines.removeLast() }
        return (lines, newline)
    }

    public static func headings(in text: String) -> [Heading] { headings(lines: lines(text).lines) }

    /// The headings of [lines], as `NoteParser` finds them.
    public static func headings(lines raw: [String]) -> [Heading] {
        let lines = raw.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        var headings: [Heading] = []
        var fenceMarker: String?
        var inComment = false
        for index in FrontMatter.parse(lines).lineCount..<lines.count {
            let raw = lines[index]
            if raw.hasMark("```") || raw.hasMark("~~~"), let match = raw.firstMatch(of: NoteParser.fence) {
                let marker = String(match.1)
                if fenceMarker == nil {
                    fenceMarker = marker
                } else if let open = fenceMarker, marker.first == open.first, marker.count >= open.count {
                    fenceMarker = nil
                }
                continue
            }
            if fenceMarker != nil { continue }
            let line = Comments.strip(raw, open: &inComment)
            if line.hasPrefix("#"), let match = line.firstMatch(of: NoteParser.heading) {
                headings.append(Heading(level: match.1.count, text: String(match.2), line: index))
            }
        }
        return headings
    }

    /// The line after the last of heading [index]'s section: the next
    /// heading of its level or above, or [lineCount].
    public static func end(of index: Int, in headings: [Heading], lineCount: Int) -> Int {
        let level = headings[index].level
        return headings[(index + 1)...].first { $0.level <= level }?.line ?? lineCount
    }

    /// The heading whose own lines hold [line]: the last heading at or
    /// above it. Nil above the first heading.
    public static func heading(at line: Int, in headings: [Heading]) -> Int? {
        headings.lastIndex { $0.line <= line }
    }

    /// How the outline names heading [heading] to keep it closed: `level:text`,
    /// as the reader's folds, which an edit above it does not move.
    public static func key(_ heading: Heading) -> String { "\(heading.level):\(heading.text)" }

    /// True when headings come under heading [index]: the next one is deeper.
    public static func hasChildren(_ index: Int, in headings: [Heading]) -> Bool {
        headings.indices.contains(index + 1) && headings[index + 1].level > headings[index].level
    }

    /// The headings the outline shows, in order, when those in [closed]
    /// (by `key`) are closed: the headings under a closed one are left out.
    public static func visible(_ headings: [Heading], closed: Set<String>) -> [Int] {
        var shown: [Int] = []
        var under: Int?
        for (index, heading) in headings.enumerated() {
            if let level = under {
                if heading.level > level { continue }
                under = nil
            }
            shown.append(index)
            if closed.contains(key(heading)), hasChildren(index, in: headings) { under = heading.level }
        }
        return shown
    }

    /// The heading the outline marks for heading [index]: itself, or the
    /// closed heading it is under. [visible] is what `visible` gave.
    public static func shown(_ index: Int, visible: [Int]) -> Int? {
        visible.last { $0 <= index }
    }

    /// The headings right under heading [index]: those of the highest
    /// level in its section. Empty when it has none.
    public static func children(of index: Int, in headings: [Heading]) -> [Int] {
        guard hasChildren(index, in: headings) else { return [] }
        let level = headings[index].level
        let below = headings[(index + 1)...].prefix { $0.level > level }
        let top = below.map(\.level).min()!
        return below.indices.filter { headings[$0].level == top }
    }

    /// The text with the headings right under heading [index] in the order
    /// of their names, as Finder orders them, each with its section. The
    /// text before the first of them stays first. Nil when they are in
    /// order already or there are fewer than two.
    public static func sortChildren(_ text: String, heading index: Int) -> String? {
        let start = headings(in: text)
        guard start.indices.contains(index) else { return nil }
        let names = children(of: index, in: start).map { start[$0].text }
        let sorted = names.enumerated().sorted {
            let order = $0.element.localizedStandardCompare($1.element)
            return order == .orderedSame ? $0.offset < $1.offset : order == .orderedAscending
        }.map(\.offset)
        guard names.count > 1, sorted != Array(names.indices) else { return nil }
        var text = text
        // Where each section is now, by its first place.
        var places = Array(names.indices)
        for (position, wanted) in sorted.enumerated() {
            let at = places.firstIndex(of: wanted)!
            guard at != position else { continue }
            let now = headings(in: text)
            let child = children(of: index, in: now)[at]
            guard let moved = move(text, heading: child, to: position) else { return nil }
            text = moved.text
            places.insert(places.remove(at: at), at: position)
        }
        return text
    }

    /// The headings of heading [index]'s level under the same parent, in
    /// order, [index] among them.
    public static func siblings(of index: Int, in headings: [Heading]) -> [Int] {
        let level = headings[index].level
        var first = index
        while first > 0, headings[first - 1].level >= level { first -= 1 }
        var last = index
        while last + 1 < headings.count, headings[last + 1].level >= level { last += 1 }
        return (first...last).filter { headings[$0].level == level }
    }

    /// A section moved: the new text, and where the moved section's first
    /// line was and is now.
    public struct Moved: Sendable, Equatable {
        public var text: String
        public var from: Int
        public var to: Int
    }

    /// The section of heading [index] at place [position] among its
    /// siblings, as `Array.move` does: the siblings after it close up. The
    /// blank lines after each section stay where they are, so a section moved
    /// to the end does not take the blank line before the next heading with
    /// it. Nil when it is there already.
    public static func move(_ text: String, heading index: Int, to position: Int) -> Moved? {
        let (lines, newline) = lines(text)
        let headings = headings(lines: lines)
        guard headings.indices.contains(index) else { return nil }
        let siblings = siblings(of: index, in: headings)
        guard let from = siblings.firstIndex(of: index), siblings.indices.contains(position), position != from else { return nil }
        let starts = siblings.map { headings[$0].line }
        let stop = end(of: siblings.last!, in: headings, lineCount: lines.count)
        // Each section is its content and the blank lines after it.
        var contents: [ArraySlice<String>] = [], gaps: [ArraySlice<String>] = []
        for (at, start) in starts.enumerated() {
            let finish = at + 1 < starts.count ? starts[at + 1] : stop
            var content = finish
            while content > start + 1, lines[content - 1].trimmingCharacters(in: .whitespaces).isEmpty { content -= 1 }
            contents.append(lines[start..<content])
            gaps.append(lines[content..<finish])
        }
        var order = Array(contents.indices)
        order.insert(order.remove(at: from), at: position)
        var out = Array(lines[..<starts[0]])
        var to = 0
        for (slot, section) in order.enumerated() {
            if section == from { to = out.count }
            out += contents[section]
            out += gaps[slot]
        }
        out += lines[stop...]
        return Moved(text: out.joined(separator: "\n") + (newline ? "\n" : ""), from: starts[from], to: to)
    }

    /// ⌥⌘↑ and ⌥⌘↓: the section the cursor is in goes above the previous
    /// sibling or below the next one, as one edit with the selection moved
    /// with it. Above the first heading, the lines move as ⌥↑ moves them.
    /// Nil when there is no sibling that way.
    public static func moveSection(in text: NSString, selection: NSRange, up: Bool) -> (range: NSRange, text: String, selection: NSRange)? {
        let string = text as String
        let line = text.substring(to: min(selection.location, text.length)).utf16.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
        let headings = headings(in: string)
        guard let index = heading(at: line, in: headings) else {
            return EditorCommands.moveLines(in: text, selection: selection, up: up)
        }
        let siblings = siblings(of: index, in: headings)
        let at = siblings.firstIndex(of: index)!
        guard let moved = move(string, heading: index, to: up ? at - 1 : at + 1) else { return nil }
        let new = moved.text as NSString
        let shift = offset(ofLine: moved.to, in: new) - offset(ofLine: moved.from, in: text)
        let selected = NSRange(location: max(0, min(selection.location + shift, new.length)), length: selection.length)
        // Only what changed is replaced, so undo and the styling see a small edit.
        let change = changed(from: text, to: new)
        return (change.old, new.substring(with: change.new), NSRange(location: selected.location, length: min(selected.length, new.length - selected.location)))
    }

    /// The UTF-16 offset of the start of line [line].
    static func offset(ofLine line: Int, in text: NSString) -> Int {
        var offset = 0, count = 0
        while count < line, offset < text.length {
            offset = NSMaxRange(text.lineRange(for: NSRange(location: offset, length: 0)))
            count += 1
        }
        return offset
    }

    /// The part of [old] that differs from [new], and the part of [new]
    /// that takes its place: the text between their common start and end.
    static func changed(from old: NSString, to new: NSString) -> (old: NSRange, new: NSRange) {
        var start = 0
        while start < old.length, start < new.length, old.character(at: start) == new.character(at: start) { start += 1 }
        var tail = 0
        while tail < old.length - start, tail < new.length - start,
            old.character(at: old.length - 1 - tail) == new.character(at: new.length - 1 - tail)
        {
            tail += 1
        }
        // Not inside a surrogate pair.
        if start > 0, start < old.length, UTF16.isTrailSurrogate(old.character(at: start)) { start -= 1 }
        if tail > 0, old.length - tail < old.length, UTF16.isTrailSurrogate(old.character(at: old.length - tail)) { tail -= 1 }
        return (NSRange(location: start, length: old.length - tail - start), NSRange(location: start, length: new.length - tail - start))
    }
}
