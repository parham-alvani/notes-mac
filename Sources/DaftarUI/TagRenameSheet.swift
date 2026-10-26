import DaftarCore
import SwiftUI

/// "Rename Tag…": the tag, and every tag under it, takes a new name in
/// every note that has it, in the text and in the `tags` property.
struct TagRenameSheet: View {
    var target: TagTarget
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    @FocusState private var focused: Bool

    private var color: Color { Palette.named(NSPalette.tagColor(target.tag)) }
    private var clean: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
    }
    private var ready: Bool { TagRename.isValid(clean) && clean != target.tag }

    var body: some View {
        let notes = store.notes(tagged: target.tag)
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "number")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(LinearGradient(colors: [color, Palette.purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: color.opacity(0.45), radius: 8, y: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Rename #\(target.tag)").font(.title2.weight(.semibold))
                    Text(notes.count == 1 ? "1 note has this tag" : "\(notes.count) notes have this tag or one under it")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            TextField("New name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if ready { rename() } }
            if !clean.isEmpty, !TagRename.isValid(clean) {
                Label("A tag has letters, digits, _, - and /, and not only digits.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Palette.red)
            } else {
                Text("#\(target.tag)/… becomes #\(clean.isEmpty ? "…" : clean)/… too. Code and links are left as they are.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.glass)
                Button("Rename") { rename() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .tint(color)
                    .disabled(!ready)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            name = target.tag
            focused = true
        }
    }

    private func rename() {
        let count = store.renameTag(target.tag, to: clean)
        store.notice = count == 1 ? "#\(target.tag) is #\(clean) in 1 note." : "#\(target.tag) is #\(clean) in \(count) notes."
        dismiss()
    }
}
