import DaftarCore
import SwiftUI

/// The inspector's outline: the note's headings, each in its colour, the
/// section the reader or the editor's cursor is in marked. A click goes to
/// the heading; a heading dragged onto another of its level moves its
/// section, with the headings under it, to that one's place. The arrow of a
/// heading with headings under it closes or opens it in the outline only;
/// with Option, every heading of its level. The app keeps what is closed.
/// A heading's menu also sorts the headings right under it by name.
struct OutlineSection: View {
    var model: WindowModel
    var path: String
    var headings: [Heading]
    @Environment(VaultStore.self) private var store
    /// The heading a drag is over.
    @ViewState private var targeted: Int?

    private static let prefix = "daftar-heading:"

    var body: some View {
        let closed = store.places.closed(path)
        let visible = Sections.visible(headings, closed: closed)
        // The section in a closed heading marks that heading.
        let current = headings.firstIndex { $0.line == model.section }.flatMap { Sections.shown($0, visible: visible) }
        Section("Outline") {
            ForEach(visible, id: \.self) { offset in
                let heading = headings[offset]
                let parent = Sections.hasChildren(offset, in: headings)
                let shut = parent && closed.contains(Sections.key(heading))
                HStack(spacing: 2) {
                    if parent {
                        Button {
                            toggle(offset, all: NSEvent.modifierFlags.contains(.option))
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(shut ? 0 : 90))
                                .frame(width: 12, height: 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(shut ? "Open (⌥ for every heading of this level)" : "Close (⌥ for every heading of this level)")
                        .accessibilityHidden(true)
                    } else {
                        Color.clear.frame(width: 12, height: 14)
                    }
                    Button {
                        model.showHeading(heading, in: path, store: store)
                    } label: {
                        OutlineRow(heading: heading, current: current == offset, targeted: targeted == offset)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, CGFloat(heading.level - 1) * 10)
                .contextMenu {
                    if parent {
                        Button(shut ? "Open" : "Close") { toggle(offset, all: false) }
                        Button(shut ? "Open Every Heading of This Level" : "Close Every Heading of This Level") { toggle(offset, all: true) }
                        Divider()
                    }
                    Button("Sort Headings Under This") { model.sortHeadings(under: heading, store: store) }
                        .disabled(Sections.children(of: offset, in: headings).count < 2)
                }
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
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Spoken.heading(level: heading.level, text: heading.text))
                .accessibilityValue(parent ? (shut ? "closed" : "open") : "")
                .accessibilityAddTraits(current == offset ? .isSelected : [])
                .accessibilityAction { model.showHeading(heading, in: path, store: store) }
                .accessibilityActions {
                    if parent {
                        Button(shut ? "Open" : "Close") { toggle(offset, all: false) }
                        Button(shut ? "Open Every Heading of This Level" : "Close Every Heading of This Level") { toggle(offset, all: true) }
                    }
                    if Sections.children(of: offset, in: headings).count > 1 {
                        Button("Sort Headings Under This") { model.sortHeadings(under: heading, store: store) }
                    }
                }
                // The drag, for VoiceOver.
                .accessibilityAction(named: "Move Section Up") { move(offset, by: -1) }
                .accessibilityAction(named: "Move Section Down") { move(offset, by: 1) }
            }
        }
    }

    /// Closes heading [offset] when it is open, and opens it when it is
    /// closed; with [all], every heading of its level with headings under it.
    private func toggle(_ offset: Int, all: Bool) {
        var closed = store.places.closed(path)
        let key = Sections.key(headings[offset])
        let close = !closed.contains(key)
        let level = headings[offset].level
        let targets = all ? headings.indices.filter { headings[$0].level == level && Sections.hasChildren($0, in: headings) } : [offset]
        for target in targets {
            if close { closed.insert(Sections.key(headings[target])) } else { closed.remove(Sections.key(headings[target])) }
        }
        store.places.setClosed(path, closed)
    }

    /// The section of heading [offset] past its previous or next sibling.
    private func move(_ offset: Int, by step: Int) {
        let siblings = Sections.siblings(of: offset, in: headings)
        guard let at = siblings.firstIndex(of: offset), siblings.indices.contains(at + step) else { return }
        model.dropSection(headings[offset], on: headings[siblings[at + step]], store: store)
    }
}

/// One heading of the outline, in its level's colour; the outline indents it.
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
