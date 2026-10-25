import Foundation

/// A Markdown table in the editor: Tab goes to the next cell and lines the
/// columns up, as Obsidian's table editor does, and Return at the end of a
/// row starts a new one.
public enum MarkdownTable {
    /// A row starts with a pipe, as every table in the vault is written.
    public static func isRow(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
    }

    /// The cells of a row, without the outer pipes. `\|` stays in its cell.
    public static func cells(_ line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body.removeLast() }
        var cells: [String] = [], cell = "", escaped = false
        for character in body {
            if character == "|", !escaped {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
            escaped = character == "\\" && !escaped
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    static func isSeparator(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { $0.wholeMatch(of: /:?-+:?/) != nil }
    }

    /// The width a cell takes in a monospaced line: a wide letter, as in
    /// Chinese, counts two.
    static func width(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { sum, scalar in
            let wide = (0x1100...0x115F).contains(scalar.value) || (0x2E80...0xA4CF).contains(scalar.value)
                || (0xAC00...0xD7A3).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value)
                || (0xFF00...0xFF60).contains(scalar.value) || (0x1F300...0x1FAFF).contains(scalar.value)
            return sum + (scalar.properties.generalCategory == .nonspacingMark ? 0 : wide ? 2 : 1)
        }
    }

    /// The rows with every column as wide as its widest cell, and as many
    /// cells in each row as the widest row has. The indent of the first row
    /// is kept.
    public static func format(_ lines: [String]) -> [String] {
        let indent = String(lines.first?.prefix { $0 == " " || $0 == "\t" } ?? "")
        var rows = lines.map(cells)
        // Known before the rows are filled out: a filled-in separator is one still.
        let separators = rows.map(isSeparator)
        let columns = rows.map(\.count).max() ?? 0
        rows = rows.map { $0 + Array(repeating: "", count: columns - $0.count) }
        var widths = Array(repeating: 3, count: columns)
        for (row, cells) in rows.enumerated() where !separators[row] {
            for (column, cell) in cells.enumerated() { widths[column] = max(widths[column], width(cell)) }
        }
        return rows.enumerated().map { row, cells in
            let parts = cells.enumerated().map { column, cell -> String in
                if separators[row] {
                    let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
                    let dashes = String(repeating: "-", count: widths[column] - (left ? 1 : 0) - (right ? 1 : 0))
                    return (left ? ":" : "") + dashes + (right ? ":" : "")
                }
                return cell + String(repeating: " ", count: widths[column] - width(cell))
            }
            return indent + "| " + parts.joined(separator: " | ") + " |"
        }
    }

    /// Where the text of cell [column] starts in a formatted [line], in UTF-16.
    public static func cellStart(_ line: String, column: Int) -> Int {
        var pipes = 0, escaped = false
        for (offset, unit) in line.utf16.enumerated() {
            if unit == 0x7C, !escaped {
                if pipes == column { return min(offset + 2, line.utf16.count) }
                pipes += 1
            }
            escaped = unit == 0x5C && !escaped
        }
        return line.utf16.count
    }

    /// The cell that holds UTF-16 [offset] of [line].
    public static func column(at offset: Int, in line: String) -> Int {
        var pipes = 0, escaped = false
        for (index, unit) in line.utf16.enumerated() {
            if index >= offset { break }
            if unit == 0x7C, !escaped { pipes += 1 }
            escaped = unit == 0x5C && !escaped
        }
        return max(0, pipes - 1)
    }

    /// Tab (or ⇧Tab, [back]) in [lines] with the cursor in [row], [column]:
    /// the table formatted, and the row and cell the cursor goes to. Past
    /// the last cell a new row is made.
    public static func tab(_ lines: [String], row: Int, column: Int, back: Bool) -> (lines: [String], row: Int, column: Int) {
        var table = format(lines)
        let columns = cells(table[0]).count
        let separators = table.map { isSeparator(cells($0)) }
        var r = row, c = column
        repeat {
            if back {
                c -= 1
                if c < 0 { r -= 1; c = columns - 1 }
            } else {
                c += 1
                if c >= columns { r += 1; c = 0 }
            }
        } while r >= 0 && r < table.count && separators[r]
        if r < 0 { return (table, 0, 0) }
        if r >= table.count {
            table = format(table + [emptyRow(columns)])
            r = table.count - 1
            c = 0
        }
        return (table, r, c)
    }

    /// A new row under [lines]' last, the table formatted, the cursor in its first cell.
    public static func newRow(_ lines: [String]) -> [String] {
        format(lines + [emptyRow(cells(lines[0]).count)])
    }

    static func emptyRow(_ columns: Int) -> String {
        "|" + String(repeating: " |", count: max(columns, 1))
    }
}

extension EditorCommands {
    /// ⌥↑ and ⌥↓: the lines that hold [selection] change places with the
    /// line above or below. The edit's range and text, and the selection
    /// after it; nil at the top or the bottom.
    public static func moveLines(in text: NSString, selection: NSRange, up: Bool) -> (range: NSRange, text: String, selection: NSRange)? {
        var lines = text.lineRange(for: selection)
        // A selection that ends at a line's start does not take that line.
        if selection.length > 0, NSMaxRange(selection) == NSMaxRange(lines), lines.length > 0 {
            let last = text.lineRange(for: NSRange(location: NSMaxRange(selection) - 1, length: 0))
            lines = NSRange(location: lines.location, length: NSMaxRange(last) - lines.location)
        }
        func body(_ range: NSRange) -> String {
            let line = text.substring(with: range)
            return line.hasSuffix("\n") ? String(line.dropLast()) : line
        }
        if up {
            guard lines.location > 0 else { return nil }
            let above = text.lineRange(for: NSRange(location: lines.location - 1, length: 0))
            let whole = NSRange(location: above.location, length: NSMaxRange(lines) - above.location)
            let ending = text.substring(with: whole).hasSuffix("\n") ? "\n" : ""
            let moved = body(lines) + "\n" + body(above) + ending
            let shift = above.length
            return (whole, moved, NSRange(location: selection.location - shift, length: selection.length))
        }
        guard NSMaxRange(lines) < text.length else { return nil }
        let below = text.lineRange(for: NSRange(location: NSMaxRange(lines), length: 0))
        let whole = NSRange(location: lines.location, length: NSMaxRange(below) - lines.location)
        let ending = text.substring(with: whole).hasSuffix("\n") ? "\n" : ""
        let moved = body(below) + "\n" + body(lines) + ending
        let shift = (body(below) as NSString).length + 1
        return (whole, moved, NSRange(location: selection.location + shift, length: selection.length))
    }
}
