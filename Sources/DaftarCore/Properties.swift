import Foundation

/// A property's value as the form edits it.
public enum PropertyValue: Sendable, Equatable {
    /// `key:` with nothing after it.
    case empty
    case text(String)
    case list([String])

    public var items: [String] {
        switch self {
        case .empty: []
        case .text(let text): [text]
        case .list(let items): items
        }
    }
}

/// Obsidian's property types, as `.obsidian/types.json` names them.
public enum PropertyType: String, Sendable, CaseIterable, Identifiable {
    case text, multitext, number, checkbox, date, datetime, aliases, tags

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .text: "Text"
        case .multitext: "List"
        case .number: "Number"
        case .checkbox: "Checkbox"
        case .date: "Date"
        case .datetime: "Date & time"
        case .aliases: "Aliases"
        case .tags: "Tags"
        }
    }

    public var isList: Bool { self == .multitext || self == .aliases || self == .tags }

    nonisolated(unsafe) private static let numeral = /^-?(\d+(\.\d*)?|\.\d+)([eE][-+]?\d+)?$/
    nonisolated(unsafe) private static let day = /^\d{4}-\d{2}-\d{2}$/
    nonisolated(unsafe) private static let moment = /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?Z?$/

    /// The type Obsidian gives [key]: the one in `types.json`, the type of
    /// `tags`, `aliases` and `cssclasses`, or else the shape of the value.
    public static func infer(_ key: String, _ value: PropertyValue, types: [String: String] = [:]) -> PropertyType {
        if let named = types[key] ?? types.first(where: { $0.key.lowercased() == key.lowercased() })?.value,
            let type = PropertyType(rawValue: named)
        {
            return type
        }
        switch key.lowercased() {
        case "tags", "tag": return .tags
        case "aliases", "alias": return .aliases
        case "cssclasses", "cssclass": return .multitext
        default: break
        }
        switch value {
        case .empty: return .text
        case .list: return .multitext
        case .text(let text):
            if text.lowercased() == "true" || text.lowercased() == "false" { return .checkbox }
            if text.wholeMatch(of: numeral) != nil { return .number }
            if text.wholeMatch(of: day) != nil, date(from: text) != nil { return .date }
            if text.wholeMatch(of: moment) != nil, date(from: text) != nil { return .datetime }
            return .text
        }
    }

    /// `2026-10-25` or `2026-10-25T09:30`, in the local time zone.
    public static func date(from text: String) -> Date? { BaseEngine.parseDate(text)?.0 }

    /// How Obsidian writes a date (`2026-10-25`) or a date and time
    /// (`2026-10-25T09:30`) in the local time zone.
    public static func format(_ date: Date, time: Bool) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return time ? day + String(format: "T%02d:%02d", parts.hour ?? 0, parts.minute ?? 0) : day
    }
}

/// What the editor shows for a note's front matter.
public enum FrontMatterForm: Sendable, Equatable {
    /// The note has no front matter; a property added makes one.
    case absent(PropertySheet)
    case form(PropertySheet)
    /// YAML the form cannot show without losing something: the raw text
    /// stays, and [reason] says why.
    case source(reason: String)

    public var sheet: PropertySheet? {
        switch self {
        case .absent(let sheet), .form(let sheet): sheet
        case .source: nil
        }
    }
}

/// The front matter as a list of properties, each with the lines it was
/// written in. A property the form did not change prints as it was, byte for
/// byte; a changed one is written again in its own style -- its quotes and a
/// flow `[a, b]` or block `- a` list -- and the body is never touched.
public struct PropertySheet: Sendable, Equatable {
    public struct Property: Sendable, Equatable, Identifiable {
        public var id: String { key }
        public var key: String
        public var value: PropertyValue
        /// The key as written, quotes and all.
        var keyText: String
        /// The lines as written; nil once the value changed.
        var lines: [String]?
        /// Blank lines after it, kept where they are.
        var trailing: [String] = []
        var style = Style()
    }

    struct Style: Sendable, Equatable {
        enum Quote: Sendable { case plain, single, double }
        /// Of the scalar, or of the list's first item.
        var quote = Quote.plain
        /// `[a, b]`, not a block of `- a` lines.
        var flow = false
        /// What goes before a block item's value: `  - `.
        var itemPrefix = "  - "
        /// Each item as written, to reuse for an item that did not change.
        var items: [(value: String, text: String)] = []

