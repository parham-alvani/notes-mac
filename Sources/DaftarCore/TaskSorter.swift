import Foundation

/// The vault's own Task Sorter plugin: in each section of a note, the tasks
/// that are done or cancelled go first and the open ones last, each with the
/// lines indented under it. Lines that are not tasks stay where they are.
public enum TaskSorter {
    nonisolated(unsafe) private static let rootTask = /^- \[([ xX\-])\][ ]/
    nonisolated(unsafe) private static let heading = /^\#{1,6}[ ]/

    /// [text] with its tasks sorted, or nil when no section changes.
    public static func sort(_ text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        var result: [String] = []
        var changed = false
        var start = 0
        for index in lines.indices.dropFirst() where lines[index].prefixMatch(of: heading) != nil {
            changed = append(lines[start..<index], to: &result) || changed
            start = index
        }
        changed = append(lines[start...], to: &result) || changed
        return changed ? result.joined(separator: "\n") : nil
    }

    private static func append(_ section: ArraySlice<String>, to result: inout [String]) -> Bool {
        if let sorted = sortSection(Array(section)) {
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

    private static func sortSection(_ lines: [String]) -> [String]? {
        var elements: [Element] = []
        var index = 0
        while index < lines.count {
            if let match = lines[index].prefixMatch(of: rootTask) {
                var block = [lines[index]]
                index += 1
                while index < lines.count, lines[index].hasPrefix("    ") || lines[index].hasPrefix("\t") {
                    block.append(lines[index])
                    index += 1
                }
                elements.append(.task(lines: block, done: match.1 != " "))
            } else {
                var run = [lines[index]]
                index += 1
                while index < lines.count, lines[index].prefixMatch(of: rootTask) == nil {
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
