import Foundation

/// The weekly review: `daftar-cli review` writes `Reviews/<from> to <to>.md`
/// every Saturday (the vault's CI runs it), the seven days before the day it
/// is written. This finds the note of this week and the newest one; the app
/// runs the command to preview or make it. The spec is `weekly-review.md` in
/// notes-linux's `docs/specs`.
public enum WeeklyReview {
    /// The folder the command writes in, `--folder`'s default.
    public static let folder = "Reviews"

    /// The day this week's review is written on: the last Saturday, today
    /// when today is one.
    public static func day(for today: Day) -> Day {
        let weekday = Calendar(identifier: .gregorian).component(.weekday, from: today.date)  // 1 Sunday … 7 Saturday
        return today.adding(days: -(weekday % 7))
    }

    /// The days a review written on [day] covers: the seven before it.
    public static func span(writtenOn day: Day) -> (from: Day, to: Day) {
        (day.adding(days: -7), day.adding(days: -1))
    }

    /// The path of the review written on [day]: `Reviews/2026-10-31 to 2026-11-06.md`.
    public static func path(writtenOn day: Day, folder: String = folder) -> String {
        let (from, to) = span(writtenOn: day)
        return (folder.isEmpty ? "" : folder + "/") + "\(from) to \(to).md"
    }

    /// The span a review's file name says, or nil for any other name.
    public static func span(ofPath path: String) -> (from: Day, to: Day)? {
        guard path.hasSuffix(".md") else { return nil }
        let name = String(path.split(separator: "/").last ?? "").dropLast(3)
        let parts = name.components(separatedBy: " to ")
        guard parts.count == 2, let from = Day(parts[0]), let to = Day(parts[1]), from <= to else { return nil }
        return (from, to)
    }

    /// This week's review among the vault's [files], when it is there:
    /// the one written on the last Saturday. A name in another case is the same note.
    public static func thisWeek(today: Day, in files: some Sequence<String>, folder: String = folder) -> String? {
        let wanted = path(writtenOn: day(for: today), folder: folder).lowercased()
        return files.first { $0.lowercased() == wanted }
    }

    /// The newest review in [folder], by the last day it covers; nil when
    /// there is none. Only the folder's own notes named `<day> to <day>.md` count.
    public static func newest(in files: some Sequence<String>, folder: String = folder) -> String? {
        let prefix = folder.isEmpty ? "" : folder.lowercased() + "/"
        var best: (path: String, to: Day)?
        for file in files {
            let lower = file.lowercased()
            guard lower.hasPrefix(prefix), !lower.dropFirst(prefix.count).contains("/"), let span = span(ofPath: file) else { continue }
            if best == nil || span.to > best!.to || (span.to == best!.to && file < best!.path) { best = (file, span.to) }
        }
        return best?.path
    }

    /// `daftar-cli review`'s arguments for the review written on [day]:
    /// printed, or with [write] made in the folder (never over a note), its path printed.
    public static func arguments(vault: URL, day: Day, write: Bool = false) -> [String] {
        ["--vault", vault.path, "review", "--day", day.description] + (write ? ["--write"] : [])
    }

    /// The vault path `review --write` printed: its last line, made relative
    /// to [vault] when it is absolute. Nil when it printed nothing.
    public static func writtenPath(_ output: String, vault: URL) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).last?.trimmingCharacters(in: .whitespaces), !line.isEmpty else { return nil }
        let root = vault.standardizedFileURL.path
        if line.hasPrefix(root + "/") { return String(line.dropFirst(root.count + 1)) }
        if line.hasPrefix("/") {
            // The vault through a link (`/tmp` is `/private/tmp`).
            let real = vault.resolvingSymlinksInPath().path
            if line.hasPrefix(real + "/") { return String(line.dropFirst(real.count + 1)) }
        }
        return line
    }
}
