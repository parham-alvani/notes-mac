import AppKit
import DaftarCore
import SwiftUI

/// View › Problems (⇧⌘M) and Edit › Format Note (⌥⇧⌘F).
struct ProblemsCommands: Commands {
    var window: WindowModel?
    var store: VaultStore

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Format Note") { window?.formatNote(store: store) }
                .keyboardShortcut("f", modifiers: [.command, .option, .shift])
                .disabled(window?.canFormat != true)
        }
        CommandGroup(after: .sidebar) {
            Button(window?.problems == true ? "Hide Problems" : "Show Problems") { window?.toggleProblems(store: store) }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(window == nil || store.root == nil)
        }
    }
}

extension PaletteCommands {
    /// The Problems panel, Fix All and Format Note, for the palette.
    static func problems(model: WindowModel, store: VaultStore) -> [PaletteCommand] {
        var out = [
            PaletteCommand(
                id: "problems", title: model.problems ? "Hide Problems" : "Show Problems", group: "View",
                symbol: "exclamationmark.triangle.fill", color: Palette.red, shortcut: "⇧⌘M"
            ) {
                model.toggleProblems(store: store)
            },
            PaletteCommand(id: "fix-vault", title: "Fix All Problems in the Vault", group: "Edit", symbol: "wand.and.stars", color: Palette.green) {
                store.checks.fixAll()
            },
        ]
        if model.canFormat {
            out.append(PaletteCommand(id: "format-note", title: "Format Note", group: "Edit", symbol: "text.alignleft", color: Palette.aqua, shortcut: "⌥⇧⌘F") {
                model.formatNote(store: store)
            })
        }
        return out
    }
}

extension WindowModel {
    /// A Markdown note is on screen: Format Note acts on it.
    var canFormat: Bool { showsText && path.map(Vault.isNote) == true }

    func toggleProblems(store: VaultStore) {
        withMotion(.snappy(duration: 0.2)) { problems.toggle() }
        if problems { store.checks.refresh() }
    }

    /// The note of [problem] at its line: the reader marks the line with the
    /// reading cursor; the editor, when the pane edits, puts its cursor there.
    func show(_ problem: Problem, store: VaultStore) {
        let line = problem.sourceLine
        if editing, focused.path == problem.path {
            if let line { focused.editorJump = EditorJump(line: line) }
            return
        }
        open(problem.path, line: line, store: store)
        if editing, let line { focused.editorJump = EditorJump(line: line) }
    }

    /// Edit › Format Note: in the editor as a step to undo, else the file.
    func formatNote(store: VaultStore) {
        guard canFormat, let path else { return }
        if editing {
            NSApp.sendAction(#selector(NoteTextView.formatNote(_:)), to: nil, from: nil)
        } else {
            store.checks.formatNote(path)
        }
    }
}

/// The toolbar's count of what the audit found; a click shows the panel.
struct ProblemsButton: View {
    var model: WindowModel
    @Environment(VaultStore.self) private var store

    var body: some View {
        let counts = store.checks.counts
        Button { model.toggleProblems(store: store) } label: {
            Label("Problems", systemImage: counts.errors > 0 ? "xmark.octagon.fill" : "exclamationmark.triangle")
                .foregroundStyle(counts.errors > 0 ? Palette.red : counts.warnings > 0 ? Palette.yellow : .secondary)
        }
        .badge(counts.errors > 0 ? counts.errors : counts.warnings)
        .help("Problems: \(counts.spoken) (⇧⌘M)")
        .accessibilityLabel("Problems")
        .accessibilityValue(counts.spoken)
    }
}

/// The Problems panel under the note: what `just audit` and `just check`
/// report, by note, errors first, with Fix and Fix All (`just fix`).
struct ProblemsPanel: View {
    var model: WindowModel
    @Environment(VaultStore.self) private var store
    @ViewState private var filter = Problems.Filter.all
    @FocusState private var focused: Bool

