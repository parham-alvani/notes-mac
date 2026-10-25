import AppKit
import DaftarCore
import SwiftUI

/// The sheet of a file command: a new note or folder, a rename, a move or a
/// delete. Each has its own colour and icon, and says what will happen to
/// the links before anything is written.
struct FileActionSheet: View {
    var action: FileAction
    var model: WindowModel
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    @ViewState private var folderQuery = ""
    @ViewState private var folder: String?
    @ViewState private var error: String?
    @ViewState private var working = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                badge
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title2.weight(.semibold))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            content
            if let note = linkNote {
                Label(note, systemImage: "link").font(.callout).foregroundStyle(color)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Palette.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.glass)
                Button(primary) { Task { await commit() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .tint(color)
                    .disabled(!ready || working)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear(perform: prepare)
    }

    // MARK: Look

    private var badge: some View {
        Image(systemName: symbol)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 48, height: 48)
            .background(
                LinearGradient(colors: [color, secondColor], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: color.opacity(0.45), radius: 8, y: 3)
    }

    private var symbol: String {
        switch action {
        case .newNote: "square.and.pencil"
        case .newFolder: "folder.badge.plus"
        case .rename: "character.cursor.ibeam"
        case .move: "folder.badge.gearshape"
        case .delete: "trash"
        case .extract: "rectangle.portrait.and.arrow.right"
        }
    }

    private var color: Color {
        switch action {
        case .newNote: Palette.accent
        case .newFolder: Palette.yellow
        case .rename: Palette.blue
        case .move: Palette.purple
        case .delete: Palette.red
        case .extract: Palette.pink
        }
    }

    private var secondColor: Color {
        switch action {
        case .newNote: Palette.pink
        case .newFolder: Palette.accent
        case .rename: Palette.green
        case .move: Palette.blue
        case .delete: Palette.pink
        case .extract: Palette.purple
        }
    }

    private var title: String {
        switch action {
        case .newNote: "New Note"
        case .newFolder: "New Folder"
        case .rename(let path): store.index.files.contains(path) ? "Rename File" : "Rename Folder"
        case .move(let path): "Move “\(shortName(path))”"
        case .delete(let path): "Move “\(shortName(path))” to the Trash?"
        case .extract: "Extract to a New Note"
        }
    }

    private var subtitle: String {
        switch action {
        case .newNote(let folder), .newFolder(let folder), .extract(let folder, _): "In " + where_(folder)
        case .rename(let path), .move(let path), .delete(let path): path
        }
    }

    private var primary: String {
        switch action {
        case .newNote, .newFolder: "Create"
        case .rename: "Rename"
        case .move: "Move"
        case .delete: "Move to Trash"
        case .extract: "Extract"
        }
    }

    private func where_(_ folder: String) -> String {
        folder.isEmpty ? store.name : folder.split(separator: "/").joined(separator: " › ")
    }

    private func shortName(_ path: String) -> String {
        let name = String(path.split(separator: "/").last ?? "")
        return Vault.isNote(name) ? String(name.dropLast(3)) : name
    }

    // MARK: Fields

    @ViewBuilder private var content: some View {
        switch action {
        case .delete:
            Text("The Trash keeps it, so it can come back, and git keeps every version that was committed.")
                .foregroundStyle(.secondary)
        case .move:
            folderPicker
        case .extract(_, let text):
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .focused($focused)
                .onSubmit { Task { await commit() } }
                .onChange(of: name) { error = nil }
            Text(text.split(whereSeparator: \.isNewline).prefix(4).joined(separator: "\n"))
                .font(.callout).foregroundStyle(.secondary).lineLimit(4)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.pink.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(Palette.pink).frame(width: 3) }
            Text("The selection becomes a link to the new note.").font(.caption).foregroundStyle(.secondary)
        default:
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .focused($focused)
                .onSubmit { Task { await commit() } }
                .onChange(of: name) { error = nil }
        }
    }

    private var folderPicker: some View {
        VStack(spacing: 8) {
            TextField("Find a folder", text: $folderQuery)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(folders, id: \.self) { candidate in
                        let chosen = candidate == folder
                        HStack(spacing: 8) {
                            Image(systemName: candidate.isEmpty ? "tray.full.fill" : "folder.fill")
                                .foregroundStyle(chosen ? .white : (candidate.isEmpty ? Palette.blue : Palette.accent))
                            Text(where_(candidate)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                        }
                        .foregroundStyle(chosen ? .white : .primary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(chosen ? color : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                        .onTapGesture { folder = candidate }
                        .onTapGesture(count: 2) {
                            folder = candidate
                            Task { await commit() }
                        }
                    }
                }
            }
            .frame(height: 240)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Every folder the item can go to, the vault itself first.
    private var folders: [String] {
        guard case .move(let path) = action else { return [] }
        var all = Set<String>([""]).union(store.index.emptyFolders)
        for file in store.index.files {
            let parts = file.split(separator: "/").dropLast()
            for end in parts.indices { all.insert(parts[...end].joined(separator: "/")) }
        }
        let parent = path.split(separator: "/").dropLast().joined(separator: "/")
        let needle = Slugs.fold(folderQuery.trimmingCharacters(in: .whitespaces))
        return all.filter { candidate in
            candidate != parent && candidate != path && !candidate.hasPrefix(path + "/")
                && (needle.isEmpty || Slugs.fold(candidate).contains(needle))
        }
        .sorted { $0.isEmpty || (!$1.isEmpty && $0.localizedStandardCompare($1) == .orderedAscending) }
    }

    /// How many notes link here, so the person knows what follows the change.
    private var linkNote: String? {
        let path: String
        switch action {
        case .rename(let p), .move(let p), .delete(let p): path = p
        default: return nil
        }
        let sources = Set(store.index.backlinks.filter { $0.key == path || $0.key.hasPrefix(path + "/") }
            .flatMap { $0.value.map(\.source) })
            .subtracting(store.index.files.filter { $0 == path || $0.hasPrefix(path + "/") })
        guard !sources.isEmpty else { return nil }
        let notes = sources.count == 1 ? "1 note links here" : "\(sources.count) notes link here"
        if case .delete = action { return notes + "; those links will show as missing." }
        return notes + "; the links follow the change."
    }

    private var ready: Bool {
        switch action {
        case .delete: true
        case .move: folder != nil
        default: VaultMoves.isValidName(name)
        }
    }

    private func prepare() {
        switch action {
        case .newNote(let folder):
            name = shortName(VaultMoves.freeName("Untitled", in: folder, files: store.index.files))
        case .newFolder(let parent):
            name = shortName(VaultMoves.freeName("New Folder", ext: "", in: parent, files: store.index.files.union(store.index.emptyFolders)))
        case .rename(let path):
            name = shortName(path)
        case .extract(_, let text):
            name = EditorCommands.extractName(from: text)
        default:
            break
        }
        focused = true
    }

    // MARK: Doing it

    private func commit() async {
        guard ready, !working else { return }
        working = true
        defer { working = false }
        do {
            switch action {
            case .newNote(let folder):
                let path = try store.createNote(named: name, in: folder)
                model.open(path, store: store)
                model.editing = true
            case .newFolder(let parent):
                _ = try store.createFolder(named: name, in: parent)
            case .rename(let path):
                let parent = path.split(separator: "/").dropLast().joined(separator: "/")
                let isFile = store.index.files.contains(path)
                var newName = name.trimmingCharacters(in: .whitespaces)
                if isFile, Vault.isNote(path) { newName = VaultMoves.noteName(newName) }
                let target = (parent.isEmpty ? "" : parent + "/") + newName
                guard VaultMoves.isValidName(name) else { throw VaultMoves.Failure.badName(name) }
                _ = try await store.move(path, to: target)
            case .move(let path):
                guard let folder else { return }
                let target = (folder.isEmpty ? "" : folder + "/") + String(path.split(separator: "/").last ?? "")
                _ = try await store.move(path, to: target)
            case .delete(let path):
                try await store.delete(path)
            case .extract(let folder, let text):
                let path = try store.createNote(named: name, in: folder, text: EditorCommands.extractBody(text))
                // A bare name when no other file has it, else the path.
                let title = Vault.title(of: path)
                let taken = store.index.files.contains { $0 != path && Vault.isNote($0) && Vault.title(of: $0).lowercased() == title.lowercased() }
                model.extractReplace?("[[\(taken ? String(path.dropLast(3)) : title)]]")
                model.extractReplace = nil
            }
            dismiss()
        } catch {
            self.error = (error as? VaultMoves.Failure)?.description ?? error.localizedDescription
        }
    }
}
