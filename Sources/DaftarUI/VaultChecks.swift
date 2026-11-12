import DaftarCore
import Foundation
import Observation

/// A note an editor is leaving, and what it said when the editor took it.
struct LeftNote: Equatable {
    var path: String
    var loaded: String
}

/// What `just audit` and `just check` report, inside the app, and what
/// `just fix` mends: `daftar-cli check`, `lint` and `fmt --check` with
/// `--json`, run in the background when the vault opens and a moment after
/// files change; and format on save, `daftar-cli fmt --stdin`. One per
/// store. Every run is a process off the main thread, and at most one audit
/// runs at a time: changes while one runs ask for one more after it.
@MainActor @Observable
final class VaultChecks {
    enum State: Equatable {
        /// Never run for this vault.
        case idle
        case running
        /// The findings are of this time.
        case done(Date)
        /// No `daftar-cli` beside the app or on `$PATH`.
        case noCLI
        /// A `daftar-cli` before 0.23.0, which has no `--json`.
        case tooOld
        case failed(String)
    }

    private(set) var problems: [Problem] = []
    private(set) var counts = Problems.Counts()
    private(set) var state = State.idle
    /// An audit runs, perhaps over findings of the last one.
    private(set) var running = false
    /// A fix runs; the Fix buttons wait for it.
    private(set) var fixing = false
    /// The findings of each note, by source line, for the margins.
    @ObservationIgnored private(set) var byPath: [String: [Problem]] = [:]

    @ObservationIgnored weak var store: VaultStore?
    /// Where `daftar-cli` is; a test gives its own.
    @ObservationIgnored var locate: () -> String? = { DaftarCLI.locate() }
    /// How long after the last change of a file the audit runs again.
    @ObservationIgnored var settle = Duration.seconds(2)
    /// Each open editor's note, for format on save at Quit.
    @ObservationIgnored var editors: [ObjectIdentifier: () -> LeftNote?] = [:]

    @ObservationIgnored private var root: URL?
    @ObservationIgnored private var soon: Task<Void, Never>?
    @ObservationIgnored private var audit: Task<Void, Never>?
    @ObservationIgnored private var again = false
    /// The panel asked for the audit that starts next.
    @ObservationIgnored private var asking = false
    /// The panel asked for an audit: a `daftar-cli` missing or too old is
    /// said once, as a notice, not at every background run.
    @ObservationIgnored private var asked = false
    @ObservationIgnored private var said = false
    /// A `daftar-cli` that said it has no `fmt --stdin`: format on save does
    /// not ask it again at every leave, until the panel checks again.
    @ObservationIgnored private var oldFormatter: String?
    /// Format on save, by note: a second leave of the same note waits for the first.
    @ObservationIgnored private var formats: [String: Task<Void, Never>] = [:]

    /// What the next audit has to read again. `lint` and `fmt` find what is
    /// in a note alone, so after a save only the notes saved are linted and
    /// checked for formatting, and their findings replace those they had;
    /// `check` reads links between notes and always reads the whole vault.
    /// A whole-vault `fmt --check` took 6.6 s of CPU on 2,800 notes, at
    /// every pause in the typing; the note alone takes 10 ms.
    enum Scope: Equatable {
        case nothing
        case notes(Set<String>)
        case vault

        func adding(_ other: Scope) -> Scope {
            switch (self, other) {
            case (.vault, _), (_, .vault): .vault
            case (.nothing, let other), (let other, .nothing): other
            case (.notes(let a), .notes(let b)): .notes(a.union(b))
            }
        }
    }

    @ObservationIgnored private(set) var scope = Scope.nothing
    /// Past this many notes, one run over the vault is cheaper than a list.
    nonisolated static let mostNotes = 500

    // MARK: The audit

    /// A vault opened: what was found in the last one goes. A vault that
    /// keeps `daftar-cli`'s settings (`.daftar.toml`, `.markdownlint.jsonc`,
    /// `.prettierrc`) is audited at once, in the background; any other only
    /// once the panel asks.
    func opened(_ root: URL) {
        soon?.cancel()
        audit?.cancel()
        audit = nil
        running = false
        again = false
        self.root = root
        said = false
        oldFormatter = nil
        show([])
        state = .idle
        scope = .vault
        if Self.usesCLI(root) { schedule(after: .milliseconds(500)) }
    }

    /// Files changed, by a save, a fix or a pull: the audit runs again once
    /// they settle, when it has run before and could. [paths] are the files
    /// that changed; nil when that is not known (a rescan), and the whole
    /// vault is linted again.
    func changed(_ paths: Set<String>? = nil) {
        scope = scope.adding(paths.map(Scope.notes) ?? .vault)
        switch state {
        case .done, .failed, .running: schedule(after: settle)
        case .idle, .noCLI, .tooOld: break
        }
    }