    var body: some View {
        let checks = store.checks
        VStack(spacing: 0) {
            Divider()
            header(checks)
            Divider()
            content(checks)
        }
        .frame(height: 240)
        .background(.background)
        .focused($focused)
        .onExitCommand { close() }
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Problems")
    }

    private func close() {
        withMotion(.snappy(duration: 0.2)) { model.problems = false }
    }

    private func header(_ checks: VaultChecks) -> some View {
        HStack(spacing: 10) {
            Text("Problems").font(.headline)
            Text(checks.counts.spoken)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if checks.running || checks.fixing {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(checks.fixing ? "Fixing" : "Checking")
            }
            Spacer()
            Picker("Show", selection: $filter) {
                Text("Errors \(checks.counts.errors)").tag(Problems.Filter.errors)
                Text("Warnings \(checks.counts.warnings)").tag(Problems.Filter.warnings)
                Text("All").tag(Problems.Filter.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Show")
            Button("Fix All") { checks.fixAll() }
                .disabled(checks.fixing || !checks.problems.contains(where: \.fixable))
                .help("Mend what has one answer in the whole vault, as just fix does: lint --fix, check --fix, fmt")
            Button { checks.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Check the vault again")
                .accessibilityLabel("Check Again")
            Button(action: close) { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Hide the panel (Escape, ⇧⌘M)")
                .accessibilityLabel("Hide Problems")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder private func content(_ checks: VaultChecks) -> some View {
        let notes = checks.grouped(filter)
        if notes.isEmpty {
            Text(emptyText(checks))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(notes) { note in
                    Section {
                        ForEach(note.problems) { row($0, checks: checks) }
                    } header: {
                        noteHeader(note, checks: checks)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func emptyText(_ checks: VaultChecks) -> String {
        if let why = VaultChecks.explanation(checks.state) { return why }
        switch checks.state {
        case .idle, .running: return "Checking the vault…"
        default: break
        }
        switch filter {
        case .errors: return "No errors."
        case .warnings: return "No warnings."
        case .all: return "No problems: the audit, lint and formatting are clean."
        }
    }

    private func noteHeader(_ note: Problems.Note, checks: VaultChecks) -> some View {
        HStack(spacing: 8) {
            Text(Vault.title(of: note.path)).font(.callout.weight(.semibold))
            Text(folder(of: note.path)).faint().lineLimit(1)
            Text(note.counts.spoken).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            if note.fixable {
                Button("Fix All") { checks.fixAll(note.path) }
                    .controlSize(.small)
                    .disabled(checks.fixing)
                    .help("Mend what has one answer in this note")
                    .accessibilityLabel("Fix All in \(Vault.title(of: note.path))")
            }
        }
    }

    private func row(_ problem: Problem, checks: VaultChecks) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { model.show(problem, store: store) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: problem.level == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(problem.level == .error ? Palette.red : Palette.yellow)
                        .accessibilityHidden(true)
                    Text(problem.line > 0 ? "Line \(problem.line)" : "Note")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)
                    Text(problem.message).lineLimit(2)
                    Spacer(minLength: 8)
                    Text(problem.code).font(.caption.monospaced()).faint()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(Vault.title(of: problem.path))\(problem.line > 0 ? " at line \(problem.line)" : "")")
            .accessibilityLabel(spoken(problem))
            if problem.fixable {
                Button("Fix") { checks.fix(problem) }
                    .controlSize(.small)
                    .disabled(checks.fixing)
                    .help("Mend it with daftar-cli \(problem.tool == .fmt ? "fmt" : "\(problem.tool.rawValue) --fix")")
                    .accessibilityLabel("Fix \(problem.code) in \(Vault.title(of: problem.path))")
            }
        }
    }

    private func spoken(_ problem: Problem) -> String {
        let level = problem.level == .error ? "Error" : "Warning"
        let place = problem.line > 0 ? "line \(problem.line)" : "the whole note"
        return "\(level), \(place): \(problem.message). \(problem.code)"
    }

    private func folder(of path: String) -> String {
        path.split(separator: "/").dropLast().joined(separator: " › ")
    }
}
