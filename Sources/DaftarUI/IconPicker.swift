import DaftarCore
import SwiftUI

/// What the icon picker is open on.
struct IconTarget: Identifiable, Equatable {
    var path: String
    var folder: Bool
    var id: String { path }
}

/// "Set Icon…": a Lucide icon or an emoji, and one of Iconic's colours, for
/// a note or a folder. They go into Iconic's own file, so Obsidian and the
/// phone show the same icon.
struct IconPicker: View {
    var target: IconTarget
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name: String?
    @ViewState private var color: String?
    @ViewState private var emoji = ""
    @ViewState private var query = ""
    @ViewState private var started = false
    @FocusState private var searching: Bool

    /// Every icon the app can draw, by its Lucide name.
    private var icons: [String] {
        let needle = Slugs.fold(query.trimmingCharacters(in: .whitespaces))
        return IconicImage.symbols.keys
            .filter { IconicImage.known(IconicImage.symbols[$0]!) != nil }
            .filter { needle.isEmpty || Slugs.fold($0.replacingOccurrences(of: "-", with: " ")).contains(needle) }
            .sorted()
    }

    private var chosen: Iconic.Icon {
        let mark = emoji.trimmingCharacters(in: .whitespaces)
        return Iconic.Icon(name: mark.isEmpty ? name : mark, color: color)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                IconicImage(icon: chosen, fallback: target.folder ? "folder.fill" : "doc.text", fallbackColor: Palette.muted)
                    .scaleEffect(2.4)
                    .accessibilityHidden(true)
                    .frame(width: 52, height: 52)
                    .glassEffect(.regular.tint(color.flatMap(IconicImage.color)?.opacity(0.25)), in: .rect(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Set Icon").font(.title2.weight(.semibold))
                    Text(target.path).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Find an icon", text: $query).textFieldStyle(.plain).focused($searching)
                    .accessibilityLabel("Find an icon")
                Divider().frame(height: 16)
                TextField("or an emoji", text: $emoji).textFieldStyle(.plain).frame(width: 90)
                    .accessibilityLabel("Emoji")
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 6)], spacing: 6) {
                    ForEach(icons, id: \.self) { icon in
                        let on = icon == name && emoji.isEmpty
                        Button {
                            name = icon
                            emoji = ""
                        } label: {
                            Image(systemName: IconicImage.symbols[icon]!)
                                .font(.system(size: 16))
                                .foregroundStyle(on ? .white : (color.flatMap(IconicImage.color) ?? .primary))
                                .frame(width: 40, height: 36)
                                .background(on ? AnyShapeStyle((color.flatMap(IconicImage.color) ?? Palette.accent).gradient) : AnyShapeStyle(.quaternary.opacity(0.4)),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(String(icon.dropFirst("lucide-".count)))
                        .accessibilityLabel(String(icon.dropFirst("lucide-".count)).replacingOccurrences(of: "-", with: " "))
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(2)
            }
            .frame(height: 210)
            HStack(spacing: 8) {
                Text("Colour").foregroundStyle(.secondary)
                swatch(nil)
                ForEach(Iconic.colors, id: \.self) { swatch($0) }
            }
            HStack {
                Button("Remove Icon", role: .destructive) {
                    store.setIcon(target.path, icon: nil, color: nil)
                    dismiss()
                }
                .buttonStyle(.glass)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.glass)
                Button("Set") {
                    store.setIcon(target.path, icon: chosen.name, color: color)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(chosen.name == nil && color == nil)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear {
            guard !started else { return }
            started = true
            searching = true
            let now = store.iconic.icon(for: target.path, folder: target.folder)
            if let current = now?.name { if now?.isEmoji == true { emoji = current } else { name = current } }
            color = now?.color
        }
    }

    private func swatch(_ value: String?) -> some View {
        let on = color == value
        return Button { color = value } label: {
            Circle()
                .fill(value.flatMap(IconicImage.color) ?? Color.secondary.opacity(0.25))
                .overlay { if value == nil { Image(systemName: "slash.circle").foregroundStyle(.secondary) } }
                .frame(width: 20, height: 20)
                .padding(3)
                .overlay(Circle().strokeBorder(on ? Color.primary.opacity(0.7) : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help(value ?? "No colour")
        .accessibilityLabel(value.map { "Colour \($0)" } ?? "No colour")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
