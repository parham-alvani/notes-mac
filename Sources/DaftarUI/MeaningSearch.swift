import DaftarCore
import Observation
import SwiftUI

/// Search by meaning for the whole app: runs `daftar-cli search --meaning-only`,
/// `related` and `semantic-index` (`Meaning`, core), downloads the model
/// when the person asks, and keeps the index up to the vault in the
/// background. Nothing here runs on the main thread but the bookkeeping.
@MainActor @Observable
final class MeaningService {
    static let shared = MeaningService()

    /// What the last run said about this Mac.
    enum Availability: Equatable {
        case unknown, ready, noModel, needsUpgrade, notInstalled
    }

    /// An index build running: the first one downloads the model.
    struct Build: Equatable {
        var downloading: Bool
        var step: Meaning.Step?
    }

    private(set) var availability = Availability.unknown
    private(set) var build: Build?
    /// Why the last build the person started failed.
    private(set) var buildError: String?
    /// Grows after each build, so related notes are asked again.
    private(set) var generation = 0

    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var refresh: Task<Void, Never>?
    /// The vault changed while a build ran: refresh again after it.
    @ObservationIgnored private var changedDuringBuild = false
    @ObservationIgnored private weak var store: VaultStore?
    /// Finds the `daftar-cli` to run; a test gives its own.
    @ObservationIgnored var findCLI: () -> String? = { PDFExport.cli() }
    /// The `daftar-cli` that was too old, by its date: an upgrade changes it.
    @ObservationIgnored private var oldCLI: (path: String, date: Date?)?

    // MARK: Searching

    /// The notes nearest [query] in meaning, or why there are none. Nil when
    /// the task was cancelled (a key typed over it).
    func search(_ query: String, vault: URL) async -> Result<[Meaning.Hit], Meaning.Failure>? {
        await ask(Meaning.searchArguments(vault: vault, query: query), priority: .userInitiated)
    }

    /// The notes nearest [note] that it does not link to yet.
    func related(_ note: String, vault: URL) async -> Result<[Meaning.Hit], Meaning.Failure>? {
        await ask(Meaning.relatedArguments(vault: vault, note: note), priority: .utility)
    }

    private func ask(_ arguments: [String], priority: QualityOfService) async -> Result<[Meaning.Hit], Meaning.Failure>? {
        guard let cli = findCLI() else {
            availability = .notInstalled
            return .failure(.failed(CLIProcess.notInstalled))
        }
        // One notice for an old `daftar-cli`, not a process at every key.
        if let oldCLI, oldCLI.path == cli, oldCLI.date == Self.modified(cli) { return .failure(.needsUpgrade) }
        let output: CLIProcess.Output
        do {
            output = try await CLIProcess.run(cli: cli, arguments, priority: priority)
        } catch {
            return Task.isCancelled ? nil : .failure(.failed((error as? CLIProcess.Failure).map(Self.describe) ?? error.localizedDescription))
        }
        guard !output.cancelled, !Task.isCancelled else { return nil }
        guard output.status == 0 else {
            let failure = Meaning.failure(status: output.status, errors: output.stderr)
            note(failure, cli: cli)
            return .failure(failure)
        }
        do {
            let hits = try await Task.detached { try Meaning.hits(output.stdout) }.value
            availability = .ready
            oldCLI = nil
            return .success(hits)
        } catch {
            return .failure(.failed("daftar-cli printed something that is not the list of notes."))
        }
    }

    private func note(_ failure: Meaning.Failure, cli: String) {
        switch failure {
        case .noModel: availability = .noModel
        case .needsUpgrade:
            availability = .needsUpgrade
            oldCLI = (cli, Self.modified(cli))
        case .failed: break
        }
    }

    private static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private static func describe(_ failure: CLIProcess.Failure) -> String {
        switch failure {
        case .notInstalled: CLIProcess.notInstalled
        case .couldNotRun(let why): "daftar-cli could not run: \(why)"
        }
    }

    // MARK: The index

    /// Downloads the model (531 MB, once) and builds the index, in the
    /// background, with its progress in [build]. A build already running
    /// is not started twice.
    func download(vault: URL) {
        startBuild(vault: vault, download: true)
    }