        static func == (a: Style, b: Style) -> Bool {
            a.quote == b.quote && a.flow == b.flow && a.itemPrefix == b.itemPrefix
                && a.items.map(\.value) == b.items.map(\.value) && a.items.map(\.text) == b.items.map(\.text)
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case exists(String)
        case badName
        public var description: String {
            switch self {
            case .exists(let key): "The note has a property “\(key)” already."
            case .badName: "A property needs a name."
            }
        }
    }

    public private(set) var properties: [Property] = []
    /// The front matter as read, fences included: an edit is applied only
    /// to a note that still starts with it.
    public let original: String
    private var open = "---"
    private var close = "---"
    private var closeNewline = true
    private var leading: [String] = []
    private var eol = ""
    private var edited = false

    // MARK: Reading

    /// The front matter of [note], as a form when every line of it fits one.
    public static func read(_ note: String) -> FrontMatterForm {
        guard let block = FrontMatterBlock(note) else {
            var sheet = PropertySheet(original: "")
            if note.contains("\r\n") {
                sheet.eol = "\r"
                sheet.open = "---\r"
                sheet.close = "---\r"
            }
            return .absent(sheet)
        }
        do {
            return .form(try PropertySheet(block))
        } catch let failure as Unrepresentable {
            return .source(reason: failure.reason)
        } catch {
            return .source(reason: "\(error)")
        }
    }

    /// Where the front matter ends, in UTF-16 units, as a text view counts:
    /// the fences and the newline after the closing one. 0 with none.
    public static func length(of note: String) -> Int {
        FrontMatterBlock(note).map { $0.text.utf16.count } ?? 0
    }

    private init(original: String) { self.original = original }

    private init(_ block: FrontMatterBlock) throws {
        original = block.text
        open = block.open
        close = block.close
        closeNewline = block.closeNewline
        eol = open.hasSuffix("\r") ? "\r" : ""
        let lines = block.lines
        var at = 0
        while at < lines.count, Self.isBlank(lines[at]) {
            leading.append(lines[at])
            at += 1
        }
        while at < lines.count {
            let line = lines[at]
            if Self.isBlank(line) {
                properties[properties.count - 1].trailing.append(line)
                at += 1
                continue
            }
            let content = Self.content(line)
            if content.first == " " || content.first == "\t" {
                throw Unrepresentable(Self.splitKey(content.trimmingCharacters(in: .whitespaces)) != nil
                    ? "It has a map inside a map." : "A value goes on over more than one line.")
            }
            if content.hasPrefix("#") { throw Unrepresentable("It has a comment.") }
            if content.hasPrefix("- ") || content == "-" { throw Unrepresentable("It is a list, not a list of properties.") }
            guard let (keyText, key, rest) = Self.splitKey(content) else {
                throw Unrepresentable("The line “\(content)” is not a property.")
            }
            if properties.contains(where: { $0.key == key }) { throw Unrepresentable("The property “\(key)” is there twice.") }
            var property = Property(key: key, value: .empty, keyText: keyText, lines: [line])
            at += 1
            if rest.isEmpty {
                // A block list, under the key or at the key's own indent.
                var items: [(String, String)] = []
                var prefix: String?
                while at < lines.count, !Self.isBlank(lines[at]) {
                    let item = Self.content(lines[at])
                    let indent = item.prefix { $0 == " " }
                    let after = item.dropFirst(indent.count)
                    guard after.hasPrefix("- ") || after == "-" else {
                        if indent.isEmpty { break }
                        throw Unrepresentable(Self.splitKey(String(after)) != nil
                            ? "“\(key)” holds a map inside a map." : "“\(key)” goes on over more than one line.")
                    }
                    let spaces = after.dropFirst().prefix { $0 == " " }
                    let itemPrefix = String(indent) + "-" + spaces
                    if let prefix, prefix.prefix(while: { $0 == " " }).count != indent.count {
                        throw Unrepresentable("The list “\(key)” has items at different indents.")
                    }
                    prefix = prefix ?? (spaces.isEmpty ? String(indent) + "- " : itemPrefix)
                    let text = String(after.dropFirst(1 + spaces.count))
                    if text.hasPrefix("- ") || text == "-" { throw Unrepresentable("“\(key)” holds a list inside a list.") }
                    if Self.splitKey(text) != nil { throw Unrepresentable("“\(key)” holds a map inside a list.") }
                    let (value, quote) = try Self.scalar(text, in: key)
                    if items.isEmpty { property.style.quote = quote }
                    items.append((value, text))
                    property.lines?.append(lines[at])
                    at += 1
                }
                // The item's own value may go on, more indented, on the next line.
                if at < lines.count, !Self.isBlank(lines[at]), Self.content(lines[at]).first == " " {
                    throw Unrepresentable("An item of “\(key)” goes on over more than one line.")
                }
                if let prefix {
                    property.value = .list(items.map(\.0))
                    property.style.itemPrefix = prefix
                    property.style.items = items.map { (value: $0.0, text: $0.1) }
                }
            } else if rest.hasPrefix("[") {
                guard rest.hasSuffix("]") else {
                    throw Unrepresentable(rest.contains(" #") ? "It has a comment." : "The list “\(key)” does not close on its line.")
                }
                let inner = rest.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                var items: [(value: String, text: String)] = []
                for text in inner.isEmpty ? [] : Self.splitFlow(inner) {
                    if text.hasPrefix("[") || text.hasPrefix("{") {
                        throw Unrepresentable("“\(key)” holds a list inside a list; a link there needs quotes.")
                    }
                    let (value, quote) = try Self.scalar(text, in: key)
                    if items.isEmpty { property.style.quote = quote }
                    items.append((value, text))
                }
                property.value = .list(items.map(\.value))
                property.style.flow = true
                property.style.items = items
            } else {
                let (value, quote) = try Self.scalar(rest, in: key)
                property.value = .text(value)
                property.style.quote = quote
            }
            properties.append(property)
        }
    }

