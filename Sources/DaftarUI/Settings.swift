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
    /// The file itself, for an edit saved in place, which the folder never sees.
    @ObservationIgnored private var fileWatcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var loading = false
    /// The file is there and could not be read (its bytes are not UTF-8, or
    /// no permission). The app then runs on the defaults and never writes:
    /// what it holds is the template, not the person's file.
    @ObservationIgnored private var unreadable = false
    /// Why the last change was not kept in the file, for the person to read; nil when it was.
    private(set) var problem: String?

    @ObservationIgnored private var vaultText = ""
    @ObservationIgnored private var vaultRoot: URL?
    /// The keys the open vault's `.daftar.toml` sets on this computer.
    private(set) var fromVault: Set<String> = []
    /// The keys of the vault's file that a vault may not set (a program, a
    /// path outside it, what leaves the computer): ignored, and named.
    private(set) var refusedByVault: [String] = []
    /// The vault's own author (`git.name`, `git.email`), for a clone that names none.
    private(set) var vaultAuthor = Git.Author()
    /// The keys this computer declines from any vault (`vault_settings` as a list).
    private(set) var declinedKeys: [String] = []
    /// This computer takes the app's settings a vault carries
    /// (`vault_settings`); off, no setting is read from any vault.
    var followsVault: Bool {
        didSet {
            guard !loading, followsVault != oldValue else { return }
            write("vault_settings", .bool(followsVault))
            load()
        }
    }

    var vaultPath: String? { didSet { writeVault() } }
    var appearance: Appearance { didSet { write("appearance.theme", .string(appearance.rawValue)); applyAppearance() } }
    var textSize: Int { didSet { write("appearance.text_size", .int(textSize)) } }
    var font: String { didSet { write("appearance.font", .string(font)) } }
    var codeFont: String { didSet { write("appearance.code_font", .string(codeFont)) } }
    /// The widest line of text, in em of the text size, in the reader and the editor; 0 is the whole window.
    var textWidth: Int { didSet { write("appearance.text_width", .int(textWidth)) } }
    /// The reading cursor's band on the line being read, in percent of the accent; 0 is none.
    var readingLine: Int { didSet { write("appearance.reading_line", .int(readingLine)) } }
    /// Pictures from the web in a note are shown; off, the reader asks no site for one until it is clicked.
    var remoteImages: Bool { didSet { write("appearance.remote_images", .bool(remoteImages)) } }
    /// Whether a note opens with its sections folded: as the vault says
    /// (`reader.folded` in its `.daftar.toml`), always, or never.
    var foldSections: FoldSections { didSet { write("appearance.fold_sections", .string(foldSections.rawValue)) } }
    /// The Jalali date beside the Gregorian one, and the Jalali month in the day picker.
    var persianCalendar: Bool { didSet { write("appearance.persian_calendar", .bool(persianCalendar)) } }
    /// `calendar.place` as the file has it: whose holidays and feasts are shown.
    var calendarPlace: String { didSet { write("calendar.place", .string(calendarPlace)) } }
    /// The place `calendarPlace` names; nil is none.
    var place: CalendarEvents.Place? { CalendarEvents.Place(calendarPlace) }
    var dockBadge: Bool { didSet { write("appearance.dock_badge", .bool(dockBadge)) } }
    var spotlight: Bool { didSet { write("appearance.spotlight", .bool(spotlight)) } }
    var hideMenuBar: Bool { didSet { write("appearance.hide_menu_bar", .bool(hideMenuBar)); applyMenuBar() } }
    var wakatime: Bool { didSet { write("wakatime.enabled", .bool(wakatime)) } }
    var wakatimeCLI: String { didSet { write("wakatime.cli", .string(wakatimeCLI)) } }
    /// Export as PDF's last choices: `daftar-cli export --contents` and `--landscape`.
    var exportContents: Bool { didSet { write("export.contents", .bool(exportContents)) } }
    var exportLandscape: Bool { didSet { write("export.landscape", .bool(exportLandscape)) } }
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
    /// A note typed in is formatted with `daftar-cli fmt` when the editor leaves it.
    var formatOnSave: Bool { didSet { write("editor.format_on_save", .bool(formatOnSave)) } }
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
    /// The one inbox note ⌥⌘S opens, a vault path; empty is `Scratchpad.md`.
    var scratchpadNote: String { didSet { write("scratchpad.note", .string(scratchpadNote)) } }
    /// Search by meaning in the sidebar and related notes in the inspector, by `daftar-cli`'s model.
    var meaningSearch: Bool { didSet { write("meaning.search", .bool(meaningSearch)) } }
    /// Minutes the vault is still after a change before the index of meaning reads it again; 0 never.
    var meaningRefresh: Int { didSet { write("meaning.refresh_minutes", .int(meaningRefresh)) } }
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

    enum FoldSections: String, CaseIterable, Identifiable {
        case vault, always, never
        var id: String { rawValue }
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
        followsVault = true
        vaultPath = nil
        appearance = .system
        textSize = 14
        font = "SF Pro"
        codeFont = "SF Mono"
        readingLine = 18
        textWidth = 46
        remoteImages = true
        foldSections = .vault
        persianCalendar = false
        calendarPlace = ""
        dockBadge = true
        spotlight = true
        hideMenuBar = false
        wakatime = false
        wakatimeCLI = ""
        exportContents = false
        exportLandscape = false
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
        formatOnSave = true
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
        scratchpadNote = "Scratchpad.md"
        meaningSearch = true
        meaningRefresh = 10
        homeImage = ""
        newTab = .home
        hiddenNames = Self.defaultHiddenNames
        showHidden = false
        load()
        watch()
    }

    /// Reads the file, making it from the template the first time.
    /// The open vault's `.daftar.toml` and its folder: the app's settings
    /// the vault carries are read with the computer's (`ResolvedSettings`).
    /// The store gives them when a vault opens, when the file changes and
    /// at each sync.
    func follow(vault text: String, root: URL?) {
        guard text != vaultText || root != vaultRoot else { return }
        vaultText = text
        vaultRoot = root
        load()
    }

    /// Whether the open vault sets [key], so its control shows "From the vault" and is off.
    func isFromVault(_ key: String) -> Bool { fromVault.contains(key) }

    private func load() {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(ConfigFile.template.utf8).write(to: url, options: .atomic)
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            unreadable = manager.fileExists(atPath: url.path)
            if unreadable { problem = "The settings file could not be read, so Daftar uses its defaults and does not change the file: \(Self.shown(url))." }
            return
        }
        if unreadable { problem = nil }
        unreadable = false
        file = ConfigFile(text: text)
        // The open vault's own settings win over this file's, for the keys
        // a vault may set and this computer has not declined.
        let resolved = ResolvedSettings.resolved(vault: vaultText, computer: text, root: vaultRoot)
        loading = true
        defer { loading = false }
        if resolved.fromVault != fromVault { fromVault = resolved.fromVault }
        if resolved.refused != refusedByVault { refusedByVault = resolved.refused }
        if resolved.author != vaultAuthor { vaultAuthor = resolved.author }
        followsVault = file["vault_settings"] != .bool(false)
        declinedKeys = file.strings("vault_settings") ?? []
        let vault = file.string("vault") ?? ""
        vaultPath = vault.isEmpty ? nil : (vault as NSString).expandingTildeInPath
        appearance = resolved.string("appearance.theme").flatMap(Appearance.init(rawValue:)) ?? .system
        textSize = resolved.int("appearance.text_size") ?? 14
        font = resolved.string("appearance.font") ?? "SF Pro"
        codeFont = resolved.string("appearance.code_font") ?? "SF Mono"
        readingLine = max(0, min(100, resolved.int("appearance.reading_line") ?? 18))
        textWidth = max(0, resolved.int("appearance.text_width") ?? 46)
        // Anything but `false` shows them, as before the setting was there.
        remoteImages = resolved.bool("appearance.remote_images") ?? true
        foldSections = resolved.string("appearance.fold_sections").flatMap(FoldSections.init(rawValue:)) ?? .vault
        persianCalendar = resolved.bool("appearance.persian_calendar") ?? false
        calendarPlace = resolved.string("calendar.place") ?? ""
        dockBadge = resolved.bool("appearance.dock_badge") ?? true
        spotlight = resolved.bool("appearance.spotlight") ?? true
        hideMenuBar = resolved.bool("appearance.hide_menu_bar") ?? false
        wakatime = resolved.bool("wakatime.enabled") ?? false
        wakatimeCLI = resolved.string("wakatime.cli") ?? ""
        exportContents = resolved.bool("export.contents") ?? false
        exportLandscape = resolved.bool("export.landscape") ?? false
        syncInterval = resolved.int("git.sync_interval") ?? 0
        pullOnLaunch = resolved.bool("git.pull_on_launch") ?? true
        meetingAlerts = resolved.bool("notifications.meetings") ?? true
        meetingLead = resolved.int("notifications.meeting_lead") ?? 5
        taskDigest = resolved.bool("notifications.digest") ?? true
        digestTime = resolved.string("notifications.digest_time").flatMap(Self.minutes) ?? 9 * 60
        shell = resolved.string("terminal.shell") ?? ""
        vimMode = resolved.bool("editor.vim_mode") ?? false
        livePreview = resolved.bool("editor.live_preview") ?? true
        propertiesForm = resolved.bool("editor.properties_form") ?? true
        typewriter = resolved.bool("editor.typewriter") ?? false
        focusMode = resolved.bool("editor.focus") ?? false
        spellCheck = resolved.bool("editor.spell_check") ?? true
        formatOnSave = resolved.bool("editor.format_on_save") ?? true
        animateCursor = resolved.bool("editor.animate_cursor") ?? true
        cursorTrail = resolved.bool("editor.cursor_trail") ?? true
        cursorEffect = resolved.string("editor.cursor_effect").flatMap(CursorEffect.init(rawValue:)) ?? CursorEffect.none
        optionAsMeta = resolved.string("editor.option_as_meta").flatMap(VimKeys.OptionKey.init(rawValue:)) ?? VimKeys.OptionKey.none
        blurPanels = resolved.bool("editor.blur_panels") ?? true
        nvimPath = resolved.string("editor.nvim") ?? ""
        nvimConfig = resolved.string("editor.nvim_config") ?? "user"
        terminalFontSize = resolved.int("terminal.font_size") ?? 13
        captureHotkey = resolved.string("capture.hotkey") ?? "ctrl+opt+n"
        captureTarget = resolved.string("capture.target") ?? "daily"
        captureHeading = resolved.string("capture.heading") ?? ""
        scratchpadNote = resolved.string("scratchpad.note") ?? "Scratchpad.md"
        meaningSearch = resolved.bool("meaning.search") ?? true
        meaningRefresh = max(0, resolved.int("meaning.refresh_minutes") ?? 10)
        homeImage = resolved.string("home.image") ?? ""
        newTab = resolved.string("home.new_tab").flatMap(NewTab.init(rawValue:)) ?? .home
        hiddenNames = resolved.strings("files.hidden") ?? Self.defaultHiddenNames
        showHidden = resolved.bool("files.show_hidden") ?? false
    }

    private func write(_ path: String, _ value: ConfigFile.Value) {
        guard !loading, file[path] != value else { return }
        guard !unreadable else {
            // The file was never read: writing would put the template where the person's settings are.
            problem = "The settings file could not be read, so this change is not kept: \(Self.shown(url))."
            return
        }
        // An edit saved in place (`>>`, some editors) reaches no folder watch:
        // the change goes onto the file as it is now, never over that edit.
        let disk = try? String(contentsOf: url, encoding: .utf8)
        let edited = disk.map { $0 != file.text } ?? false
        var changed = edited ? ConfigFile(text: disk ?? "") : file
        changed.set(path, value)
        do {
            try Data(changed.text.utf8).write(to: url, options: .atomic)
            file = changed
            problem = nil
            // The rest of that edit takes effect too.
            if edited { DispatchQueue.main.async { [weak self] in self?.load() } }
        } catch {
            // Not kept in `file` either: what the app holds stays what the file says.
            problem = "The setting was not saved to \(Self.shown(url)): \(error.localizedDescription)"
        }
    }

    /// The vault's folder, written as the person writes paths: under the
    /// home folder with `~`, so the file is the same on every Mac. A path
    /// the file already names, by either spelling, is not written again.
    private func writeVault() {
        let now = vaultPath ?? ""
        let written = file.string("vault") ?? ""
        if (written as NSString).expandingTildeInPath == now { return }
        write("vault", .string((now as NSString).abbreviatingWithTildeInPath))
    }

    private static func shown(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }

    /// The file is written atomically -- by this app and by most editors -- so
    /// the watch is on the folder, and any change there reads the file again.
    /// An edit saved in place (`>>`, nano, some editors) changes no folder:
    /// the file is watched too, and watched again once it is replaced.
    private func watch() {
        watchFile()
        let folder = open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard folder >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: folder, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A file that could not be read is tried again at each change of the folder.
                self.watchFile()
                self.reloadIfChanged()
            }
        }
        source.setCancelHandler { close(folder) }
        source.resume()
        watcher = source
    }

    private func reloadIfChanged() {
        let text = try? String(contentsOf: url, encoding: .utf8)
        guard unreadable || (text != nil && text != file.text) else { return }
        load()
    }

    /// A watch on the file as it is now; a replaced file gets a new one.
    private func watchFile() {
        fileWatcher?.cancel()
        fileWatcher = nil
        let handle = open(url.path, O_EVTONLY)
        guard handle >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: handle, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !source.data.isDisjoint(with: [.delete, .rename]) { self.watchFile() }
                self.reloadIfChanged()
            }
        }
        source.setCancelHandler { close(handle) }
        source.resume()
        fileWatcher = source
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
