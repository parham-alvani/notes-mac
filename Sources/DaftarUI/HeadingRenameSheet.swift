import DaftarCore
import SwiftUI

/// "Rename Heading…": the heading the cursor is in takes a new name, and
/// every link to it in the vault follows, as the list shows.
struct HeadingRenameSheet: View {
    var target: HeadingTarget
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    @ViewState private var notes: [HeadingRename.NoteEdits] = []
    /// The name [notes] are for.
    @ViewState private var listed: String?
    @FocusState private var focused: Bool

    private var heading: Heading { target.headings[target.index] }
    private var clean: String { name.trimmingCharacters(in: .whitespaces) }
    private var ready: Bool { !clean.isEmpty && clean != heading.text && listed == clean }
    private var change: HeadingRename.Change {
        HeadingRename.Change(path: target.path, headings: target.headings, renames: [target.index: clean])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "number.square")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(LinearGradient(colors: [Palette.heading(heading.level), Palette.accent], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Rename Heading").font(.title2.weight(.semibold))
                    Text("\(String(repeating: "#", count: heading.level)) \(heading.text) in \(Vault.title(of: target.path))")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            TextField("New name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .accessibilityLabel("New name of the heading")
                .onSubmit { if ready { rename() } }
            Text(status).font(.callout).foregroundStyle(.secondary)
            HeadingEditList(notes: listed == clean ? notes : [])
                .frame(height: 260)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.glass)
                Button("Rename") { rename() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .tint(Palette.accent)
                    .disabled(!ready)
            }
        }
        .padding(24)
        .frame(width: 720)
        .onAppear {
            name = heading.text
            focused = true
        }
        // A short wait after each key.
        .task(id: clean) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, !clean.isEmpty, clean != heading.text else { return }
            let found = await store.headingEdits(change, retitle: true)
            guard !Task.isCancelled else { return }
            notes = found
            listed = clean
        }
    }

    private var status: String {
        if clean.isEmpty || clean == heading.text { return "Type the new name." }
        if listed != clean { return "Looking for links…" }
        let links = notes.reduce(0) { $0 + $1.edits.reduce(0) { $0 + $1.links } }
        let others = notes.filter { $0.path != target.path }.count
        if links <= 0 { return "No link names this heading: only the heading changes." }
        return (links == 1 ? "1 link changes" : "\(links) links change") + " with it"
            + (others == 0 ? ", in this note." : ", in \(Spoken.count(others, "other note")).") + " Code is left as it is."
    }

    private func rename() {
        let shown = notes
        Task {
            await store.flushEditors()
            let done = store.applyHeadingEdits(shown)
            store.notice = done.refused.isEmpty
                ? "“\(heading.text)” is “\(clean)”."
                : "The heading was not renamed in \(done.refused.map(Vault.title(of:)).joined(separator: ", ")): it changed after the preview."
            dismiss()
        }
    }
}

/// After a heading is renamed in the editor: "Update 3 links in 2
/// notes?", with the lines, Update and Not Now. It does not stop the typing.
struct HeadingLinksBanner: View {
    var change: HeadingRename.Change
    var onDone: () -> Void
    @Environment(VaultStore.self) private var store
    @ViewState private var notes: [HeadingRename.NoteEdits]?
    @ViewState private var expanded = false

    static func question(_ notes: [HeadingRename.NoteEdits], of path: String) -> String {
        let links = notes.reduce(0) { $0 + $1.edits.reduce(0) { $0 + $1.links } }
        if notes.count == 1, notes[0].path == path { return links == 1 ? "Update 1 link in this note?" : "Update \(links) links in this note?" }
        return "Update \(links == 1 ? "1 link" : "\(links) links") in \(notes.count == 1 ? "1 note" : "\(notes.count) notes")?"
    }

    var body: some View {
        // A stack, not a group: the task must run while there is nothing to show.
        VStack(spacing: 0) {
            if let notes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "link").foregroundStyle(Palette.accent).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.question(notes, of: change.path)).font(.callout.weight(.semibold))
                            Text(renamedText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button { withMotion { expanded.toggle() } } label: {
                            Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        }
                        .buttonStyle(.borderless)
                        .help(expanded ? "Hide the links" : "Show the links")
                        .accessibilityLabel(expanded ? "Hide the links" : "Show the links")
                        Button("Not Now") { onDone() }.buttonStyle(.glass)
                        Button("Update") { update(notes) }.buttonStyle(.glassProminent).tint(Palette.accent)
                    }
                    if expanded { HeadingEditList(notes: notes).frame(height: 220) }
                }
                .padding(12)
                .frame(maxWidth: 640)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(16)
                .accessibilityElement(children: .contain)
                .onAppear { announce(Self.question(notes, of: change.path)) }
            }
        }
        .task {
            let found = await store.headingEdits(change)
            if found.isEmpty { return onDone() }
            notes = found
        }
    }

    private var renamedText: String {
        change.renames.sorted { $0.key < $1.key }.map { "“\(change.headings[$0.key].text)” is now “\($0.value)”" }.joined(separator: ", ")
    }

    private func update(_ shown: [HeadingRename.NoteEdits]) {
        Task {
            await store.flushEditors()
            let done = store.applyHeadingEdits(shown)
            let links = done.replacements == 1 ? "1 link" : "\(done.replacements) links"
            store.notice = done.refused.isEmpty
                ? "\(links) updated."
                : "\(links) updated. Not changed, because they changed after the preview: " + done.refused.map(Vault.title(of:)).joined(separator: ", ")
            onDone()
        }
    }
}

/// The lines a heading rename changes, by note, each before and after, in
/// the rows of Replace in Vault.
struct HeadingEditList: View {
    var notes: [HeadingRename.NoteEdits]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(notes) { note in
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text").foregroundStyle(Palette.blue).accessibilityHidden(true)
                        Text(Vault.title(of: note.path)).font(.headline).lineLimit(1)
                        Text(note.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(note.edits.count)").font(.caption.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Palette.accent.opacity(0.18), in: Capsule())
                            .accessibilityLabel(Spoken.count(note.edits.count, "line", plural: "lines"))
                    }
                    .padding(.top, 4)
                    ForEach(note.edits) { edit in
                        VStack(spacing: 0) {
                            DiffRow(kind: .removed, old: edit.line + 1, new: nil, text: Text(edit.before))
                            DiffRow(kind: .added, old: nil, new: edit.line + 1, text: Text(edit.after))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(.leading, 22)
                    }
                }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
