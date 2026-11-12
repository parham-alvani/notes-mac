import AppKit
import DaftarCore
import SwiftUI

/// ⇧⌘J: the job search on a board. Every note with a `job_stage` property
/// is a card in its stage's column, the going stages in a search's order
/// and the closed ones folded into one column at the end. A card dragged to
/// another column writes its note's `job_stage`, and nothing else. Above
/// the columns, the events booked for the next two weeks.
struct JobBoardView: View {
    @Bindable var model: WindowModel
    @Environment(VaultStore.self) private var store
    @ViewState private var search: JobSearch?
    @ViewState private var showsClosed = false
    @ViewState private var showsChannels = false
    @ViewState private var target: String?

    /// The days of booked events the strip above the columns shows.
    static let eventDays = 14

    var body: some View {
        VStack(spacing: 0) {
            if let search {
                let board = search.board()
                let now = LocalTime(date: Date())
                let events = search.upcoming(now: now, until: LocalTime(day: now.day.adding(days: Self.eventDays + 1)))
                header(search, booked: events.count)
                if search.applications.isEmpty {
                    ContentUnavailableView {
                        Label("No applications", systemImage: "briefcase")
                    } description: {
                        Text("An application is a note with a `job_stage` property, such as `Companies/Acme/Acme.md`.")
                    }
                } else {
                    eventStrip(events, now: now)
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(board.going) { column($0, in: search, now: now) }
                            if showsClosed {
                                ForEach(board.closed) { column($0, in: search, now: now) }
                            } else {
                                closedSummary(board.closed, in: search)
                            }
                        }
                        .padding(16)
                    }
                }
            } else {
                ProgressView("Reading the job search…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.background)
        // Off the main thread, and again whenever a note changes.
        .task(id: store.revision) { search = await store.jobSearch(quiet: true) }
    }

    // MARK: Parts

    private func header(_ search: JobSearch, booked: Int) -> some View {
        let closed = search.applications.filter(\.closed).count
        let going = search.applications.count - closed
        return GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "briefcase.fill")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(LinearGradient(colors: [Palette.green, Palette.blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Job Search").font(.headline)
                    Text("\(going) going · \(closed) closed · \(booked) booked in \(Self.eventDays) days")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showsChannels.toggle() } label: { Label("Channels", systemImage: "point.3.connected.trianglepath.dotted") }
                    .help("How each channel did: its applications and how many got past applied")
                    .popover(isPresented: $showsChannels, arrowEdge: .bottom) { ChannelsTable(channels: search.channels()) }
                Toggle(isOn: Binding(get: { showsClosed }, set: { on in withMotion(.snappy) { showsClosed = on } })) {
                    Label("Closed", systemImage: "archivebox")
                }
                .toggleStyle(.button)
                .help("Show a column for each closed stage, not one folded column")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    /// The events of the next two weeks, the soonest first.
    private func eventStrip(_ events: [JobApplication], now: LocalTime) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Booked in the next \(Self.eventDays) days").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.green)
                .accessibilityAddTraits(.isHeader)
            if events.isEmpty {
                Text("Nothing is booked. A company's `job_next` property is its next event.").font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(events) { JobEventTile(application: $0, model: model, now: now) }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.horizontal, 16).padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func column(_ column: JobSearch.Column, in search: JobSearch, now: LocalTime) -> some View {
        let color = Self.color(column.stage)
        let lit = target == column.stage
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 9, height: 9).accessibilityHidden(true)
                Text(JobSearch.title(column.stage)).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(column.applications.count)").font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(color.opacity(0.18), in: Capsule())
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(JobSearch.title(column.stage)), \(Spoken.count(column.applications.count, "application"))")
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .glassEffect(.regular.tint(color.opacity(0.22)), in: .rect(cornerRadius: 12))
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(column.applications) { card($0, color: color, in: search, now: now) }
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
        }
        .padding(8)
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(color.opacity(lit ? 0.16 : 0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(color.opacity(lit ? 0.8 : 0), lineWidth: 2))
        .motionAnimation(.snappy, value: lit)
        .dropDestination(for: String.self) { paths, _ in drop(paths, on: column.stage, in: search) } isTargeted: { over in
            if over { target = column.stage } else if target == column.stage { target = nil }
        }
    }

    /// The closed stages folded: a row for each with its count, each a place
    /// to drop a card on; a click unfolds them into columns.
    private func closedSummary(_ columns: [JobSearch.Column], in search: JobSearch) -> some View {
        let count = columns.reduce(0) { $0 + $1.applications.count }
        return VStack(alignment: .leading, spacing: 10) {
            Button { withMotion(.snappy) { showsClosed = true } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "archivebox.fill").foregroundStyle(Palette.muted).accessibilityHidden(true)
                    Text("Closed").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(count)").font(.caption.monospacedDigit().weight(.semibold))
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary).accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Closed, \(Spoken.count(count, "application"))")
            .accessibilityHint("Shows a column for each closed stage")
            .help("Show a column for each closed stage")
            .padding(.horizontal, 12).padding(.vertical, 8)
            .glassEffect(.regular.tint(Palette.muted.opacity(0.22)), in: .rect(cornerRadius: 12))
            ForEach(columns) { column in
                let color = Self.color(column.stage)
                let lit = target == column.stage
                HStack {
                    Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text(JobSearch.title(column.stage))
                    Spacer()
                    Text("\(column.applications.count)").monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(color.opacity(lit ? 0.22 : 0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(color.opacity(lit ? 0.8 : 0), lineWidth: 2))
                .motionAnimation(.snappy, value: lit)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(JobSearch.title(column.stage)), \(Spoken.count(column.applications.count, "application"))")
                .dropDestination(for: String.self) { paths, _ in drop(paths, on: column.stage, in: search) } isTargeted: { over in
                    if over { target = column.stage } else if target == column.stage { target = nil }
                }
            }
        }
        .padding(8)
        .frame(width: 200)
        .background(Palette.muted.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func card(_ application: JobApplication, color: Color, in search: JobSearch, now: LocalTime) -> some View {
        JobCard(application: application, color: color, now: now, model: model)
            .accessibilityActions {
                ForEach(stages(search).filter { $0 != application.stage }, id: \.self) { stage in
                    Button("Move to \(JobSearch.title(stage))") { move(application, to: stage) }
                }
            }
            .draggable(application.path) {
                Text(application.company).font(.headline).padding(10).frame(width: 220, alignment: .leading)
                    .background(Palette.panel, in: RoundedRectangle(cornerRadius: 11))
            }
            .contextMenu {
                Button("Open \(application.company)") { model.open(application.path, store: store) }
                if let prep = application.prep { Button("Open the Preparation Note") { model.open(prep, store: store) } }
                Divider()
                Menu("Move to") {
                    ForEach(stages(search).filter { $0 != application.stage }, id: \.self) { stage in
                        Button(JobSearch.title(stage)) { move(application, to: stage) }
                    }
                }
            }
    }

    // MARK: Moves

    /// Every stage a card can go to: the board's columns, closed ones too.
    private func stages(_ search: JobSearch) -> [String] {
        let board = search.board()
        return (board.going + board.closed).map(\.stage)
    }

    private func drop(_ paths: [String], on stage: String, in search: JobSearch) -> Bool {
        target = nil
        var moved = false
        for path in paths {
            guard let application = search.applications.first(where: { $0.path == path }), application.stage != stage else { continue }
            move(application, to: stage)
            moved = true
        }
        return moved
    }

    /// Writes the stage, and moves the card at once: the board reads the
    /// vault again when the file watcher sees the write.
    private func move(_ application: JobApplication, to stage: String) {
        guard store.setJobStage(application, to: stage), let index = search?.applications.firstIndex(where: { $0.path == application.path }) else { return }
        withMotion(.snappy) {
            search?.applications[index].stage = stage
            search?.applications[index].closed = JobKeys().closed.contains(stage)
        }
        announce("\(application.company) moved to \(JobSearch.title(stage))")
    }

    static func color(_ stage: String) -> Color {
        switch stage {
        case "applied": Palette.blue
        case "screening": Palette.aqua
        case "interviewing": Palette.accent
        case "offer", "accepted": Palette.green
        case "rejected": Palette.red
        case "withdrawn", "declined", "closed": Palette.muted
        default: Palette.named(NSPalette.tagColor(stage))
        }
    }
}

/// One application on the board: the company's logo and name, the role,
/// the channel, the next booked event with a link to its preparation note,
/// and a mark when the note has gone quiet. For VoiceOver it is one element.
struct JobCard: View {
    var application: JobApplication
    var color: Color
    var now: LocalTime
    var model: WindowModel
    @Environment(VaultStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 9) {
                CompanyLogo(path: application.logo, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(application.company).font(.headline).lineLimit(1)
                    if let role = JobText.role(application) {
                        Text(role).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Label(application.channel, systemImage: "arrow.triangle.branch")
                    .foregroundStyle(Palette.purple)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let quiet = application.quiet {
                    Label("Quiet \(quiet.days) days", systemImage: "moon.zzz.fill")
                        .foregroundStyle(Palette.yellow)
                        .padding(.horizontal, 5)
                        .background(Palette.yellow.opacity(0.14), in: Capsule())
                        .help(quiet.message)
                }
            }
            .font(.caption)
            if let when = JobText.when(application) {
                let passed = JobText.passed(application, now: now)
                VStack(alignment: .leading, spacing: 3) {
                    Label(passed ? "\(when), passed" : when, systemImage: application.nextHasTime ? "clock" : "calendar")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(passed ? Palette.red : Palette.green)
                    if let step = application.nextStep {
                        Text(step).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if let prep = application.prep {
                        Button { model.open(prep, store: store) } label: { Label("Preparation", systemImage: "doc.text.magnifyingglass") }
                            .buttonStyle(.link).font(.caption)
                            .help("Open \(Vault.title(of: prep))")
                    }
                }
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((passed ? Palette.red : Palette.green).opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(10)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 11, bottomLeadingRadius: 11).fill(color).frame(width: 3)
        }
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .onTapGesture { model.open(application.path, store: store) }
        // A card is reached with Tab: Return opens the company's note.
        .focusable(interactions: .activate)
        .onKeyPress(.return) {
            model.open(application.path, store: store)
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(JobText.spoken(application, now: now))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the company's note")
        .accessibilityAction(.default) { model.open(application.path, store: store) }
        .accessibilityAction(named: "Open the Preparation Note") {
            if let prep = application.prep { model.open(prep, store: store) }
        }
        .help(application.path)
    }
}

/// A booked event in the strip above the board, or on Today.
struct JobEventTile: View {
    var application: JobApplication
    var model: WindowModel
    var now: LocalTime
    @Environment(VaultStore.self) private var store

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            CompanyLogo(path: application.logo, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(JobText.when(application) ?? "").font(.caption.weight(.bold)).foregroundStyle(Palette.green)
                Text(application.company).font(.callout.weight(.semibold)).lineLimit(1)
                if let step = application.nextStep {
                    Text(step).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let prep = application.prep {
                    Button { model.open(prep, store: store) } label: { Label("Preparation", systemImage: "doc.text.magnifyingglass") }
                        .buttonStyle(.link).font(.caption)
                        .help("Open \(Vault.title(of: prep))")
                }
            }
        }
        .padding(10)
        .frame(width: 250, alignment: .leading)
        .background(Palette.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Palette.green.opacity(0.25)))
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .onTapGesture { model.open(application.path, store: store) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(JobText.spoken(application, now: now))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) { model.open(application.path, store: store) }
        .accessibilityAction(named: "Open the Preparation Note") {
            if let prep = application.prep { model.open(prep, store: store) }
        }
    }
}

/// The next booked event of the job search, on the Today page.
struct NextJobEventCard: View {
    var model: WindowModel
    @Environment(VaultStore.self) private var store
    @ViewState private var next: JobApplication?
    @ViewState private var later = 0

    var body: some View {
        // A VStack, not a Group: a `.task` on an empty Group never runs.
        VStack(alignment: .leading, spacing: 0) {
            if let next {
                Card(title: "Next in the job search", symbol: "briefcase.fill", color: Palette.green) {
                    JobEventTile(application: next, model: model, now: LocalTime(date: Date()))
                    if later > 0 {
                        Button("\(later) more booked · Job Search") { model.page = .jobs }
                            .buttonStyle(.link).font(.callout)
                    }
                }
            }
        }
        .task(id: store.revision) {
            let events = await store.jobSearch(quiet: false).upcoming(now: LocalTime(date: Date()))
            next = events.first
            later = max(events.count - 1, 0)
        }
    }
}

/// The table of channels in the board's header.
private struct ChannelsTable: View {
    var channels: [ChannelCount]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                Text("Channel")
                Text("Applied").gridColumnAlignment(.trailing)
                Text("Past applied").gridColumnAlignment(.trailing)
                Text("Rate").gridColumnAlignment(.trailing)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Divider()
            ForEach(channels, id: \.channel) { channel in
                GridRow {
                    Text(channel.channel).lineLimit(1)
                    Text("\(channel.applications)").monospacedDigit()
                    Text("\(channel.pastApplied)").monospacedDigit()
                    Text("\(Int(channel.rate.rounded()))%").monospacedDigit().foregroundStyle(channel.pastApplied > 0 ? Palette.green : Palette.muted)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(channel.channel): \(Spoken.count(channel.applications, "application")), \(channel.pastApplied) past applied, \(Int(channel.rate.rounded())) percent")
            }
        }
        .font(.callout)
        .padding(14)
        .frame(minWidth: 360)
    }
}

/// A company folder's logo, as the sidebar draws it, or a building.
struct CompanyLogo: View {
    var path: String?
    var size: CGFloat
    @Environment(VaultStore.self) private var store

    var body: some View {
        Group {
            if let url = path.flatMap(store.url(of:)), let image = Logo.image(url) {
                Image(nsImage: image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: size / 5, style: .continuous))
            } else {
                Image(systemName: "building.2.fill").resizable().scaledToFit().padding(size / 6)
                    .foregroundStyle(Palette.aqua)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// What a card says, in the app's date style on Madrid's clock.
enum JobText {
    /// `Fri 13 Nov, 15:30`, or the day alone.
    static func when(_ application: JobApplication) -> String? {
        guard let date = application.next?.date() else { return nil }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated)
        if application.nextHasTime { style = style.hour().minute() }
        style.timeZone = LocalTime.zone
        return date.formatted(style)
    }

    /// The booked event is behind [now]: the note should say what happened.
    static func passed(_ application: JobApplication, now: LocalTime) -> Bool {
        guard let next = application.next else { return false }
        return application.nextHasTime ? next < now : next.day < now.day
    }

    /// The first role, and how many more.
    static func role(_ application: JobApplication) -> String? {
        guard let first = application.roles.first(where: { !$0.isEmpty }) else { return nil }
        return application.roles.count > 1 ? "\(first) +\(application.roles.count - 1)" : first
    }

    /// The card in words.
    static func spoken(_ application: JobApplication, now: LocalTime) -> String {
        var parts = [application.company, JobSearch.title(application.stage)]
        if !application.roles.isEmpty { parts.append(application.roles.joined(separator: " and ")) }
        parts.append("via \(application.channel)")
        if let when = when(application) {
            parts.append("next: \(application.nextStep ?? "an event") on \(when)" + (passed(application, now: now) ? ", passed" : ""))
        }
        if let quiet = application.quiet { parts.append("quiet for \(quiet.days) days") }
        if application.prep != nil { parts.append("has a preparation note") }
        return parts.joined(separator: ", ")
    }
}

extension VaultStore {
    /// The vault's job search, read off the main thread from the index as
    /// it is now. With [quiet], each going note is read from disk for the
    /// `memory-quiet` rule of the vault's `.daftar.toml`.
    func jobSearch(quiet: Bool) async -> JobSearch {
        let index = index, excluded = excluded, root = root
        return await Task.detached(priority: .userInitiated) {
            var search = JobSearch(index: index) { !excluded.contains($0) }
            if quiet, let root {
                let rules = QuietRules.read(try? String(contentsOf: root.appending(path: ".daftar.toml"), encoding: .utf8))
                let today = LocalTime(date: Date()).day
                search.markQuiet(rules, today: today) { path in
                    guard let file = VaultStore.file(path, in: root) else { return nil }
                    return try? String(contentsOf: file, encoding: .utf8)
                }
            }
            return search
        }.value
    }
}
