import AppKit
import DaftarCore
import SwiftUI

/// One command of the palette.
struct PaletteCommand: Identifiable {
    var id: String
    var title: String
    var group: String
    var symbol: String
    var color: Color
    var shortcut = ""
    var run: () -> Void
}

/// Every command the palette offers for the window, the menus' commands
/// and a few that have no menu item.
@MainActor
enum PaletteCommands {
    static func all(model: WindowModel, store: VaultStore, openWindow: OpenWindowAction, openSettings: OpenSettingsAction) -> [PaletteCommand] {
        let note = model.showsPage ? nil : model.path
        var out: [PaletteCommand] = [
            PaletteCommand(id: "open", title: "Quick Open", group: "Go", symbol: "magnifyingglass", color: Palette.accent, shortcut: "⌘P") {
                model.openSwitcher()
            },
            PaletteCommand(id: "today", title: "Today", group: "Go", symbol: "sun.max.fill", color: Palette.yellow, shortcut: "⌘1") {
                model.showsToday = true
            },
            PaletteCommand(id: "board", title: "Task Board", group: "Go", symbol: "rectangle.split.3x1.fill", color: Palette.purple, shortcut: "⌘2") {
                model.showsBoard = true
            },
            PaletteCommand(id: "random", title: "Open Random Note", group: "Go", symbol: "dice.fill", color: Palette.purple) {
                let notes = store.index.notes.keys.filter { !store.excluded.contains($0) }
                if let path = notes.randomElement() { model.open(path, store: store) }
            },
            PaletteCommand(id: "new-note", title: "New Note", group: "File", symbol: "square.and.pencil", color: Palette.accent, shortcut: "⌘N") {
                model.fileAction = .newNote(folder: model.currentFolder)
            },
            PaletteCommand(id: "new-folder", title: "New Folder", group: "File", symbol: "folder.badge.plus", color: Palette.yellow, shortcut: "⇧⌘N") {
                model.fileAction = .newFolder(parent: model.currentFolder)
            },
            PaletteCommand(id: "window", title: "New Window", group: "File", symbol: "macwindow.badge.plus", color: Palette.blue, shortcut: "⌥⌘N") {
                openWindow(id: "main")
            },
            PaletteCommand(id: "inspector", title: model.inspector ? "Hide Inspector" : "Show Inspector", group: "View", symbol: "sidebar.right", color: Palette.aqua, shortcut: "⌥⌘I") {
                model.inspector.toggle()
            },
            PaletteCommand(id: "terminal", title: model.terminal ? "Hide Terminal" : "Show Terminal", group: "View", symbol: "apple.terminal", color: Palette.green, shortcut: "⌃`") {
                model.terminal.toggle()
            },
            PaletteCommand(id: "bigger", title: "Bigger Text", group: "View", symbol: "textformat.size.larger", color: Palette.pink, shortcut: "⌘+") {
                store.settings.textSize = min(store.settings.textSize + 1, 28)
            },
            PaletteCommand(id: "smaller", title: "Smaller Text", group: "View", symbol: "textformat.size.smaller", color: Palette.pink, shortcut: "⌘−") {
                store.settings.textSize = max(store.settings.textSize - 1, 10)
            },
            PaletteCommand(id: "vault-graph", title: "Show the Graph", group: "View", symbol: "point.3.connected.trianglepath.dotted", color: Palette.purple, shortcut: "⌥⌘G") {
                model.graph = true
            },
            PaletteCommand(id: "icon", title: "Set Icon for This Note", group: "Note", symbol: "face.smiling", color: Palette.yellow) {
                if let note { model.iconTarget = IconTarget(path: note, folder: false) }
            },
            PaletteCommand(id: "translate", title: "Translate the Selection or the Note", group: "Note", symbol: "translate", color: Palette.blue, shortcut: "⌃⌘T") {
                model.translate(store: store)
            },
            PaletteCommand(id: "assistant", title: "Summarize or Ask with Apple Intelligence", group: "Note", symbol: "apple.intelligence", color: Palette.purple, shortcut: "⌥⌘A") {
                model.assistant = true
            },
            PaletteCommand(id: "settings", title: "Settings", group: "App", symbol: "gearshape.fill", color: Palette.muted, shortcut: "⌘,") {
                openSettings()
            },
        ]
        if store.isRepository {
            out += [
                PaletteCommand(id: "sync", title: "Sync Now", group: "Git", symbol: "arrow.triangle.2.circlepath", color: Palette.green, shortcut: "⇧⌘S") {
                    Task { await store.sync() }
                },
                PaletteCommand(id: "pull", title: "Pull", group: "Git", symbol: "arrow.down.circle.fill", color: Palette.blue) {
                    Task { await store.pull() }
                },
            ]
        }
        if model.canGoBack {
            out.append(PaletteCommand(id: "back", title: "Go Back", group: "Go", symbol: "chevron.left", color: Palette.muted, shortcut: "⌘[") { model.goBack() })
        }
        if model.canGoForward {
            out.append(PaletteCommand(id: "forward", title: "Go Forward", group: "Go", symbol: "chevron.right", color: Palette.muted, shortcut: "⌘]") { model.goForward() })
        }
        if let note {
            let bookmarked = store.bookmarks.contains(note)
            out += [
                PaletteCommand(id: "edit", title: model.editing ? "Read the Note" : "Edit the Note", group: "Note", symbol: model.editing ? "book" : "square.and.pencil", color: Palette.accent, shortcut: "⌘E") {
                    model.editing.toggle()
                },
                PaletteCommand(id: "find", title: "Find in Note", group: "Note", symbol: "text.magnifyingglass", color: Palette.accent, shortcut: "⌘F") {
                    model.find(.showFindInterface)
                },
                PaletteCommand(id: "bookmark", title: bookmarked ? "Remove Bookmark" : "Bookmark the Note", group: "Note", symbol: bookmarked ? "star.slash" : "star.fill", color: Palette.yellow, shortcut: "⌘D") {
                    store.toggleBookmark(note)
                },
                PaletteCommand(id: "graph", title: "Show the Note's Graph", group: "Note", symbol: "point.3.connected.trianglepath.dotted", color: Palette.purple, shortcut: "⌥⌘G") {
                    model.graph = true
                },
                PaletteCommand(id: "extract", title: "Extract Selection to New Note", group: "Note", symbol: "rectangle.portrait.and.arrow.right", color: Palette.pink, shortcut: "⌥⌘X") {
                    if !model.editing { model.editing = true }
                    DispatchQueue.main.async { NSApp.sendAction(#selector(NoteTextView.extractSelection(_:)), to: nil, from: nil) }
                },
                PaletteCommand(id: "rename", title: "Rename", group: "Note", symbol: "character.cursor.ibeam", color: Palette.blue, shortcut: "⌘R") {
                    model.fileAction = .rename(note)
                },
                PaletteCommand(id: "move", title: "Move to…", group: "Note", symbol: "folder.badge.gearshape", color: Palette.purple, shortcut: "⌥⌘M") {
                    model.fileAction = .move(note)
                },
                PaletteCommand(id: "trash", title: "Move to Trash", group: "Note", symbol: "trash.fill", color: Palette.red) {
                    model.fileAction = .delete(note)
                },
                PaletteCommand(id: "copy-link", title: "Copy Link", group: "Note", symbol: "link", color: Palette.aqua) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("[[\(Vault.title(of: note))]]", forType: .string)
                },
                PaletteCommand(id: "finder", title: "Show in Finder", group: "Note", symbol: "folder.fill", color: Palette.blue) {
                    if let url = store.url(of: note) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                },
                PaletteCommand(id: "obsidian", title: "Open in Obsidian", group: "Note", symbol: "arrow.up.forward.app.fill", color: Palette.purple) {
                    openInObsidian(note, store: store)
                },
                PaletteCommand(id: "note-tab", title: "Open in New Tab", group: "Note", symbol: "plus.rectangle.on.rectangle", color: Palette.blue, shortcut: "⌘T") {
                    openWindow(value: TabRequest(path: note))
                },
            ]
        }
        return out
    }

    /// The commands that match [query], best first; with no query, the
    /// ones used last, then the rest in their groups.
    static func filter(_ commands: [PaletteCommand], _ query: String, recent: [String]) -> [(command: PaletteCommand, positions: [Int])] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            let used = recent.compactMap { id in commands.first { $0.id == id } }
            let rest = commands.filter { !recent.contains($0.id) }
            return (used + rest).map { ($0, []) }
        }
        return commands.compactMap { command -> (PaletteCommand, Fuzzy.Match)? in
            Fuzzy.match(trimmed, in: command.title).map { (command, $0) }
        }
        .sorted { a, b in
            let boost = { (id: String) in recent.contains(id) ? 3 : 0 }
            return a.1.score + boost(a.0.id) > b.1.score + boost(b.0.id)
        }
        .map { ($0.0, $0.1.positions) }
    }
}

