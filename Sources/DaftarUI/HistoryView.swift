import AppKit
import DaftarCore
import SwiftUI

/// The note's history in the vault's repository, as obsidian-git's
/// history view shows it: each commit that changed the note, newest first,
/// and the lines it added and removed. An older text can be restored; the
/// restore is an edit like any other, and the next sync commits it.
struct HistorySheet: View {
    var model: WindowModel
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @ViewState private var revisions: [Git.Revision] = []
    @ViewState private var loading = true
    /// The text of each commit, by its hash, once read.
    @ViewState private var texts: [String: String] = [:]
    /// The working copy differs from the last commit.
    @ViewState private var uncommitted = false
    @ViewState private var selection: String?
    @ViewState private var whole = false
    @ViewState private var confirmRestore = false

    private static let working = "working"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .top, spacing: 14) {
                list.frame(width: 280)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Picker("", selection: $whole) {
                    Text("Changes").tag(false)
                    Text("Whole Note").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button("Restore This Version…") { confirmRestore = true }
                    .buttonStyle(.glass)
                    .disabled(selection == nil || selection == Self.working || text(of: selection) == nil)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.glassProminent)
            }
        }
        .padding(22)
        .frame(width: 920, height: 620)
        .task { await load() }
        .confirmationDialog("Restore this version of the note?", isPresented: $confirmRestore) {
            Button("Restore") { restore() }
        } message: {
            Text("The note's text becomes the text of this commit. The next sync commits the change, so the text of now stays in the history.")
        }
    }

    private var path: String? { model.showsPage ? nil : model.path }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(LinearGradient(colors: [Palette.aqua, Palette.blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("History").font(.title3.weight(.semibold))
                Text(path.map(Vault.title(of:)) ?? "No note").font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !revisions.isEmpty {
                Text(revisions.count == 1 ? "1 commit" : "\(revisions.count) commits").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: The commits

    private var list: some View {
        List(selection: $selection) {
            if uncommitted {
                row(title: "Not committed yet", detail: "The text on disk", symbol: "pencil.circle.fill", color: Palette.accent)
                    .tag(Self.working)
            }
            ForEach(revisions) { revision in
                // The vault's commits all say "update notes @ <time> on <host>": the date names a commit better.
                row(title: revision.date.formatted(date: .abbreviated, time: .shortened), detail: "\(revision.author) · \(revision.subject)",
                    symbol: revision.path == revisions.first?.path ? "circle.fill" : "arrow.right.circle.fill",
                    color: revision.path == revisions.first?.path ? Palette.blue : Palette.purple)
                    .help(revision.path == revisions.first?.path ? "\(revision.subject)\n\(revision.hash)" : "\(revision.subject)\n\(revision.hash)\nThe note was \(revision.path) then.")
                    .tag(revision.hash)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if loading {
                ProgressView()
            } else if revisions.isEmpty {
                ContentUnavailableView(store.isRepository ? "No history" : "Not a repository", systemImage: "clock",
                    description: Text(store.isRepository ? "No commit has this note yet." : "The vault is not a Git repository, so it keeps no history."))
            }
        }
        .onChange(of: selection) { _, _ in Task { await loadSelection() } }
    }

    private func row(title: String, detail: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.caption).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: The lines

    @ViewBuilder private var detail: some View {
        if let selection, let new = text(of: selection) {
            let old = parentText(of: selection)
            if whole {
                ScrollView {
                    Text(new).font(Font(Fonts.code(size: 12))).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            } else if let old {
                let lines = LineDiff.lines(from: old, to: new)
                let counts = LineDiff.counts(lines)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text("+\(counts.added)").foregroundStyle(Palette.green)
                        Text("−\(counts.removed)").foregroundStyle(Palette.red)
                        if let revision = revisions.first(where: { $0.hash == selection }), let parent = parent(of: selection), parent.path != revision.path {
                            Text("moved from \(parent.path)").foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption.monospacedDigit().weight(.semibold))
                    DiffLines(hunks: LineDiff.hunks(lines))
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if selection != nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Choose a commit", systemImage: "arrow.left", description: Text("Its changes to the note show here."))
        }
    }

    /// The commit before [id], or nil for the first one.
    private func parent(of id: String) -> Git.Revision? {
        if id == Self.working { return revisions.first }
        guard let index = revisions.firstIndex(where: { $0.hash == id }), index + 1 < revisions.count else { return nil }
        return revisions[index + 1]
    }

    private func text(of id: String?) -> String? {
        guard let id else { return nil }
        if id == Self.working { return path.flatMap { store.text(of: $0) } }
        return texts[id]
    }

    /// The text before [id]'s change: empty for the commit that made the note.
    private func parentText(of id: String) -> String? {
        guard let parent = parent(of: id) else { return "" }
        return texts[parent.hash]
    }

    private func load() async {
        defer { loading = false }
        guard let path else { return }
        revisions = await store.history(of: path)
        if let last = revisions.first, let text = await store.text(of: last) {
            texts[last.hash] = text
            uncommitted = store.text(of: path).map { $0 != text } ?? false
        }
        selection = uncommitted ? Self.working : revisions.first?.hash
        await loadSelection()
    }

    private func loadSelection() async {
        guard let selection else { return }
        for id in [selection, parent(of: selection)?.hash].compactMap({ $0 }) where id != Self.working && texts[id] == nil {
            if let revision = revisions.first(where: { $0.hash == id }), let text = await store.text(of: revision) { texts[id] = text }
        }
    }

    private func restore() {
        guard let path, let selection, selection != Self.working, let text = texts[selection] else { return }
        do {
            try store.write(text, to: path)
            let date = revisions.first { $0.hash == selection }?.date.formatted(date: .abbreviated, time: .shortened) ?? selection
            store.notice = "\(Vault.title(of: path)) has its text of \(date) again."
            dismiss()
        } catch {
            store.notice = "The note could not be restored: \(error.localizedDescription)"
        }
    }
}

/// The changed lines with the lines around them, as `git diff` shows them.
private struct DiffLines: View {
    var hunks: [[LineDiff.Line]]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if hunks.isEmpty {
                    Text("This commit did not change the note's text.").foregroundStyle(.secondary).padding(10)
                }
                ForEach(hunks.indices, id: \.self) { index in
                    if index > 0 {
                        Text("⋯").foregroundStyle(.tertiary).padding(.vertical, 4).padding(.leading, 10)
                    }
                    ForEach(Array(hunks[index].enumerated()), id: \.offset) { _, line in
                        row(line)
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ line: LineDiff.Line) -> some View {
        DiffRow(kind: line.kind, old: line.old, new: line.new, text: Text(line.text.isEmpty ? " " : line.text))
    }
}

/// One line of a diff: its numbers, `+` or `−`, and the text in green or
/// red. "Replace in Vault" shows its before and after with it too.
struct DiffRow: View {
    var kind: LineDiff.Kind
    var old: Int?
    var new: Int?
    var text: Text

    var body: some View {
        let color: Color? = switch kind {
        case .added: Palette.green
        case .removed: Palette.red
        case .same: nil
        }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(old.map(String.init) ?? "").frame(width: 34, alignment: .trailing).foregroundStyle(.tertiary)
            Text(new.map(String.init) ?? "").frame(width: 34, alignment: .trailing).foregroundStyle(.tertiary)
            Text(kind == .added ? "+" : kind == .removed ? "−" : "").foregroundStyle(color ?? .secondary).frame(width: 12)
            text.foregroundStyle(color ?? .primary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Font(Fonts.code(size: 12)))
        .padding(.horizontal, 8).padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.map { $0.opacity(0.12) } ?? Color.clear)
    }
}