    /// Stops the build: the command is ended, and what it wrote is its own to finish next time.
    func cancelBuild() {
        buildTask?.cancel()
    }

    private func startBuild(vault: URL, download: Bool) {
        guard buildTask == nil else { return }
        if download { buildError = nil }
        build = Build(downloading: download, step: nil)
        changedDuringBuild = false
        buildTask = Task {
            defer {
                buildTask = nil
                build = nil
                generation += 1
                if changedDuringBuild { scheduleRefresh() }
            }
            guard let cli = findCLI() else {
                availability = .notInstalled
                if download { buildError = CLIProcess.notInstalled }
                return
            }
            do {
                let output = try await CLIProcess.run(
                    cli: cli, Meaning.indexArguments(vault: vault, download: download),
                    priority: download ? .utility : .background
                ) { line in
                    guard let step = Meaning.progress(line) else { return }
                    Task { @MainActor in
                        if self.build != nil { self.build?.step = step }
                    }
                }
                guard !output.cancelled else { return }
                if output.status == 0 {
                    availability = .ready
                } else {
                    let failure = Meaning.failure(status: output.status, errors: output.stderr)
                    note(failure, cli: cli)
                    if download { buildError = failure.message }
                }
            } catch {
                if download { buildError = (error as? CLIProcess.Failure).map(Self.describe) ?? error.localizedDescription }
            }
        }
    }

    /// Keeps the index up to [store]'s vault: after a change, once the
    /// vault has been still for `meaning.refresh_minutes`, `semantic-index`
    /// reads again the notes that changed, at background priority, never two at once.
    func follow(_ store: VaultStore) {
        guard self.store !== store else { return }
        self.store = store
        observe()
    }

    private func observe() {
        guard let store else { return }
        withObservationTracking {
            _ = store.revision
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observe()
                self?.scheduleRefresh()
            }
        }
    }

    private func scheduleRefresh() {
        guard let store, store.settings.meaningSearch, store.settings.meaningRefresh > 0 else { return }
        // Only a vault whose index there is: the model is never downloaded unasked.
        guard availability == .ready || (availability == .unknown && Self.modelDownloaded()) else { return }
        if buildTask != nil {
            changedDuringBuild = true
            return
        }
        refresh?.cancel()
        let minutes = store.settings.meaningRefresh
        refresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled, let self, let store = self.store, let root = store.root, !store.loading else { return }
            self.startBuild(vault: root, download: false)
        }
    }

    /// Whether `daftar-cli`'s model folder has anything in it:
    /// `$XDG_CACHE_HOME/daftar/models`, else `~/.cache/daftar/models`.
    static func modelDownloaded(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let cache = environment["XDG_CACHE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (NSHomeDirectory() + "/.cache")
        let models = cache + "/daftar/models"
        return !((try? FileManager.default.contentsOfDirectory(atPath: models)) ?? []).filter { !$0.hasPrefix(".") }.isEmpty
    }
}

/// One list of hits by meaning, for the sidebar's search or the inspector's
/// related notes: asked again for each query or note, the run before
/// cancelled, its process ended.
@MainActor @Observable
final class MeaningQuery {
    private(set) var hits: [Meaning.Hit] = []
    private(set) var failure: Meaning.Failure?
    /// What [hits] answer; nil before the first answer.
    private(set) var answered: String?
    private(set) var asking: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var answeredGeneration = -1

    /// Searches for [query] after [delay] of no new key; nothing for an
    /// empty query or a `#tag`, or with the setting off.
    func search(_ query: String, store: VaultStore, delay: Duration = .milliseconds(450)) {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard store.settings.meaningSearch, !query.isEmpty, !query.hasPrefix("#"), let root = store.root else { return clear() }
        start(query, delay: delay) { await MeaningService.shared.search(query, vault: root) }
    }

    /// The notes related to [path], asked again for another note or after
    /// the index was built again.
    func relate(_ path: String, store: VaultStore) {
        guard store.settings.meaningSearch, let root = store.root, Vault.isNote(path) else { return clear() }
        let generation = MeaningService.shared.generation
        guard asking != path, answered != path || answeredGeneration != generation else { return }
        start(path, delay: .milliseconds(150)) { await MeaningService.shared.related(path, vault: root) }
        answeredGeneration = generation
    }

