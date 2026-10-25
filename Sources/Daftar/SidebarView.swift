import AppKit
import DaftarCore
import SwiftUI

/// What a sidebar row stands for.
enum SidebarItem: Hashable {
    case today
    case file(String)
}

/// The sidebar, as a Mac app has one: Today at the top, then the vault's
/// folders. Typing in the search field above it lists the hits instead.
struct SidebarView: View {
    @Bindable var model: WindowModel
    @Environment(VaultStore.self) private var store

    var body: some View {
        Group {
            if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                FilesList(model: model)
            } else {
                SearchResults(model: model)
            }
        }
        .searchable(text: $model.query, placement: .sidebar, prompt: "Search \(store.name)")
    }
}

struct FilesList: View {
    @Bindable var model: WindowModel
    @Environment(VaultStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let groups = store.taskGroups()
        List(selection: selection) {
            Section {
                Label {
                    Text("Today")
                } icon: {
                    Image(systemName: "sun.max.fill").foregroundStyle(Palette.yellow)
                }
                .badge(groups.today.count + groups.overdue.count)
                    .tag(SidebarItem.today)
            }
            Section(store.name) {
                OutlineGroup(store.index.tree, children: \.children) { node in
                    FileRow(node: node)
                        .tag(SidebarItem.file(node.folderNote ?? node.path))
                        .contextMenu { FileMenu(path: node.folderNote ?? node.path, folder: node.isFolder ? node.path : nil, model: model) }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// Selecting a row opens it; the selection follows the note on screen.
    private var selection: Binding<SidebarItem?> {
        Binding {
            if model.showsToday { return .today }
            return model.path.map { .file($0) }
        } set: { item in
            switch item {
            case .today: model.showsToday = true
            case .file(let path) where store.index.files.contains(path):
                if path != model.path || model.showsToday { model.open(path, store: store) }
            default: break
            }
        }
    }
}

struct FileRow: View {
    var node: TreeNode
    @Environment(VaultStore.self) private var store

    var body: some View {
        let icon = store.iconic.icon(for: node.path, folder: node.isFolder)
        Label {
            Text(node.name).foregroundStyle(Vault.isNote(node.path) || node.isFolder ? .primary : .secondary)
        } icon: {
            if node.isFolder {
                IconicImage(icon: icon, fallback: node.folderNote != nil ? "folder.fill" : "folder", fallbackColor: Palette.accent)
            } else if Vault.isNote(node.path) {
                IconicImage(icon: icon, fallback: "doc.text", fallbackColor: Palette.muted)
            } else {
                IconicImage(icon: icon, fallback: attachmentSymbol, fallbackColor: Palette.purple)
            }
        }
    }

    private var attachmentSymbol: String {
        switch node.path.split(separator: ".").last?.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic": "photo"
        case "pdf": "doc.richtext"
        case "base": "tablecells"
        case "canvas": "rectangle.on.rectangle"
        default: "paperclip"
        }
    }
}

/// The right-click menu of a file or folder.
struct FileMenu: View {
    var path: String
    var folder: String?
    var model: WindowModel
    @Environment(VaultStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if Vault.isNote(path), store.index.files.contains(path) {
            Button("Open in New Window") { openWindow(value: path) }
            Button("Open in Obsidian") { openInObsidian(path, store: store) }
            Divider()
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("[[\(Vault.title(of: path))]]", forType: .string)
            }
        }
        if let url = store.url(of: folder ?? path) {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            if Vault.isNote(path) || folder == nil {
                ShareLink(item: url)
            }
        }
    }
}

/// Full-text search, and `#tag` for the notes that carry a tag.
struct SearchResults: View {
    @Bindable var model: WindowModel
    @Environment(VaultStore.self) private var store
    @ViewState private var hits: [SearchIndex.Hit] = []
    @ViewState private var searched = false

    var body: some View {
        List {
            Section(searched ? "\(hits.count == 100 ? "100+" : String(hits.count)) notes" : "Searching…") {
                ForEach(hits, id: \.path) { hit in
                    Button {
                        model.findText = firstWord
                        model.open(hit.path, store: store)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Vault.title(of: hit.path)).font(.headline)
                            if !hit.snippet.isEmpty {
                                Text(highlighted(hit.snippet)).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                            }
                            Text(hit.path.split(separator: "/").dropLast().joined(separator: " › "))
                                .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { FileMenu(path: hit.path, model: model) }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if searched && hits.isEmpty { ContentUnavailableView.search(text: model.query) }
        }
        .task(id: "\(model.query)|\(store.revision)") { await run() }
    }

    private var firstWord: String? {
        let word = model.query.split(separator: " ").first.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: "\"#"))
        return word?.isEmpty == false ? word : nil
    }

    private func run() async {
        let query = model.query.trimmingCharacters(in: .whitespaces)
        if query.hasPrefix("#"), !query.contains(" ") {
            let tag = Slugs.fold(String(query.dropFirst()))
            hits = store.index.notes.values
                .filter { $0.parsed.tags.contains { Slugs.fold($0) == tag || Slugs.fold($0).hasPrefix(tag + "/") } }
                .map { SearchIndex.Hit(path: $0.path, snippet: "") }
                .sorted { $0.path < $1.path }
            searched = true
            return
        }
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        let search = store.search
        hits = await Task.detached { search.search(query) }.value
        searched = true
    }

    /// FTS5 marks each match between `\u{1}` and `\u{2}`.
    private func highlighted(_ snippet: String) -> AttributedString {
        var out = AttributedString()
        var bold = false
        var chunk = ""
        func emit() {
            var part = AttributedString(chunk.replacingOccurrences(of: "\n", with: " "))
            if bold {
                part.foregroundColor = Palette.accent
                part.inlinePresentationIntent = .stronglyEmphasized
            }
            out += part
            chunk = ""
        }
        for ch in snippet {
            if ch == "\u{1}" || ch == "\u{2}" {
                emit()
                bold = ch == "\u{1}"
            } else {
                chunk.append(ch)
            }
        }
        emit()
        return out
    }
}

/// The note's outline, its backlinks and its tags.
struct InspectorView: View {
    @Bindable var model: WindowModel
    @Environment(VaultStore.self) private var store

    var body: some View {
        if !model.showsToday, let path = model.path, let note = store.index.notes[path] {
            List {
                if !note.parsed.headings.isEmpty {
                    Section("Outline") {
                        ForEach(Array(note.parsed.headings.enumerated()), id: \.offset) { _, heading in
                            Button {
                                model.open(path, heading: heading.text, store: store)
                            } label: {
                                Text(heading.text)
                                    .font(heading.level <= 2 ? .body.weight(.medium) : .body)
                                    .foregroundStyle(heading.level <= 2 ? .primary : .secondary)
                                    .padding(.leading, CGFloat(heading.level - 1) * 10)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: TextDirection.startsRtl(heading.text) ? .trailing : .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                let backlinks = store.index.backlinks[path] ?? []
                Section("Backlinks") {
                    if backlinks.isEmpty {
                        Text("No note links here.").foregroundStyle(.secondary)
                    }
                    ForEach(backlinks, id: \.self) { link in
                        Button {
                            model.open(link.source, line: link.line, store: store)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Vault.title(of: link.source))
                                Text(link.source.split(separator: "/").dropLast().joined(separator: " › "))
                                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !note.parsed.tags.isEmpty {
                    Section("Tags") {
                        FlowTags(tags: note.parsed.tags) { model.searchTag($0) }
                    }
                }
            }
            .listStyle(.sidebar)
        } else {
            ContentUnavailableView("No note", systemImage: "sidebar.right", description: Text("Open a note to see its outline and backlinks."))
        }
    }
}

struct FlowTags: View {
    var tags: [String]
    var action: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Button("#" + tag) { action(tag) }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .foregroundStyle(Palette.accent)
                    .background(Palette.accent.opacity(0.15), in: Capsule())
            }
        }
    }
}

/// ⌘O: a note by its name, in a Spotlight-like panel.
struct QuickOpenView: View {
    @Bindable var model: WindowModel
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @ViewState private var query = ""
    @ViewState private var selected = 0
    @FocusState private var focused: Bool

    var body: some View {
        let results = store.quickOpen(query, recent: model.recent)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                TextField("Open a note by name", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($focused)
                    .onSubmit { choose(results) }
                    .onKeyPress(.downArrow) { selected = min(selected + 1, max(results.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            .padding(14)
            if !results.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element) { index, path in
                                HStack(spacing: 10) {
                                    Image(systemName: "doc.text").foregroundStyle(index == selected ? .white : Palette.accent)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(Vault.title(of: path)).lineLimit(1)
                                        Text(path.split(separator: "/").dropLast().joined(separator: " › "))
                                            .font(.caption).lineLimit(1)
                                            .foregroundStyle(index == selected ? .white.opacity(0.8) : .secondary)
                                    }
                                    Spacer()
                                }
                                .foregroundStyle(index == selected ? .white : .primary)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(index == selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                                .onTapGesture { selected = index; choose(results) }
                                .id(index)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: selected) { _, index in proxy.scrollTo(index) }
                }
            }
        }
        .frame(width: 600, height: results.isEmpty ? nil : 420)
        .background(.regularMaterial)
        .onAppear { focused = true }
        .onChange(of: query) { selected = 0 }
    }

    private func choose(_ results: [String]) {
        guard results.indices.contains(selected) else { return }
        model.open(results[selected], store: store)
        dismiss()
    }
}

@MainActor
func openInObsidian(_ path: String, store: VaultStore) {
    guard let file = store.url(of: path) else { return }
    var components = URLComponents()
    components.scheme = "obsidian"
    components.host = "open"
    components.queryItems = [URLQueryItem(name: "path", value: file.path)]
    if let url = components.url { NSWorkspace.shared.open(url) }
}
