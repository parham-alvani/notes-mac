import Foundation

/// Quick capture: a line typed in the small panel, added to the end of a
/// note or of one of its sections. Every line the note had stays, in order.
public enum QuickCapture {
    nonisolated(unsafe) private static let listItem = /^[ \t]*(?:[-*+]|\d+[.)])[ \t]/

    /// The line to add for what was typed, or nil for nothing. A capture is
    /// one line: line breaks become spaces. As a task, it is `- [ ] text`.
    public static func line(_ typed: String, task: Bool) -> String? {
        let text = typed.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard !text.isEmpty else { return nil }
        guard task else { return text }
        // "- [ ] x" or "[ ] x" typed by hand is a task already.
        if text.hasPrefix("- [") { return text }
        return "- [ ] " + (text.hasPrefix("[ ] ") ? String(text.dropFirst(4)) : text)
    }

    /// [text] with [line] added: at the end of the section under [heading]
    /// (with its subsections), or at the end of the note when [heading] is
    /// nil or empty. A heading not in the note is made at its end, as `## Name`,
    /// or at the level its own `#` marks give (`### Inbox`). The match is the
    /// heading's text, without case; the first one wins.
    public static func append(_ line: String, to text: String, heading: String? = nil) -> String {
        var lines = text.components(separatedBy: "\n")
        // A note written with CRLF gets CRLF lines.
        let eol = lines.count > 1 && lines[0].hasSuffix("\r") ? "\r" : ""
        let wanted = headingName(heading ?? "")
        guard !wanted.name.isEmpty else {
            let at = (lastFilled(lines, in: 0..<lines.count) ?? -1) + 1
            insert([line], at: at, in: &lines, eol: eol)
            return lines.joined(separator: "\n")
        }
        let headings = NoteParser.parse(text).headings
        if let found = headings.firstIndex(where: { Self.fold($0.text) == Self.fold(wanted.name) }) {
            let start = headings[found].line
            let end = headings[(found + 1)...].first { $0.level <= headings[found].level }?.line ?? lines.count
            let at = (lastFilled(lines, in: (start + 1)..<end) ?? start) + 1
            insert([line], at: at, in: &lines, eol: eol)
        } else {
            let at = (lastFilled(lines, in: 0..<lines.count) ?? -1) + 1
            insert([String(repeating: "#", count: wanted.level) + " " + wanted.name, line], at: at, in: &lines, eol: eol)
        }
        return lines.joined(separator: "\n")
    }

    /// "## Inbox" is Inbox at level 2; a bare name is level 2 too.
    private static func headingName(_ spec: String) -> (name: String, level: Int) {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        let marks = trimmed.prefix { $0 == "#" }.count
        let name = trimmed.dropFirst(marks).trimmingCharacters(in: .whitespaces)
        return (name, (1...6).contains(marks) ? marks : 2)
    }

    private static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The last line in [range] with something on it.
    private static func lastFilled(_ lines: [String], in range: Range<Int>) -> Int? {
        range.last { !lines[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// [new] at [at], after a blank line when the line above would take it in:
    /// a paragraph goes on into a plain line, and `---` above text makes a
    /// heading of it. A list item after a list item, or anything right under
    /// a heading, needs none.
    private static func insert(_ new: [String], at: Int, in lines: inout [String], eol: String) {
        var block = new
        if at > 0 {
            let above = lines[at - 1].trimmingCharacters(in: .whitespacesAndNewlines)
            let heading = above.hasPrefix("#") && (above.drop { $0 == "#" }.first.map { $0 == " " || $0 == "\t" } ?? true)
            let list = above.prefixMatch(of: listItem) != nil && new[0].prefixMatch(of: listItem) != nil
            if !above.isEmpty && !heading && !list { block.insert("", at: 0) }
        }
        lines.insert(contentsOf: block.map { $0 + eol }, at: at)
    }
}

/// A global shortcut written as text, as in the settings file:
/// `ctrl+opt+n`, `cmd+shift+space`, `f13`. Modifiers are `cmd` (`command`),
/// `ctrl` (`control`), `opt` (`option`, `alt`) and `shift`; the key is a
/// letter, a digit, `space`, `return`, `tab`, `escape`, `delete`, an arrow
/// (`left`, `right`, `up`, `down`), `f1` to `f20`, or one of `- = [ ] ; ' , . / \ \``.
/// Parts are joined with `+`, in any order and any case. A key other than
/// F1-F20 needs Command, Control or Option, so typing never sets it off.
public struct HotKeySpec: Sendable, Equatable {
    /// The Mac's virtual key code (`kVK_*`) for the key on a US layout.
    public var keyCode: UInt32
    public var command = false
    public var control = false
    public var option = false
    public var shift = false
    /// The key as it is shown: "N", "Space", "F13".
    public var key: String

    public init(keyCode: UInt32, key: String, command: Bool = false, control: Bool = false, option: Bool = false, shift: Bool = false) {
        self.keyCode = keyCode
        self.key = key
        self.command = command
        self.control = control
        self.option = option
        self.shift = shift
    }

    /// The shortcut [spec] names, or nil when it is empty or not understood.
    public static func parse(_ spec: String) -> HotKeySpec? {
        let parts = spec.lowercased().split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 1, !parts.contains(where: \.isEmpty) else { return nil }
        guard let key = keys[parts.last!] else { return nil }
        var out = HotKeySpec(keyCode: key.code, key: key.name)
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command", "⌘": out.command = true
            case "ctrl", "control", "⌃": out.control = true
            case "opt", "option", "alt", "⌥": out.option = true
            case "shift", "⇧": out.shift = true
            default: return nil
            }
        }
        let function = key.name.hasPrefix("F") && key.name.count > 1
        guard function || out.command || out.control || out.option else { return nil }
        return out
    }

    /// As a menu shows it: ⌃⌥⇧⌘ and the key.
    public var symbols: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key
    }

    /// Each key by its name, with the name it is shown with.
    static let keys: [String: (code: UInt32, name: String)] = {
        var out: [String: (code: UInt32, name: String)] = [:]
        let letters: [(Character, UInt32)] = [
            ("a", 0x00), ("s", 0x01), ("d", 0x02), ("f", 0x03), ("h", 0x04), ("g", 0x05), ("z", 0x06), ("x", 0x07), ("c", 0x08),
            ("v", 0x09), ("b", 0x0B), ("q", 0x0C), ("w", 0x0D), ("e", 0x0E), ("r", 0x0F), ("y", 0x10), ("t", 0x11), ("o", 0x1F),
            ("u", 0x20), ("i", 0x22), ("p", 0x23), ("l", 0x25), ("j", 0x26), ("k", 0x28), ("n", 0x2D), ("m", 0x2E),
        ]
        for (letter, code) in letters { out[String(letter)] = (code, String(letter).uppercased()) }
        let digits: [UInt32] = [0x1D, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19]
        for (digit, code) in digits.enumerated() { out[String(digit)] = (code, String(digit)) }
        let marks: [(String, UInt32)] = [
            ("-", 0x1B), ("=", 0x18), ("[", 0x21), ("]", 0x1E), (";", 0x29), ("'", 0x27), (",", 0x2B), (".", 0x2F), ("/", 0x2C),
            ("\\", 0x2A), ("`", 0x32),
        ]
        for (mark, code) in marks { out[mark] = (code, mark) }
        let named: [(String, UInt32, String)] = [
            ("space", 0x31, "Space"), ("return", 0x24, "↩"), ("enter", 0x24, "↩"), ("tab", 0x30, "⇥"), ("escape", 0x35, "⎋"),
            ("esc", 0x35, "⎋"), ("delete", 0x33, "⌫"), ("backspace", 0x33, "⌫"), ("left", 0x7B, "←"), ("right", 0x7C, "→"),
            ("down", 0x7D, "↓"), ("up", 0x7E, "↑"),
        ]
        for (name, code, shown) in named { out[name] = (code, shown) }
        let functions: [UInt32] = [
            0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,
        ]
        for (index, code) in functions.enumerated() { out["f\(index + 1)"] = (code, "F\(index + 1)") }
        return out
    }()
}
