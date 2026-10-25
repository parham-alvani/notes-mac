import Foundation

/// The editing rules that are more than inserting a character: what Return
/// does in a list, what Tab does to an item, what ⌘↩ does to a line. Pure
/// functions of one line, so the editor stays thin and these are tested.
public enum EditorCommands {
    nonisolated(unsafe) private static let item = /^(\s*(?:>\s?)*\s*)([-*+]|(\d+)([.)]))(\s+)(\[[^\]]\]\s+)?(.*)$/

    /// What Return inserts after [line]: the next item's marker, or nil to
    /// insert a plain newline. An empty item ends the list instead, which is
    /// `.endList` -- the editor clears the marker.
    public enum Return: Equatable {
        case insert(String)
        case endList
    }

    public static func onReturn(after line: String) -> Return? {
        guard let match = line.wholeMatch(of: item) else { return nil }
        let indent = String(match.1)
        let space = String(match.5)
        let text = String(match.7)
        let hasTask = match.6 != nil
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return .endList }
        var marker = String(match.2)
        if let number = match.3.flatMap({ Int($0) }), let close = match.4 { marker = "\(number + 1)\(close)" }
        return .insert("\n" + indent + marker + space + (hasTask ? "[ ] " : ""))
    }

    /// The vault indents a nested item by four spaces.
    public static let indentUnit = "    "

    public static func indent(_ line: String) -> String { indentUnit + line }

    public static func outdent(_ line: String) -> String {
        if line.hasPrefix(indentUnit) { return String(line.dropFirst(indentUnit.count)) }
        if line.hasPrefix("\t") { return String(line.dropFirst()) }
        return String(line.drop { $0 == " " })
    }

    public static func isListItem(_ line: String) -> Bool { line.wholeMatch(of: item) != nil }

    /// ⌘↩: a task is ticked or opened again, as a click on its box does; a
    /// list item becomes a task; any other line becomes a task item.
    public static func toggleTask(_ line: String, today: Day) -> [String] {
        if let toggled = TaskLine.toggled(line, today: today.description) { return toggled }
        if let match = line.wholeMatch(of: item) {
            return [String(match.1) + String(match.2) + String(match.5) + "[ ] " + String(match.7)]
        }
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let text = line.dropFirst(indent.count)
        return [indent + "- [ ] " + text]
    }

    /// The name Obsidian gives a pasted image, in the attachment folder.
    public static func pastedImageName(at date: Date = Date(), ext: String = "png") -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyyMMddHHmmss"
        return "Pasted image \(format.string(from: date)).\(ext)"
    }

    /// The text after an unclosed `[[` that ends at [location], which `[[`
    /// completion replaces, or nil when the cursor is not in one.
    public static func linkQuery(in text: NSString, at location: Int) -> NSRange? {
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        let before = text.substring(with: NSRange(location: line.location, length: location - line.location)) as NSString
        let open = before.range(of: "[[", options: .backwards)
        guard open.location != NSNotFound else { return nil }
        let typed = before.substring(from: NSMaxRange(open))
        guard !typed.contains("]]"), !typed.contains("|"), !typed.contains("#") else { return nil }
        return NSRange(location: line.location + NSMaxRange(open), length: (typed as NSString).length)
    }
}
