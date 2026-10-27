import AppKit
import DaftarCore
import SwiftUI

/// The path of the open note above it: the vault, each folder, the note.
/// A folder opens a menu of what is in it, to go sideways; the note's own
/// crumb has the file commands.
struct Breadcrumb: View {
    var path: String
    @Bindable var model: WindowModel
    /// In a split window: closes this pane.
    var onClose: (() -> Void)?
    @Environment(VaultStore.self) private var store
    @ViewState private var words: Int?

    var body: some View {
        let parts = path.split(separator: "/").map(String.init)
        let folders = (0..<max(parts.count - 1, 0)).map { parts[...$0].joined(separator: "/") }
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    folderCrumb("", name: store.name, symbol: "books.vertical.fill", color: Palette.blue)
                    ForEach(folders, id: \.self) { folder in
                        separator
                        folderCrumb(folder, name: String(folder.split(separator: "/").last ?? ""), symbol: nil, color: Palette.accent)
                    }
                    separator
                    noteCrumb
                }
                .padding(.horizontal, 12)
            }
            if let words, words >= 50 {
                Text("\(words.formatted()) words · \(max(1, Int((Double(words) / 220).rounded()))) min")
                    .font(.caption).faint().lineLimit(1).fixedSize()
                    .padding(.trailing, 10)
                    .help("The words of the note, and how long it takes to read at 220 words a minute")
                    .accessibilityLabel("\(words.formatted()) words, \(max(1, Int((Double(words) / 220).rounded()))) minutes to read")
            }
            if store.periodic.period(of: path) != nil { periodicControls.padding(.trailing, 10) }
            if let onClose { PaneCloseButton(action: onClose).padding(.trailing, 8) }
        }
        .frame(height: 34)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Path of the note")
        .task(id: "\(path)\u{0}\(store.revision)") {
            words = Vault.isNote(path) ? store.text(of: path).map { EditorController.words(in: $0 as NSString, range: NSRange(location: 0, length: ($0 as NSString).length)) } : nil
        }
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [Palette.accent.opacity(0.5), Palette.pink.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
        }
    }

    /// On a periodic note: the nearest earlier and later notes of the
    /// series, and a menu of the current one and the same time in earlier years.
    private var periodicControls: some View {
        let periodic = store.periodic
        let earlier = periodic.nearest(store.index.files, from: path, step: -1)
        let later = periodic.nearest(store.index.files, from: path, step: 1)
        let years = periodic.yearsAgo(store.index.files, from: path)
        return HStack(spacing: 2) {
            Button { if let earlier { model.open(earlier, store: store) } } label: { Image(systemName: "chevron.left") }
                .disabled(earlier == nil)
                .accessibilityLabel(earlier.map { "Previous \(periodic.period.noun): \(Vault.title(of: $0))" } ?? "No earlier note")
                .help(earlier.map { "Previous: \(Vault.title(of: $0)) (⌥⌘←)" } ?? "No earlier note")
            Menu {
                Button(periodic.period.current) { model.openPeriodicNote(store: store) }
                if !years.isEmpty {
                    Section("Earlier years") {
                        ForEach(years, id: \.path) { year in
                            Button("\(year.years == 1 ? "A year ago" : "\(year.years) years ago"): \(Vault.title(of: year.path))") {
                                model.open(year.path, store: store)
                            }
                        }
                    }
                }
            } label: {
                Label(periodic.period.noun, systemImage: "calendar").font(.callout)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            Button { if let later { model.open(later, store: store) } } label: { Image(systemName: "chevron.right") }
                .disabled(later == nil)
                .accessibilityLabel(later.map { "Next \(periodic.period.noun): \(Vault.title(of: $0))" } ?? "No later note")
                .help(later.map { "Next: \(Vault.title(of: $0)) (⌥⌘→)" } ?? "No later note")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Palette.aqua)
    }

    private var separator: some View {
        Image(systemName: "chevron.compact.right").font(.system(size: 11, weight: .bold)).faint()
            .accessibilityHidden(true)
    }

    /// A folder: its icon and name, and a menu of what it holds.
    private func folderCrumb(_ folder: String, name: String, symbol: String?, color: Color) -> some View {
        Menu {
            let note = folder.isEmpty ? nil : folder + "/" + name + ".md"
            if let note, store.index.files.contains(note) {
                Button { model.open(note, store: store) } label: { Label("Open \(name)", systemImage: "doc.richtext") }
                Divider()
            }
            ForEach(store.folder(folder) ?? [], id: \.path) { node in
                entry(node)
            }
        } label: {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).foregroundStyle(color)
                } else {
                    IconicImage(
                        icon: store.iconic.icon(for: folder, folder: true), fallback: "folder.fill", fallbackColor: color,
                        logo: Vault.logo(of: folder, in: store.index.files).flatMap(store.url(of:))
                    )
                    .frame(width: 14, height: 14)
                }
                Text(name).foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.callout)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(folder.isEmpty ? "What is at the top of \(store.name)" : "What is in \(name)")
        .accessibilityLabel(folder.isEmpty ? "Vault \(name)" : "Folder \(name)")
        .accessibilityHint("Shows what is in it")
    }

    /// One row of a folder's menu: a note opens, a folder is a submenu.
    private func entry(_ node: TreeNode) -> AnyView {
        if node.isFolder {
            AnyView(Menu {
                if let note = node.folderNote {
                    Button("Open \(node.name)") { model.open(note, store: store) }
                    Divider()
                }
                ForEach(node.children ?? [], id: \.path) { entry($0) }
            } label: {
                Label(node.name, systemImage: node.logo == nil ? "folder" : "photo")
            })
        } else {
            AnyView(Button {
                model.open(node.path, store: store)
            } label: {
                Label(node.name, systemImage: node.path == path ? "checkmark" : Vault.isNote(node.path) ? "doc.text" : Base.isBase(node.path) ? "tablecells" : Canvas.isCanvas(node.path) ? "rectangle.on.rectangle" : Vault.isImage(node.path) ? "photo" : "paperclip")
            })
        }
    }

    /// The note itself: its name, bold, and the commands on the file.
    private var noteCrumb: some View {
        Menu {
            Button("Set Icon…") { model.iconTarget = IconTarget(path: path, folder: false) }
            Button("Rename…") { model.fileAction = .rename(path) }
            Button("Move to…") { model.fileAction = .move(path) }
            Button(store.bookmarks.contains(path) ? "Remove Bookmark" : "Bookmark") { store.toggleBookmark(path) }
            Divider()
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("[[\(Vault.title(of: path))]]", forType: .string)
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
            if let url = store.url(of: path) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                if Vault.isImage(path) {
                    Button("Open in Default App") { NSWorkspace.shared.open(url) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                IconicImage(
                    icon: store.iconic.icon(for: path, folder: false),
                    fallback: Base.isBase(path) ? "tablecells" : Canvas.isCanvas(path) ? "rectangle.on.rectangle" : Vault.isImage(path) ? "photo" : "doc.text.fill", fallbackColor: Palette.pink)
                    .frame(width: 14, height: 14)
                Text(Vault.isNote(path) ? Vault.title(of: path) : String(path.split(separator: "/").last ?? ""))
                    .fontWeight(.semibold).lineLimit(1)
                if store.bookmarks.contains(path) {
                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(Palette.yellow)
                        .transition(.symbolEffect(.appear))
                }
            }
            .font(.callout)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .glassEffect(.regular.tint(Palette.accent.opacity(0.25)).interactive(), in: .capsule)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Vault.isNote(path) ? Vault.title(of: path) : String(path.split(separator: "/").last ?? ""))
        .accessibilityValue(store.bookmarks.contains(path) ? "Bookmarked" : "")
        .accessibilityHint("The commands on this note")
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