    struct Unrepresentable: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    private static func content(_ line: String) -> String { line.hasSuffix("\r") ? String(line.dropLast()) : line }
    private static func isBlank(_ line: String) -> Bool { line.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" } }

    private static let indicators: Set<Character> = ["-", "?", ":", ",", "[", "]", "{", "}", "#", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`"]

    /// `key: value`: the key as written, the key, and the rest of the line.
    static func splitKey(_ text: String) -> (String, String, String)? {
        if let quote = text.first, quote == "\"" || quote == "'" {
            guard let close = text.dropFirst().firstIndex(of: quote) else { return nil }
            let name = String(text[text.index(after: text.startIndex)..<close])
            let after = text[text.index(after: close)...]
            guard after.hasPrefix(":"), after.count == 1 || after.unicodeScalars.dropFirst().first == " ", !name.contains("\\") else { return nil }
            return (String(text[...close]), name, after.dropFirst().trimmingCharacters(in: .whitespaces))
        }
        guard let first = text.first, !indicators.contains(first) else { return nil }
        var index = text.startIndex
        while let colon = text[index...].firstIndex(of: ":") {
            let next = text.index(after: colon)
            // A scalar, not a letter: a space and a combining mark after it are one letter.
            if next == text.endIndex || [" ", "\t"].contains(text[next...].unicodeScalars.first) {
                let key = String(text[..<colon])
                guard key == key.trimmingCharacters(in: .whitespaces), !key.isEmpty else { return nil }
                return (key, key, text[next...].trimmingCharacters(in: .whitespaces))
            }
            index = next
        }
        return nil
    }

    /// One scalar on one line, and how it was quoted.
    static func scalar(_ text: String, in key: String) throws -> (String, Style.Quote) {
        guard let first = text.first else { return ("", .plain) }
        switch first {
        case "'":
            guard text.count >= 2, text.hasSuffix("'") else { throw open(text, key) }
            let inner = String(text.dropFirst().dropLast())
            // A lone quote inside ends the string early: what follows is not part of it.
            guard inner.replacingOccurrences(of: "''", with: "").contains("'") == false else { throw open(text, key) }
            return (inner.replacingOccurrences(of: "''", with: "'"), .single)
        case "\"":
            guard text.count >= 2, text.hasSuffix("\"") else { throw open(text, key) }
            var out = ""
            var escaped = false
            for character in text.dropFirst().dropLast() {
                if escaped {
                    switch character {
                    case "\\", "\"", "/": out.append(character)
                    case "n": out.append("\n")
                    case "r": out.append("\r")
                    case "t": out.append("\t")
                    default: throw Unrepresentable("“\(key)” has an escape the form does not know.")
                    }
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    throw open(text, key)
                } else {
                    out.append(character)
                }
            }
            if escaped { throw open(text, key) }
            return (out, .double)
        case "&", "*": throw Unrepresentable("It has an anchor or an alias (“\(key)”).")
        case "!": throw Unrepresentable("“\(key)” has a YAML tag.")
        case "|", ">": throw Unrepresentable("“\(key)” is text on more than one line.")
        case "{": throw Unrepresentable("“\(key)” holds a map inside a map.")
        case "%", "@", "`": throw Unrepresentable("“\(key)” starts with a character YAML keeps for itself.")
        default:
            if text.contains(" #") || text.contains("\t#") { throw Unrepresentable("It has a comment.") }
            if text.contains(": ") || text.hasSuffix(":") { throw Unrepresentable("“\(key)” has a colon that YAML reads as a map.") }
            return (text.trimmingCharacters(in: .whitespaces), .plain)
        }
    }

