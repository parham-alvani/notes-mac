import AppKit
import DaftarCore
import SwiftUI

/// What a sidebar row stands for.
enum SidebarItem: Hashable {
    case today
    case board
    case file(String)
    /// A bookmark: the same file as its row in the tree, a row of its own.
    case bookmark(String)
    /// A tag in the tag list; choosing it lists its notes.
    case tag(String)
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
    /// The folder a dragged file is over.
    @ViewState private var dropTarget: String?
    @ViewState private var tagsOpen = false

    var body: some View {
        let groups = store.taskGroups()
        List(selection: selection) {
            Section {
                Label {
                    Text("Today")
                } icon: {
                    Image(systemName: "sun.max.fill").resizable().scaledToFit().foregroundStyle(Palette.yellow)
                        .frame(width: IconicImage.slot, height: IconicImage.slot)
                }
                .badge(groups.today.count + groups.overdue.count)
                    .tag(SidebarItem.today)
                Label {
                    Text("Board")
                } icon: {
                    Image(systemName: "rectangle.split.3x1.fill").resizable().scaledToFit().foregroundStyle(Palette.purple)
                        .frame(width: IconicImage.slot, height: IconicImage.slot)
                }
                .badge(groups.inProgress.count)
                .tag(SidebarItem.board)
            }
            let bookmarks = store.bookmarks.entries.filter { $0.folder || store.index.files.contains($0.path) }
            if !bookmarks.isEmpty {
                Section("Bookmarks") {
                    ForEach(bookmarks, id: \.path) { entry in
                        Label {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(entry.title ?? (Vault.isNote(entry.path) ? Vault.title(of: entry.path) : String(entry.path.split(separator: "/").last ?? "")))
                                    .lineLimit(1)
                                if let group = entry.group {
                                    Text(group).font(.caption2).foregroundStyle(Palette.yellow.opacity(0.8))
                                }
                            }
                        } icon: {
                            if entry.folder, let logo = Vault.logo(of: entry.path, in: store.index.files).flatMap(store.url(of:)) {
                                IconicImage(icon: nil, fallback: "folder.fill", fallbackColor: Palette.accent, logo: logo)
                            } else {
                                Image(systemName: entry.folder ? "folder.fill" : "star.fill")
                                    .foregroundStyle(entry.folder ? Palette.accent : Palette.yellow)
                                    .frame(width: IconicImage.slot, height: IconicImage.slot)
                            }
                        }
                        // A bookmarked folder opens its folder note.
                        .tag(SidebarItem.bookmark(entry.folder ? entry.path + "/" + (entry.path.split(separator: "/").last.map(String.init) ?? "") + ".md" : entry.path))
                        .contextMenu {
                            Button("Remove Bookmark") { store.toggleBookmark(entry.path) }
                        }
                    }
                }
            }
            Section(store.name) {
                OutlineGroup(store.index.tree, children: \.children) { node in
                    FileRow(node: node, dropTarget: dropTarget == node.path)
                        .tag(SidebarItem.file(node.folderNote ?? node.path))
                        .contextMenu { FileMenu(path: node.folderNote ?? node.path, folder: node.isFolder ? node.path : nil, model: model) }
                        .draggable(node.path)
                        .dropDestination(for: String.self) { paths, _ in
                            drop(paths, into: node)
                        } isTargeted: { over in
                            if over, node.isFolder { dropTarget = node.path } else if dropTarget == node.path { dropTarget = nil }
                        }
                }
            }
            let tags = store.index.tagTree
            if !tags.isEmpty {
                Section(isExpanded: $tagsOpen) {
                    OutlineGroup(tags, children: \.children) { node in
                        let color = Palette.named(NSPalette.tagColor(node.tag))
                        HStack(spacing: 6) {
                            Image(systemName: "number").font(.caption.weight(.bold)).foregroundStyle(color)
                                .frame(width: IconicImage.slot, height: IconicImage.slot)
                            Text(node.name).foregroundStyle(color).lineLimit(1)
                            Spacer()
                            Text("\(node.count)").font(.caption.monospacedDigit().weight(.medium)).foregroundStyle(color)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(color.opacity(0.15), in: Capsule())
                        }
                        .tag(SidebarItem.tag(node.tag))
                    }
                } header: {
                    Text("Tags · \(store.index.tags.count)")
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// A file or folder dragged onto a folder moves into it, links and all.
    private func drop(_ paths: [String], into node: TreeNode) -> Bool {
        dropTarget = nil
        guard node.isFolder else { return false }
        let files = store.index.files
        let moving = paths.filter { path in
            let parent = path.split(separator: "/").dropLast().joined(separator: "/")
            // Only what is in the vault, and not what moves with its folder.
            let known = files.contains(path) || store.index.emptyFolders.contains(path) || files.contains { $0.hasPrefix(path + "/") }
            return known && parent != node.path && path != node.path && !node.path.hasPrefix(path + "/")
                && !paths.contains { $0 != path && path.hasPrefix($0 + "/") }
        }
        guard !moving.isEmpty else { return false }
        Task {
            for path in moving {
                do {
                    let target = node.path + "/" + String(path.split(separator: "/").last ?? "")
                    _ = try await store.move(path, to: target)
                } catch {
                    store.notice = (error as? VaultMoves.Failure)?.description ?? error.localizedDescription
                }
            }
        }
        return true
    }

    /// Selecting a row opens it; the selection follows the note on screen.
    private var selection: Binding<SidebarItem?> {
        Binding {
            if model.showsToday { return .today }
            if model.showsBoard { return .board }
            return model.path.map { .file($0) }
        } set: { item in
            switch item {
            case .today: model.showsToday = true
            case .board: model.showsBoard = true
            case .tag(let tag): model.searchTag(tag)
            case .file(let path) where store.index.files.contains(path),
                .bookmark(let path) where store.index.files.contains(path):
                if path != model.path || model.showsPage { model.open(path, store: store) }
            default: break
            }
        }
    }
}

struct FileRow: View {
    var node: TreeNode
    var dropTarget = false
    @Environment(VaultStore.self) private var store

    var body: some View {
        let icon = store.iconic.icon(for: node.path, folder: node.isFolder)
        Label {
            Text(node.name).foregroundStyle(Vault.opensInApp(node.path) || node.isFolder ? .primary : .secondary)
        } icon: {
            if node.isFolder {
                IconicImage(
                    icon: icon, fallback: node.folderNote != nil ? "folder.fill" : "folder", fallbackColor: Palette.accent,
                    logo: node.logo.flatMap(store.url(of:)))
            } else if Vault.isNote(node.path) {
                IconicImage(icon: icon, fallback: "doc.text", fallbackColor: Palette.muted)
            } else {
                IconicImage(icon: icon, fallback: attachmentSymbol, fallbackColor: Palette.purple)
            }
        }
        .padding(.vertical, dropTarget ? 2 : 0)
        .background(dropTarget ? Palette.accent.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
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
        if Vault.opensInApp(path), store.index.files.contains(path) {
            Button(store.bookmarks.contains(path) ? "Remove Bookmark" : "Bookmark") { store.toggleBookmark(path) }
            Button("Open in New Tab") { openWindow(value: TabRequest(path: path)) }
            Button("Open in Obsidian") { openInObsidian(path, store: store) }
            Divider()
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("[[\(Vault.title(of: path))]]", forType: .string)
            }
        }
        if let url = store.url(of: folder ?? path) {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            if Vault.opensInApp(path) || folder == nil {
                ShareLink(item: url)
            }
        }
        Divider()
        let item = folder ?? path
        let parent = folder ?? path.split(separator: "/").dropLast().joined(separator: "/")
        Button("New Note") { model.fileAction = .newNote(folder: parent) }
        Button("New Folder…") { model.fileAction = .newFolder(parent: parent) }
        Divider()
        Button("Rename…") { model.fileAction = .rename(item) }
        Button("Move to…") { model.fileAction = .move(item) }
        Divider()
        Button("Move to Trash…", role: .destructive) { model.fileAction = .delete(item) }
    }
}

/// Full-text search, and `#tag` for the notes that carry a tag.
struct SearchResults: View {
    @Bindable var model: WindowModel
    @Environment(VaultStore.self) private var store
    @ViewState private var hits: [SearchIndex.Hit] = []
    /// The query [hits] are for: the list never shows another one's.
    @ViewState private var searchedFor: String?
    /// Notes by name, as ⌘P finds them, at once on each key.
    @ViewState private var names: [String] = []

    private var searched: Bool { searchedFor == model.query }

    var body: some View {
        List {
            if !names.isEmpty {
                Section("Notes") {
                    ForEach(names, id: \.self) { path in
                        Button {
                            model.open(path, store: store)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: Base.isBase(path) ? "tablecells" : "doc.text").foregroundStyle(Base.isBase(path) ? Palette.green : Palette.accent)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(Vault.title(of: path)).font(.headline).lineLimit(1)
                                    Text(path.split(separator: "/").dropLast().joined(separator: " › "))
                                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu { FileMenu(path: path, model: model) }
                    }
                }
            }
            Section(searched ? "In the text · \(hits.count == 100 ? "100+" : String(hits.count))" : "Searching the text…") {
                ForEach(searched ? hits : [], id: \.path) { hit in
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
            if searched && hits.isEmpty && names.isEmpty { ContentUnavailableView.search(text: model.query) }
        }
        .onAppear { findNames() }
        .onChange(of: model.query) { findNames() }
        .task(id: "\(model.query)|\(store.revision)") { await run() }
    }

    private var firstWord: String? {
        let word = model.query.split(separator: " ").first.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: "\"#"))
        return word?.isEmpty == false ? word : nil
    }

    /// The notes whose name, aliases or folders hold the words: what a
    /// person typing a note's name is looking for, first.
    private func findNames() {
        let query = model.query.trimmingCharacters(in: .whitespaces)
        names = query.isEmpty || query.hasPrefix("#") ? [] : store.quickOpen(query, recent: model.recent, limit: 8)
    }

    private func run() async {
        let asked = model.query
        let query = model.query.trimmingCharacters(in: .whitespaces)
        if query.hasPrefix("#"), !query.contains(" ") {
            let tag = Slugs.fold(String(query.dropFirst()))
            hits = store.index.notes.values
                .filter { !store.excluded.contains($0.path) }
                .filter { $0.parsed.tags.contains { Slugs.fold($0) == tag || Slugs.fold($0).hasPrefix(tag + "/") } }
                .map { SearchIndex.Hit(path: $0.path, snippet: "") }
                .sorted { $0.path < $1.path }
            searchedFor = asked
            return
        }
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        let search = store.search
        let excluded = store.excluded
        let shown = Set(names)
        let found = await Task.detached { search.search(query).filter { !excluded.contains($0.path) && !shown.contains($0.path) } }.value
        guard !Task.isCancelled, asked == model.query else { return }
        hits = found
        searchedFor = asked
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

    /// The note's links, each once, with where it goes when it goes anywhere.
    private func outgoingLinks(_ note: NoteEntry, from path: String) -> [(target: String, path: String?, embed: Bool)] {
        var seen = Set<String>()
        return note.parsed.links.compactMap { link in
            guard !link.target.isEmpty, seen.insert(link.target).inserted else { return nil }
            let found = store.index.resolve(link.target, from: path)
            guard found != path else { return nil }
            return (link.target, found, link.embed)
        }
    }

    var body: some View {
        if !model.showsPage, let path = model.path, let note = store.index.notes[path] {
            List {
                if !note.parsed.headings.isEmpty {
                    Section("Outline") {
                        ForEach(Array(note.parsed.headings.enumerated()), id: \.offset) { _, heading in
                            Button {
                                model.open(path, heading: heading.text, store: store)
                            } label: {
                                // Each level in its heading colour, as the reader shows it.
                                HStack(spacing: 6) {
                                    RoundedRectangle(cornerRadius: 1.5)
                                        .fill(Palette.heading(heading.level))
                                        .frame(width: 3, height: heading.level <= 2 ? 14 : 10)
                                    Text(heading.text)
                                        .font(heading.level <= 2 ? .body.weight(.medium) : .callout)
                                        .foregroundStyle(heading.level <= 3 ? Palette.heading(heading.level) : .secondary)
                                        .lineLimit(1)
                                }
                                .padding(.leading, CGFloat(heading.level - 1) * 10)
                                .frame(maxWidth: .infinity, alignment: TextDirection.startsRtl(heading.text) ? .trailing : .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                let backlinks = store.index.backlinks[path] ?? []
                Section {
                    if backlinks.isEmpty {
                        Text("No note links here.").foregroundStyle(.secondary)
                    }
                    ForEach(backlinks, id: \.self) { link in
                        Button {
                            model.open(link.source, line: link.line, store: store)
                        } label: {
                            LinkRow(path: link.source, symbol: "arrow.turn.down.right", color: Palette.aqua)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    SectionTitle(title: "Backlinks", count: backlinks.count, color: Palette.aqua)
                }
                let outgoing = outgoingLinks(note, from: path)
                if !outgoing.isEmpty {
                    Section {
                        ForEach(outgoing, id: \.target) { link in
                            if let found = link.path {
                                Button { model.open(found, store: store) } label: {
                                    LinkRow(path: found, symbol: link.embed ? "photo" : "arrow.up.right", color: link.embed ? Palette.pink : Palette.accent)
                                }
                                .buttonStyle(.plain)
                            } else {
                                Label(link.target, systemImage: "link.badge.plus")
                                    .foregroundStyle(Palette.red.opacity(0.85))
                                    .lineLimit(1)
                                    .help("Not in the vault yet")
                            }
                        }
                    } header: {
                        SectionTitle(title: "Outgoing links", count: outgoing.count, color: Palette.accent)
                    }
                }
                if !note.parsed.tags.isEmpty {
                    Section {
                        FlowTags(tags: note.parsed.tags) { model.searchTag($0) }
                    } header: {
                        SectionTitle(title: "Tags", count: note.parsed.tags.count, color: Palette.pink)
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
                // The tag's own colour, the same in the reader and the editor.
                let color = Palette.named(NSPalette.tagColor(tag))
                Button("#" + tag) { action(tag) }
                    .buttonStyle(.plain)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .foregroundStyle(color)
                    .background(color.opacity(0.15), in: Capsule())
                    .overlay(Capsule().strokeBorder(color.opacity(0.3)))
            }
        }
    }
}

/// A section's name in its colour, with a count.
struct SectionTitle: View {
    var title: String
    var count: Int
    var color: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(color)
            if count > 0 {
                Text("\(count)").font(.caption2.weight(.bold).monospacedDigit()).foregroundStyle(color)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(color.opacity(0.15), in: Capsule())
            }
        }
    }
}

/// A note in a list of links: its name, its folder, a coloured mark.
struct LinkRow: View {
    var path: String
    var symbol: String
    var color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol).font(.caption.weight(.bold)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(Vault.isNote(path) ? Vault.title(of: path) : String(path.split(separator: "/").last ?? "")).lineLimit(1)
                let folder = path.split(separator: "/").dropLast().joined(separator: " › ")
                if !folder.isEmpty {
                    Text(folder).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// ⌘P: a note by its name, in a Spotlight-like panel.
struct QuickOpenView: View {
    @Bindable var model: WindowModel
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @ViewState private var selected = 0
    /// Worked out once for each keystroke, not in `body`, which SwiftUI may
    /// evaluate many times for one change.
    @ViewState private var results: [String] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title2.weight(.semibold)).foregroundStyle(Palette.accent)
                    // Escape closes the panel wherever the focus is, not only
                    // while the field has it; a panel left open would make
                    // the next ⌘P do nothing.
                    .background {
                        Button("Close") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                            .opacity(0)
                            .accessibilityHidden(true)
                    }
                TextField("Open a note by name", text: $model.switcherQuery)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($focused)
                    .onSubmit { choose(results) }
                    .onKeyPress(.downArrow) { selected = min(selected + 1, max(results.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            .padding(14)
            Divider()
            if results.isEmpty {
                // One height for the panel, always: a sheet that resizes while
                // the person types makes SwiftUI lay it out again and again.
                Text(model.switcherQuery.trimmingCharacters(in: .whitespaces).isEmpty ? "Type a note's name." : "No note is called “\(model.switcherQuery)”.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element) { index, path in
                                HStack(spacing: 10) {
                                    Image(systemName: Base.isBase(path) ? "tablecells" : "doc.text")
                                        .foregroundStyle(index == selected ? .white : Base.isBase(path) ? Palette.green : Palette.accent)
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
                                .background(
                                    index == selected
                                        ? AnyShapeStyle(LinearGradient(colors: [Palette.accent, Palette.pink], startPoint: .leading, endPoint: .trailing))
                                        : AnyShapeStyle(.clear),
                                    in: RoundedRectangle(cornerRadius: 8))
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
        .frame(width: 600, height: 420)
        .onAppear { focused = true }
        .defaultFocus($focused, true)
        // Once the field has the focus, keys go to it again; what was typed
        // before is already its text, with the cursor after it.
        .onChange(of: focused) {
            model.switcherFieldFocused = focused
            guard focused else { return }
            DispatchQueue.main.async {
                if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                }
                if model.switcherSubmit {
                    model.switcherSubmit = false
                    choose(results)
                }
            }
        }
        // A panel opened soon after the last one closed gets its focus late,
        // while the old sheet is still going away, and the first keys were
        // lost. The field asks again until it has the focus.
        .task {
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(50))
                if focused { break }
                focused = true
            }
        }
        // ⌘P again while the panel is open puts the focus back in its field.
        .onChange(of: model.quickOpenRequests) { focused = true }
        // At once on each change, not in a task that runs later: Return
        // pressed before a task ran opened a result for the old text.
        .onAppear { results = store.quickOpen(model.switcherQuery, recent: model.recent) }
        .onChange(of: model.switcherQuery) {
            results = store.quickOpen(model.switcherQuery, recent: model.recent)
            selected = 0
        }
        .onChange(of: store.revision) {
            results = store.quickOpen(model.switcherQuery, recent: model.recent)
            selected = min(selected, max(results.count - 1, 0))
        }
    }

    private func choose(_ shown: [String]) {
        // The results for the text in the field now, whatever the list shows.
        let results = shown == store.quickOpen(model.switcherQuery, recent: model.recent) ? shown : store.quickOpen(model.switcherQuery, recent: model.recent)
        if results != shown { selected = 0 }
        guard results.indices.contains(selected) else {
            // Return on an empty list ends the field's editing; the focus
            // goes back so the next key, Escape too, still reaches it.
            DispatchQueue.main.async { focused = true }
            return
        }
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
