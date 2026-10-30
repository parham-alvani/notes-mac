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
    var spotlight: Bool { didSet { write("appearance.spotlight", .bool(spotlight)) } }
    var hideMenuBar: Bool { didSet { write("appearance.hide_menu_bar", .bool(hideMenuBar)); applyMenuBar() } }
    var wakatime: Bool { didSet { write("wakatime.enabled", .bool(wakatime)) } }
    var wakatimeCLI: String { didSet { write("wakatime.cli", .string(wakatimeCLI)) } }
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
    var vimMode: Bool { didSet { write("editor.vim_mode", .bool(vimMode)) } }
    var livePreview: Bool { didSet { write("editor.live_preview", .bool(livePreview)) } }
    /// The front matter shows as a form of properties above the editor, not as YAML.
    var propertiesForm: Bool { didSet { write("editor.properties_form", .bool(propertiesForm)) } }
    /// The cursor's line stays in the middle of the editor while you type.
    var typewriter: Bool { didSet { write("editor.typewriter", .bool(typewriter)) } }
    /// Every paragraph but the cursor's dims.
    var focusMode: Bool { didSet { write("editor.focus", .bool(focusMode)) } }
    /// Spelling as you type, each paragraph in its own language.
    var spellCheck: Bool { didSet { write("editor.spell_check", .bool(spellCheck)) } }
    /// Neovim mode: the cursor slides to where it goes, as Neovide's does.
    var animateCursor: Bool { didSet { write("editor.animate_cursor", .bool(animateCursor)) } }
    /// The sliding cursor stretches: its front corners go first, its back ones follow.
    var cursorTrail: Bool { didSet { write("editor.cursor_trail", .bool(cursorTrail)) } }
    /// Particles where the Neovim cursor goes, as Neovide's `vfx_mode`.
    var cursorEffect: CursorEffect { didSet { write("editor.cursor_effect", .string(cursorEffect.rawValue)) } }
    /// Which ⌥ keys Neovim gets as Meta.
    var optionAsMeta: VimKeys.OptionKey { didSet { write("editor.option_as_meta", .string(optionAsMeta.rawValue)) } }
    /// Neovim's completion menu and command line show the note blurred behind them.
    var blurPanels: Bool { didSet { write("editor.blur_panels", .bool(blurPanels)) } }
    var nvimPath: String { didSet { write("editor.nvim", .string(nvimPath)) } }
    var nvimConfig: String { didSet { write("editor.nvim_config", .string(nvimConfig)) } }
    var terminalFontSize: Int { didSet { write("terminal.font_size", .int(terminalFontSize)) } }
    /// Quick capture's global shortcut, as `HotKeySpec` reads it; empty is off.
    var captureHotkey: String { didSet { write("capture.hotkey", .string(captureHotkey)) } }
    /// "daily", or a note's vault path.
    var captureTarget: String { didSet { write("capture.target", .string(captureTarget)) } }
    var captureHeading: String { didSet { write("capture.heading", .string(captureHeading)) } }
    /// The folder of the day's scratch notes, `<folder>/YYYY-MM-DD.md`; empty is the vault's top.
    var scratchpadFolder: String { didSet { write("scratchpad.folder", .string(scratchpadFolder)) } }
    /// The home page's picture, as the file has it: absolute, `~` or in the vault; empty is none.
    var homeImage: String { didSet { write("home.image", .string(homeImage)) } }
    /// What ⌘T opens: the home page, or the note the window shows.
    var newTab: NewTab { didSet { write("home.new_tab", .string(newTab.rawValue)) } }
    /// Files for AI agents, by name in any folder, kept out of the lists as Obsidian's excluded files are.
    var hiddenNames: [String] { didSet { write("files.hidden", .strings(hiddenNames)) } }
    /// The hidden and the excluded files show in the lists anyway.
    var showHidden: Bool { didSet { write("files.show_hidden", .bool(showHidden)) } }

    static let defaultHiddenNames = ["CLAUDE.md", "AGENTS.md", "GEMINI.md", "CLAUDE.local.md"]

    enum CursorEffect: String, CaseIterable, Identifiable {
        case none, railgun, torpedo, pixiedust, sonicboom, ripple
        var id: String { rawValue }
        var title: String { self == .none ? "None" : rawValue.capitalized }
    }

    enum NewTab: String, CaseIterable, Identifiable {
        case home, note
        var id: String { rawValue }
    }

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

    /// What the app keeps for itself, such as the reading places: not in the
    /// configuration folder, which is the person's own. Beside a test's
    /// file, so a test never writes to the person's Library.
    var stateDirectory: URL {
        if url == ConfigFile.defaultURL, ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] == nil {
            return URL.applicationSupportDirectory.appending(path: "Daftar")
        }
        return url.deletingLastPathComponent().appending(path: "state")
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
        spotlight = true
        hideMenuBar = false
        wakatime = false
        wakatimeCLI = ""
        syncInterval = 0
        pullOnLaunch = true
        meetingAlerts = true
        meetingLead = 5
        taskDigest = true
        digestTime = 9 * 60
        shell = ""
        terminalFontSize = 13
        vimMode = false
        livePreview = true
        propertiesForm = true
        typewriter = false
        focusMode = false
        spellCheck = true
        animateCursor = true
        cursorTrail = true
        cursorEffect = .none
        optionAsMeta = .none
        blurPanels = true
        nvimPath = ""
        nvimConfig = "user"
        captureHotkey = "ctrl+opt+n"
        captureTarget = "daily"
        captureHeading = ""
        scratchpadFolder = "Scratchpad"
        homeImage = ""
        newTab = .home
        hiddenNames = Self.defaultHiddenNames
        showHidden = false
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
        spotlight = file.bool("appearance.spotlight") ?? true
        hideMenuBar = file.bool("appearance.hide_menu_bar") ?? false
        wakatime = file.bool("wakatime.enabled") ?? false
        wakatimeCLI = file.string("wakatime.cli") ?? ""
        syncInterval = file.int("git.sync_interval") ?? 0
        pullOnLaunch = file.bool("git.pull_on_launch") ?? true
        meetingAlerts = file.bool("notifications.meetings") ?? true
        meetingLead = file.int("notifications.meeting_lead") ?? 5
        taskDigest = file.bool("notifications.digest") ?? true
        digestTime = file.string("notifications.digest_time").flatMap(Self.minutes) ?? 9 * 60
        shell = file.string("terminal.shell") ?? ""
        vimMode = file.bool("editor.vim_mode") ?? false
        livePreview = file.bool("editor.live_preview") ?? true
        propertiesForm = file.bool("editor.properties_form") ?? true
        typewriter = file.bool("editor.typewriter") ?? false
        focusMode = file.bool("editor.focus") ?? false
        spellCheck = file.bool("editor.spell_check") ?? true
        animateCursor = file.bool("editor.animate_cursor") ?? true
        cursorTrail = file.bool("editor.cursor_trail") ?? true
        cursorEffect = file.string("editor.cursor_effect").flatMap(CursorEffect.init(rawValue:)) ?? CursorEffect.none
        optionAsMeta = file.string("editor.option_as_meta").flatMap(VimKeys.OptionKey.init(rawValue:)) ?? VimKeys.OptionKey.none
        blurPanels = file.bool("editor.blur_panels") ?? true
        nvimPath = file.string("editor.nvim") ?? ""
        nvimConfig = file.string("editor.nvim_config") ?? "user"
        terminalFontSize = file.int("terminal.font_size") ?? 13
        captureHotkey = file.string("capture.hotkey") ?? "ctrl+opt+n"
        captureTarget = file.string("capture.target") ?? "daily"
        captureHeading = file.string("capture.heading") ?? ""
        scratchpadFolder = file.string("scratchpad.folder") ?? "Scratchpad"
        homeImage = file.string("home.image") ?? ""
        newTab = file.string("home.new_tab").flatMap(NewTab.init(rawValue:)) ?? .home
        hiddenNames = file.strings("files.hidden") ?? Self.defaultHiddenNames
        showHidden = file.bool("files.show_hidden") ?? false
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

    /// The menu bar hides while the app is in front, and shows when the pointer reaches it.
    func applyMenuBar() {
        guard let app = NSApp else { return }
        var options = app.presentationOptions
        // Full screen hides the menu bar in its own way.
        guard !options.contains(.fullScreen) else { return }
        if hideMenuBar { options.insert(.autoHideMenuBar) } else { options.remove(.autoHideMenuBar) }
        app.presentationOptions = options
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
