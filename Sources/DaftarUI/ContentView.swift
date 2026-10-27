import CoreSpotlight
import AppKit
import DaftarCore
import SwiftUI
import Translation

/// One window: the sidebar, the note, and the inspector beside it.
struct ContentView: View {
    /// The note a new tab opens on.
    var initialPath: String?
    @Environment(VaultStore.self) private var store
    @ViewState private var model = WindowModel()

    var body: some View {
        @Bindable var model = model
        Group {
            if store.root == nil {
                WelcomeView()
            } else {
                NavigationSplitView {
                    SidebarView(model: model)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
                } detail: {
                    if model.terminal {
                        VSplitView {
                            detail.frame(minHeight: 160)
                            TerminalPane(session: model.terminalSession, folder: store.root)
                                .frame(minHeight: 120, idealHeight: 260)
                        }
                    } else {
                        detail
                    }
                }
                .inspector(isPresented: Binding { model.inspector && !model.showsPage } set: { model.inspector = $0 }) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 200, ideal: 260, max: 400)
                }
            }
        }
        .tint(Palette.accent)
        .navigationTitle(title)
        .navigationSubtitle(model.showsPage ? store.name : model.path.map { folder(of: $0) } ?? "")
        .toolbar { toolbar }
        .sheet(isPresented: $model.quickOpen) {
            QuickOpenView(model: model)
        }
        .sheet(isPresented: $model.palette) {
            CommandPaletteView(model: model)
        }
        .sheet(isPresented: $model.graph) {
            GraphView(model: model)
        }
        .sheet(isPresented: $model.assistant) {
            AssistantSheet(model: model)
        }
        .sheet(item: $model.iconTarget) { IconPicker(target: $0) }
        .sheet(isPresented: $model.history) {
            HistorySheet(model: model)
        }
        .sheet(item: $model.tagRename) { TagRenameSheet(target: $0) }
        .sheet(isPresented: $model.conflicts) {
            ConflictSheet(model: model)
        }
        // A sync that stopped on a conflict opens the conflicts in the window in front.
        .onChange(of: store.conflictStops) { _, _ in
            if store.rebasing, ActiveWindow.shared.model == nil || ActiveWindow.shared.model === model { model.conflicts = true }
        }
        .sheet(item: $model.vaultReplace) { VaultReplaceSheet(target: $0) }
        .sheet(item: $model.headingRename) { HeadingRenameSheet(target: $0) }
        .translationPresentation(isPresented: Binding { model.translation != nil } set: { if !$0 { model.translation = nil } }, text: model.translation ?? "")
        .sheet(item: $model.taskEdit) { task in
            TaskEditSheet(task: task)
        }
        .sheet(item: $model.fileAction) { action in
            FileActionSheet(action: action, model: model)
        }
        .overlay(alignment: .bottom) { noticeBanner }
        // ⌘O opens the switcher too, as in the vault's Obsidian hotkeys.
        .background {
            Button("Quick Open") { model.openSwitcher() }
                .keyboardShortcut("o")
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .focusedSceneValue(\.window, model)
        .background(TabbedWindow(model: model))
        .onAppear {
            // Every window follows a move or a delete, wherever it was made.
            store.followers[ObjectIdentifier(model)] = { [weak model] in model?.follow($0) }
            model.places = store.places
            if let initialPath, model.request == nil, store.index.files.contains(initialPath) || store.loading {
                model.open(initialPath, store: store)
            }
        }
        .onDisappear { store.followers[ObjectIdentifier(model)] = nil }
        // Neovim mode: one pane edits at a time.
        .onChange(of: store.settings.vimMode, initial: true) { _, vim in
            model.oneEditor = vim
            if vim { model.setEditing(model.editing, in: model.focused) }
        }
        .onChange(of: model.path) { _, path in
            if let path { WakaTime.shared.heartbeat(path, store: store) }
            // The voice reads the note it started on, and stops when this window leaves it.
            if ReadAloud.shared.path != nil, ReadAloud.shared.path != path, model.readerView === ReadAloud.shared.view { ReadAloud.shared.stop() }
        }
        .onOpenURL { url in model.handle(url, store: store) }
        // A note chosen in Spotlight.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let path = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String, store.index.files.contains(path) {
                model.open(path, store: store)
            }
        }
        // A `daftar://` link goes to the window that is open, not to a new one.
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
    }

    private var title: String {
        if model.showsToday { return "Today" }
        if model.showsBoard { return "Board" }
        return model.path.map(Vault.title(of:)) ?? store.name
    }

    @ViewBuilder private var detail: some View {
        if store.loading {
            ProgressView("Reading \(store.name)…")
        } else if model.showsToday {
            TodayView(model: model)
        } else if model.showsBoard {
            BoardView(model: model)
        } else {
            NotePanes(model: model)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        @Bindable var model = model
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!model.canGoBack)
            Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(!model.canGoForward)
            Button { model.goHome() } label: { Label("Home", systemImage: "house") }
                .disabled(model.showsHome)
                .help("Show the home page (⇧⌘D)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let path = model.path, !model.showsPage {
                // A picture has no editor.
                if !model.showsImage {
                    Picker("Mode", selection: $model.editing) {
                        Label("Read", systemImage: "book").tag(false)
                        Label("Edit", systemImage: "square.and.pencil").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .help("Read or edit the note (⌘E)")
                }
                if let url = store.url(of: path) {
                    ShareLink(item: url)
                }
            }
            if store.rebasing {
                Button { model.conflicts = true } label: {
                    Label("Conflicts", systemImage: "exclamationmark.triangle.fill")
                }
                .badge(store.conflicts.count)
                .foregroundStyle(Palette.accent)
                .help("The pull stopped on a conflict. Choose what to keep; sync waits until then.")
            }
            if store.isRepository {
                SyncButton()
            }
        }
        // The panes are their own group of glass, apart from the note's tools.
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $model.terminal) { Label("Terminal", systemImage: "apple.terminal") }
                .help("Show or hide a terminal in the vault's folder (⌃`)")
            Button { model.inspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                .help("Show or hide the outline and backlinks")
        }
    }

    @ViewBuilder private var noticeBanner: some View {
        if let notice = store.notice {
            Text(notice)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassEffect(.regular.interactive(), in: .capsule)
                .padding(.bottom, 16)
                .task {
                    try? await Task.sleep(for: .seconds(5))
                    store.notice = nil
                }
                .onTapGesture { store.notice = nil }
                // Said when it shows: VoiceOver does not see a banner come.
                .onAppear { announce(notice) }
                .onChange(of: notice) { _, text in announce(text) }
                .accessibilityAddTraits(.isStaticText)
                .accessibilityAction(named: "Dismiss") { store.notice = nil }
        }
    }

    private func folder(of path: String) -> String {
        let parts = path.split(separator: "/").dropLast()
        return parts.joined(separator: " › ")
    }

}