    /// The panel opened, or Refresh: now, or after the audit that runs.
    func refresh() {
        asked = true
        oldFormatter = nil
        scope = .vault
        asking = true
        soon?.cancel()
        start()
    }

    private func schedule(after delay: Duration) {
        soon?.cancel()
        soon = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    private func start() {
        guard audit == nil else {
            again = true
            return
        }
        audit = Task { [weak self] in
            await self?.runAudit()
            guard let self, !Task.isCancelled else { return }
            self.audit = nil
            if self.again {
                self.again = false
                self.start()
            }
        }
    }

    /// The vault's own `[audit]` profile of `.daftar.toml`, which `just audit` uses.
    nonisolated static func hasAuditProfile(_ root: URL) -> Bool {
        guard let text = try? String(contentsOf: root.appending(path: ".daftar.toml"), encoding: .utf8) else { return false }
        return text.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces) == "[audit]" }
    }

    nonisolated static func usesCLI(_ root: URL) -> Bool {
        [".daftar.toml", ".markdownlint.jsonc", ".prettierrc"].contains { FileManager.default.fileExists(atPath: root.appending(path: $0).path) }
    }

    /// The three commands of an audit, as `just check` and `just audit` run
    /// them; with [notes], `lint` and `fmt --check` of those notes only, and
    /// neither when the list is empty.
    nonisolated static func auditArguments(vault: URL, profile: Bool, notes: [String]? = nil) -> [[String]] {
        let base = ["--vault", vault.path]
        let check = base + ["check", "--json"] + (profile ? ["--profile", "audit"] : [])
        guard let notes else { return [check, base + ["lint", "--json"], base + ["fmt", "--check", "--json"]] }
        if notes.isEmpty { return [check] }
        // After `--`, a note whose name starts with `-` is a note.
        return [check, base + ["lint", "--json", "--"] + notes, base + ["fmt", "--check", "--json", "--"] + notes]
    }

    /// The notes of [paths] that `lint` and `fmt` read in a run over the
    /// vault: notes, there, and not hidden. A path that is not there fails
    /// the whole command, so a deleted note is left out (its findings go).
    nonisolated static func lintable(_ paths: Set<String>, in root: URL, hidden: ExcludedFiles) -> [String] {
        paths.filter { path in
            Vault.isNote(path) && !hidden.contains(path) && FileManager.default.fileExists(atPath: root.appending(path: path).path)
        }.sorted()
    }

    private func runAudit() async {
        guard let root else { return }
        guard let cli = locate() else {
            state = .noCLI
            show([])
            announce()
            return
        }
        running = true
        defer { if self.root == root { running = false } }
        // Only notes saved since an audit of the whole vault are read alone.
        var taken = scope
        scope = .nothing
        if case .done = state {} else { taken = .vault }
        var notes: Set<String>?
        if case .notes(let paths) = taken, paths.count <= Self.mostNotes { notes = paths }
        // A run that does not finish leaves the whole vault to read again.
        var finished = false
        defer { if !finished { scope = scope.adding(.vault) } }
        // The panel waits for its audit, and the vault's is long; the one
        // after a save is background work, on the efficiency cores.
        let quality: QualityOfService = asking || notes == nil ? .utility : .background
        asking = false
        if case .idle = state { state = .running }
        var found: [Problem] = []
        let lintable = notes.map { Self.lintable($0, in: root, hidden: store?.hidden ?? ExcludedFiles()) }
        for arguments in Self.auditArguments(vault: root, profile: Self.hasAuditProfile(root), notes: lintable) {
            let output: DaftarCLI.Output
            do {
                output = try await DaftarCLI.run(cli, arguments, in: root, quality: quality)
            } catch is CancellationError {
                return
            } catch {
                guard self.root == root else { return }
                state = .failed((error as? DaftarCLI.Failure).map { if case .notRun(let why) = $0 { why } else { "" } } ?? error.localizedDescription)
                return
            }
            guard !Task.isCancelled, !output.cancelled, self.root == root else { return }
            if DaftarCLI.tooOld(output) {
                state = .tooOld
                show([])
                announce()
                return
            }
            let text = output.text
            let parsed = await Task.detached(priority: .utility) { Problems.parse(text) }.value
            guard self.root == root else { return }
            // `check` fails when it finds an error: that is a finding, not a failure.
            if output.status != 0, parsed.isEmpty, !output.stderr.isEmpty {
                state = .failed(DaftarCLI.failure(output.stderr))
                return
            }
            found += parsed
        }
        finished = true
        if let notes {
            // The notes read again lose the findings they had; `check` is new in full.
            found += problems.filter { $0.tool != .check && !notes.contains($0.path) }
        }
        show(found)
        state = .done(Date())
    }

    /// Once for the vault, after the panel asked.
    private func announce() {
        guard asked, !said, let notice = Self.explanation(state) else { return }
        said = true
        store?.notice = notice
    }

    /// The findings of [path] by source line, for the editor's margin. It
    /// reads [problems], so a view that asks is drawn again after an audit.
    func marks(for path: String) -> [Int: [Problem]] {
        guard !problems.isEmpty, let found = byPath[path] else { return [:] }
        return Problems.lines(found, of: path)
    }

    /// The findings the panel lists, by note, worked out once for each
    /// filter and set of findings, not at each drawing.
    func grouped(_ filter: Problems.Filter) -> [Problems.Note] {
        if let known = groups[filter] { return known }
        let made = Problems.grouped(problems, filter: filter)
        groups[filter] = made
        return made
    }

    @ObservationIgnored private var groups: [Problems.Filter: [Problems.Note]] = [:]

    private func show(_ found: [Problem]) {
        groups = [:]
        problems = found
        counts = Problems.counts(found)
        var paths: [String: [Problem]] = [:]
        for problem in found { paths[problem.path, default: []].append(problem) }
        byPath = paths
    }

    /// What the panel or a notice says about a state that has no findings.
    static func explanation(_ state: State) -> String? {
        switch state {
        case .noCLI: DaftarCLI.missing
        case .tooOld: DaftarCLI.upgrade
        case .failed(let why): "The audit failed: \(why)"
        case .idle, .running, .done: nil
        }
    }

    // MARK: Fixes

    /// The arguments of the fixes `just fix` runs, in its order: lint's,
    /// then the audit's, then the formatting; for [paths], or the whole
    /// vault when there are none.
    nonisolated static func fixArguments(vault: URL, tools: Set<Problem.Tool>, paths: [String]) -> [[String]] {
        let base = ["--vault", vault.path]
        // After `--`, a note whose name starts with `-` is a note.
        let files = paths.isEmpty ? [] : ["--"] + paths
        var out: [[String]] = []
        if tools.contains(.lint) { out.append(base + ["lint", "--fix"] + files) }
        if tools.contains(.check) { out.append(base + ["check", "--fix"] + files) }
        if tools.contains(.fmt) { out.append(base + ["fmt"] + files) }
        return out
    }

    /// The Fix of one finding: its tool's fix of its note.
    func fix(_ problem: Problem) { fix(tools: [problem.tool], paths: [problem.path]) }

    /// Fix All of a note, or of the vault with nil: what `just fix` does.
    func fixAll(_ path: String? = nil) { fix(tools: Set(Problem.Tool.allCases), paths: path.map { [$0] } ?? []) }

    /// The editors save first, so the fix reads what was typed and no editor
    /// writes its older text over it; the notes are read again after, and
    /// an editor with nothing unsaved takes them.
    private func fix(tools: Set<Problem.Tool>, paths: [String]) {
        guard let store, let root, !fixing else { return }
        guard let cli = locate() else {
            store.notice = DaftarCLI.missing
            return
        }
        fixing = true
        Task {
            defer { fixing = false }
            await store.flushEditors()
            for arguments in Self.fixArguments(vault: root, tools: tools, paths: paths) {
                guard let output = try? await DaftarCLI.run(cli, arguments, in: root), self.root == root else { return }
                if DaftarCLI.tooOld(output) || Self.refusesPaths(output, paths) {
                    store.notice = DaftarCLI.upgrade
                    return
                }
                if output.usageError != nil {
                    store.notice = DaftarCLI.failure(output.stderr)
                    return
                }
            }
            for path in paths { store.places.markRead(path) }
            // The watcher sees a fix of the whole vault; a note's is read at once.
            if !paths.isEmpty { store.changed(Set(paths)) }
            refresh()
        }
    }

    /// A `daftar-cli` whose `check` takes no files (before 0.23.0) says so as
    /// "unexpected argument '<file>'".
    nonisolated static func refusesPaths(_ output: DaftarCLI.Output, _ paths: [String]) -> Bool {
        guard let usage = output.usageError else { return false }
        return paths.contains { usage.hasPrefix("error: unexpected argument '\($0)'") } || usage.hasPrefix("error: unexpected argument '--'")
    }

    // MARK: Format

    enum FormatFailure: Error, Equatable {
        case noCLI, tooOld
        case failed(String)

        var notice: String {
            switch self {
            case .noCLI: DaftarCLI.missing
            case .tooOld: DaftarCLI.upgrade
            case .failed(let why): "The note was not formatted: \(why)"
            }
        }
    }

    nonisolated static func formatArguments(vault: URL, path: String) -> [String] {
        // `--path=` keeps a note named `-x.md` a value.
        ["--vault", vault.path, "fmt", "--stdin", "--path=\(path)"]
    }

    /// [text] formatted as the note at [path] of the vault: `daftar-cli fmt
    /// --stdin`, which writes nothing.
    func formatted(_ text: String, path: String) async -> Result<String, FormatFailure> {
        guard let root else { return .failure(.failed("No vault is open.")) }
        guard let cli = locate() else { return .failure(.noCLI) }
        do {
            let output = try await DaftarCLI.run(cli, Self.formatArguments(vault: root, path: path), input: Data(text.utf8), in: root)
            if DaftarCLI.tooOld(output) { return .failure(.tooOld) }
            guard output.status == 0, !output.cancelled else { return .failure(.failed(DaftarCLI.failure(output.stderr))) }
            return .success(output.text)
        } catch is CancellationError {
            return .failure(.failed("Cancelled."))
        } catch {
            return .failure(.failed((error as? DaftarCLI.Failure).map { if case .notRun(let why) = $0 { why } else { "" } } ?? error.localizedDescription))
        }
    }

    /// Edit › Format Note: [text] formatted, or nil once a notice has said
    /// why not.
    func formattedForCommand(_ text: String, path: String) async -> String? {
        switch await formatted(text, path: path) {
        case .success(let out): return out
        case .failure(let failure):
            store?.notice = failure.notice
            return nil
        }
    }

    /// Format on save: an editor left [left] at [moment]. Once that editor's
    /// text is on disk (a Neovim that was let go writes it in [after]), the
    /// file is formatted, when the setting is on and it was typed in. With
    /// no `daftar-cli`, or one too old, nothing happens and nothing is said.
    /// The write goes through the editors' gate and the file is read again
    /// first: a note that changed meanwhile is left alone.
    func formatOnLeave(_ left: LeftNote, at moment: NoteFormat.Moment, after: Task<Void, Never>? = nil) {
        guard let store, root != nil,
            NoteFormat.formats(at: moment, setting: store.settings.formatOnSave, path: left.path, edited: true)
        else { return }
        let previous = formats[left.path]
        let task = Task { [weak self] in
            await previous?.value
            await after?.value
            await self?.formatFile(left)
        }
        formats[left.path] = task
        Task { [weak self] in
            await task.value
            if self?.formats[left.path] == task { self?.formats[left.path] = nil }
        }
    }

    private func formatFile(_ left: LeftNote) async {
        guard let store, let text = store.text(of: left.path) else { return }
        guard NoteFormat.formats(at: .closed, setting: true, path: left.path, edited: text != left.loaded) else { return }
        guard oldFormatter == nil || oldFormatter != locate() else { return }
        let result = await formatted(text, path: left.path)
        if result == .failure(.tooOld) { oldFormatter = locate() }
        guard case .success(let out) = result, out != text, !out.isEmpty else { return }
        await store.flushEditors()
        // Typed again since, or written by another app: not this format's to change.
        guard store.text(of: left.path) == text else { return }
        do {
            try store.write(out, to: left.path)
        } catch {
            store.notice = "\(Vault.title(of: left.path)) could not be formatted: \(error.localizedDescription)"
        }
    }

    /// A format on save is under way, which Quit waits for.
    var formatting: Bool { !formats.isEmpty }

    /// Quit: each note open in an editor is formatted as if it were left,
    /// and the formats under way finish. The app gives this a few seconds.
    func formatOpenNotes() async {
        for note in editors.values.compactMap({ $0() }) { formatOnLeave(note, at: .quit) }
        for task in formats.values { await task.value }
    }

    /// Format Note in the reader: the file, through the editors' gate.
    func formatNote(_ path: String) {
        guard let store else { return }
        Task {
            await store.flushEditors()
            guard let text = store.text(of: path), let out = await formattedForCommand(text, path: path) else { return }
            guard out != text else {
                store.notice = "\(Vault.title(of: path)) is formatted already."
                return
            }
            await store.flushEditors()
            guard store.text(of: path) == text else {
                store.notice = "\(Vault.title(of: path)) changed while it was formatted. Nothing was written."
                return
            }
            do {
                try store.write(out, to: path)
            } catch {
                store.notice = "\(Vault.title(of: path)) could not be formatted: \(error.localizedDescription)"
            }
        }
    }
}
