import DaftarCore
import SwiftUI

/// ⇧⌘H, "Replace in Vault…": every match of a text or a regular
/// expression in the vault's notes, or a folder's, by note, each with its
/// line before and after. Replace writes the checked ones; a note that
/// changed after the preview is refused.
struct VaultReplaceSheet: View {
    var target: ReplaceTarget
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @ViewState private var find = ""
    @ViewState private var replacement = ""
    @ViewState private var options = VaultReplace.Options()
    @ViewState private var folder = ""
    @ViewState private var results: [NoteMatches] = []
    /// The query [results] are for.
    @ViewState private var searched: Query?
    @ViewState private var problem: String?
    /// The matches the person unchecked; a new search checks every match again.
    @ViewState private var unchecked: Set<MatchKey> = []
    @ViewState private var summary: ReplaceSummary?
    @ViewState private var flushed = false
    @FocusState private var focused: Bool

    /// More matches than this are not listed: replace them and search again.
    private static let limit = 5000

    struct Query: Hashable {
        var find: String
        var replacement: String
        var options: VaultReplace.Options
        var folder: String
    }

    private var query: Query { Query(find: find, replacement: replacement, options: options, folder: folder) }
    private var current: Bool { searched == query }
    private var shown: [NoteMatches] { current ? results : [] }
    private var total: Int { shown.reduce(0) { $0 + $1.matches.count } }
    private var chosen: Set<MatchKey> {
        Set(shown.flatMap { note in note.matches.map { MatchKey(path: note.path, id: $0.id) } }).subtracting(unchecked)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            fields
            status
            list
            Text("Replace writes the notes now. The next sync commits the change, so the history of each note keeps the old text.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(summary == nil ? "Cancel" : "Done", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction).buttonStyle(.glass)
                let count = chosen.count
                Button(count == 1 ? "Replace 1 Match" : "Replace \(count) Matches") { replace() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .tint(Palette.accent)
                    .disabled(count == 0)
            }
        }
        .padding(22)
        .frame(width: 860, height: 640)
        .onAppear {
            folder = target.folder
            focused = true
        }
        // A short wait after each key, and again when the vault changes.
        .task(id: [AnyHashable(query), AnyHashable(store.revision)]) { await search() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(LinearGradient(colors: [Palette.accent, Palette.pink], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Replace in Vault").font(.title3.weight(.semibold))
                Text(folder.isEmpty ? "Every note of \(store.name), without the excluded files" : "The notes in \(folder)")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Picker("Look in", selection: $folder) {
                Text("Whole Vault").tag("")
                Divider()
                ForEach(folders, id: \.self) { Text($0).tag($0) }
            }
            .fixedSize()
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Find").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    TextField(options.regularExpression ? "Regular expression" : "Text", text: $find)
                        .textFieldStyle(.roundedBorder)
                        .font(Font(Fonts.code(size: 13)))
                        .focused($focused)
                }
                GridRow {
                    Text("Replace").foregroundStyle(.secondary)
                    TextField(options.regularExpression ? "Replacement: $1 is the first group" : "Replacement", text: $replacement)
                        .textFieldStyle(.roundedBorder)
                        .font(Font(Fonts.code(size: 13)))
                }
            }
            HStack(spacing: 16) {
                Toggle("Match Case", isOn: $options.matchCase)
                Toggle("Whole Word", isOn: $options.wholeWord)
                Toggle("Regular Expression", isOn: $options.regularExpression)
                Toggle("Skip Code", isOn: $options.skipCode)
                    .help("Leave code blocks and inline code as they are.")
            }
            .toggleStyle(.checkbox)
            .padding(.leading, 62)
        }
    }

