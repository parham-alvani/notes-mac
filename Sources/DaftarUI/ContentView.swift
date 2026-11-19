import CoreSpotlight
import AppKit
import DaftarCore
import SwiftUI
import Translation

/// One window: the sidebar, the tabs with their notes, and the inspector
/// beside them. The sidebar, the toolbar, the inspector and the panels are
/// the window's, and act on the tab in front.
struct ContentView: View {
    @Environment(VaultStore.self) private var store
    @ViewState private var tabs = WindowTabs()
    /// The window is on screen. Until then the sidebar and the toolbar are
    /// empty: AppKit lays a new window out when it makes it, when it sizes
    /// it and when it shows it, and with the tree's rows and the toolbar's
    /// items in it each of those was most of a new window's wait. They are
    /// laid out once, after.
    @ViewState private var settled = false

    var body: some View {
        // The tab the window stands around: built again when another one is in
        // front, a frame after its note is shown (`WindowTabs.chrome`).
        @Bindable var model = tabs.chrome
        Group {
            if store.root == nil {
                WelcomeView()
            } else {
                NavigationSplitView {
                    Group {
                        if settled { SidebarView(model: model) } else { Color.clear }
                    }
                    .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
                } detail: {
                    TabDetails(tabs: tabs)
                }
                .inspector(isPresented: $model.inspectorShown) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 200, ideal: 260, max: 400)
                }
            }
        }
        .tint(Palette.accent)
        .modifier(WindowFollowing(model: model, tabs: tabs))
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
        .sheet(item: $model.vaultReplace) { VaultReplaceSheet(target: $0) }
        .sheet(item: $model.headingRename) { HeadingRenameSheet(target: $0) }
        .translationPresentation(isPresented: Binding { model.translation != nil } set: { if !$0 { model.translation = nil } }, text: model.translation ?? "")
        .sheet(item: $model.taskEdit) { task in
            TaskEditSheet(task: task)
        }
        .sheet(item: $model.taskCancel) { CancelTaskSheet(request: $0) }
        .sheet(item: $model.taskNew) { TaskEditSheet(new: $0) }
        .sheet(item: $model.weeklyReview) { WeeklyReviewSheet(preview: $0, model: model) }
        .sheet(item: $model.fileAction) { action in
            FileActionSheet(action: action, model: model)
        }
        .overlay(alignment: .bottom) { NoticeBanner() }
        // ⌘O opens the switcher too, as in the vault's Obsidian hotkeys.
        .background {
            Group {
                Button("Quick Open") { model.openSwitcher() }
                    .keyboardShortcut("o")
                // The tabs' other keys, as in Safari: ⌃Tab and ⌃⇧Tab are in the Window menu.
                Button("Show Next Tab") { tabs.step(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Show Previous Tab") { tabs.step(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .focusedSceneValue(\.window, model)
        .background(TabbedWindow(model: model, tabs: tabs) { settled = true })
        .drillDeckFollows(store)
        .onAppear {
            let store = store
            tabs.release = { store.followers[ObjectIdentifier($0)] = nil }
            tabs.adopt = { tab in
                // Every tab follows a move or a delete, wherever it was made.
                store.followers[ObjectIdentifier(tab)] = { [weak tab] in tab?.follow($0) }
                tab.places = store.places
                // Neovim mode: one pane edits at a time.
                tab.oneEditor = store.settings.vimMode
            }
        }
        .onDisappear { tabs.releaseAll() }
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

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if settled { WindowToolbar(tabs: tabs, store: store) }
    }
}

/// The window's toolbar. It has one shape for every tab: the tabs' own
/// object is what its items are made with, and each item reads the tab in
/// front in its own view. So a switch of tabs, a note opened or the home
/// page shown changes what the buttons say and never which buttons there
/// are -- when the shape changed (Read or Edit and Share only with a note),
/// SwiftUI took every item out and made it again, about 140 ms of toolbar
/// layout. A control with nothing to act on is dimmed, not left out. The
/// toolbar itself reads only what a vault changes rarely: a repository, a
/// rebase, a finding (`VaultChecks.any`, never `counts`).
private struct WindowToolbar: ToolbarContent {
    var tabs: WindowTabs
    var store: VaultStore

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            HistoryButton(tabs: tabs, forward: false)
            HistoryButton(tabs: tabs, forward: true)
            HomeButton(tabs: tabs)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            ModePicker(tabs: tabs)
            ShareButton(tabs: tabs)
            if store.rebasing {
                ConflictsButton(tabs: tabs)
            }
            if store.isRepository {
                SyncButton()
            }
        }
        // The panes are their own group of glass, apart from the note's tools.
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            if store.checks.any { TabProblemsButton(tabs: tabs) }
            TerminalToggle(tabs: tabs)
            InspectorButton(tabs: tabs)
        }
    }
}

