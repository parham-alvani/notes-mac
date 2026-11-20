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
        /// The vault is a read-only clone (`daftar.readonly` in its git
        /// config): the app writes no file of it.
        case readOnly
    }

    /// Whether the vault at [root] is a read-only clone. Asked before every
    /// write, so the answer is kept for the clone's config file as it is
    /// now (its date, size and inode) and git runs again only when that
    /// file changed: a `git config daftar.readonly true` in a shell holds
    /// for the app's next write.
    public static func isReadOnly(_ root: URL) -> Bool { ReadOnlyClones.shared.isReadOnly(root) }

    /// Throws `Failure.readOnly` for a read-only clone, before anything of
    /// the vault is read or written. Every write of the app comes through here.
    public static func refuseReadOnly(_ root: URL) throws {
        if isReadOnly(root) { throw Failure.readOnly }
    }

    /// Ticks or opens the task on [line] of [text]. [status] is what the view
    /// showed, which the line must still hold, and [expected], when given,
    /// the task's text it showed.
    public static func toggleTask(in text: String, line: Int, status: Character, expected: String? = nil, today: Day,
                                  statuses: TaskStatuses = .current) throws -> String {
        var lines = text.components(separatedBy: "\n")
        guard line >= 0, line < lines.count else { throw Failure.taskMoved }
        let raw = lines[line]
        let crlf = raw.hasSuffix("\r")
        let clean = crlf ? String(raw.dropLast()) : raw
        // Another task with the same status that moved onto the line is not this one.
        guard let task = TaskLine.parse(clean, line: line, section: ""), task.status == status,
            expected.map({ $0.trimmingCharacters(in: .whitespaces) == task.text.trimmingCharacters(in: .whitespaces) }) ?? true,
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
        if isReadOnly(root) { return paths.map { _ in .failure(Failure.readOnly) } }
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
        try refuseReadOnly(root)
        let url = root.appending(path: path)
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            throw Failure.unreadable
        }
        let result = try edit(text)
        guard result != text else { return }
        try Data(result.utf8).write(to: url, options: .atomic)
    }
}

extension VaultEdits.Failure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .taskMoved: "The note changed before the click."
        case .textMoved: "The note changed since it was shown."
        case .unreadable: "The note could not be read."
        case .readOnly: "This vault is read-only."
        }
    }
}

/// The answer to "is this clone read-only", kept for each vault until its
/// git config file changes.
final class ReadOnlyClones: @unchecked Sendable {
    static let shared = ReadOnlyClones()

    private struct Stamp: Equatable {
        var date: Date?
        var size: Int?
        var inode: UInt64?
    }

    private struct Entry {
        /// The clone's config file.
        var config: String
        var stamp: Stamp
        var readOnly: Bool
    }

    private let lock = NSLock()
    private var known: [String: Entry] = [:]

    func isReadOnly(_ root: URL) -> Bool {
        let key = root.standardizedFileURL.path
        let entry = lock.withLock { known[key] }
        if let entry, Self.stamp(entry.config) == entry.stamp { return entry.readOnly }
        // No `.git` in the folder or above it: no repository, and no git to ask.
        guard Self.inRepository(root) else {
            lock.withLock { known[key] = nil }
            return false
        }
        let git = Git(root: root)
        let found = git.ask(["rev-parse", "--path-format=absolute", "--git-path", "config"])
        guard found.status == 0, !found.output.isEmpty else { return false }
        // The stamp is taken first: a change while git answers is asked about again.
        let stamp = Self.stamp(found.output)
        let readOnly = git.readsReadOnly()
        lock.withLock { known[key] = Entry(config: found.output, stamp: stamp, readOnly: readOnly) }
        return readOnly
    }

    private static func inRepository(_ root: URL) -> Bool {
        var folder = root.standardizedFileURL.path
        while true {
            if FileManager.default.fileExists(atPath: folder + "/.git") { return true }
            let parent = (folder as NSString).deletingLastPathComponent
            if parent == folder || parent.isEmpty { return false }
            folder = parent
        }
    }

    private static func stamp(_ path: String) -> Stamp {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return Stamp(
            date: attributes?[.modificationDate] as? Date, size: (attributes?[.size] as? NSNumber)?.intValue,
            inode: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value)
    }
}