    @ViewBuilder private var status: some View {
        if let summary {
            VStack(alignment: .leading, spacing: 4) {
                Label(summaryText(summary), systemImage: summary.refused.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(summary.refused.isEmpty ? Palette.green : Palette.yellow)
                if !summary.refused.isEmpty {
                    Text("Not changed, because they changed after the preview or could not be written: "
                        + summary.refused.map(Vault.title(of:)).joined(separator: ", "))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .font(.callout.weight(.medium))
        } else if let problem, current {
            Label(problem, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Palette.red)
        } else if !find.isEmpty, current {
            Text(total == 0 ? "No matches" : "\(total) \(total == 1 ? "match" : "matches") in \(shown.count) \(shown.count == 1 ? "note" : "notes") · \(chosen.count) checked"
                + (total >= Self.limit ? " · only the first \(Self.limit) are listed" : ""))
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        } else {
            Text(find.isEmpty ? "Type the text to find." : "Searching…").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(shown) { note in
                    noteRow(note)
                    ForEach(note.matches) { match in
                        matchRow(match, in: note.path)
                    }
                }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func noteRow(_ note: NoteMatches) -> some View {
        let keys = note.matches.map { MatchKey(path: note.path, id: $0.id) }
        let on = Binding { keys.allSatisfy { !unchecked.contains($0) } } set: { value in
            if value { unchecked.subtract(keys) } else { unchecked.formUnion(keys) }
        }
        return HStack(spacing: 8) {
            Toggle("", isOn: on).toggleStyle(.checkbox).labelsHidden()
            Image(systemName: "doc.text").foregroundStyle(Palette.blue)
            Text(Vault.title(of: note.path)).font(.headline).lineLimit(1)
            Text(note.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text("\(note.matches.count)").font(.caption.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Palette.accent.opacity(0.18), in: Capsule())
        }
        .padding(.top, 4)
    }

    private func matchRow(_ match: VaultReplace.Match, in path: String) -> some View {
        let key = MatchKey(path: path, id: match.id)
        let on = Binding { !unchecked.contains(key) } set: { value in
            if value { unchecked.remove(key) } else { unchecked.insert(key) }
        }
        return HStack(alignment: .center, spacing: 6) {
            Toggle("", isOn: on).toggleStyle(.checkbox).labelsHidden()
            VStack(spacing: 0) {
                DiffRow(kind: .removed, old: match.line + 1, new: nil, text: Text(marked(match, replaced: false)))
                DiffRow(kind: .added, old: nil, new: match.line + 1, text: Text(marked(match, replaced: true)))
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .opacity(on.wrappedValue ? 1 : 0.45)
        }
        .padding(.leading, 22)
    }

    /// The line with the match, or its replacement, marked.
    private func marked(_ match: VaultReplace.Match, replaced: Bool) -> AttributedString {
        var middle = AttributedString((replaced ? match.replacement : match.found).replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "↵"))
        middle.backgroundColor = (replaced ? Palette.green : Palette.red).opacity(0.3)
        middle.font = Font(Fonts.code(size: 12)).bold()
        if middle.characters.isEmpty, !replaced { middle = AttributedString("‸") }
        return AttributedString(match.prefix) + middle + AttributedString(match.suffix)
    }

    /// The folders with notes in them, for the scope.
    private var folders: [String] {
        var all = Set<String>(target.folder.isEmpty ? [] : [target.folder])
        for file in store.index.files where Vault.isNote(file) && !store.excluded.contains(file) {
            let parts = file.split(separator: "/").dropLast()
            for end in parts.indices { all.insert(parts[...end].joined(separator: "/")) }
        }
        return all.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func summaryText(_ summary: ReplaceSummary) -> String {
        let notes = summary.notes == 1 ? "1 note" : "\(summary.notes) notes"
        let replacements = summary.replacements == 1 ? "1 replacement" : "\(summary.replacements) replacements"
        let refused = summary.refused.isEmpty ? "" : summary.refused.count == 1 ? ", 1 note refused" : ", \(summary.refused.count) notes refused"
        return "\(notes) changed, \(replacements)\(refused)."
    }

    private func search() async {
        let query = query
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        if !flushed {
            // An unsaved edit in an open note is on disk before it is read.
            await store.flushEditors()
            flushed = true
        }
        if searched != query {
            unchecked = []
            summary = nil
        }
        do {
            guard let pattern = try VaultReplace.Pattern(find: query.find, replace: query.replacement, options: query.options) else {
                results = []
                problem = nil
                searched = query
                return
            }
            let found = await store.replaceMatches(pattern, in: query.folder)
            guard !Task.isCancelled else { return }
            var listed: [NoteMatches] = []
            var count = 0
            for note in found where count < Self.limit {
                listed.append(note)
                count += note.matches.count
            }
            results = listed
            problem = nil
        } catch {
            results = []
            problem = error.localizedDescription
        }
        searched = query
    }

    private func replace() {
        guard current, let pattern = try? VaultReplace.Pattern(find: find, replace: replacement, options: options) else { return }
        Task {
            await store.flushEditors()
            let done = store.replace(pattern, shown: results, chosen: chosen)
            summary = done
            unchecked = []
            store.notice = summaryText(done)
        }
    }
}
