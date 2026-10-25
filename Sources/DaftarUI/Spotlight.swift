import CoreSpotlight
import DaftarCore
import Foundation
import UniformTypeIdentifiers

/// The vault's notes in Spotlight: each note by its name, aliases, tags and
/// text, opened in Daftar when it is chosen. The index is the system's, on
/// this Mac; excluded files are left out, and turning the setting off takes
/// every note out again.
@MainActor
final class Spotlight {
    static let shared = Spotlight()

    private let index = CSSearchableIndex.default()
    /// The vault the index holds, and the notes in it with when they changed.
    private var root: URL?
    private var indexed: [String: Date] = [:]
    private var running: Task<Void, Never>?
    /// The vault whose notes were taken out, with the setting off.
    private var cleared: URL?

    /// The index follows the vault: called whenever the vault changes.
    func follow(_ store: VaultStore) {
        guard let current = store.root, !store.loading else { return }
        guard store.settings.spotlight else {
            if cleared != current { clear(current) }
            return
        }
        cleared = nil
        let notes = store.index.notes.values.filter { !store.excluded.contains($0.path) }
        let fresh = root != current
        if fresh {
            // The vault before is not finished: its notes are not this one's.
            running?.cancel()
            root = current
            indexed = [:]
        }
        let previous = running
        running = Task {
            await previous?.value
            // What an earlier run left may be gone by now: start again.
            if fresh { try? await index.deleteSearchableItems(withDomainIdentifiers: [current.path]) }
            let now = Dictionary(notes.map { ($0.path, $0.modified) }) { a, _ in a }
            let gone = indexed.keys.filter { now[$0] == nil }
            let changed = notes.filter { indexed[$0.path] != $0.modified }
            if !gone.isEmpty { try? await index.deleteSearchableItems(withIdentifiers: gone) }
            for batch in stride(from: 0, to: changed.count, by: 400) {
                guard !Task.isCancelled else { return }
                let part = Array(changed[batch..<min(batch + 400, changed.count)])
                let items = part.map { Self.item($0, domain: current.path) }
                do {
                    try await index.indexSearchableItems(items)
                    guard root == current else { return }
                    for note in part { indexed[note.path] = note.modified }
                } catch {
                    return
                }
            }
            if root == current { for path in gone { indexed[path] = nil } }
        }
    }

    private func clear(_ current: URL) {
        cleared = current
        running?.cancel()
        root = nil
        indexed = [:]
        Task { try? await index.deleteSearchableItems(withDomainIdentifiers: [current.path]) }
    }

    nonisolated static func item(_ note: NoteEntry, domain: String) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: UTType(filenameExtension: "md") ?? .plainText)
        attributes.title = note.title
        attributes.displayName = note.title
        attributes.alternateNames = note.parsed.aliases
        attributes.keywords = note.parsed.tags + note.parsed.aliases
        let plain = note.parsed.plain
        attributes.contentDescription = String(plain.prefix(300))
        attributes.textContent = String(plain.prefix(20_000))
        attributes.contentModificationDate = note.modified
        attributes.containerTitle = note.path.split(separator: "/").dropLast().joined(separator: " › ")
        let item = CSSearchableItem(uniqueIdentifier: note.path, domainIdentifier: domain, attributeSet: attributes)
        // Spotlight keeps a note it has not been told about again for a while.
        item.expirationDate = .distantFuture
        return item
    }
}
