import DaftarCore
import SwiftUI

/// The inspector's outline: the note's headings, each in its colour, the
/// section the reader or the editor's cursor is in marked. A click goes to
/// the heading; a heading dragged onto another of its level moves its
/// section, with the headings under it, to that one's place.
struct OutlineSection: View {
    var model: WindowModel
    var path: String
    var headings: [Heading]
    @Environment(VaultStore.self) private var store
    /// The heading a drag is over.
    @ViewState private var targeted: Int?

    private static let prefix = "daftar-heading:"

    var body: some View {
        Section("Outline") {
            ForEach(Array(headings.enumerated()), id: \.offset) { offset, heading in
                let current = model.section == heading.line
                Button {
                    model.showHeading(heading, in: path, store: store)
                } label: {
                    OutlineRow(heading: heading, current: current, targeted: targeted == offset)
                }
                .buttonStyle(.plain)
                .draggable(Self.prefix + String(offset))
                .dropDestination(for: String.self) { items, _ in
                    guard let item = items.first, item.hasPrefix(Self.prefix), let from = Int(item.dropFirst(Self.prefix.count)),
                        headings.indices.contains(from), from != offset
                    else { return false }
                    model.dropSection(headings[from], on: heading, store: store)
                    return true
                } isTargeted: { inside in
                    if inside { targeted = offset } else if targeted == offset { targeted = nil }
                }
                .accessibilityLabel(Spoken.heading(level: heading.level, text: heading.text))
                .accessibilityAddTraits(current ? .isSelected : [])
                // The drag, for VoiceOver.
                .accessibilityAction(named: "Move Section Up") { move(offset, by: -1) }
                .accessibilityAction(named: "Move Section Down") { move(offset, by: 1) }
            }
        }
    }

    /// The section of heading [offset] past its previous or next sibling.
    private func move(_ offset: Int, by step: Int) {
        let siblings = Sections.siblings(of: offset, in: headings)
        guard let at = siblings.firstIndex(of: offset), siblings.indices.contains(at + step) else { return }
        model.dropSection(headings[offset], on: headings[siblings[at + step]], store: store)
    }
}

/// One heading of the outline: its level's colour and indent.
struct OutlineRow: View {
    var heading: Heading
    var current: Bool
    var targeted: Bool

    var body: some View {
        let color = Palette.heading(heading.level)
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 3, height: heading.level <= 2 ? 14 : 10)
            Text(heading.text)
                .font(heading.level <= 2 ? .body.weight(.medium) : .callout)
                .foregroundStyle(heading.level <= 3 ? color : .secondary)
                .lineLimit(1)
        }
        .padding(.leading, CGFloat(heading.level - 1) * 10)
        .frame(maxWidth: .infinity, alignment: TextDirection.startsRtl(heading.text) ? .trailing : .leading)
        .padding(.vertical, 1).padding(.horizontal, 4)
        .background(current ? color.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            // Where a dragged section goes.
            if targeted { RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.accent, lineWidth: 1.5) }
        }
        .contentShape(Rectangle())
    }
}
