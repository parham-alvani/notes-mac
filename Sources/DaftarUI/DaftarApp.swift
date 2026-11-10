import AppKit
import DaftarCore
import SwiftUI

public struct DaftarApp: App {
    public init() {}

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ViewState private var store = VaultStore()
    @FocusedValue(\.window) private var focusedWindow
    /// The window the menu commands act on: the focused one, or else the one
    /// last in front. SwiftUI's focused value is empty while no Daftar window
    /// holds the focus -- after a sheet closes, or with a panel in front --
    /// and every command, ⌘P among them, would turn grey with nothing to do.
    private var window: WindowModel? { focusedWindow ?? ActiveWindow.shared.model }

    public var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 760, minHeight: 440)
                .onAppear {
                    delegate.store = store
                    QuickCaptureController.shared.store = store
                    VaultFollower.shared.follow(store)
                }
                // The settings file can change under the app: follow it.
                .onChange(of: store.settings.syncInterval) { store.scheduleAutoSync() }
                .onChange(of: store.settings.hiddenNames) { store.refreshHidden() }
                .onChange(of: store.settings.showHidden) { store.refreshHidden() }
                .onChange(of: store.settings.vaultPath) { _, path in
                    if let path, path != store.root?.path { store.open(URL(filePath: path)) }
                }
        }
        .windowToolbarStyle(.unified)
        .handlesExternalEvents(matching: ["*"])
        .commands {
            FileCommands(window: window, store: store)
            EditorModeCommands(window: window, store: store)
            CommandGroup(after: .pasteboard) {
                Button("Copy Block Link") { window?.copyBlockLink(store: store) }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                    .disabled(window?.showsText != true)
                Divider()
                Button("Find…") { window?.find(.showFindInterface) }
                    .keyboardShortcut("f")
                    .disabled(window?.showsText != true)
                Button("Search in Vault") { window?.searchRequests += 1 }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(window == nil || store.root == nil)
                Button("Find Next") { window?.find(.nextMatch) }
                    .keyboardShortcut("g")
                    .disabled(window?.showsText != true)
                Button("Find Previous") { window?.find(.previousMatch) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(window?.showsText != true)
                Button("Replace in Vault…") { window?.vaultReplace = ReplaceTarget(folder: "") }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                    .disabled(window == nil || store.root == nil)
            }
            CommandGroup(after: .newItem) {
                Button("Open Vault…") { chooseVault(store) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Quick Open…") { window?.openSwitcher() }
                    .keyboardShortcut("p")
                    .disabled(window == nil)
                Button("Command Palette…") { window?.palette = true }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(window == nil)
                Button("Quick Capture…") { QuickCaptureController.shared.show() }
            }
            // ⌘P is the file switcher, as in Obsidian; nothing here prints.
            CommandGroup(replacing: .printItem) {}
            CommandGroup(after: .sidebar) {
                Button("Show Inspector") { window?.inspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Button("Show Terminal") { window?.terminal.toggle() }
                    .keyboardShortcut("`", modifiers: .control)
                Button("Show Graph") { window?.graph = true }
                    .keyboardShortcut("g", modifiers: [.command, .option])
                    .disabled(window == nil)
                Button("Translate…") { window?.translate(store: store) }
                    .keyboardShortcut("t", modifiers: [.command, .control])
                    .disabled(window?.showsText != true)
                Button(ReadAloud.shared.isSpeaking ? "Stop Reading Aloud" : "Read Aloud") { window?.readAloud() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(!ReadAloud.shared.isSpeaking && window?.showsText != true)
                Button("Apple Intelligence…") { window?.assistant = true }
                    .keyboardShortcut("a", modifiers: [.command, .option])
                    .disabled(window?.showsText != true)
                Divider()
                Button(window?.editing == true ? "Read" : "Edit") { window?.editing.toggle() }
                    .keyboardShortcut("e")
                    .disabled(window?.showsText != true)
                Button(window?.isSplit == true ? "Close Split" : "Split Right") { window?.toggleSplit() }
                    .keyboardShortcut("\\")
                    .disabled(window == nil || window?.showsPage == true)
                Toggle("Show Hidden Files", isOn: Bindable(store.settings).showHidden)
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Divider()
                // On a picture the same keys zoom the picture, as in Preview.
                Button(window?.showsImage == true ? "Zoom In" : "Bigger Text") {
                    if let window, window.showsImage { window.zoomImage("in") } else { store.settings.textSize = min(store.settings.textSize + 1, 28) }
                }
                .keyboardShortcut("+")
                Button(window?.showsImage == true ? "Zoom Out" : "Smaller Text") {
                    if let window, window.showsImage { window.zoomImage("out") } else { store.settings.textSize = max(store.settings.textSize - 1, 10) }
                }
                .keyboardShortcut("-")
                Button("Actual Size") {
                    if let window, window.showsImage { window.zoomImage("actual") } else { store.settings.textSize = 14 }
                }
                .keyboardShortcut("0")
                Button("Zoom to Fit") { window?.zoomImage("fit") }
                    .keyboardShortcut("9")
                    .disabled(window?.showsImage != true)
            }
            CommandMenu("Go") {
                Button("Back") { window?.goBack() }
                    .keyboardShortcut("[")
                    .disabled(!(window?.canGoBack ?? false))
                Button("Forward") { window?.goForward() }
                    .keyboardShortcut("]")
                    .disabled(!(window?.canGoForward ?? false))
                Divider()
                Button("Home") { window?.goHome() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(window == nil || window?.showsHome == true)
                Button("Today") { window?.showsToday = true }
                    .keyboardShortcut("1")
                Button("Board") { window?.showsBoard = true }
                    .keyboardShortcut("2")
                Button(store.periodic.period.current) { window?.openPeriodicNote(store: store) }
                    .keyboardShortcut("3")
                    .disabled(window == nil || store.root == nil)
                Button("Previous \(store.periodic.period.noun)") {
                    if let window, let path = window.periodicNeighbour(-1, store: store) { window.open(path, store: store) }
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(window?.periodicNeighbour(-1, store: store) == nil)
                Button("Next \(store.periodic.period.noun)") {
                    if let window, let path = window.periodicNeighbour(1, store: store) { window.open(path, store: store) }
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(window?.periodicNeighbour(1, store: store) == nil)
                Divider()
                Button("Sync Now") { Task { await store.sync() } }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!store.isRepository)
                Button("Resolve Sync Conflicts…") { window?.conflicts = true }
                    .disabled(!store.rebasing || window == nil)
            }
        }

        // A tab: ⌘T, or a link opened with ⌘-click.
        WindowGroup("Tab", for: TabRequest.self) { $request in
            ContentView(initialPath: request?.path)
                .environment(store)
                .frame(minWidth: 760, minHeight: 440)
        }
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView().environment(store)
        }

        MenuBarExtra {
            MenuBarView().environment(store)
        } label: {
            // The menu bar's icon is there with no window open: quick capture
            // gets the store from it too.
            Group {
                if let icon = Resources.menuBarIcon {
                    Image(nsImage: icon)
                } else {
                    Image(systemName: "book.closed")
                }
            }
            .accessibilityLabel("Daftar")
            .onAppear {
                QuickCaptureController.shared.store = store
                VaultFollower.shared.follow(store)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// What follows the vault for the whole app: the Dock badge, the planned
/// alerts and Spotlight. It belongs to the app, not to a window: started
/// from the menu bar icon, which is there from launch, it runs once for each
/// change however many windows are open, and with none open too -- a pull
/// that brings a moved meeting plans its alert again while every window is
/// closed.
@MainActor
final class VaultFollower {
    static let shared = VaultFollower()

    private weak var store: VaultStore?
    private var pending: Task<Void, Never>?
    private var badgeShown: Bool?
    /// How long after a change the badge and the alerts follow: changes come in runs.
    var delay: Duration = .seconds(2)
    /// The three things that follow, which a test replaces.
    var badge: (String?) -> Void = { NSApp?.dockTile.badgeLabel = $0 }
    var plan: (VaultStore) async -> Void = { await Notifier.shared.plan(store: $0) }
    var spotlight: (VaultStore) -> Void = { Spotlight.shared.follow($0) }

    /// Follows [store] from now on; asked again for the same store, it does nothing.
    func follow(_ store: VaultStore) {
        guard self.store !== store else { return }
        self.store = store
        observe()
        changed()
    }

    /// Hears the next change of what the three depend on, then listens again.
    private func observe() {
        guard let store else { return }
        withObservationTracking {
            _ = (store.revision, store.loading, store.root, store.settings.dockBadge, store.settings.spotlight)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observe()
                self?.changed()
            }
        }
    }

    private func changed() {
        guard let store else { return }
        spotlight(store)
        // The badge's own switch shows at once; the vault's changes after a moment.
        if badgeShown != store.settings.dockBadge {
            badgeShown = store.settings.dockBadge
            updateBadge(store)
        }
        pending?.cancel()
        pending = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, store.root != nil, !store.loading else { return }
            updateBadge(store)
            await plan(store)
        }
    }

    private func updateBadge(_ store: VaultStore) {
        guard store.settings.dockBadge, store.root != nil else { return badge(nil) }
        let groups = store.taskGroups(days: 0)
        let count = groups.today.count + groups.overdue.count
        badge(count > 0 ? String(count) : nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The vault, whose editors are saved before the app quits.
    weak var store: VaultStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppSettings.shared.applyAppearance()
            AppSettings.shared.applyMenuBar()
            FullScreenEscape.install()
            Notifier.shared.start()
            QuickCaptureController.shared.start()
        }
    }

    /// The alerts and the menu bar stay when the last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// The editors save only a moment after the typing stops, and SwiftUI
    /// does not close their views on Quit: save them all first. Neovim gets
    /// a few seconds, so a stuck one cannot keep the app from quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            store?.places.write()
            guard let store, !store.flushers.isEmpty else { return .terminateNow }
            answered = false
            Task { @MainActor in
                await store.flushEditors()
                self.answer(sender)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                self.answer(sender)
            }
            return .terminateLater
        }
    }

    private var answered = false

    @MainActor private func answer(_ sender: NSApplication) {
        guard !answered else { return }
        answered = true
        sender.reply(toApplicationShouldTerminate: true)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            NotificationSettings().tabItem { Label("Notifications", systemImage: "bell.badge") }
            EditorSettings().tabItem { Label("Editor", systemImage: "character.cursor.ibeam") }
            GitSettings().tabItem { Label("Git", systemImage: "arrow.triangle.2.circlepath") }
            TerminalSettings().tabItem { Label("Terminal", systemImage: "apple.terminal") }
            CaptureSettings().tabItem { Label("Capture", systemImage: "square.and.pencil") }
            HomeSettings().tabItem { Label("Home", systemImage: "photo") }
        }
        .frame(width: 520)
        .tint(Palette.accent)
        .safeAreaInset(edge: .bottom) { SettingsProblem() }
    }

    /// The Neovim config beside Daftar's own settings file, as the file names it.
    static func daftarInit(_ settings: AppSettings) -> String {
        settings.url.deletingLastPathComponent().appending(path: "init.lua").path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

/// Why a change in this window was not kept in the settings file, when it was not.
private struct SettingsProblem: View {
    @Environment(VaultStore.self) private var store

    var body: some View {
        if let problem = store.settings.problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(Palette.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .accessibilityLabel("Settings not saved. \(problem)")
        }
    }
}

private struct GeneralSettings: View {
    @Environment(VaultStore.self) private var store

    /// Apple's faces first, then every family installed, so any font can be picked.
    static func textFonts(current: String) -> [String] {
        var names = ["New York", "SF Pro", "SF Pro Rounded"] + NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }
        if !names.contains(current) { names.insert(current, at: 0) }
        return names
    }

    static func codeFonts(current: String) -> [String] {
        let fixed = NSFontManager.shared.availableFontFamilies.filter { family in
            !family.hasPrefix(".") && (NSFont(name: family, size: 12)?.isFixedPitch ?? false
                || NSFontManager.shared.availableMembers(ofFontFamily: family)?.first.flatMap { $0.first as? String }
                    .flatMap { NSFont(name: $0, size: 12)?.isFixedPitch } ?? false)
        }
        var names = ["SF Mono"] + fixed
        if !names.contains(current) { names.insert(current, at: 0) }
        return names
    }

    var body: some View {
        @Bindable var settings = store.settings
        Form {
            LabeledContent("Vault") {
                HStack {
                    Text(store.root?.path ?? "None").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Change…") { chooseVault(store) }
                }
            }
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppSettings.Appearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Stepper("Text size: \(settings.textSize) pt", value: $settings.textSize, in: 10...28)
            Picker("Font", selection: $settings.font) {
                ForEach(Self.textFonts(current: settings.font), id: \.self) { Text($0).tag($0) }
            }
            Picker("Code font", selection: $settings.codeFont) {
                ForEach(Self.codeFonts(current: settings.codeFont), id: \.self) { Text($0).tag($0) }
            }
            Toggle("Load pictures from the web", isOn: $settings.remoteImages)
                .help("Off, a picture from another site is a placeholder until you click it, so opening a note tells no site.")
            Toggle("Persian calendar", isOn: $settings.persianCalendar)
                .help("The Solar Hijri date on the home page and Today, and the Jalali month in the day picker.")
            Picker("Holidays and feasts", selection: Binding { settings.place?.key ?? "" } set: { settings.calendarPlace = $0 }) {
                Text("None").tag("")
                ForEach(CalendarEvents.Place.allCases, id: \.self) { Text($0.name).tag($0.key) }
            }
            .help("Shown on Today, the home page and the day picker, each opening its note when the vault has one by that name.")
            Toggle("Count today's tasks on the Dock icon", isOn: $settings.dockBadge)
            Toggle("Show notes in Spotlight", isOn: $settings.spotlight)
                .help("The index is on this Mac only. Excluded files are left out.")
            Toggle("Hide the menu bar", isOn: $settings.hideMenuBar)
                .help("The menu bar comes back when the pointer reaches the top of the screen.")
            Section {
                HiddenNamesField(settings: settings)
                Toggle("Show hidden files", isOn: $settings.showHidden)
            } footer: {
                Text("Files with these names, in any folder, and Obsidian's excluded files are not in the file tree, quick open, search or the graph. A link to one still opens it.")
            }
            Section {
                Toggle("Send reading and writing time to WakaTime", isOn: $settings.wakatime)
            } footer: {
                Text(WakaTime.cli(settings.wakatimeCLI) == nil
                    ? "wakatime-cli is not installed: brew install wakatime-cli. The key is read from ~/.wakatime.cfg."
                    : "Uses wakatime-cli and the key in ~/.wakatime.cfg. The note's path and the vault's name leave this Mac.")
            }
            Section {
                LabeledContent("Settings file") {
                    HStack {
                        Text(settings.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .foregroundStyle(.secondary).font(.callout.monospaced())
                        Button("Show in Finder") { settings.revealFile() }
                    }
                }
            } footer: {
                Text("Every setting is in this file. Edit it in any editor; the app follows the change at once.")
            }
        }
        .formStyle(.grouped)
    }
}

/// `files.hidden` as names with commas between them, written when the field
/// is submitted or left, so a comma being typed is not taken away.
private struct HiddenNamesField: View {
    let settings: AppSettings
    @ViewState private var text = ""

    var body: some View {
        TextField("Hidden files", text: $text, prompt: Text("CLAUDE.md, AGENTS.md"))
            .onSubmit(save)
            .onAppear { text = settings.hiddenNames.joined(separator: ", ") }
            .onDisappear(perform: save)
            .onChange(of: settings.hiddenNames) { _, names in text = names.joined(separator: ", ") }
    }

    private func save() {
        settings.hiddenNames = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

private struct NotificationSettings: View {
    @Environment(VaultStore.self) private var store

    var body: some View {
        @Bindable var settings = store.settings
        Form {
            Section {
                Toggle("Announce meetings", isOn: $settings.meetingAlerts)
                Stepper("\(settings.meetingLead) minutes before", value: $settings.meetingLead, in: 0...60)
                    .disabled(!settings.meetingAlerts)
            } footer: {
                Text("Meetings come from the week notes in Calendar/, which Daftar on the phone writes.")
            }
            Section {
                Toggle("Morning digest of the tasks due", isOn: $settings.taskDigest)
                DatePicker("At", selection: digestTime, displayedComponents: .hourAndMinute)
                    .disabled(!settings.taskDigest)
            }
            Section {
                Button("Open Notification Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.meetingAlerts) { replan() }
        .onChange(of: settings.meetingLead) { replan() }
        .onChange(of: settings.taskDigest) { replan() }
        .onChange(of: settings.digestTime) { replan() }
    }

    private func replan() {
        Task { await Notifier.shared.plan(store: store) }
    }

    private var digestTime: Binding<Date> {
        Binding {
            Calendar.current.date(
                bySettingHour: store.settings.digestTime / 60, minute: store.settings.digestTime % 60, second: 0, of: Date()) ?? Date()
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            store.settings.digestTime = (parts.hour ?? 9) * 60 + (parts.minute ?? 0)
        }
    }
}

private struct GitSettings: View {
    @Environment(VaultStore.self) private var store

    var body: some View {
        @Bindable var settings = store.settings
        Form {
            Section {
                Picker("Sync automatically", selection: $settings.syncInterval) {
                    Text("Off").tag(0)
                    Text("Every minute").tag(1)
                    Text("Every 5 minutes").tag(5)
                    Text("Every 15 minutes").tag(15)
                }
                Toggle("Pull when the app starts", isOn: $settings.pullOnLaunch)
            } footer: {
                Text("A sync commits, pulls with a rebase and pushes, with the system git and your SSH keys. Keep it off while Obsidian's git plugin syncs the same folder: two syncs at once can conflict.")
            }
            if let error = store.syncError {
                Section("Last error") {
                    Text(error).font(.callout.monospaced()).textSelection(.enabled)
                }
            } else if let last = store.lastSync {
                LabeledContent("Last sync", value: last.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .formStyle(.grouped)
    }
}

private struct EditorSettings: View {
    @Environment(VaultStore.self) private var store

    var body: some View {
        @Bindable var settings = store.settings
        let found = NeovimClient.locate(settings.nvimPath)
        Form {
            Section {
                Toggle("Hide the marks away from the cursor (live preview)", isOn: $settings.livePreview)
                Toggle("Show the front matter as properties", isOn: $settings.propertiesForm)
                Toggle("Keep the cursor's line in the middle (typewriter)", isOn: $settings.typewriter)
                Toggle("Dim all but the cursor's paragraph (focus)", isOn: $settings.focusMode)
                Toggle("Check spelling as you type", isOn: $settings.spellCheck)
                Toggle("Edit with Neovim", isOn: $settings.vimMode)
                LabeledContent("nvim") {
                    Text(found?.path ?? "Not found").foregroundStyle(found == nil ? Palette.red : .secondary)
                }
                TextField("Path", text: $settings.nvimPath, prompt: Text("Found on its own"))
                Picker("Configuration", selection: $settings.nvimConfig) {
                    Text("Mine (init.lua)").tag("user")
                    Text("Daftar's (\(SettingsView.daftarInit(settings)))").tag(SettingsView.daftarInit(settings))
                    Text("None (--clean)").tag("clean")
                    if !["user", "clean", SettingsView.daftarInit(settings)].contains(settings.nvimConfig) {
                        Text(settings.nvimConfig).tag(settings.nvimConfig)
                    }
                }
            } footer: {
                Text("Your Neovim owns the buffer and writes the file; the editor shows it, with its colours, images and right-to-left text. Your config sees g:daftar = 1. ⌘ shortcuts stay with the app.")
            }
            Section {
                Toggle("Slide the cursor", isOn: $settings.animateCursor)
                Toggle("Leave a trail behind it", isOn: $settings.cursorTrail)
                    .disabled(!settings.animateCursor)
                Picker("Cursor effect", selection: $settings.cursorEffect) {
                    ForEach(AppSettings.CursorEffect.allCases) { Text($0.title).tag($0) }
                }
                Picker("Option key as Meta", selection: $settings.optionAsMeta) {
                    Text("Neither").tag(VimKeys.OptionKey.none)
                    Text("Left").tag(VimKeys.OptionKey.left)
                    Text("Right").tag(VimKeys.OptionKey.right)
                    Text("Both").tag(VimKeys.OptionKey.both)
                }
                Toggle("Blur the note behind the menu and the command line", isOn: $settings.blurPanels)
            } header: {
                Text("Neovim")
            } footer: {
                Text("As in Neovide. An Option key that is Meta sends <M-x> to Neovim and no longer types å or €. Reduce Motion stops the slide and the effects.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct TerminalSettings: View {
    @Environment(VaultStore.self) private var store

    var body: some View {
        @Bindable var settings = store.settings
        Form {
            Section {
                TextField("Shell", text: $settings.shell, prompt: Text(ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"))
                Stepper("Font size: \(settings.terminalFontSize) pt", value: $settings.terminalFontSize, in: 9...24)
            } footer: {
                Text("The terminal opens in the vault's folder with ⌃`. A change here applies to the next terminal.")
            }
        }
        .formStyle(.grouped)
    }
}

/// The menu bar: what is on today, without opening a window.
struct MenuBarView: View {
    @Environment(VaultStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let today = Day.today()
        let meetings = store.calendarDays(from: today, count: 1).first?.meetings ?? []
        let upcoming = meetings.filter { ($0.end ?? .distantFuture) > Date() }
        let groups = store.taskGroups(today: today, days: 0)
        VStack(alignment: .leading, spacing: 10) {
            Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.headline)
                .accessibilityAddTraits(.isHeader)
            if upcoming.isEmpty {
                Text("No more meetings today.").foregroundStyle(.secondary)
            }
            ForEach(upcoming) { MeetingRow(meeting: $0) }
            Divider()
            Text("\(groups.today.count) due today · \(groups.overdue.count) overdue")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(groups.today.prefix(8)) { task in
                TaskRow(task: task) { show(task.path) }
            }
            Divider()
            Button("Quick Capture…") { QuickCaptureController.shared.show() }
                .buttonStyle(.borderless)
            HStack {
                Button("Open Daftar") { show("today") }
                Spacer()
                SettingsLink { Text("Settings…") }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 360)
        .tint(Palette.accent)
    }

    private func show(_ path: String) {
        NSApp.activate()
        if NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) == false { openWindow(id: "main") }
        let value = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        if let url = URL(string: "daftar://open?path=" + value) { NSWorkspace.shared.open(url) }
    }
}

/// File › New Note (⌘N) and the commands on the open note. ⌘N makes a
/// note, as in Obsidian, so New Window moves to ⌥⌘N.
struct FileCommands: Commands {
    var window: WindowModel?
    var store: VaultStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { window?.fileAction = .newNote(folder: window?.currentFolder ?? "") }
                .keyboardShortcut("n")
                .disabled(window == nil)
            Button("New Folder…") { window?.fileAction = .newFolder(parent: window?.currentFolder ?? "") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(window == nil)
            Button("Today's Scratchpad") { window?.openScratchpad(store: store) }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(window == nil || store.root == nil)
            Button("New Tab") {
                let note = store.settings.newTab == .note && window?.showsPage != true ? window?.path : nil
                openWindow(value: TabRequest(path: note))
            }
                .keyboardShortcut("t")
            Button("New Window") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            Button("Rename…") { if let path = window?.path { window?.fileAction = .rename(path) } }
                .keyboardShortcut("r")
                .disabled(window?.path == nil || window?.showsPage == true)
            Button("Move to…") { if let path = window?.path { window?.fileAction = .move(path) } }
                .keyboardShortcut("m", modifiers: [.command, .option])
                .disabled(window?.path == nil || window?.showsPage == true)
            Button("Extract Selection to New Note…") {
                NSApp.sendAction(#selector(NoteTextView.extractSelection(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("x", modifiers: [.command, .option])
            .disabled(window?.editing != true || window?.showsPage == true)
            Button("Move to Trash…") { if let path = window?.path { window?.fileAction = .delete(path) } }
                .disabled(window?.path == nil || window?.showsPage == true)
            Button("Show History…") { window?.history = true }
                .keyboardShortcut("y", modifiers: [.command, .option])
                .disabled(window?.showsText != true || !store.isRepository)
            Button("Sort Tasks") { window?.sortTasks(store: store) }
                .disabled(window?.showsText != true)
            Button("Rename Heading…") { window?.renameHeading(store: store) }
                .disabled(window?.showsText != true)
            Button("Move Section Up") { window?.moveSection(up: true, store: store) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(window?.showsText != true)
            Button("Move Section Down") { window?.moveSection(up: false, store: store) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(window?.showsText != true)
            Button("Sort Headings Under This") { window?.sortHeadings(store: store) }
                .disabled(window?.showsText != true)
            Divider()
            Button("Export as PDF…") { window?.exportPDF(store: store) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(window?.showsText != true)
            Divider()
            Button(window?.path.map { store.bookmarks.contains($0) } == true ? "Remove Bookmark" : "Bookmark") {
                if let path = window?.path { store.toggleBookmark(path) }
            }
            .keyboardShortcut("d")
            .disabled(window?.path == nil || window?.showsPage == true)
        }
    }
}
