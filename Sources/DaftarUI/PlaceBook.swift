import CryptoKit
import DaftarCore
import Foundation
import Observation

/// What the app remembers of the notes of one vault (`ReadingPlaces`): the
/// reading places, folds, the outline's closed headings and read times, shared by every
/// window and written to a file a second after the last change, and when
/// the app quits. Without a [directory] they live only as long as the app.
@MainActor @Observable
final class PlaceBook {
    /// Grows when a note is read, so the marks of updated notes follow;
    /// the cursor's moves are not watched.
    private(set) var reads = 0
    /// Grows when a heading is closed or opened in an outline.
    private(set) var outlines = 0
    @ObservationIgnored private var places = ReadingPlaces()
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private var save: Task<Void, Never>?

    init() {}

    /// The places of the vault at [root], kept in [directory]: one file for
    /// each vault, named after its path.
    func load(root: URL, directory: URL) {
        write()
        let name = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        file = directory.appending(path: "places-\(name).json")
        places = file.flatMap { try? Data(contentsOf: $0) }.map(ReadingPlaces.init(data:)) ?? ReadingPlaces()
        reads += 1
    }

    subscript(path: String) -> Int? {
        get { places[path] }
        set {
            guard let newValue, places[path] != newValue else { return }
            places.set(path, line: newValue)
            later()
        }
    }

    func folds(_ path: String) -> [String] { places.folds(path) }

    func setFolds(_ path: String, _ folds: [String]) {
        guard places.folds(path) != folds else { return }
        places.setFolds(path, folds)
        later()
    }

    func closed(_ path: String) -> Set<String> {
        _ = outlines
        _ = reads
        return Set(places.closed(path))
    }

    func setClosed(_ path: String, _ closed: Set<String>) {
        guard Set(places.closed(path)) != closed else { return }
        places.setClosed(path, closed.sorted())
        outlines += 1
        later()
    }

    func lastRead(_ path: String) -> Date? {
        _ = reads
        return places.lastRead(path)
    }

    /// The notes read last, newest first.
    func recentlyRead(_ limit: Int) -> [String] {
        _ = reads
        return places.recentlyRead(limit)
    }

    func markRead(_ path: String, at date: Date = Date()) {
        places.markRead(path, at: date)
        reads += 1
        later()
    }

    func follow(_ change: VaultChange) {
        switch change {
        case .moved(let moves, _): places.moved(moves)
        case .deleted(let path): places.forget(path)
        }
        later()
    }

    private func later() {
        guard file != nil else { return }
        save?.cancel()
        save = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.write()
        }
    }

    /// Now, if anything is waiting to be written.
    func write() {
        guard let save, let file else { return }
        save.cancel()
        self.save = nil
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? places.data.write(to: file, options: .atomic)
    }
}
