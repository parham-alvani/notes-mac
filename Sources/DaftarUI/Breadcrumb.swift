import AppKit
import DaftarCore
import SwiftUI

/// The path of the open note above it: the vault, each folder, the note.
/// A folder opens a menu of what is in it, to go sideways; the note's own
/// crumb has the file commands.
struct Breadcrumb: View {
    var path: String
    @Bindable var model: WindowModel
    @Environment(VaultStore.self) private var store

    var body: some View {
        let parts = path.split(separator: "/").map(String.init)
        let folders = (0..<max(parts.count - 1, 0)).map { parts[...$0].joined(separator: "/") }
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
        .frame(height: 34)
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [Palette.accent.opacity(0.5), Palette.pink.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
        }
    }

    private var separator: some View {
        Image(systemName: "chevron.compact.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.tertiary)
    }

    /// A folder: its icon and name, and a menu of what it holds.
    private func folderCrumb(_ folder: String, name: String, symbol: String?, color: Color) -> some View {
        Menu {
            let note = folder.isEmpty ? nil : folder + "/" + name + ".md"
            if let note, store.index.files.contains(note) {
                Button { model.open(note, store: store) } label: { Label("Open \(name)", systemImage: "doc.richtext") }
                Divider()
            }
            ForEach(store.index.folder(folder) ?? [], id: \.path) { node in
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
                Label(node.name, systemImage: node.path == path ? "checkmark" : Vault.isNote(node.path) ? "doc.text" : Base.isBase(node.path) ? "tablecells" : "paperclip")
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
            }
        } label: {
            HStack(spacing: 5) {
                IconicImage(
                    icon: store.iconic.icon(for: path, folder: false),
                    fallback: Base.isBase(path) ? "tablecells" : "doc.text.fill", fallbackColor: Palette.pink)
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
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
