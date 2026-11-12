import AppKit
import DaftarCore

/// A pane's Neovim while the pane reads (⌘E): kept, not ended, so the
/// editor's next open takes it again in a few milliseconds, with each
/// note's undo in its buffer, where a new Neovim took a fifth of a second
/// to start. One is kept at a time; it is ended after [idleLimit] unused,
/// when the pane goes, when its note is moved or deleted, and at Quit. A
/// Neovim started with other settings is not taken again
/// (`NeovimSession.reusable`).
@MainActor
final class NeovimKeeper {
    private(set) var session: NeovimSession?
    private var idle: Task<Void, Never>?
    /// The kept Neovim writing its note: a flush waits for it.
    private var saving: Task<Void, Never>?
    private weak var store: VaultStore?

    /// How long a kept Neovim waits for the editor before it is ended.
    static var idleLimit = Duration.seconds(600)

    private static let all = NSHashTable<NeovimKeeper>.weakObjects()

    init() { Self.all.add(self) }

    isolated deinit {
        session?.kill()
        release()
    }

    /// Keeps [session], which the editor let go; [saving] is its last write.
    func keep(_ session: NeovimSession, store: VaultStore, saving: Task<Void, Never>) {
        end()
        self.session = session
        self.store = store
        self.saving = saving
        let id = ObjectIdentifier(self)
        store.followers[id] = { [weak self] in self?.follow($0) }
        store.flushers[id] = { [weak self] in await self?.saving?.value }
        idle = Task { [weak self] in
            try? await Task.sleep(for: Self.idleLimit)
            guard !Task.isCancelled else { return }
            self?.end()
        }
    }

    /// The kept Neovim, for the editor, when it can take a note: else it
    /// is ended, and the editor starts a new one.
    func take(for settings: AppSettings, root: URL) -> NeovimSession? {
        guard let session = release() else { return nil }
        if session.reusable(with: settings, root: root) { return session }
        Task { await session.stop(writing: false) }
        return nil
    }

    /// Ends the kept Neovim. Its note was written when it was kept.
    func end() {
        guard let session = release() else { return }
        Task { await session.stop(writing: false) }
    }

    @discardableResult
    private func release() -> NeovimSession? {
        let session = self.session
        self.session = nil
        idle?.cancel()
        idle = nil
        saving = nil
        if let store {
            store.followers[ObjectIdentifier(self)] = nil
            store.flushers[ObjectIdentifier(self)] = nil
        }
        store = nil
        return session
    }

    /// A move or a delete of the kept note ends its Neovim, which would
    /// write the old file; any other note's hidden buffer is wiped.
    private func follow(_ change: VaultChange) {
        guard let session else { return }
        let gone: [String]
        switch change {
        case .moved(let moves, _): gone = Array(moves.keys)
        case .deleted(let path): gone = [path]
        }
        let note = session.notePath
        if gone.contains(where: { note == $0 || note.hasPrefix($0 + "/") }) {
            release()
            session.kill()
            return
        }
        session.forget(gone)
    }

    /// Every kept Neovim, at Quit: their notes are written already.
    static func endAll() {
        for keeper in all.allObjects {
            keeper.release()?.kill()
        }
    }
}
