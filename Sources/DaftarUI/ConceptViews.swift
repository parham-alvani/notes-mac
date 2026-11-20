import DaftarCore
import SwiftUI

/// An OKF concept in the app: a note whose front matter has a `type`
/// (`OKF`, core; `docs/specs/open-knowledge-format.md` in notes-linux). The
/// inspector's Concept section, the line above a deprecated or stale
/// concept in the reader, and Mark as Verified.
struct ConceptSection: View {
    var model: WindowModel
    var path: String
    var concept: OKF.Concept
    @Environment(VaultStore.self) private var store

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(concept.type).font(.callout.weight(.medium)).lineLimit(2)
                    .accessibilityLabel("Type: \(concept.type)")
                ConceptChips(concept: concept)
                if let description = concept.description {
                    Text(description).font(.callout).foregroundStyle(.secondary).lineLimit(4)
                }
                Button("Mark as Verified", systemImage: "checkmark.seal") {
                    Task { await store.markVerified(path) }
                }
                .buttonStyle(.glass).controlSize(.small)
                .disabled(store.readOnly)
                .help(store.readOnly ? ReadOnlyBadge.explanation : "Adds your name and the time to this concept's verified property: you checked that it is right")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } header: {
            InspectorHeader { SectionTitle(title: "Concept", count: 0, color: Palette.blue) }
        }
    }
}

/// The trust tier, the status when it is not stable, and staleness, each in
/// words: a colour alone says nothing to VoiceOver.
struct ConceptChips: View {
    var concept: OKF.Concept

    var body: some View {
        let tier = concept.tier
        HStack(spacing: 6) {
            chip(tier.title, symbol: Self.symbol(tier), color: Self.color(tier)).help(Self.tooltip(concept))
            if let status = concept.status.title {
                chip(status, symbol: concept.isDeprecated ? "archivebox" : "pencil.line", color: concept.isDeprecated ? Palette.red : Palette.yellow)
                    .help(concept.isDeprecated ? "This concept is deprecated: it is kept, and should not be relied on" : "The status its properties give")
            }
            if let stale = concept.staleTitle() {
                chip(stale, symbol: "clock.badge.exclamationmark", color: Palette.accent)
                    .help(concept.staleIsMalformed ? "stale_after is not a date Daftar can read, so the concept counts as stale" : "Past its stale_after: check it again")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func chip(_ title: String, symbol: String, color: Color) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    static func symbol(_ tier: OKF.Tier) -> String {
        switch tier {
        case .unverified: "questionmark.circle"
        case .machineConfirmed: "gearshape.2"
        case .humanReviewed: "checkmark.seal.fill"
        }
    }

    static func color(_ tier: OKF.Tier) -> Color {
        switch tier {
        case .unverified: Palette.muted
        case .machineConfirmed: Palette.aqua
        case .humanReviewed: Palette.green
        }
    }

    /// The last current verifier and its day, or why there is none.
    static func tooltip(_ concept: OKF.Concept) -> String {
        if let last = concept.lastVerified, let date = last.at.date { return "Verified by \(last.by) on \(OKF.day(date))" }
        if concept.verified.isEmpty { return "Nobody has confirmed this text" }
        return "The text changed after it was last confirmed"
    }
}

/// One line above a deprecated or stale concept's text in the reader, and
/// nothing above any other note.
struct ConceptLine: View {
    var path: String
    var open: (String) -> Void
    @Environment(VaultStore.self) private var store

    var body: some View {
        if let concept = store.index.concept(of: path), let text = Self.text(concept) {
            HStack(spacing: 6) {
                Image(systemName: concept.isDeprecated ? "archivebox" : "clock.badge.exclamationmark").accessibilityHidden(true)
                Text(text)
                if concept.isDeprecated, let next = store.index.superseding(path) {
                    Text("Replaced by")
                    Button(Vault.title(of: next)) { open(next) }
                        .buttonStyle(.link)
                        .accessibilityHint("Opens the concept that replaces this one")
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .foregroundStyle(concept.isDeprecated ? Palette.red : Palette.accent)
            .padding(.horizontal, 16).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .accessibilityElement(children: .contain)
        }
    }

    /// "Deprecated." or "Stale since <day>: check it again."; nil for any other concept.
    static func text(_ concept: OKF.Concept, now: Date = Date()) -> String? {
        if concept.isDeprecated { return "Deprecated." }
        guard concept.isStale(now: now) else { return nil }
        guard let date = concept.staleAfter?.date else { return "Stale: its stale_after is not a date. Check it again." }
        return "Stale since \(OKF.day(date)): check it again."
    }
}

extension VaultStore {
    /// The note at [path] is a deprecated concept: dimmed in quick open and search.
    func isDeprecated(_ path: String) -> Bool { index.concept(of: path)?.isDeprecated == true }

    /// Who Mark as Verified signs as: `okf.actor` of the settings, else the
    /// local part of the clone's `user.email`; nil when neither says.
    func verifier() async -> String? {
        var email: String?
        if let root, isRepository { email = try? await Git(root: root).run(["config", "--get", "user.email"]) }
        return OKF.actor(configured: settings.okfActor, email: email)
    }

    /// Mark as Verified: `{ by: human:<id>, at: <now> }` in the concept's
    /// `verified`, in the place of that person's event when there is one.
    /// The editors save first, the file is read again, and only the lines
    /// of `verified` change. Never in a read-only vault, and only on a concept.
    @discardableResult
    func markVerified(_ path: String, at now: Date = Date()) async -> Bool {
        do {
            try refuseReadOnly()
        } catch {
            notice = Self.readOnlyNotice
            return false
        }
        guard let actor = await verifier() else {
            notice = "Set who you are first: okf.actor in the settings file (Settings › Vault), or user.email in the vault's git config."
            return false
        }
        await flushEditors()
        guard let text = text(of: path) else {
            notice = "\(Vault.title(of: path)) could not be read."
            return false
        }
        do {
            let marked = try OKF.markVerified(text, by: actor, at: now, path: path)
            try write(marked, to: path)
            // The editors take it now, as they take a property's change.
            noteChanged(path)
            notice = "Verified by \(actor)."
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }
}

extension PaletteCommands {
    /// Mark as Verified, on a concept only.
    static func concept(model: WindowModel, store: VaultStore) -> [PaletteCommand] {
        guard !model.showsPage, let path = model.path, store.index.concept(of: path) != nil, !store.readOnly else { return [] }
        return [
            PaletteCommand(id: "mark-verified", title: "Mark as Verified", group: "Note", symbol: "checkmark.seal.fill", color: Palette.green) {
                Task { await store.markVerified(path) }
            }
        ]
    }
}
