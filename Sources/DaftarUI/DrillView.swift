import AppKit
import DaftarCore
import SwiftUI
import WebKit

extension AppSettings {
    /// Where the drill's state file is: Daftar's XDG state folder, which
    /// `daftar-cli drill` and its MCP tools use too, so the three share one
    /// review history. A test's settings keep it in their own state folder,
    /// and so does a run with a test `XDG_CONFIG_HOME` and no `XDG_STATE_HOME`.
    var drillFolder: URL {
        guard url == ConfigFile.defaultURL else { return stateDirectory }
        let environment = ProcessInfo.processInfo.environment
        if environment["XDG_STATE_HOME"]?.hasPrefix("/") == true || environment["XDG_CONFIG_HOME"] == nil {
            return DrillState.folder(environment: environment)
        }
        return stateDirectory
    }
}

/// The drill cards of the open vault (`Drill`, core) and their reviews, for
/// every window: the deck is the notes of `Drill.folder`, read off the main
/// thread when the vault opens and again when a note of that folder
/// changes; the state is read again when the app comes to the front, so a
/// rating made with `daftar-cli` meanwhile counts.
@MainActor @Observable
final class DrillDeck {
    struct Counts: Equatable {
        /// Cards rated before and due today or earlier.
        var due = 0
        /// Cards never rated.
        var fresh = 0
        /// The day the next card not due today comes due.
        var next: Day?
    }

    private(set) var cards: [DrillCard] = []
    private(set) var state = DrillState()
    /// The open vault's deck was read once.
    private(set) var ready = false
    private(set) var counts = Counts()
    @ObservationIgnored private(set) var file: URL?
    @ObservationIgnored private var root: URL?
    /// The last deck was read from an index with no notes yet.
    @ObservationIgnored private var readEmpty = true
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var writes: Task<Void, Never>?

    /// Reads the deck again when the vault is new or a note of the deck's
    /// folder changed; the views call it as the store changes.
    func follow(_ store: VaultStore) {
        guard let root = store.root else {
            self.root = nil
            cards = []
            state = DrillState()
            counts = Counts()
            ready = false
            return
        }
        guard !store.loading else { return }
        // A vault opens before its index is read: the deck read then was empty.
        let changed = store.lastChanged.contains { $0.hasPrefix(Drill.folder + "/") } || readEmpty != store.index.notes.isEmpty
        if root == self.root, !changed { return }
        load(store)
    }

    /// The deck and the state, read off the main thread.
    func load(_ store: VaultStore) {
        guard let root = store.root else { return }
        if root != self.root { ready = false }
        self.root = root
        generation += 1
        let generation = generation, index = store.index, hidden = store.hidden
        readEmpty = index.notes.isEmpty
        let file = DrillState.file(root: root, in: store.settings.drillFolder)
        self.file = file
        Task.detached(priority: .userInitiated) {
            let cards = Drill.deck(root: root, paths: Drill.notes(in: index, hidden: { hidden.contains($0) }))
            let state = DrillState.load(file)
            await MainActor.run {
                guard generation == self.generation else { return }
                self.cards = cards
                self.state = state
                self.ready = true
                self.recount()
            }
        }
    }

    /// The state file read again, off the main thread.
    func reloadState() {
        guard ready, let file else { return }
        let generation = generation
        Task.detached(priority: .utility) {
            let state = DrillState.load(file)
            await MainActor.run {
                guard generation == self.generation, state != self.state else { return }
                self.state = state
                self.recount()
            }
        }
    }

    func recount(today: Day = .today()) {
        let next = Counts(
            due: Drill.due(cards, state: state, today: today, new: 0, limit: .max).count,
            fresh: cards.count(where: { state.due($0) == nil }),
            next: Drill.nextDue(cards, state: state, after: today))
        if next != counts { counts = next }
    }

    /// The cards a session asks today.
    func session(today: Day = .today()) -> DrillSession {
        DrillSession(cards: Drill.due(cards, state: state, today: today))
    }

