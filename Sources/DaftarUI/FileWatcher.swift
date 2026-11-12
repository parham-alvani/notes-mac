import CoreServices
import DaftarCore
import Foundation

/// The vault's files, watched with FSEvents. Reports vault paths, and only
/// ones the app reads: a `git` run or a `node_modules` install says nothing.
/// Of `.obsidian` it reports the Tasks plugin's settings, for the statuses,
/// and the files the store keeps a copy of (`settings`). When the system
/// says it dropped events, or that a folder must be read again, it asks for
/// a rescan: the paths it gives then are not the files that changed.
final class FileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let base: String
    private let handler: (Set<String>) -> Void
    private let rescan: () -> Void

    /// The files of `.obsidian` the store reads once and keeps: a pull or
    /// Obsidian changes them, and the store reads them again.
    static let dailyNotes = ".obsidian/daily-notes.json"
    static let templates = ".obsidian/templates.json"
    static let bookmarks = ".obsidian/bookmarks.json"
    static let iconic = ".obsidian/plugins/iconic/data.json"
    static let app = ".obsidian/app.json"
    static let settings: Set<String> = [dailyNotes, templates, bookmarks, iconic, app]

    /// Whether a change of the vault path [relative] is one to report.
    static func reports(_ relative: String) -> Bool {
        !relative.isEmpty && (Vault.counts(relative) || relative == TaskStatuses.file || settings.contains(relative))
    }

    /// Whether an event with [flags] means events were lost: the queue
    /// overflowed, here or in the kernel, or a whole folder changed at once.
    static func lostEvents(_ flags: FSEventStreamEventFlags) -> Bool {
        let lost = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
        return flags & FSEventStreamEventFlags(lost) != 0
    }

    init(root: URL, handler: @escaping (Set<String>) -> Void, rescan: @escaping () -> Void = {}) {
        // FSEvents gives real paths: `/private/tmp/…`, which
        // `resolvingSymlinksInPath` would make `/tmp/…`, and no event would
        // be in the vault.
        let real = Self.realPath(root)
        base = real.removingSuffixSlash + "/"
        self.handler = handler
        self.rescan = rescan
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]
            if (0..<count).contains(where: { FileWatcher.lostEvents(flags[$0]) }) { watcher.rescan() }
            watcher.report(list.prefix(count))
        }
        stream = FSEventStreamCreate(
            nil, callback, &context, [real] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "daftar.watcher"))
            FSEventStreamStart(stream)
        }
    }

    /// The path of [url] with every link resolved, `/private` kept.
    static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.resolvingSymlinksInPath().path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func report(_ paths: ArraySlice<String>) {
        var changed = Set<String>()
        for path in paths where path.hasPrefix(base) {
            let relative = Slugs.normalize(String(path.dropFirst(base.count)))
            if Self.reports(relative) { changed.insert(relative) }
        }
        if !changed.isEmpty { handler(changed) }
    }
}

extension String {
    var removingSuffixSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}
