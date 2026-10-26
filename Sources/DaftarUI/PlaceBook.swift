import CryptoKit
import DaftarCore
import Foundation

/// The reading places of one vault (`ReadingPlaces`), shared by every
/// window and written to a file a second after the last change, and when
/// the app quits. Without a [directory] they live only as long as the app.
@MainActor
final class PlaceBook {
    private var places = ReadingPlaces()
    private var file: URL?
    private var save: Task<Void, Never>?

    init() {}

    /// The places of the vault at [root], kept in [directory]: one file for
    /// each vault, named after its path.
    func load(root: URL, directory: URL) {
        write()
        let name = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        file = directory.appending(path: "places-\(name).json")
        places = file.flatMap { try? Data(contentsOf: $0) }.map(ReadingPlaces.init(data:)) ?? ReadingPlaces()
    }

    subscript(path: String) -> Int? {
        get { places[path] }
        set {
            guard let newValue, places[path] != newValue else { return }
            places.set(path, line: newValue)
            later()
        }
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
