import Foundation

/// A tag renamed in a note: `#old` in the text and `old` in the `tags`
/// property become the new name, and so do the tags under it, `#old/sub`.
/// Tags match without regard to case, as Obsidian counts them. Code, code
/// blocks and links are left as they are.
public enum TagRename {
    /// A fence line, also for `VaultReplace`'s "Skip code".
    nonisolated(unsafe) static let fence = /^\s*(?:>\s*)*(```+|~~~+)/
    nonisolated(unsafe) private static let name = /[\p{L}\p{N}_\/-]+/
    nonisolated(unsafe) private static let bodyTag = /(?:^|\s)#([\p{L}\p{N}_\/-]+)/
    nonisolated(unsafe) private static let property = /^([A-Za-z_][\w-]*)\s*:(.*)$/
    nonisolated(unsafe) private static let item = /^(\s*-\s+)(.*)$/
    nonisolated(unsafe) private static let protected = /`[^`\n]*`|!?\[\[[^\]\n]*\]\]|!?\[[^\]\n]*\]\([^)\n]*\)|[a-zA-Z][a-zA-Z0-9+.-]*:\/\/\S+/

    /// A name a tag can have: letters, digits, `_`, `-` and `/`, not only digits.
    public static func isValid(_ tag: String) -> Bool {
        let bare = tag.hasPrefix("#") ? String(tag.dropFirst()) : tag
        return bare.wholeMatch(of: name) != nil && !bare.allSatisfy { $0.isNumber || $0 == "/" || $0 == "-" }
            && !bare.hasPrefix("/") && !bare.hasSuffix("/") && !bare.contains("//")
    }

    /// [text] with the tag [old] named [new], or the text as it was.
    public static func rename(_ text: String, from old: String, to new: String) -> String {
        let old = old.hasPrefix("#") ? String(old.dropFirst()) : old
        let new = new.hasPrefix("#") ? String(new.dropFirst()) : new
        guard isValid(old), isValid(new), old != new else { return text }
        func renamed(_ tag: Substring) -> String? {
            let folded = tag.lowercased(), from = old.lowercased()
            if folded == from { return new }
            if folded.hasPrefix(from + "/") { return new + tag.dropFirst(old.count) }
            return nil
        }

        var lines = text.components(separatedBy: "\n")
        var start = 0
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
            let end = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" })
        {
            var inTags = false
            for index in 1..<end {
                let line = lines[index]
                if let match = line.wholeMatch(of: property) {
                    inTags = ["tags", "tag"].contains(match.1.lowercased())
                    if inTags {
                        lines[index] = String(match.1) + ":" + String(match.2).replacing(name) { renamed($0.output) ?? String($0.output) }
                    }
                } else if inTags, let match = line.wholeMatch(of: item) {
                    lines[index] = String(match.1) + String(match.2).replacing(name) { renamed($0.output) ?? String($0.output) }
                } else if !line.hasPrefix(" "), !line.hasPrefix("\t") {
                    inTags = false
                }
            }
            start = end + 1
        }

        var fenceMarker: String?
        for index in lines.indices where index >= start {
            let line = lines[index]
            if let match = line.prefixMatch(of: fence) {
                let marker = String(match.1)
                if fenceMarker == nil {
                    fenceMarker = marker
                } else if let open = fenceMarker, marker.first == open.first, marker.count >= open.count {
                    fenceMarker = nil
                }
                continue
            }
            guard fenceMarker == nil, line.contains("#") else { continue }
            let taken = line.matches(of: protected).map(\.range)
            var result = ""
            var last = line.startIndex
            for match in line.matches(of: bodyTag) where !taken.contains(where: { $0.overlaps(match.range) }) {
                guard let replacement = renamed(match.1) else { continue }
                result += line[last..<match.1.startIndex] + replacement
                last = match.1.endIndex
            }
            if last != line.startIndex { lines[index] = result + line[last...] }
        }
        return lines.joined(separator: "\n")
    }
}
