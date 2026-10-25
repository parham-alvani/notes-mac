import Foundation

/// A YAML document as a `.base` file writes it: block maps and lists, plain
/// and quoted scalars, flow lists and block scalars. Not anchors, tags or
/// several documents in one file; Obsidian writes none of those.
public indirect enum YAMLNode: Sendable, Equatable {
    case null
    case scalar(String)
    case list([YAMLNode])
    /// In the file's order.
    case map([YAMLEntry])

    public subscript(key: String) -> YAMLNode? {
        if case .map(let entries) = self { return entries.first { $0.key == key }?.value }
        return nil
    }

    public var string: String? {
        if case .scalar(let text) = self { return text }
        return nil
    }

    public var items: [YAMLNode] {
        switch self {
        case .list(let items): items
        case .null: []
        default: [self]
        }
    }

    public var entries: [YAMLEntry] {
        if case .map(let entries) = self { return entries }
        return []
    }
}

public struct YAMLEntry: Sendable, Equatable {
    public var key: String
    public var value: YAMLNode
}

public enum YAML {
    struct Line {
        var indent: Int
        var text: String
    }

    public static func parse(_ source: String) -> YAMLNode {
        var lines: [Line] = source.components(separatedBy: "\n").compactMap { raw in
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasPrefix("#") || text == "---" || text == "..." { return nil }
            return Line(indent: line.prefix { $0 == " " }.count, text: text)
        }
        guard let first = lines.first else { return .null }
        var at = 0
        return block(&lines, &at, indent: first.indent)
    }

    private static func isItem(_ text: String) -> Bool { text == "-" || text.hasPrefix("- ") }

    private static func block(_ lines: inout [Line], _ at: inout Int, indent: Int) -> YAMLNode {
        guard at < lines.count else { return .null }
        return isItem(lines[at].text) ? list(&lines, &at, indent: indent) : map(&lines, &at, indent: indent)
    }

    private static func list(_ lines: inout [Line], _ at: inout Int, indent: Int) -> YAMLNode {
        var items: [YAMLNode] = []
        while at < lines.count, lines[at].indent == indent, isItem(lines[at].text) {
            let text = lines[at].text
            let rest = text.dropFirst().trimmingCharacters(in: .whitespaces)
            if rest.isEmpty {
                at += 1
                if at < lines.count, lines[at].indent > indent {
                    items.append(block(&lines, &at, indent: lines[at].indent))
                } else {
                    items.append(.null)
                }
            } else if splitKey(rest) != nil || isItem(rest) {
                // `- key: value` starts a map whose keys line up after the dash.
                let inner = indent + text.count - rest.count
                lines[at] = Line(indent: inner, text: rest)
                items.append(block(&lines, &at, indent: inner))
            } else {
                items.append(scalar(rest, &lines, &at, parent: indent))
            }
        }
        return .list(items)
    }

    private static func map(_ lines: inout [Line], _ at: inout Int, indent: Int) -> YAMLNode {
        var entries: [YAMLEntry] = []
        while at < lines.count, lines[at].indent == indent, !isItem(lines[at].text) {
            guard let (key, value) = splitKey(lines[at].text) else {
                at += 1
                continue
            }
            if value.isEmpty {
                at += 1
                // A list under a key may sit at the key's own indent.
                if at < lines.count, lines[at].indent > indent || (lines[at].indent == indent && isItem(lines[at].text)) {
                    entries.append(YAMLEntry(key: key, value: block(&lines, &at, indent: lines[at].indent)))
                } else {
                    entries.append(YAMLEntry(key: key, value: .null))
                }
            } else {
                entries.append(YAMLEntry(key: key, value: scalar(value, &lines, &at, parent: indent)))
            }
        }
        return .map(entries)
    }

    /// `key: value`, where the key is plain or quoted; an expression with a
    /// colon in a string is not a key.
    static func splitKey(_ text: String) -> (String, String)? {
        if let quote = text.first, quote == "\"" || quote == "'" {
            guard let close = text.dropFirst().firstIndex(of: quote) else { return nil }
            let after = text[text.index(after: close)...]
            guard after.hasPrefix(":"), after.count == 1 || after.dropFirst().first == " " else { return nil }
            return (String(text[text.index(after: text.startIndex)..<close]), after.dropFirst().trimmingCharacters(in: .whitespaces))
        }
        var index = text.startIndex
        while let colon = text[index...].firstIndex(of: ":") {
            let next = text.index(after: colon)
            if next == text.endIndex || text[next] == " " {
                let key = text[..<colon]
                guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || "_-. $/".contains($0) }) else { return nil }
                return (key.trimmingCharacters(in: .whitespaces), text[next...].trimmingCharacters(in: .whitespaces))
            }
            index = next
        }
        return nil
    }

    private static func scalar(_ value: String, _ lines: inout [Line], _ at: inout Int, parent: Int) -> YAMLNode {
        at += 1
        if let style = value.first, style == "|" || style == ">", value.count <= 2 {
            var parts: [String] = []
            while at < lines.count, lines[at].indent > parent {
                parts.append(lines[at].text)
                at += 1
            }
            return .scalar(parts.joined(separator: style == "|" ? "\n" : " "))
        }
        return inline(value)
    }

    /// One value on one line: quoted, a flow list, or plain.
    static func inline(_ value: String) -> YAMLNode {
        let text = stripComment(value)
        if text == "~" || text == "null" || text.isEmpty { return .null }
        if text == "{}" { return .map([]) }
        if text.hasPrefix("["), text.hasSuffix("]") {
            let inner = text.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            return .list(inner.isEmpty ? [] : splitFlow(inner).map(inline))
        }
        if text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") {
            return .scalar(String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'"))
        }
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            var out = ""
            var escaped = false
            for character in text.dropFirst().dropLast() {
                if escaped {
                    switch character {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    default: out.append(character)
                    }
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else {
                    out.append(character)
                }
            }
            return .scalar(out)
        }
        return .scalar(text)
    }

    /// A ` #` outside quotes starts a comment.
    private static func stripComment(_ text: String) -> String {
        guard text.contains(" #") else { return text }
        var quote: Character?
        var previous: Character = " "
        for (offset, character) in text.enumerated() {
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#", previous == " " {
                return String(text.prefix(offset)).trimmingCharacters(in: .whitespaces)
            }
            previous = character
        }
        return text
    }

    /// The items of a flow list, split at the commas outside quotes and brackets.
    private static func splitFlow(_ text: String) -> [String] {
        var items: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        for character in text {
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "[" || character == "{" {
                depth += 1
            } else if character == "]" || character == "}" {
                depth -= 1
            } else if character == ",", depth == 0 {
                items.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(character)
        }
        items.append(current.trimmingCharacters(in: .whitespaces))
        return items
    }
}
