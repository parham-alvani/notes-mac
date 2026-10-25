import AppKit
import DaftarCore
import Foundation
import Observation

/// The app's settings. All of them live in one file,
/// `~/.config/daftar/config.toml` (see `ConfigFile`); nothing is kept in
/// `UserDefaults`. An edit to the file shows in the app at once, and a change
/// in the Settings window writes that one value to the file.
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()

    @ObservationIgnored let url: URL
    @ObservationIgnored private var file = ConfigFile(text: ConfigFile.template)
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var loading = false

    var vaultPath: String? { didSet { write("vault", .string(vaultPath ?? "")) } }
    var appearance: Appearance { didSet { write("appearance.theme", .string(appearance.rawValue)); applyAppearance() } }
    var textSize: Int { didSet { write("appearance.text_size", .int(textSize)) } }
    var font: String { didSet { write("appearance.font", .string(font)) } }
    var codeFont: String { didSet { write("appearance.code_font", .string(codeFont)) } }
    var dockBadge: Bool { didSet { write("appearance.dock_badge", .bool(dockBadge)) } }
    /// Minutes between commit-pull-push runs; 0 is off.
    var syncInterval: Int { didSet { write("git.sync_interval", .int(syncInterval)) } }
    var pullOnLaunch: Bool { didSet { write("git.pull_on_launch", .bool(pullOnLaunch)) } }
    var meetingAlerts: Bool { didSet { write("notifications.meetings", .bool(meetingAlerts)) } }
    /// How long before a meeting it is announced, in minutes.
    var meetingLead: Int { didSet { write("notifications.meeting_lead", .int(meetingLead)) } }
    var taskDigest: Bool { didSet { write("notifications.digest", .bool(taskDigest)) } }
    /// Minutes after midnight.
    var digestTime: Int { didSet { write("notifications.digest_time", .string(Self.clock(digestTime))) } }
    var shell: String { didSet { write("terminal.shell", .string(shell)) } }
    var terminalFontSize: Int { didSet { write("terminal.font_size", .int(terminalFontSize)) } }

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: "Match System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    /// [url] is for tests, which must never touch the person's own file.
    init(url: URL = ConfigFile.defaultURL) {
        self.url = url
        vaultPath = nil
        appearance = .system
        textSize = 14
        font = "SF Pro"
        codeFont = "SF Mono"
        dockBadge = true
        syncInterval = 0
        pullOnLaunch = true
        meetingAlerts = true
        meetingLead = 5
        taskDigest = true
        digestTime = 9 * 60
        shell = ""
        terminalFontSize = 13
        load()
        watch()
    }

    /// Reads the file, making it from the template the first time.
    private func load() {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(ConfigFile.template.utf8).write(to: url, options: .atomic)
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        file = ConfigFile(text: text)
        loading = true
        defer { loading = false }
        let vault = file.string("vault") ?? ""
        vaultPath = vault.isEmpty ? nil : (vault as NSString).expandingTildeInPath
        appearance = file.string("appearance.theme").flatMap(Appearance.init(rawValue:)) ?? .system
        textSize = file.int("appearance.text_size") ?? 14
        font = file.string("appearance.font") ?? "SF Pro"
        codeFont = file.string("appearance.code_font") ?? "SF Mono"
        dockBadge = file.bool("appearance.dock_badge") ?? true
        syncInterval = file.int("git.sync_interval") ?? 0
        pullOnLaunch = file.bool("git.pull_on_launch") ?? true
        meetingAlerts = file.bool("notifications.meetings") ?? true
        meetingLead = file.int("notifications.meeting_lead") ?? 5
        taskDigest = file.bool("notifications.digest") ?? true
        digestTime = file.string("notifications.digest_time").flatMap(Self.minutes) ?? 9 * 60
        shell = file.string("terminal.shell") ?? ""
        terminalFontSize = file.int("terminal.font_size") ?? 13
    }

    private func write(_ path: String, _ value: ConfigFile.Value) {
        guard !loading, file[path] != value else { return }
        file.set(path, value)
        try? Data(file.text.utf8).write(to: url, options: .atomic)
    }

    /// The file is written atomically -- by this app and by most editors -- so
    /// the watch is on the folder, and any change there reads the file again.
    private func watch() {
        let folder = open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard folder >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: folder, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let text = try? String(contentsOf: self.url, encoding: .utf8), text != self.file.text else { return }
                self.load()
            }
        }
        source.setCancelHandler { close(folder) }
        source.resume()
        watcher = source
    }

    func applyAppearance() {
        NSApp?.appearance = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    func revealFile() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    static func minutes(_ clock: String) -> Int? {
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return parts[0] * 60 + parts[1]
    }
}
