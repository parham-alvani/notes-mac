import CoreServices
import DaftarCore
import Foundation

/// The vault's files, watched with FSEvents. Reports vault paths, and only
/// ones the app reads: a `git` run or a `node_modules` install says nothing.
/// Of `.obsidian` it reports the Tasks plugin's settings, for the statuses.
final class FileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let base: String
    private let handler: (Set<String>) -> Void

    init(root: URL, handler: @escaping (Set<String>) -> Void) {
        base = root.resolvingSymlinksInPath().path.removingSuffixSlash + "/"
        self.handler = handler
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]
            watcher.report(list.prefix(count))
        }
        stream = FSEventStreamCreate(
            nil, callback, &context, [root.resolvingSymlinksInPath().path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "daftar.watcher"))
            FSEventStreamStart(stream)
        }
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
            if !relative.isEmpty, Vault.counts(relative) || relative == TaskStatuses.file { changed.insert(relative) }
        }
        if !changed.isEmpty { handler(changed) }
    }
}

extension String {
    var removingSuffixSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}