    private func start(_ key: String, delay: Duration, _ run: @escaping @MainActor () async -> Result<[Meaning.Hit], Meaning.Failure>?) {
        task?.cancel()
        asking = key
        task = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            guard let result = await run(), !Task.isCancelled else { return }
            switch result {
            case .success(let found):
                hits = found
                failure = nil
            case .failure(let why):
                hits = []
                failure = why
            }
            answered = key
            asking = nil
        }
    }

    private func clear() {
        task?.cancel()
        task = nil
        hits = []
        failure = nil
        answered = nil
        asking = nil
    }
}

/// The rows of a list by meaning: the hits, or the one row that says why
/// there are none: the model to download (with the build's progress and a
/// Cancel), a `daftar-cli` to upgrade, or what failed.
struct MeaningRows: View {
    var query: MeaningQuery
    /// The query or note the list should answer.
    var key: String
    /// Paths the list leaves out: shown above already, or hidden.
    var leaving: (String) -> Bool
    var empty: String
    var open: (Meaning.Hit) -> Void
    @Environment(VaultStore.self) private var store
    private var service: MeaningService { MeaningService.shared }

    var shown: [Meaning.Hit] { query.answered == key ? query.hits.filter { !leaving($0.path) } : [] }

    var body: some View {
        // A refresh in the background leaves the hits as they are; the index still answers.
        if let build = service.build, build.downloading || query.failure == .noModel {
            BuildRow(build: build)
        } else if let failure = query.answered == key ? query.failure : nil {
            switch failure {
            case .noModel:
                Button {
                    if let root = store.root { service.download(vault: root) }
                } label: {
                    Label("Download the model (531 MB)", systemImage: "arrow.down.circle")
                        .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
                .help("Search by meaning runs a model on this Mac, offline, in Persian and English: daftar-cli downloads it once and indexes the vault.")
                .accessibilityHint("Downloads the model of search by meaning once, then indexes the vault")
                if let error = service.buildError {
                    Text(error).font(.caption).foregroundStyle(Palette.red).fixedSize(horizontal: false, vertical: true)
                }
            case .needsUpgrade, .failed:
                Label(failure.message, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        } else if query.answered != key {
            Text("Looking…").foregroundStyle(.secondary)
        } else if shown.isEmpty {
            Text(empty).foregroundStyle(.secondary)
        } else {
            ForEach(shown, id: \.path) { hit in
                Button { open(hit) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        LinkRow(path: hit.path, symbol: "sparkle.magnifyingglass", color: Palette.purple)
                        if !hit.snippet.isEmpty {
                            Text(hit.snippet.replacingOccurrences(of: "\n", with: " "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                .multilineTextAlignment(TextDirection.startsRtl(hit.snippet) ? .trailing : .leading)
                                .frame(maxWidth: .infinity, alignment: TextDirection.startsRtl(hit.snippet) ? .trailing : .leading)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Vault.title(of: hit.path))
                .accessibilityValue(hit.snippet)
                .accessibilityHint("Near in meaning")
            }
        }
    }
}

/// The model coming down, or the index being built: a bar and a Cancel.
private struct BuildRow: View {
    var build: MeaningService.Build

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Button("Cancel") { MeaningService.shared.cancelBuild() }
                    .buttonStyle(.borderless).controlSize(.small)
                    .accessibilityLabel(build.downloading ? "Cancel the download" : "Cancel indexing")
            }
            if let step = build.step {
                ProgressView(value: step.fraction).controlSize(.small)
            } else {
                ProgressView().progressViewStyle(.linear).controlSize(.small)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var title: String {
        switch build.step {
        case .downloading(let percent)?: "Downloading the model: \(percent)% of 531 MB"
        case .indexing(let done, let total)?: "Indexing by meaning: \(done) of \(total)"
        case nil: build.downloading ? "Downloading the model…" : "Indexing by meaning…"
        }
    }
}