    private static func open(_ text: String, _ key: String) -> Unrepresentable {
        text.contains(" #") ? Unrepresentable("It has a comment.") : Unrepresentable("A quote in “\(key)” does not close on its line.")
    }

    /// The items of a flow list, split at the commas outside quotes and brackets.
    private static func splitFlow(_ text: String) -> [String] {
        var items: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        var escaped = false
        for character in text {
            if let open = quote {
                // `\"` does not close a double-quoted item.
                if escaped {
                    escaped = false
                } else if open == "\"", character == "\\" {
                    escaped = true
                } else if character == open {
                    quote = nil
                }
            } else if character == "\"" || character == "'", current.allSatisfy({ $0 == " " }) {
                // Only at an item's start: `it's` is plain text.
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

    // MARK: Edits

    public func value(_ key: String) -> PropertyValue? { properties.first { $0.key == key }?.value }

    /// A new value for [key]; nothing when it has that value already.
    public mutating func set(_ key: String, _ value: PropertyValue) {
        let value = value == .text("") ? .empty : value
        guard let at = properties.firstIndex(where: { $0.key == key }), properties[at].value != value else { return }
        properties[at].value = value
        properties[at].lines = nil
        edited = true
    }

    /// A new property, after the others.
    public mutating func add(_ key: String, _ value: PropertyValue) throws {
        let name = key.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains(where: \.isNewline) else { throw Failure.badName }
        guard !properties.contains(where: { $0.key == name }) else { throw Failure.exists(name) }
        var property = Property(key: name, value: value == .text("") ? .empty : value, keyText: try Self.keyText(name), lines: nil)
        if case .list = value { property.style.flow = false }
        properties.append(property)
        edited = true
    }

    public mutating func remove(_ key: String) {
        guard let at = properties.firstIndex(where: { $0.key == key }) else { return }
        let gone = properties.remove(at: at)
        // Its blank lines stay with the property before it.
        if at > 0 { properties[at - 1].trailing += gone.trailing } else { leading += gone.trailing }
        edited = true
    }

    /// Renames [key] in place; its value and its lines stay as they are.
    public mutating func rename(_ key: String, to new: String) throws {
        let name = new.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains(where: \.isNewline) else { throw Failure.badName }
        guard name != key, let at = properties.firstIndex(where: { $0.key == key }) else { return }
        guard !properties.contains(where: { $0.key == name }) else { throw Failure.exists(name) }
        let text = try Self.keyText(name)
        if var lines = properties[at].lines, let first = lines.first, first.hasPrefix(properties[at].keyText) {
            lines[0] = text + first.dropFirst(properties[at].keyText.count)
            properties[at].lines = lines
        } else {
            properties[at].lines = nil
        }
        properties[at].keyText = text
        properties[at].key = name
        edited = true
    }

    // MARK: Writing

    /// The front matter as it prints now: [original] when nothing changed,
    /// nothing when the last property went.
    public var text: String {
        guard edited else { return original }
        guard !properties.isEmpty else { return "" }
        var lines = [open] + leading
        for property in properties {
            lines += property.lines ?? Self.lines(of: property).map { $0 + eol }
            lines += property.trailing
        }
        lines.append(close)
        return lines.joined(separator: "\n") + (closeNewline ? "\n" : "")
    }

    /// [note] with this front matter, or nil when the note's front matter is
    /// no longer the one this sheet was read from.
    public func applied(to note: String) -> String? {
        let now = FrontMatterBlock(note)?.text ?? ""
        guard now == original else { return nil }
        let body = String(decoding: note.utf8.dropFirst(now.utf8.count), as: UTF8.self)
        // A new block before a note that has no newline after it.
        return text + body
    }

    private static func lines(of property: Property) -> [String] {
        let key = property.keyText + ":"
        let style = property.style
        switch property.value {
        case .empty:
            return [key]
        case .text(let text):
            return text.isEmpty ? [key] : [key + " " + quoted(text, style.quote, flow: false)]
        case .list(let items):
            var unused = style.items
            let texts = items.map { item -> String in
                if let at = unused.firstIndex(where: { $0.value == item }) { return unused.remove(at: at).text }
                return quoted(item, style.quote, flow: style.flow)
            }
            if style.flow { return [key + " [" + texts.joined(separator: ", ") + "]"] }
            return texts.isEmpty ? [key] : [key] + texts.map { style.itemPrefix + $0 }
        }
    }

    /// A key as YAML reads it back: plain, or in quotes that hold no escape.
    private static func keyText(_ name: String) throws -> String {
        if let first = name.first, !indicators.contains(first), !name.contains(": "), !name.hasSuffix(":"), !name.contains(" #"),
            !name.contains(where: { $0.isNewline || $0 == "\t" })
        {
            return name
        }
        if !name.contains("\""), !name.contains("\\") { return "\"" + name + "\"" }
        if !name.contains("'") { return "'" + name + "'" }
        throw Failure.badName
    }

    /// [text] in the style asked for, or in double quotes when plain text
    /// would read as something else.
    static func quoted(_ text: String, _ quote: Style.Quote, flow: Bool) -> String {
        switch quote {
        case .single where !text.contains(where: { $0.isNewline || $0 == "\t" }):
            return "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
        case .plain where isPlain(text, flow: flow):
            return text
        default:
            return "\"" + escape(text) + "\""
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func isPlain(_ text: String, flow: Bool) -> Bool {
        guard let first = text.first, let last = text.last, first != " ", last != " " else { return false }
        if indicators.contains(first) && !(first == "-" && text.count > 1 && text.dropFirst().first != " ") { return false }
        if ["null", "Null", "NULL", "~"].contains(text) { return false }
        if text.contains(": ") || text.hasSuffix(":") || text.contains(" #") { return false }
        if text.contains(where: { $0.isNewline || $0 == "\t" || $0.asciiValue.map { $0 < 32 } ?? false }) { return false }
        if flow, text.contains(where: { ",[]{}".contains($0) }) { return false }
        return true
    }
}

/// The front matter's fences and lines in a note, as written: a first line
/// of `---` and the next `---` or `...` line.
struct FrontMatterBlock {
    /// From the start through the closing fence and its newline.
    var text: String
    var open: String
    var close: String
    var closeNewline: Bool
    /// The lines between the fences, each with its `\r` if it had one.
    var lines: [String]

    init?(_ note: String) {
        let bytes = note.utf8
        var lines: [String] = []
        var start = bytes.startIndex
        var first = true
        var opening = ""
        while start < bytes.endIndex {
            let end = bytes[start...].firstIndex(of: 10) ?? bytes.endIndex
            let line = String(decoding: bytes[start..<end], as: UTF8.self)
            let bare = (line.hasSuffix("\r") ? String(line.dropLast()) : line).trimmingCharacters(in: .whitespaces)
            if first {
                guard bare == "---" else { return nil }
                opening = line
                first = false
            } else if bare == "---" || bare == "..." {
                open = opening
                close = line
                closeNewline = end < bytes.endIndex
                text = String(decoding: bytes[..<(closeNewline ? bytes.index(after: end) : end)], as: UTF8.self)
                self.lines = lines
                return
            } else {
                lines.append(line)
            }
            guard end < bytes.endIndex else { break }
            start = bytes.index(after: end)
        }
        return nil
    }
}

/// The property names used in the vault, the most used first, for the
/// completion of a new property's name.
public enum PropertyNames {
    public static func ranked(_ keys: some Sequence<String>) -> [String] {
        var counts: [String: Int] = [:]
        for key in keys { counts[key, default: 0] += 1 }
        return counts.sorted { ($1.value, $0.key.lowercased()) < ($0.value, $1.key.lowercased()) }.map(\.key)
    }

    /// The names that start with [prefix], then those that hold it.
    public static func complete(_ prefix: String, from names: [String], limit: Int = 8) -> [String] {
        let query = prefix.lowercased().trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Array(names.prefix(limit)) }
        let starts = names.filter { $0.lowercased().hasPrefix(query) && $0.lowercased() != query }
        let holds = names.filter { !$0.lowercased().hasPrefix(query) && $0.lowercased().contains(query) }
        return Array((starts + holds).prefix(limit))
    }
}
