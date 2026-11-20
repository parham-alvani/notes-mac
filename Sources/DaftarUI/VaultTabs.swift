import CryptoKit
import DaftarCore
import Foundation

/// The tabs each vault had when it was left, kept by the vault's folder as
/// the reading places are: `tabs-<hash>.json` in the app's state folder. A
/// change of vault writes the tabs of the vault being left and opens the
/// ones the new vault had (`docs/specs/several-vaults.md` in notes-linux).
/// A vault that is renamed or moved is a new vault to them.
enum VaultTabs {
    /// One window's tabs: each a note's vault path, a page, or the home page.
    struct Window: Codable, Equatable {
        var tabs: [Tab]
        /// The tab in front.
        var front: Int
    }

    struct Tab: Codable, Equatable {
        /// The note in the tab; nil is the home page.
        var path: String?
        /// Today, the board and the other pages, by `Page`'s name.
        var page: String?
    }

    /// The name the state files of the vault at [root] carry: the first
    /// bytes of its path's SHA-256, as `places-<hash>.json` has.
    static func hash(of root: URL) -> String {
        SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func file(of root: URL, in directory: URL) -> URL { directory.appending(path: "tabs-\(hash(of: root)).json") }

    /// The windows the vault at [root] had; none for a vault never left.
    static func read(_ root: URL, in directory: URL) -> [Window] {
        guard let data = try? Data(contentsOf: file(of: root, in: directory)) else { return [] }
        return (try? JSONDecoder().decode([Window].self, from: data)) ?? []
    }

    static func write(_ windows: [Window], of root: URL, in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(windows) else { return }
        try? data.write(to: file(of: root, in: directory), options: .atomic)
    }
}

extension WindowTabs {
    /// What the window's tabs show now, to open again when the vault is opened again.
    var kept: VaultTabs.Window {
        VaultTabs.Window(
            tabs: tabs.map { VaultTabs.Tab(path: $0.path, page: $0.page?.rawValue) },
            front: tabs.firstIndex { $0 === current } ?? 0)
    }

    /// Every tab of the window is closed and [kept]'s are opened in their
    /// place, each note at its reading place; nil, or a vault opened for
    /// the first time, is the home page. A note that is no longer in the
    /// vault's folder is left out. The tabs closed are new models' business
    /// no more: nothing of the vault before stays in the window.
    func show(_ kept: VaultTabs.Window?, store: VaultStore) {
        var front = 0
        var made: [WindowModel] = []
        for (place, tab) in (kept?.tabs ?? []).enumerated() {
            // A note that went since: its tab does not come back.
            if let path = tab.path, store.url(of: path).map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? true { continue }
            let model = WindowModel()
            model.tabs = self
            model.inspector = current.inspector
            adopt(model)
            if let path = tab.path { model.open(path, store: store) }
            if let page = tab.page.flatMap(Page.init(rawValue:)) { model.page = page }
            if place == kept?.front { front = made.count }
            made.append(model)
        }
        if made.isEmpty {
            let home = WindowModel()
            home.tabs = self
            home.inspector = current.inspector
            adopt(home)
            made = [home]
        }
        replace(with: made, front: made[min(front, made.count - 1)])
    }
}
