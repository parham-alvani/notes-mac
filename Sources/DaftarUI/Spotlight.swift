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
    /// Gives a batch of notes to the system's index; a test replaces it.
    var send: @MainActor ([NoteEntry], String) async throws -> Void = { notes, domain in
        // The text of each note, up to 20,000 letters, is cut off the main thread;
        // the items, which are not `Sendable`, are made here from plain values.
        let fields = await Task.detached(priority: .utility) { notes.map(Fields.init) }.value
        try await CSSearchableIndex.default().indexSearchableItems(fields.map { $0.item(domain: domain) })
    }
    /// The index refused a batch (an ad-hoc signed build gets
    /// `CSIndexErrorDomain -1000`): it will refuse the next too, so nothing
    /// more is built or sent until the app starts again or the setting is
    /// turned off and on.
    private(set) var failed = false
    /// The vault the index holds, and the notes in it with when they changed.
    private var root: URL?
    private var indexed: [String: Date] = [:]
    private var running: Task<Void, Never>?
    /// A vault just opened whose earlier items are not taken out yet.
    private var unclear: URL?
    /// The vault whose notes were taken out, with the setting off.
    private var cleared: URL?

    /// The index follows the vault: called whenever the vault changes.
    func follow(_ store: VaultStore) {
        guard let current = store.root, !store.loading else { return }
        guard store.settings.spotlight else {
            failed = false
            if cleared != current { clear(current) }
            return
        }
        guard !failed else { return }
        cleared = nil
        let notes = store.index.notes, hidden = store.hidden
        let fresh = root != current
        if fresh {
            // The vault before is not finished: its notes are not this one's.
            root = current
            indexed = [:]
            unclear = current
        }
        // A newer look replaces one not finished: what it sent is kept in
        // `indexed`, and the next one sends the rest.
        running?.cancel()
        let previous = running
        running = Task {
            await previous?.value
            // What an earlier run left may be gone by now: start again, even
            // when the run that found the new vault was replaced.
            if unclear == current {
                try? await index.deleteSearchableItems(withDomainIdentifiers: [current.path])
                if unclear == current { unclear = nil }
            }
            let known = indexed
            // Every note is looked at, off the main thread.
            let (gone, changed) = await Task.detached(priority: .utility) {
                let shown = notes.values.filter { !hidden.contains($0.path) }
                let now = Dictionary(shown.map { ($0.path, $0.modified) }) { a, _ in a }
                return (known.keys.filter { now[$0] == nil }, shown.filter { known[$0.path] != $0.modified })
            }.value
            guard !Task.isCancelled else { return }
            if !gone.isEmpty { try? await index.deleteSearchableItems(withIdentifiers: gone) }
            for batch in stride(from: 0, to: changed.count, by: 400) {
                guard !Task.isCancelled else { return }
                let part = Array(changed[batch..<min(batch + 400, changed.count)])
                do {
                    try await send(part, current.path)
                    guard root == current else { return }
                    for note in part { indexed[note.path] = note.modified }
                } catch {
                    failed = true
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
        Fields(note).item(domain: domain)
    }

    /// What Spotlight is told of a note, as plain values: made off the main thread.
    struct Fields: Sendable {
        var path: String
        var title: String
        var aliases: [String]
        var keywords: [String]
        var description: String
        var text: String
        var modified: Date
        var container: String

        init(_ note: NoteEntry) {
            path = note.path
            title = note.title
            aliases = note.parsed.aliases
            keywords = note.parsed.tags + note.parsed.aliases
            let plain = note.parsed.plain
            description = String(plain.prefix(300))
            text = String(plain.prefix(20_000))
            modified = note.modified
            container = note.path.split(separator: "/").dropLast().joined(separator: " › ")
        }

        func item(domain: String) -> CSSearchableItem {
            let attributes = CSSearchableItemAttributeSet(contentType: UTType(filenameExtension: "md") ?? .plainText)
            attributes.title = title
            attributes.displayName = title
            attributes.alternateNames = aliases
            attributes.keywords = keywords
            attributes.contentDescription = description
            attributes.textContent = text
            attributes.contentModificationDate = modified
            attributes.containerTitle = container
            let item = CSSearchableItem(uniqueIdentifier: path, domainIdentifier: domain, attributeSet: attributes)
            // Spotlight keeps a note it has not been told about again for a while.
            item.expirationDate = .distantFuture
            return item
        }
    }
}
