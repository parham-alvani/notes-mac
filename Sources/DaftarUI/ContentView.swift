import AppKit
import DaftarCore
import SwiftUI

/// One window: the sidebar, the note, and the inspector beside it.
struct ContentView: View {
    @Environment(VaultStore.self) private var store
    @ViewState private var model = WindowModel()
    @Environment(\.openWindow) private var openWindow

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
                .inspector(isPresented: Binding { model.inspector && !model.showsToday } set: { model.inspector = $0 }) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 200, ideal: 260, max: 400)
                }
            }
        }
        .tint(Palette.accent)
        .navigationTitle(title)
        .navigationSubtitle(model.showsToday ? store.name : model.path.map { folder(of: $0) } ?? "")
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
        .sheet(item: $model.fileAction) { action in
            FileActionSheet(action: action, model: model)
        }
        .overlay(alignment: .bottom) { noticeBanner }
        // ⌘O opens the switcher too, as in the vault's Obsidian hotkeys.
        .background {
            Button("Quick Open") { model.quickOpen = true }
                .keyboardShortcut("o")
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .focusedSceneValue(\.window, model)
        .onOpenURL { url in model.handle(url, store: store) }
        // A `daftar://` link goes to the window that is open, not to a new one.
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
    }

    private var title: String {
        if model.showsToday { return "Today" }
        return model.path.map(Vault.title(of:)) ?? store.name
    }

    @ViewBuilder private var detail: some View {
        if store.loading {
            ProgressView("Reading \(store.name)…")
        } else if model.showsToday {
            TodayView(model: model)
        } else if let path = model.path, model.editing {
            EditorView(path: path, store: store)
        } else if model.request != nil {
            ReaderView(
                request: model.request, store: store,
                onOpen: { path, anchor, newWindow in
                    if newWindow {
                        openWindow(value: path)
                    } else {
                        model.open(path, heading: anchor, store: store)
                    }
                },
                onTag: { model.searchTag($0) },
                findText: model.findText,
                findCommand: model.readerFind)
        } else {
            ContentUnavailableView {
                Label("No note open", systemImage: "doc.text")
            } description: {
                Text("Choose a note in the sidebar, or press ⌘P to find one by name.")
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        @Bindable var model = model
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!model.canGoBack)
            Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(!model.canGoForward)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let path = model.path, !model.showsToday {
                Picker("Mode", selection: $model.editing) {
                    Label("Read", systemImage: "book").tag(false)
                    Label("Edit", systemImage: "square.and.pencil").tag(true)
                }
                .pickerStyle(.segmented)
                .help("Read or edit the note (⌘E)")
                if let url = store.url(of: path) {
                    ShareLink(item: url)
                }
            }
            if store.isRepository {
                SyncButton()
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $model.terminal) { Label("Terminal", systemImage: "apple.terminal") }
                .help("Show or hide a terminal in the vault's folder (⌃`)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.inspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                .help("Show or hide the outline and backlinks")
        }
    }

    @ViewBuilder private var noticeBanner: some View {
        if let notice = store.notice {
            Text(notice)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 16)
                .task {
                    try? await Task.sleep(for: .seconds(5))
                    store.notice = nil
                }
                .onTapGesture { store.notice = nil }
        }
    }

    private func folder(of path: String) -> String {
        let parts = path.split(separator: "/").dropLast()
        return parts.joined(separator: " › ")
    }

}

/// A window opened on one note, by ⌘-click on a link.
struct NoteWindow: View {
    var path: String
    @Environment(VaultStore.self) private var store
    @ViewState private var model = WindowModel()

    var body: some View {
        ReaderView(
            request: model.request, store: store,
            onOpen: { path, anchor, _ in model.open(path, heading: anchor, store: store) },
            onTag: { _ in }, findText: nil)
            .tint(Palette.accent)
            .navigationTitle(model.path.map(Vault.title(of:)) ?? "")
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                        .disabled(!model.canGoBack)
                }
            }
            .onAppear { if model.request == nil { model.open(path, store: store) } }
            .frame(minWidth: 400, minHeight: 300)
    }
}

/// Git in the toolbar: the branch and how it stands, and a menu to sync.
struct SyncButton: View {
    @Environment(VaultStore.self) private var store

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
                .foregroundStyle(store.syncError != nil ? Palette.red : (store.gitStatus?.changed ?? 0) > 0 ? Palette.accent : .primary)
        } primaryAction: {
            Task { await store.sync() }
        }
        .disabled(store.syncing)
        .help(store.syncError.map { "The last sync failed: \($0)" } ?? "Commit, pull and push. Hold for more.")
    }

    private var symbol: String {
        if store.syncing { return "arrow.triangle.2.circlepath.circle" }
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
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 128, height: 128)
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
