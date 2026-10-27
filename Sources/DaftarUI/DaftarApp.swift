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
                }
                .task(id: store.revision) {
                    // After the vault changes, the alerts and the badge follow.
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, store.root != nil, !store.loading else { return }
                    updateBadge()
                    await Notifier.shared.plan(store: store)
                }
                .onChange(of: store.settings.dockBadge) { updateBadge() }
                .onChange(of: store.revision, initial: true) { Spotlight.shared.follow(store) }
                .onChange(of: store.settings.spotlight) { Spotlight.shared.follow(store) }
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
                    .disabled(window?.path == nil || window?.showsPage == true)
                Divider()
                Button("Find…") { window?.find(.showFindInterface) }
                    .keyboardShortcut("f")
                    .disabled(window?.path == nil || window?.showsPage == true)
                Button("Search in Vault") { window?.searchRequests += 1 }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(window == nil || store.root == nil)
                Button("Find Next") { window?.find(.nextMatch) }
                    .keyboardShortcut("g")
                    .disabled(window?.path == nil || window?.showsPage == true)
                Button("Find Previous") { window?.find(.previousMatch) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(window?.path == nil || window?.showsPage == true)
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
                    .disabled(window?.path == nil || window?.showsPage == true)
                Button(ReadAloud.shared.isSpeaking ? "Stop Reading Aloud" : "Read Aloud") { window?.readAloud() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(!ReadAloud.shared.isSpeaking && (window?.path == nil || window?.showsPage == true))
                Button("Apple Intelligence…") { window?.assistant = true }
                    .keyboardShortcut("a", modifiers: [.command, .option])
                    .disabled(window?.path == nil || window?.showsPage == true)
                Divider()
                Button(window?.editing == true ? "Read" : "Edit") { window?.editing.toggle() }
                    .keyboardShortcut("e")
                    .disabled(window?.path == nil || window?.showsPage == true)
                Button(window?.isSplit == true ? "Close Split" : "Split Right") { window?.toggleSplit() }
                    .keyboardShortcut("\\")
                    .disabled(window == nil || window?.showsPage == true)
                Toggle("Show Hidden Files", isOn: Bindable(store.settings).showHidden)
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Divider()
                Button("Bigger Text") { store.settings.textSize = min(store.settings.textSize + 1, 28) }
                    .keyboardShortcut("+")
                Button("Smaller Text") { store.settings.textSize = max(store.settings.textSize - 1, 10) }
                    .keyboardShortcut("-")
                Button("Actual Size") { store.settings.textSize = 14 }
                    .keyboardShortcut("0")
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
            .onAppear { QuickCaptureController.shared.store = store }
        }
        .menuBarExtraStyle(.window)
    }

    private func updateBadge() {
        guard store.settings.dockBadge else {
            NSApp.dockTile.badgeLabel = nil
            return
        }
        let groups = store.taskGroups(days: 0)
        let count = groups.today.count + groups.overdue.count
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
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
    }

    /// The Neovim config beside Daftar's own settings file, as the file names it.
    static func daftarInit(_ settings: AppSettings) -> String {
        settings.url.deletingLastPathComponent().appending(path: "init.lua").path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
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
            Button("New Tab") { openWindow(value: TabRequest(path: window?.showsPage == true ? nil : window?.path)) }
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
                .disabled(window?.path == nil || window?.showsPage == true || !store.isRepository)
            Button("Sort Tasks") { window?.sortTasks(store: store) }
                .disabled(window?.path == nil || window?.showsPage == true)
            Button("Rename Heading…") { window?.renameHeading(store: store) }
                .disabled(window?.path == nil || window?.showsPage == true)
            Button("Move Section Up") { window?.moveSection(up: true, store: store) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(window?.path == nil || window?.showsPage == true)
            Button("Move Section Down") { window?.moveSection(up: false, store: store) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(window?.path == nil || window?.showsPage == true)
            Divider()
            Button("Export as PDF…") { window?.exportPDF() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(window?.path == nil || window?.showsPage == true || window?.editing == true)
            Divider()
            Button(window?.path.map { store.bookmarks.contains($0) } == true ? "Remove Bookmark" : "Bookmark") {
                if let path = window?.path { store.toggleBookmark(path) }
            }
            .keyboardShortcut("d")
            .disabled(window?.path == nil || window?.showsPage == true)
        }
    }
}