    /// The card's review if it were rated [rating] now: the interval each button names.
    func preview(_ card: DrillCard, _ rating: DrillRating, today: Day = .today()) -> DrillReview {
        DrillReview.rate(state.reviews[card.id], rating, today: today)
    }

    /// Rates [card]: at once in memory, so the next card comes with no wait,
    /// then in the file, one write after another off the main thread, each
    /// reading the file again first so a rating `daftar-cli` made is kept.
    func rate(_ card: DrillCard, _ rating: DrillRating, store: VaultStore, today: Day = .today()) {
        state.rate(card.id, rating, today: today)
        recount(today: today)
        guard let file else { return }
        let previous = writes, generation = generation, id = card.id
        writes = Task {
            await previous?.value
            let written = await Task.detached(priority: .userInitiated) { () -> Result<DrillState, Error> in
                Result { try DrillState.rate(id, rating, today: today, in: file).state }
            }.value
            guard generation == self.generation else { return }
            switch written {
            case .success(let state):
                self.state = state
                self.recount(today: today)
            case .failure(let error):
                store.notice = "The rating could not be saved in \(file.path(percentEncoded: false)): \(error.localizedDescription)"
            }
        }
    }
}

extension View {
    /// Keeps the store's drill deck in step with the vault: the window's
    /// content view carries it, so the counts are right with any page open.
    func drillDeckFollows(_ store: VaultStore) -> some View {
        modifier(DrillFollower(store: store))
    }
}

private struct DrillFollower: ViewModifier {
    let store: VaultStore

    struct Key: Equatable {
        var root: URL?
        var loading: Bool
        var revision: Int
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: Key(root: store.root, loading: store.loading, revision: store.revision), initial: true) {
                store.drill.follow(store)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                store.drill.reloadState()
            }
    }
}

/// Review Cards: the drill cards due, one at a time in the note pane. The
/// question comes with the headings above it; Space or Return shows the
/// answer as the reader draws it; 1 to 4 rate it Again, Hard, Good or Easy,
/// each button naming when the card comes back; `e` opens the card's note
/// at its heading, and Escape leaves.
struct DrillView: View {
    @Bindable var model: WindowModel
    @Environment(VaultStore.self) private var store
    @ViewState private var session: DrillSession?
    @ViewState private var revealed = false
    @ViewState private var keys = DrillKeys()
    @ViewState private var answer = AnswerView()

