import AppKit
import DaftarCore
import SwiftUI

/// A pull that stopped on a conflict: the files it stopped on, and for a
/// note each conflict with the remote's lines beside the person's. Git's
/// "ours" and "theirs" are swapped in a rebase, so this sheet never says
/// them: it says "On the remote" and "Your change".
struct ConflictSheet: View {
    var model: WindowModel
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @ViewState private var selection: String?
    /// Each note's text as it was read, with its conflict marks.
    @ViewState private var texts: [String: String] = [:]
    /// The side chosen for each conflict of each note, by its number.
    @ViewState private var choices: [String: [Int: ConflictText.Choice]] = [:]
    /// The side kept of a whole file that has no marks to choose in.
    @ViewState private var whole: [String: Git.Resolution] = [:]
    @ViewState private var confirmAbort = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .top, spacing: 14) {
                list.frame(width: 260)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Button("Abort Sync…", role: .destructive) { confirmAbort = true }
                    .buttonStyle(.glass)
                    .help("Stop the pull. Your commits stay as they were before it, and the next sync pulls again.")
                Spacer()
                Text(remaining == 0 ? "Every file is resolved." : remaining == 1 ? "1 file to resolve" : "\(remaining) files to resolve")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Later") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.glass)
                Button("Finish Sync") { Task { await finish() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(remaining > 0 || store.syncing)
            }
        }
        .padding(22)
        .frame(width: 980, height: 660)
        .task { await load() }
        .onChange(of: store.conflicts) { _, _ in Task { await load() } }
        .confirmationDialog("Abort the sync?", isPresented: $confirmAbort) {
            Button("Abort Sync", role: .destructive) {
                Task {
                    await store.abortConflicts()
                    if !store.rebasing { dismiss() }
                }
            }
        } message: {
            Text("The pull stops and your notes are as they were before it. Your changes stay committed on this Mac, and the next sync tries the pull again.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(LinearGradient(colors: [Palette.accent, Palette.red], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Sync Conflicts").font(.title3.weight(.semibold))
                Text("These files changed on the remote and on this Mac. Choose what to keep; the sync waits until you finish.")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
        }
    }

    // MARK: The files

    private var list: some View {
        List(selection: $selection) {
            ForEach(store.conflicts) { file in
                HStack(spacing: 8) {
                    Image(systemName: resolved(file) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(resolved(file) ? Palette.green : Palette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Vault.title(of: file.path)).lineLimit(1)
                        Text(status(of: file)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
                .help(file.path)
                .tag(file.path)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if store.conflicts.isEmpty {
                ContentUnavailableView("Nothing to choose", systemImage: "checkmark.circle",
                    description: Text(store.rebasing ? "Every file is resolved. Finish the sync to go on." : "No sync is stopped."))
            }
        }
    }

    private func status(of file: Git.Conflicted) -> String {
        if let resolution = whole[file.path] { return resolution == .keepRemote ? "Keep the remote's" : "Keep yours" }
        if usesMarks(file) {
            let count = conflictCount(file.path)
            if count == 0 { return "No marks left" }
            let chosen = choices[file.path]?.count ?? 0
            return "\(chosen) of \(count) chosen"
        }
        return "\(describe(file.remote)) on the remote, \(describe(file.mine)) here"
    }

    private func describe(_ side: Git.Side) -> String {
        switch side {
        case .changed: "changed"
        case .added: "added"
        case .deleted: "deleted"
        }
    }

    // MARK: One file

    @ViewBuilder private var detail: some View {
        if let path = selection, let file = store.conflicts.first(where: { $0.path == path }) {
            if usesMarks(file), let text = texts[path] {
                noteDetail(file, text: text)
            } else {
                wholeFileDetail(file)
            }
        } else {
            ContentUnavailableView("Choose a file", systemImage: "arrow.left", description: Text("Its conflicts show here."))
        }
    }

    private func noteDetail(_ file: Git.Conflicted, text: String) -> some View {
        let parts = ConflictText.parse(text)
        let numbered = Array(parts.enumerated())
        let count = conflictCount(file.path)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(file.path).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Spacer()
                if count > 0 {
                    choiceButtons(chosen: allChosen(file.path, count: count)) { choice in
                        choices[file.path] = Dictionary(uniqueKeysWithValues: (0..<count).map { ($0, choice) })
                    }
                }
                Button("Edit") { edit(file.path) }
                    .buttonStyle(.glass)
                    .help("Open the note in the editor with the conflict marks, to write the text yourself")
            }
            if count == 0 {
                ContentUnavailableView("No conflict marks", systemImage: "checkmark.circle",
                    description: Text("The note has no conflict marks left. It is kept as it is."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(numbered, id: \.offset) { offset, part in
                            if case let .conflict(conflict) = part {
                                let number = conflictNumber(parts, at: offset)
                                hunk(conflict, number: number, of: count, path: file.path, before: context(parts, before: offset))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func hunk(_ conflict: ConflictText.Conflict, number: Int, of count: Int, path: String, before: String) -> some View {
        let chosen = choices[path]?[number]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Conflict \(number + 1) of \(count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                choiceButtons(chosen: chosen) { choices[path, default: [:]][number] = $0 }
            }
            if !before.isEmpty {
                Text(before).font(Font(Fonts.code(size: 12))).foregroundStyle(.tertiary).lineLimit(2)
            }
            HStack(alignment: .top, spacing: 10) {
                side("On the remote", text: conflict.remote, color: Palette.blue, kept: chosen == .remote || chosen == .both)
                side("Your change", text: conflict.mine, color: Palette.accent, kept: chosen == .mine || chosen == .both)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func side(_ title: String, text: String, color: Color, kept: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(color)
                if kept { Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(color) }
            }
            Text(text.isEmpty ? "(nothing)" : String(text.dropLast(text.hasSuffix("\n") ? 1 : 0)))
                .font(Font(Fonts.code(size: 12)))
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(color.opacity(kept ? 0.16 : 0.06), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(kept ? 0.6 : 0), lineWidth: 1))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func choiceButtons(chosen: ConflictText.Choice?, choose: @escaping (ConflictText.Choice) -> Void) -> some View {
        HStack(spacing: 6) {
            choiceButton("Keep Remote", .remote, chosen: chosen, choose: choose, help: "Keep the remote's lines")
            choiceButton("Keep Mine", .mine, chosen: chosen, choose: choose, help: "Keep your lines")
            choiceButton("Keep Both", .both, chosen: chosen, choose: choose, help: "Keep the remote's lines, then yours")
        }
    }

    @ViewBuilder
    private func choiceButton(_ title: String, _ choice: ConflictText.Choice, chosen: ConflictText.Choice?,
        choose: @escaping (ConflictText.Choice) -> Void, help: String) -> some View {
        if chosen == choice {
            Button(title) { choose(choice) }.buttonStyle(.glassProminent).controlSize(.small).help(help)
        } else {
            Button(title) { choose(choice) }.buttonStyle(.glass).controlSize(.small).help(help)
        }
    }

    private func wholeFileDetail(_ file: Git.Conflicted) -> some View {
        let chosen = whole[file.path]
        return VStack(alignment: .leading, spacing: 14) {
            Text(file.path).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            Text(file.hasMarks
                ? "Daftar shows the lines of notes only. Keep one side of this file whole."
                : "One side deleted this file and the other changed it. Keep one side: keeping a deletion deletes the file.")
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 10) {
                wholeSide("On the remote", side: file.remote, color: Palette.blue, kept: chosen == .keepRemote)
                wholeSide("Your change", side: file.mine, color: Palette.accent, kept: chosen == .keepMine)
            }
            HStack(spacing: 6) {
                Spacer()
                if chosen == .keepRemote {
                    Button("Keep Remote") { whole[file.path] = .keepRemote }.buttonStyle(.glassProminent)
                } else {
                    Button("Keep Remote") { whole[file.path] = .keepRemote }.buttonStyle(.glass)
                }
                if chosen == .keepMine {
                    Button("Keep Mine") { whole[file.path] = .keepMine }.buttonStyle(.glassProminent)
                } else {
                    Button("Keep Mine") { whole[file.path] = .keepMine }.buttonStyle(.glass)
                }
            }
            Spacer()
        }
    }

    private func wholeSide(_ title: String, side: Git.Side, color: Color, kept: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(color)
                if kept { Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(color) }
            }
            Label(side == .deleted ? "Deleted the file" : side == .added ? "Added the file" : "Changed the file",
                systemImage: side == .deleted ? "trash" : "doc")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(kept ? 0.16 : 0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(kept ? 0.6 : 0), lineWidth: 1))
    }

    // MARK: State

    /// A note both sides changed: its conflicts are chosen one by one.
    private func usesMarks(_ file: Git.Conflicted) -> Bool { file.isMarkdown && file.hasMarks }

    private func conflictCount(_ path: String) -> Int { texts[path].map { ConflictText.conflicts(in: $0).count } ?? 0 }

    private func conflictNumber(_ parts: [ConflictText.Part], at offset: Int) -> Int {
        parts[..<offset].count { if case .conflict = $0 { true } else { false } }
    }

    /// The last two lines before the conflict at [offset], to place it.
    private func context(_ parts: [ConflictText.Part], before offset: Int) -> String {
        guard offset > 0, case let .plain(text) = parts[offset - 1] else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().suffix(2).joined(separator: "\n")
    }

    private func allChosen(_ path: String, count: Int) -> ConflictText.Choice? {
        guard let first = choices[path]?[0], (0..<count).allSatisfy({ choices[path]?[$0] == first }) else { return nil }
        return first
    }

    private func resolved(_ file: Git.Conflicted) -> Bool {
        if usesMarks(file), texts[file.path] != nil {
            return (choices[file.path]?.count ?? 0) >= conflictCount(file.path)
        }
        return whole[file.path] != nil
    }

    private var remaining: Int { store.conflicts.count { !resolved($0) } }

    /// Reads the notes again, keeping the choices of a note whose text did not change.
    private func load() async {
        await store.flushEditors()
        var read: [String: String] = [:]
        for file in store.conflicts where usesMarks(file) {
            if let url = store.url(of: file.path), let text = try? String(contentsOf: url, encoding: .utf8) { read[file.path] = text }
        }
        for (path, text) in read where texts[path] != text { choices[path] = nil }
        texts = read
        let paths = Set(store.conflicts.map(\.path))
        whole = whole.filter { paths.contains($0.key) }
        choices = choices.filter { paths.contains($0.key) }
        if selection.map({ !paths.contains($0) }) ?? true { selection = store.conflicts.first?.path }
    }

    private func edit(_ path: String) {
        model.open(path, store: store)
        model.editing = true
        dismiss()
    }

    private func finish() async {
        await store.flushEditors()
        var resolutions: [(Git.Conflicted, Git.Resolution)] = []
        for file in store.conflicts {
            if usesMarks(file) {
                // The note is read again: a change since it was shown is chosen again, not written over.
                guard let url = store.url(of: file.path), let text = try? String(contentsOf: url, encoding: .utf8), text == texts[file.path] else {
                    store.notice = "\(Vault.title(of: file.path)) changed while it was shown. It is shown again; choose once more."
                    return await load()
                }
                resolutions.append((file, .text(ConflictText.resolve(ConflictText.parse(text), choices: choices[file.path] ?? [:]))))
            } else if let resolution = whole[file.path] {
                resolutions.append((file, resolution))
            }
        }
        if await store.finishConflicts(resolutions) {
            store.notice = "The conflicts are resolved and the sync is done."
            dismiss()
        } else {
            await load()
        }
    }
}
