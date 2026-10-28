import Foundation

/// The edits the app makes to a vault file. Each one reads the file as it is
/// now and refuses when the file no longer says what the person clicked on,
/// so a click on an old view of a note never changes the wrong line.
public enum VaultEdits {
    public enum Failure: Error, Equatable {
        /// The line is not the task that was clicked: the file changed under the view.
        case taskMoved
        /// The text to change is no longer where it was found.
        case textMoved
        case unreadable
    }

    /// Ticks or opens the task on [line] of [text]. [status] is what the view
    /// showed, which the line must still hold.
    public static func toggleTask(in text: String, line: Int, status: Character, today: Day, statuses: TaskStatuses = .current) throws -> String {
        var lines = text.components(separatedBy: "\n")
        guard line >= 0, line < lines.count else { throw Failure.taskMoved }
        let raw = lines[line]
        let crlf = raw.hasSuffix("\r")
        let clean = crlf ? String(raw.dropLast()) : raw
        guard let task = TaskLine.parse(clean, line: line, section: ""), task.status == status,
            let replacement = TaskLine.toggled(clean, today: today.description, statuses: statuses)
        else { throw Failure.taskMoved }
        lines.replaceSubrange(line...line, with: replacement.map { crlf ? $0 + "\r" : $0 })
        return lines.joined(separator: "\n")
    }

    /// The task on [line] of [text] written from [fields]. [before] is the
    /// task the form was opened on, which the line must still hold. A new
    /// status is set as a status menu sets it (`TaskLine.settingStatus`),
    /// with the form's reason.
    public static func editTask(in text: String, line: Int, before: TaskFields, fields: TaskFields, today: Day = .today(),
                                statuses: TaskStatuses = .current) throws -> String {
        var lines = text.components(separatedBy: "\n")
        guard line >= 0, line < lines.count else { throw Failure.taskMoved }
        let raw = lines[line]
        let crlf = raw.hasSuffix("\r")
        let clean = crlf ? String(raw.dropLast()) : raw
        var kept = fields
        kept.status = before.status
        guard TaskLine.fields(clean) == before, let written = TaskLine.edited(clean, kept) else { throw Failure.taskMoved }
        var replacement = [written]
        if fields.status != before.status,
            let changed = TaskLine.settingStatus(written, to: fields.status, reason: fields.reason, today: today, statuses: statuses)
        {
            replacement = changed
        }
        lines.replaceSubrange(line...line, with: replacement.map { crlf ? $0 + "\r" : $0 })
        return lines.joined(separator: "\n")
    }

    /// Applies [edit] to the file at [path] in [root], written in place.
    /// [edit] applied to each of [paths], several files at a time: a tag
    /// rename can write thousands of notes. For each path, in order, whether
    /// its text changed, or what stopped it.
    public static func apply(_ paths: [String], in root: URL, _ edit: @Sendable (String) throws -> String) -> [Result<Bool, any Error>] {
        nonisolated(unsafe) let results = UnsafeMutableBufferPointer<Result<Bool, any Error>>.allocate(capacity: paths.count)
        defer { results.deallocate() }
        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            var changed = false
            do {
                try apply(paths[index], in: root) { text in
                    let result = try edit(text)
                    changed = result != text
                    return result
                }
                (results.baseAddress! + index).initialize(to: .success(changed))
            } catch {
                (results.baseAddress! + index).initialize(to: .failure(error))
            }
        }
        defer { _ = results.deinitialize() }
        return Array(results)
    }

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