    var body: some View {
        let deck = store.drill
        Group {
            if !deck.ready {
                ProgressView("Reading the cards…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let session, let turn = session.current {
                asking(turn, in: session)
            } else {
                done
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            start()
            keys.start { handle($0) }
        }
        .onDisappear { keys.stop() }
        .onChange(of: deck.ready) { start() }
    }

    private func start() {
        guard store.drill.ready, session == nil || session?.isDone == true else { return }
        session = store.drill.session()
        revealed = false
    }

    // MARK: A card

    private func asking(_ turn: DrillSession.Turn, in session: DrillSession) -> some View {
        let card = turn.card
        return VStack(alignment: .leading, spacing: 16) {
            progress(session, again: turn.again)
            question(card, again: turn.again)
                .id(card.id)
                .transition(.opacity)
            ZStack {
                ReaderView(
                    request: ReaderRequest(path: card.path, text: card.answer), store: store, revision: store.revision,
                    onOpen: { path, anchor, _ in model.open(path, heading: anchor, store: store) },
                    onTag: { model.searchTag($0) },
                    onView: { view in
                        answer.view = view
                        view.isHidden = !revealed
                    }
                )
                .opacity(revealed ? 1 : 0)
                .allowsHitTesting(revealed)
                if !revealed {
                    Button(action: reveal) {
                        Label("Show Answer", systemImage: "eye")
                            .font(.title3.weight(.medium))
                            .padding(.horizontal, 18).padding(.vertical, 8)
                    }
                    .buttonStyle(.glass)
                    .help("Show the answer (Space or Return)")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.panel.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            footer(card, again: turn.again)
        }
        .padding(24)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
    }

    private func progress(_ session: DrillSession, again: Bool) -> some View {
        let number = min(session.rated + 1, session.total)
        let said = again ? "Asked again, \(session.rated) of \(session.total) rated" : "Card \(number) of \(session.total)"
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Review Cards").font(.title2.bold())
                Spacer()
                Text(again ? "again · \(session.rated) of \(session.total)" : "\(number) of \(session.total)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(session.rated), total: Double(max(session.total, 1)))
                .tint(Palette.green)
                .motionAnimation(.easeOut(duration: 0.25), value: session.rated)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Review Cards, \(said)")
    }

    private func question(_ card: DrillCard, again: Bool) -> some View {
        let context = card.context.joined(separator: " › ")
        // A Persian card reads from the right, its context with it.
        let rtl = TextDirection.startsRtl(card.question)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(context)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if again {
                    Chip(text: "Again", symbol: "arrow.counterclockwise", color: Palette.red)
                        .accessibilityLabel("Asked again after it was forgotten")
                }
            }
            Text(Self.inline(card.question))
                .font(.title.weight(.semibold))
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Question: \(card.question). From \(context)")
    }

    /// A heading's inline Markdown (emphasis, code, links) as text.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    @ViewBuilder
    private func footer(_ card: DrillCard, again: Bool) -> some View {
        HStack(spacing: 10) {
            Button { model.open(card.path, line: card.line, store: store) } label: {
                Label("Open Note", systemImage: "arrow.up.forward.square")
            }
            .buttonStyle(.glass)
            .help("Open \(Vault.title(of: card.path)) at this heading (e)")
            Spacer()
            if revealed {
                ForEach(DrillRating.allCases) { rating in
                    ratingButton(rating, card: card, again: again)
                }
            } else {
                Text("Space shows the answer").font(.callout).faint()
            }
        }
        .controlSize(.large)
    }

    private func ratingButton(_ rating: DrillRating, card: DrillCard, again: Bool) -> some View {
        let color = Self.color(rating)
        // A card asked again is not written: its first rating was.
        let when = again ? (rating == .again ? "once more" : "done") : DrillReview.spoken(days: store.drill.preview(card, rating).interval)
        return Button { rate(rating) } label: {
            VStack(spacing: 1) {
                Text("\(rating.rawValue)  \(rating.title)").font(.body.weight(.semibold))
                Text(when).font(.caption.monospacedDigit()).opacity(0.75)
            }
            .frame(minWidth: 72)
        }
        .buttonStyle(.glass)
        // The glass takes the tint: a label in the rating's colour on the
        // window's orange tint could not be read (Hard was orange on orange).
        .tint(color)
        .help("\(rating.title) (\(rating.rawValue)): " + (again ? "this card was rated already" : "next in \(when)"))
        .accessibilityLabel(rating.title)
        .accessibilityValue(again ? (rating == .again ? "asks it once more" : "ends this card") : "next in \(when)")
    }

    static func color(_ rating: DrillRating) -> Color {
        switch rating {
        case .again: Palette.red
        case .hard: Palette.accent
        case .good: Palette.green
        case .easy: Palette.blue
        }
    }

    // MARK: Done

    private var done: some View {
        let deck = store.drill
        let asked = session?.total ?? 0
        let more = deck.session()
        return VStack(spacing: 14) {
            Image(systemName: asked == 0 ? "checkmark.circle" : "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(Palette.green)
                .accessibilityHidden(true)
            Text(asked == 0 ? "No cards are due" : "Done for now").font(.title.bold())
            if let session, asked > 0 {
                Text("\(Spoken.count(session.rated, "card")) rated, \(session.forgotten) forgotten.")
                    .foregroundStyle(.secondary)
            }
            if let next = deck.counts.next {
                Text("The next cards are due \(Self.when(next)).")
                    .foregroundStyle(.secondary)
            }
            if deck.cards.isEmpty {
                Text("A card is a heading of a note in \(Drill.folder)/, and its section is the answer.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack {
                if !more.isDone {
                    Button {
                        answer.view?.isHidden = true
                        withMotion(.easeOut(duration: 0.2)) {
                            session = more
                            revealed = false
                        }
                    } label: {
                        Label("Review \(Spoken.count(more.total, "More Card", plural: "More Cards"))", systemImage: "rectangle.on.rectangle.angled")
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Palette.green)
                    .help("Another session: \(Spoken.count(deck.counts.fresh, "card")) never asked (Return)")
                }
                Button("Close") { model.showsDrill = false }
                    .buttonStyle(.glass)
                    .help("Leave Review Cards (Escape)")
            }
            .controlSize(.large)
            .padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: 560)
    }

    /// `today`, `tomorrow`, or the day and how far it is.
    static func when(_ day: Day, today: Day = .today()) -> String {
        let days = today.days(to: day)
        switch days {
        case ...0: return "today"
        case 1: return "tomorrow"
        default:
            let date = Calendar.current.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) ?? Date()
            return "on \(date.formatted(.dateTime.weekday(.wide).day().month(.wide))), in \(days) days"
        }
    }

    // MARK: Actions

    private func reveal() {
        guard !revealed else { return }
        answer.view?.isHidden = false
        withMotion(.easeOut(duration: 0.16)) { revealed = true }
    }

    private func rate(_ rating: DrillRating) {
        guard revealed, var next = session, let turn = next.current else { return }
        if next.rate(rating) { store.drill.rate(turn.card, rating, store: store) }
        // The answer hides at once, so the next one is never seen fading out.
        var hide = Transaction()
        hide.disablesAnimations = true
        withTransaction(hide) { revealed = false }
        answer.view?.isHidden = true
        withMotion(.easeOut(duration: 0.2)) { session = next }
    }

    /// A key of the page; true when it was used. Keys typed into a field,
    /// the terminal or a sheet, and keys with ⌘, ⌃ or ⌥, are not the page's.
    private func handle(_ event: NSEvent) -> Bool {
        guard model.showsDrill, ActiveWindow.shared.model === model, let window = event.window, window === NSApp.keyWindow,
            window.attachedSheet == nil, !model.quickOpen
        else { return false }
        if let responder = window.firstResponder as? NSTextInputClient, !(responder is WKWebView) {
            if !(responder is NSTextView) || (responder as? NSTextView)?.isEditable == true { return false }
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        guard flags.isEmpty else { return false }
        let current = session?.current
        switch event.keyCode {
        case 53:
            model.showsDrill = false
        case 49, 36, 76:
            if current != nil {
                reveal()
            } else if event.keyCode != 49 {
                let more = store.drill.session()
                guard !more.isDone else { return false }
                answer.view?.isHidden = true
                session = more
                revealed = false
            }
        case 18, 83: rate(.again)
        case 19, 84: rate(.hard)
        case 20, 85: rate(.good)
        case 21, 86: rate(.easy)
        case 14:
            guard let card = current?.card else { return false }
            model.open(card.path, line: card.line, store: store)
        default:
            return false
        }
        return true
    }
}

/// The answer's web view. It lays out the next answer while it is hidden,
/// so the flip only paints; and hidden, VoiceOver does not read the answer
/// before the question is answered.
@MainActor final class AnswerView {
    weak var view: WKWebView?
}

/// The page's keys, from a local monitor: the answer is a web view, which
/// would take them otherwise, and they work with any keyboard layout
/// (Persian too), by key code.
@MainActor final class DrillKeys {
    private var monitor: Any?

    func start(_ handle: @escaping @MainActor (NSEvent) -> Bool) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Local monitors run on the main thread, with the event loop.
            nonisolated(unsafe) let event = event
            let used = MainActor.assumeIsolated { handle(event) }
            return used ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
