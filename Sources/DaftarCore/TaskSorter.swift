import Foundation

/// The vault's own Task Sorter plugin: in each section of a note, the tasks
/// that are done or cancelled go first and the open ones last, each with the
/// lines indented under it. Lines that are not tasks stay where they are,
/// and so does everything in a code fence: an example of a task list is
/// text, not tasks, and a `# comment` in it starts no section.
public enum TaskSorter {
    nonisolated(unsafe) private static let rootTask = /^- \[([ xX\-])\][ ]/
    nonisolated(unsafe) private static let heading = /^\#{1,6}[ ]/

    /// [text] with its tasks sorted, or nil when no section changes.
    public static func sort(_ text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        let fenced = fenced(lines)
        var result: [String] = []
        var changed = false
        var start = 0
        for index in lines.indices.dropFirst() where !fenced[index] && lines[index].hasPrefix("#") && lines[index].prefixMatch(of: heading) != nil {
            changed = append(lines[start..<index], fenced, to: &result) || changed
            start = index
        }
        changed = append(lines[start...], fenced, to: &result) || changed
        return changed ? result.joined(separator: "\n") : nil
    }

    /// For each line, whether it is a code fence's: its marks or what is between them.
    private static func fenced(_ lines: [String]) -> [Bool] {
        var out = [Bool](repeating: false, count: lines.count)
        var open: Substring?
        for (index, line) in lines.enumerated() {
            if let mark = NoteParser.fenceMark(line) {
                out[index] = true
                if let first = open {
                    if mark.first == first.first, mark.count >= first.count { open = nil }
                } else {
                    open = mark
                }
            } else {
                out[index] = open != nil
            }
        }
        return out
    }

    private static func append(_ section: ArraySlice<String>, _ fenced: [Bool], to result: inout [String]) -> Bool {
        if let sorted = sortSection(section, fenced) {
            result += sorted
            return true
        }
        result += section
        return false
    }

    private enum Element {
        case task(lines: [String], done: Bool)
        case other([String])
    }

    private static func sortSection(_ lines: ArraySlice<String>, _ fenced: [Bool]) -> [String]? {
        var elements: [Element] = []
        var index = lines.startIndex
        func task(_ at: Int) -> Bool? {
            guard !fenced[at], lines[at].hasPrefix("- ["), let match = lines[at].prefixMatch(of: rootTask) else { return nil }
            return match.1 != " "
        }
        while index < lines.endIndex {
            if let done = task(index) {
                var block = [lines[index]]
                index += 1
                // What is indented under the task goes with it, by however many spaces:
                // a child two spaces in is its child as much as one four in.
                while index < lines.endIndex, lines[index].hasPrefix(" ") || lines[index].hasPrefix("\t") {
                    block.append(lines[index])
                    index += 1
                }
                elements.append(.task(lines: block, done: done))
            } else {
                var run = [lines[index]]
                index += 1
                while index < lines.endIndex, task(index) == nil {
                    run.append(lines[index])
                    index += 1
                }
                elements.append(.other(run))
            }
        }
        let tasks = elements.compactMap { element -> (lines: [String], done: Bool)? in
            if case let .task(lines, done) = element { return (lines, done) }
            return nil
        }
        let sorted = tasks.filter(\.done) + tasks.filter { !$0.done }
        guard sorted.map(\.lines) != tasks.map(\.lines) else { return nil }
        var next = sorted.makeIterator()
        return elements.flatMap { element -> [String] in
            switch element {
            case let .other(lines): return lines
            case .task: return next.next()?.lines ?? []
            }
        }
    }
}
