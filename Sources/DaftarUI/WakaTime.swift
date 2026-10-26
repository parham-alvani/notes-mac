import DaftarCore
import Foundation

/// WakaTime's heartbeats, sent with `wakatime-cli` as the editor plugins
/// send them: a note opened or read, at most every two minutes for the same
/// note, and every save. Off unless `wakatime.enabled` is on; the key is
/// `wakatime-cli`'s own, in `~/.wakatime.cfg`.
@MainActor
final class WakaTime {
    static let shared = WakaTime()

    private var last: (entity: String, time: Date)?

    /// The `wakatime-cli` to run: [configured], or the one the plugins
    /// install in `~/.wakatime`, or Homebrew's.
    nonisolated static func cli(_ configured: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [(configured as NSString).expandingTildeInPath].filter { !$0.isEmpty }
            + [home + "/.wakatime/wakatime-cli", "/opt/homebrew/bin/wakatime-cli", "/usr/local/bin/wakatime-cli"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The note at [path] was read ([write] false) or saved.
    func heartbeat(_ path: String, store: VaultStore, write: Bool = false) {
        guard store.settings.wakatime, Vault.isNote(path), let file = store.url(of: path),
            let cli = Self.cli(store.settings.wakatimeCLI)
        else { return }
        let now = Date()
        if !write, let last, last.entity == file.path, now.timeIntervalSince(last.time) < 120 { return }
        last = (file.path, now)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let process = Process()
        process.executableURL = URL(filePath: cli)
        process.arguments = [
            "--entity", file.path,
            "--plugin", "daftar/\(version) daftar-wakatime/\(version)",
            "--project", store.name,
            "--language", "Markdown",
            "--category", "writing docs",
            "--time", String(now.timeIntervalSince1970),
        ] + (write ? ["--write"] : [])
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
