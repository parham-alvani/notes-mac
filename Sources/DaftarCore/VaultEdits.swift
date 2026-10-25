import Foundation

/// The edits the app makes to a vault file. Each one reads the file as it is
/// now and refuses when the file no longer says what the person clicked on,
/// so a click on an old view of a note never changes the wrong line.
public enum VaultEdits {
    public enum Failure: Error, Equatable {
        /// The line is not the task that was clicked: the file changed under the view.
        case taskMoved
        case unreadable
    }

    /// Ticks or opens the task on [line] of [text]. [status] is what the view
    /// showed, which the line must still hold.
    public static func toggleTask(in text: String, line: Int, status: Character, today: Day) throws -> String {
        var lines = text.components(separatedBy: "\n")
        guard line >= 0, line < lines.count else { throw Failure.taskMoved }
        let raw = lines[line]
        let crlf = raw.hasSuffix("\r")
        let clean = crlf ? String(raw.dropLast()) : raw
        guard let task = TaskLine.parse(clean, line: line, section: ""), task.status == status,
            let replacement = TaskLine.toggled(clean, today: today.description)
        else { throw Failure.taskMoved }
        lines.replaceSubrange(line...line, with: replacement.map { crlf ? $0 + "\r" : $0 })
        return lines.joined(separator: "\n")
    }

    /// Applies [edit] to the file at [path] in [root], written in place.
    public static func apply(_ path: String, in root: URL, _ edit: (String) throws -> String) throws {
        let url = root.appending(path: path)
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            throw Failure.unreadable
        }
        let result = try edit(text)
        guard result != text else { return }
        try Data(result.utf8).write(to: url, options: .atomic)
    }
}