/// What a new tab opens: a note, or nothing. Each request is new, so the
/// same note can be open in two tabs.
struct TabRequest: Codable, Hashable {
    var path: String?
    var id = UUID()
}

/// The Daftar window last in front, for the menu commands when no window
/// holds SwiftUI's focus.
@MainActor @Observable
final class ActiveWindow {
    static let shared = ActiveWindow()
    weak var model: WindowModel?
}

/// Makes the window a tab of the others: every Daftar window is one tab
/// group, as Obsidian keeps its notes in tabs of one window. It also
/// tells `ActiveWindow` when its window comes to the front.
struct TabbedWindow: NSViewRepresentable {
    var model: WindowModel?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.model = model
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.tabbingMode = .preferred
            window.tabbingIdentifier = "daftar.main"
            coordinator.watch(window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { context.coordinator.model = model }

    @MainActor
    final class Coordinator {
        weak var model: WindowModel?
        nonisolated(unsafe) private var token: NSObjectProtocol?

        func watch(_ window: NSWindow) {
            // The first window counts as in front until another one is.
            if window.isKeyWindow || ActiveWindow.shared.model == nil { ActiveWindow.shared.model = model }
            token = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { ActiveWindow.shared.model = self?.model }
            }
        }

        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}

/// Git in the toolbar: the branch and how it stands, and a menu to sync.
struct SyncButton: View {
    @Environment(VaultStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Menu {
            if let status = store.gitStatus {
                Text("On \(status.branch)")
                Text(describe(status))
            }
            if let last = store.lastSync {
                Text("Last sync \(last.formatted(date: .omitted, time: .shortened))")
            }
            if let error = store.syncError {
                Text("Failed: \(error)")
            }
            Divider()
            Button("Sync Now") { Task { await store.sync() } }
            Button("Pull") { Task { await store.pull() } }
        } label: {
            Label(title, systemImage: symbol)
                // The arrows turn while the sync runs, and the icon changes in place.
                .symbolEffect(.rotate, options: .repeat(.continuous), isActive: store.syncing && !reduceMotion)
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(store.syncError != nil ? Palette.red : (store.gitStatus?.changed ?? 0) > 0 ? Palette.accent : .primary)
        } primaryAction: {
            Task { await store.sync() }
        }
        .disabled(store.syncing)
        // The icon's colour and shape are the state: in words for VoiceOver.
        .accessibilityLabel("Sync")
        .accessibilityValue(spokenState)
        .help(store.syncError.map { "The last sync failed: \($0)" } ?? "Commit, pull and push. Hold for more.")
    }