/// ⇧⌘P: every command by its name, as Obsidian's command palette.
struct CommandPaletteView: View {
    @Bindable var model: WindowModel
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @ViewState private var query = ""
    @ViewState private var selected = 0
    @FocusState private var focused: Bool

    var body: some View {
        let commands = PaletteCommands.all(model: model, store: store, openWindow: openWindow, openSettings: openSettings)
        let results = PaletteCommands.filter(commands, query, recent: model.recentCommands)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command").font(.title2.weight(.semibold))
                    .foregroundStyle(LinearGradient(colors: [Palette.accent, Palette.pink], startPoint: .top, endPoint: .bottom))
                TextField("Run a command", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($focused)
                    .onSubmit { run(results) }
                    .onKeyPress(.downArrow) { selected = min(selected + 1, max(results.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.command.id) { index, result in
                            row(result.command, positions: result.positions, chosen: index == selected)
                                .onTapGesture { selected = index; run(results) }
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selected) { _, index in proxy.scrollTo(index) }
            }
            if results.isEmpty {
                Text("No command matches “\(query)”.").foregroundStyle(.secondary).padding(20)
            }
        }
        .frame(width: 620, height: 440)
        .onAppear { focused = true }
        .onChange(of: query) { selected = 0 }
    }

    private func row(_ command: PaletteCommand, positions: [Int], chosen: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: command.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(command.color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(highlighted(command.title, positions, chosen: chosen)).lineLimit(1)
                Text(command.group).font(.caption).foregroundStyle(chosen ? .white.opacity(0.75) : .secondary)
            }
            Spacer()
            if !command.shortcut.isEmpty {
                Text(command.shortcut)
                    .font(.callout.monospaced().weight(.medium))
                    .foregroundStyle(chosen ? .white : .secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(chosen ? .white.opacity(0.18) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .foregroundStyle(chosen ? .white : .primary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            chosen
                ? AnyShapeStyle(LinearGradient(colors: [command.color, command.color.opacity(0.75)], startPoint: .leading, endPoint: .trailing))
                : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
    }

    /// The letters the query matched, in the accent colour and bold.
    private func highlighted(_ title: String, _ positions: [Int], chosen: Bool) -> AttributedString {
        var out = AttributedString()
        for (offset, character) in title.enumerated() {
            var piece = AttributedString(String(character))
            if positions.contains(offset) {
                piece.font = .body.bold()
                piece.foregroundColor = chosen ? .white : Palette.accent
            }
            out += piece
        }
        return out
    }

    private func run(_ results: [(command: PaletteCommand, positions: [Int])]) {
        guard results.indices.contains(selected) else { return }
        let command = results[selected].command
        model.recentCommands.removeAll { $0 == command.id }
        model.recentCommands.insert(command.id, at: 0)
        dismiss()
        // After the sheet is gone, so a command can open another one.
        DispatchQueue.main.async { command.run() }
    }
}
