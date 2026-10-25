import AppKit
import DaftarCore
import SwiftUI

@main
struct DaftarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = VaultStore()
    @FocusedValue(\.window) private var window

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 760, minHeight: 440)
                .task(id: store.revision) {
                    // After the vault changes, the alerts and the badge follow.
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, store.root != nil, !store.loading else { return }
                    updateBadge()
                    await Notifier.shared.plan(store: store)
                }
                .onChange(of: store.settings.dockBadge) { updateBadge() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Vault…") { chooseVault(store) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Quick Open…") { window?.quickOpen = true }
                    .keyboardShortcut("o")
                    .disabled(window == nil)
            }
            CommandGroup(after: .sidebar) {
                Button("Show Inspector") { window?.inspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
                Button("Bigger Text") { store.settings.textSize = min(store.settings.textSize + 1, 28) }
                    .keyboardShortcut("+")
                Button("Smaller Text") { store.settings.textSize = max(store.settings.textSize - 1, 10) }
                    .keyboardShortcut("-")
                Button("Actual Size") { store.settings.textSize = 15 }
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
                Button("Today") { window?.showsToday = true }
                    .keyboardShortcut("1")
                Divider()
                Button("Sync Now") { Task { await store.sync() } }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!store.isRepository)
            }
        }

        WindowGroup("Note", for: String.self) { $path in
            if let path {
                NoteWindow(path: path).environment(store)
            }
        }

        Settings {
            SettingsView().environment(store)
        }

        MenuBarExtra {
            MenuBarView().environment(store)
        } label: {
            if let icon = Resources.menuBarIcon {
                Image(nsImage: icon)
            } else {
                Image(systemName: "book.closed")
            }
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppSettings.shared.applyAppearance()
            Notifier.shared.start()
        }
    }

    /// The alerts and the menu bar stay when the last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            NotificationSettings().tabItem { Label("Notifications", systemImage: "bell.badge") }
            GitSettings().tabItem { Label("Git", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(width: 520)
        .tint(Palette.accent)
    }
}

private struct GeneralSettings: View {
    @Environment(VaultStore.self) private var store

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
            Toggle("Count today's tasks on the Dock icon", isOn: $settings.dockBadge)
        }
        .formStyle(.grouped)
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
                .onChange(of: settings.syncInterval) { store.scheduleAutoSync() }
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