/// Back or Forward, in the toolbar.
private struct HistoryButton: View {
    var tabs: WindowTabs
    var forward: Bool

    var body: some View {
        let model = tabs.chrome
        if forward {
            Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(!model.canGoForward)
        } else {
            Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!model.canGoBack)
        }
    }
}

/// Home, in the toolbar.
private struct HomeButton: View {
    var tabs: WindowTabs

    var body: some View {
        let model = tabs.chrome
        Button { model.goHome() } label: { Label("Home", systemImage: "house") }
            .disabled(model.showsHome)
            .help("Show the home page (⇧⌘D)")
    }
}

/// Share, in the toolbar: the note's file. Dimmed on a page and the home page.
private struct ShareButton: View {
    var tabs: WindowTabs
    @Environment(VaultStore.self) private var store

    var body: some View {
        let model = tabs.chrome
        let url = model.showsPage ? nil : model.path.flatMap { store.url(of: $0) }
        ShareLink(item: url ?? URL(filePath: "/"))
            .disabled(url == nil)
    }
}

/// The conflicts of a pull that stopped, in the toolbar while it is stopped.
private struct ConflictsButton: View {
    var tabs: WindowTabs
    @Environment(VaultStore.self) private var store

    var body: some View {
        Button { tabs.chrome.conflicts = true } label: {
            Label("Conflicts", systemImage: "exclamationmark.triangle.fill")
        }
        .badge(store.conflicts.count)
        .foregroundStyle(Palette.accent)
        .help("The pull stopped on a conflict. Choose what to keep; sync waits until then.")
    }
}

/// Problems, in the toolbar, for the tab in front.
private struct TabProblemsButton: View {
    var tabs: WindowTabs

    var body: some View { ProblemsButton(model: tabs.chrome) }
}

/// The terminal under the note, in the toolbar.
private struct TerminalToggle: View {
    var tabs: WindowTabs

    var body: some View {
        @Bindable var model = tabs.chrome
        Toggle(isOn: $model.terminal) { Label("Terminal", systemImage: "apple.terminal") }
            .help("Show or hide a terminal in the vault's folder (⌃`)")
    }
}

/// The inspector, in the toolbar.
private struct InspectorButton: View {
    var tabs: WindowTabs

    var body: some View {
        Button { tabs.chrome.inspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
            .help("Show or hide the outline and backlinks")
    }
}

/// What the window follows and names itself by: its title, and the changes
/// of the note, the vault and the settings it answers to. A modifier of its
/// own: read in `ContentView.body`, each of these built the whole window's
/// view again, toolbar and all, in every tab, the hidden ones too -- about
/// 100 ms of toolbar layout for each tab at every file that changed.
private struct WindowFollowing: ViewModifier {
    var model: WindowModel
    var tabs: WindowTabs
    @Environment(VaultStore.self) private var store

