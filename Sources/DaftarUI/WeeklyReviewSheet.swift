import DaftarCore
import SwiftUI

/// This week's review, before it is a note: the review written on [day],
/// which `daftar-cli review` prints for the preview and `--write` makes.
struct ReviewPreview: Identifiable, Equatable {
    var day: Day
    let id = UUID()

    var path: String { WeeklyReview.path(writtenOn: day) }
}

extension WindowModel {
    /// Go › Weekly Review (⌘4): this week's review note, the one written on
    /// the last Saturday, when it is there; else a preview of it with a
    /// button that writes it to `Reviews/`.
    func openWeeklyReview(store: VaultStore, today: Day = .today()) {
        if let path = WeeklyReview.thisWeek(today: today, in: store.index.files) {
            open(path, store: store)
        } else {
            weeklyReview = ReviewPreview(day: WeeklyReview.day(for: today))
        }
    }
}

/// The preview: the review drawn by the reader, as it would read in the
/// vault, with Save to Reviews/. Escape closes it and writes nothing.
struct WeeklyReviewSheet: View {
    var preview: ReviewPreview
    @Bindable var model: WindowModel
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @ViewState private var markdown: String?
    @ViewState private var error: String?
    @ViewState private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "calendar.badge.checkmark")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(LinearGradient(colors: [Palette.aqua, Palette.blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Weekly Review").font(.title3.weight(.semibold))
                    Text("A preview of \(preview.path), not in the vault yet").font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction).buttonStyle(.glass)
                Button(saving ? "Saving…" : "Save to \(WeeklyReview.folder)/") { save() }
                    .keyboardShortcut("s")
                    .buttonStyle(.glassProminent).tint(Palette.accent)
                    .disabled(markdown == nil || saving)
                    .help("Makes \(preview.path) with daftar-cli review --write, as the weekly CI does")
            }
            .padding(16)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Palette.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 10)
                    .textSelection(.enabled)
                    .onAppear { announce(error) }
            }
            Divider()
            Group {
                if let markdown {
                    ReaderView(
                        request: ReaderRequest(path: preview.path, text: markdown), store: store, revision: store.revision,
                        onOpen: { path, anchor, _ in
                            dismiss()
                            model.open(path, heading: anchor, store: store)
                        },
                        onTag: { tag in
                            dismiss()
                            model.searchTag(tag)
                        })
                } else if error == nil {
                    ProgressView("Writing the review…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, idealWidth: 860, minHeight: 520, idealHeight: 760)
        .task { await load() }
    }

    /// `daftar-cli review --day`, off the main thread.
    private func load() async {
        guard let root = store.root else { return error = "No vault is open." }
        do {
            let output = try await CLIProcess.run(WeeklyReview.arguments(vault: root, day: preview.day))
            guard !output.cancelled else { return }
            if output.status == 0 {
                markdown = String(decoding: output.stdout, as: UTF8.self)
            } else {
                error = Self.failure(output.stderr)
            }
        } catch {
            self.error = Self.describe(error)
        }
    }

    /// `--write`, which never writes over a note, then the note.
    private func save() {
        guard let root = store.root, !saving else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                let output = try await CLIProcess.run(WeeklyReview.arguments(vault: root, day: preview.day, write: true))
                guard output.status == 0 else { return error = Self.failure(output.stderr) }
                let path = WeeklyReview.writtenPath(String(decoding: output.stdout, as: UTF8.self), vault: root) ?? preview.path
                // The index takes the new file from the watcher; wait for it, a moment at most.
                store.changed([path])
                for _ in 0..<40 where !store.index.files.contains(path) { try? await Task.sleep(for: .milliseconds(50)) }
                dismiss()
                model.open(path, store: store)
            } catch {
                self.error = Self.describe(error)
            }
        }
    }

    /// What a failed run says: its last line, as Export as PDF says it.
    static func failure(_ errors: String) -> String {
        if errors.contains("unrecognized subcommand 'review'") || errors.contains("unexpected argument '--day'") {
            return "The weekly review needs a newer daftar-cli: brew upgrade parham-alvani/tap/daftar-cli"
        }
        return PDFExport.failure(errors)
    }

    private static func describe(_ error: Error) -> String {
        switch error as? CLIProcess.Failure {
        case .notInstalled?: CLIProcess.notInstalled
        case .couldNotRun(let why)?: "daftar-cli could not run: \(why)"
        case nil: error.localizedDescription
        }
    }
}

/// Today's small card: the newest review in `Reviews/`, when there is one.
struct ReviewCard: View {
    @Bindable var model: WindowModel
    @Environment(VaultStore.self) private var store

    var body: some View {
        if let path = WeeklyReview.newest(in: store.index.files.filter { !store.excluded.contains($0) }) {
            Card(title: "Weekly review", symbol: "calendar.badge.checkmark", color: Palette.aqua) {
                Button { model.open(path, store: store) } label: {
                    LinkRow(path: path, symbol: "arrow.up.right", color: Palette.aqua)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the newest weekly review")
            }
        }
    }
}