    private var spokenState: String {
        if store.syncing { return "Syncing" }
        if store.rebasing { return "Stopped on a conflict" }
        if let error = store.syncError { return "The last sync failed: \(error)" }
        guard let status = store.gitStatus else { return "" }
        return "On \(status.branch), " + describe(status)
    }

    private var symbol: String {
        if store.syncing { return "arrow.triangle.2.circlepath.circle" }
        if store.rebasing { return "exclamationmark.arrow.triangle.2.circlepath" }
        if store.syncError != nil { return "exclamationmark.arrow.triangle.2.circlepath" }
        if let status = store.gitStatus, status.changed > 0 || status.ahead > 0 { return "arrow.up.circle" }
        if let status = store.gitStatus, status.behind > 0 { return "arrow.down.circle" }
        return "checkmark.circle"
    }

    private var title: String {
        guard let status = store.gitStatus else { return "Sync" }
        return status.changed > 0 ? "\(status.changed) changed" : status.branch
    }

    private func describe(_ status: Git.Status) -> String {
        var parts: [String] = []
        parts.append(status.changed == 0 ? "No changes" : "\(status.changed) files changed")
        if status.ahead > 0 { parts.append("\(status.ahead) to push") }
        if status.behind > 0 { parts.append("\(status.behind) to pull") }
        return parts.joined(separator: ", ")
    }
}

struct WelcomeView: View {
    @Environment(VaultStore.self) private var store

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 128, height: 128).accessibilityHidden(true)
            Text("Daftar").font(.largeTitle.bold())
            Text("Open the folder of an Obsidian vault. The app reads it where it is, and changes only what you change.")
                .multilineTextAlignment(.center).frame(maxWidth: 360).foregroundStyle(.secondary)
            Button("Open Vault…") { chooseVault(store) }.keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
func chooseVault(_ store: VaultStore) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = "Open Vault"
    if panel.runModal() == .OK, let url = panel.url { store.open(url) }
}

/// The focused window's model, for the menu commands. A plain key rather
/// than `@Entry`: the macro's plugin ships with Xcode, not with the command
/// line tools this builds with.
struct FocusedWindowKey: FocusedValueKey {
    typealias Value = WindowModel
}

extension FocusedValues {
    var window: WindowModel? {
        get { self[FocusedWindowKey.self] }
        set { self[FocusedWindowKey.self] = newValue }
    }
}