    func body(content: Content) -> some View {
        content
            .navigationTitle(model.title(store: store))
            .navigationSubtitle(model.showsPage ? store.name : model.path.map { folder(of: $0) } ?? "")
            // A sync that stopped on a conflict opens the conflicts in the window in front.
            .onChange(of: store.conflictStops) { _, _ in
                if store.rebasing, ActiveWindow.shared.model == nil || ActiveWindow.shared.model === model { model.conflicts = true }
            }
            // Neovim mode: one pane edits at a time.
            .onChange(of: store.settings.vimMode, initial: true) { _, vim in
                for tab in tabs.tabs {
                    tab.oneEditor = vim
                    if vim { tab.setEditing(tab.editing, in: tab.focused) }
                }
            }
            .onChange(of: model.path) { _, path in
                if let path { WakaTime.shared.heartbeat(path, store: store) }
                // The voice reads the note it started on, and stops when this window leaves it.
                if ReadAloud.shared.path != nil, ReadAloud.shared.path != path, model.readerView === ReadAloud.shared.view { ReadAloud.shared.stop() }
            }
            // A setting that could not be saved is said, not dropped in silence.
            .onChange(of: store.settings.problem, initial: true) { _, problem in
                if let problem { store.notice = problem }
            }
    }

    private func folder(of path: String) -> String {
        let parts = path.split(separator: "/").dropLast()
        return parts.joined(separator: " › ")
    }
}

/// The tabs' notes, one over the other with only the tab in front seen, under
/// the bar of tabs. A tab left stays as it is -- its page loaded and
/// scrolled, its editor with its Neovim -- so coming back to it draws nothing.
private struct TabDetails: View {
    var tabs: WindowTabs

    var body: some View {
        let current = tabs.current
        ZStack {
            ForEach(tabs.tabs) { tab in
                let shown = tab === current
                WindowDetail(model: tab)
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    .accessibilityHidden(!shown)
                    .zIndex(shown ? 1 : 0)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { TabStrip(tabs: tabs) }
    }
}

/// One tab beside the sidebar: a page or the note panes, over the terminal
/// when it is shown.
private struct WindowDetail: View {
    var model: WindowModel
    @Environment(VaultStore.self) private var store

    var body: some View {
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

    @ViewBuilder private var detail: some View {
        Group {
            if store.loading {
                ProgressView("Reading \(store.name)…")
            } else if model.showsToday {
                TodayView(model: model)
            } else if model.showsBoard {
                BoardView(model: model)
            } else if model.showsJobs {
                JobBoardView(model: model)
            } else if model.showsDrill {
                DrillView(model: model)
            } else {
                NotePanes(model: model)
            }
        }
        // An inset, so showing the panel leaves the note's view where it is.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.problems { ProblemsPanel(model: model).transition(.move(edge: .bottom)) }
        }
    }
}

/// What the store has to say, over the bottom of the window for five seconds.
private struct NoticeBanner: View {
    @Environment(VaultStore.self) private var store

    var body: some View {
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
}

/// Read or Edit, in the toolbar. Its own view, so ⌘E updates this picker
/// alone: read in the window's toolbar, `editing` made SwiftUI build the
/// whole toolbar again at each switch, about 200 ms of layout before the
/// editor or the reader could show. Dimmed where there is no text to edit:
/// a page, the home page, a picture.
private struct ModePicker: View {
    var tabs: WindowTabs

    var body: some View {
        @Bindable var model = tabs.chrome
        Picker("Mode", selection: $model.editing) {
            Label("Read", systemImage: "book").tag(false)
            Label("Edit", systemImage: "square.and.pencil").tag(true)
        }
        .pickerStyle(.segmented)
        .disabled(!model.showsText)
        .help("Read or edit the note (⌘E)")
    }
}

/// The Daftar window last in front, for the menu commands when no window
/// holds SwiftUI's focus.
@MainActor @Observable
final class ActiveWindow {
    static let shared = ActiveWindow()
    weak var model: WindowModel?
}

/// Tells the app about the window a `ContentView` is in: it is a Daftar
/// window (`daftar.main`), its tabs are Daftar's own and not AppKit's, and
/// `ActiveWindow` hears when it comes to the front.
struct TabbedWindow: NSViewRepresentable {
    var model: WindowModel?
    var tabs: WindowTabs?
    /// Called once, when the window is on screen.
    var settled: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = WindowView()
        let coordinator = context.coordinator
        coordinator.model = model
        let settled = settled
        let tabs = tabs
        view.moved = { window in
            // AppKit's window tabs are off: with them a second window became
            // a tab of the first, beside Daftar's own tabs.
            window.tabbingMode = .disallowed
            window.tabbingIdentifier = "daftar.main"
            tabs?.window = window
            coordinator.watch(window)
            DispatchQueue.main.async { settled() }
        }
        return view
    }

    /// Tells when it is put in a window, before SwiftUI shows the window.
    final class WindowView: NSView {
        var moved: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let moved else { return }
            self.moved = nil
            moved(window)
        }
    }

    /// The model is the tab in front: the menus act on it.
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.model = model }

    @MainActor
    final class Coordinator {
        weak var model: WindowModel?
        nonisolated(unsafe) private var token: NSObjectProtocol?
        nonisolated(unsafe) private var seen: NSObjectProtocol?
        nonisolated(unsafe) private var keys: Any?

        func watch(_ window: NSWindow) {
            // The first window counts as in front until another one is.
            if window.isKeyWindow || ActiveWindow.shared.model == nil { ActiveWindow.shared.model = model }
            token = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) {
                [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    ActiveWindow.shared.model = self?.model
                }
            }
            seen = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) {
                [weak window] _ in
                MainActor.assumeIsolated { if let window { EdgeHover.follow(window) } }
            }
            EdgeHover.follow(window)
            // ⌃Tab and ⌃⇧Tab, before AppKit takes them to move the keys to the next view.
            keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
                // Local monitors run on the main thread, with the event loop.
                nonisolated(unsafe) let event = event
                return MainActor.assumeIsolated { TabKeys.takes(event, in: window) } ? nil : event
            }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
            if let seen { NotificationCenter.default.removeObserver(seen) }
            if let keys { NSEvent.removeMonitor(keys) }
        }
    }
}

/// In full screen AppKit shows a collapsed sidebar when the pointer comes to
/// the screen's edge, and for that each window follows every move of the
/// pointer, in any app, and asks the window server at each one whether it is
/// on a Space in view (`_startObservingEdgeHover`, `SLSWindowIsOnCurrentSpace`).
/// Every tab is a window, so with a dozen tabs a pointer that moves kept the
/// main thread busy. Only a window in view needs it: the others have it off
/// until they are seen again.
@MainActor
enum EdgeHover {
    private static let key = "revealsOnEdgeHoverInFullscreen"
    /// The items it turned off, to turn on again: never one AppKit had off.
    private static let off = NSHashTable<NSSplitViewItem>.weakObjects()

    static func follow(_ window: NSWindow) {
        set(window.occlusionState.contains(.visible), in: window)
    }

    /// Turns the reveal off in a window that is not seen, and on again, where
    /// it was on, in one that is.
    static func set(_ seen: Bool, in window: NSWindow) {
        for item in items(under: window.contentView) where item.responds(to: Selector(("setRevealsOnEdgeHoverInFullscreen:"))) {
            if seen, off.contains(item) {
                item.setValue(true, forKey: key)
                off.remove(item)
            } else if !seen, item.value(forKey: key) as? Bool == true {
                item.setValue(false, forKey: key)
                off.add(item)
            }
        }
    }

    private static func items(under view: NSView?) -> [NSSplitViewItem] {
        guard let view else { return [] }
        let own = ((view as? NSSplitView)?.delegate as? NSSplitViewController)?.splitViewItems ?? []
        return own + view.subviews.flatMap { items(under: $0) }
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
