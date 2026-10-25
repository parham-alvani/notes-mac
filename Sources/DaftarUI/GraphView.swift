import AppKit
import DaftarCore
import SwiftUI

/// ⌥⌘G: the notes around the open one, or the whole vault, as a graph.
/// Each top folder has its colour, a node grows with its links, the open
/// note glows, and pointing at a note lights its links.
struct GraphView: View {
    @Bindable var model: WindowModel
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @ViewState private var wholeVault = false
    @ViewState private var depth = 2
    @ViewState private var graph = NoteGraph()
    @ViewState private var layout: GraphLayout?
    @ViewState private var hovered: Int?
    @ViewState private var zoom: CGFloat = 1
    @ViewState private var settledZoom: CGFloat = 1
    @ViewState private var pan: CGSize = .zero
    @ViewState private var settledPan: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geometry in
                ZStack {
                    if let layout {
                        canvas(layout, size: geometry.size)
                    } else {
                        ProgressView("Laying out \(graph.nodes.count) notes…")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.background)
            }
            legend
        }
        .frame(width: 980, height: 720)
        .task(id: "\(wholeVault)|\(depth)|\(store.revision)") { await build() }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(LinearGradient(colors: [Palette.purple, Palette.blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(wholeVault ? "Graph of \(store.name)" : "Graph of \(model.path.map(Vault.title(of:)) ?? "the note")").font(.headline)
                Text("\(graph.nodes.count) notes · \(graph.edges.count) links").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !wholeVault {
                Stepper("\(depth) \(depth == 1 ? "step" : "steps") away", value: $depth, in: 1...4).fixedSize()
            }
            Picker("Show", selection: $wholeVault) {
                Text("This note").tag(false)
                Text("Whole vault").tag(true)
            }
            .pickerStyle(.segmented).fixedSize()
            .disabled(model.path == nil)
            Button { withAnimation { zoom = 1; settledZoom = 1; pan = .zero; settledPan = .zero } } label: {
                Image(systemName: "scope")
            }
            .help("Fit the graph to the window")
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    private var legend: some View {
        let groups = Dictionary(grouping: graph.nodes, by: \.group).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }.prefix(8)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(groups), id: \.0) { group, count in
                    HStack(spacing: 5) {
                        Circle().fill(color(of: group)).frame(width: 9, height: 9)
                        Text(group.isEmpty ? "Vault root" : group).font(.caption)
                        Text("\(count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(color(of: group).opacity(0.12), in: Capsule())
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private func color(of group: String) -> Color {
        group.isEmpty ? Palette.muted : Palette.named(NSPalette.tagColor(group))
    }

    // MARK: Drawing

    /// Where the graph's own coordinates fall in the view.
    private func transform(_ layout: GraphLayout, size: CGSize) -> (scale: CGFloat, dx: CGFloat, dy: CGFloat) {
        guard let minX = layout.x.min(), let maxX = layout.x.max(), let minY = layout.y.min(), let maxY = layout.y.max() else {
            return (1, size.width / 2, size.height / 2)
        }
        let width = max(maxX - minX, 1), height = max(maxY - minY, 1)
        let fit = min((size.width - 80) / width, (size.height - 80) / height, 2.2)
        let scale = fit * zoom
        let dx = size.width / 2 - (minX + maxX) / 2 * scale + pan.width
        let dy = size.height / 2 - (minY + maxY) / 2 * scale + pan.height
        return (scale, dx, dy)
    }

    private func radius(_ node: NoteGraph.Node) -> CGFloat {
        (node.distance == 0 ? 9 : 3.5) + CGFloat(Double(node.degree).squareRoot()) * 1.8
    }

    private func canvas(_ layout: GraphLayout, size: CGSize) -> some View {
        let t = transform(layout, size: size)
        let point = { (i: Int) in CGPoint(x: layout.x[i] * t.scale + t.dx, y: layout.y[i] * t.scale + t.dy) }
        let lit: Set<Int> = hovered.map { hover in
            Set(graph.edges.compactMap { $0.from == hover ? $0.to : $0.to == hover ? $0.from : nil } + [hover])
        } ?? []
        let showAll = graph.nodes.count <= 120 || t.scale > 1.4
        return Canvas { context, _ in
            // Links: faint, and lit in the accent when they touch the pointed note.
            for edge in graph.edges {
                var path = Path()
                path.move(to: point(edge.from))
                path.addLine(to: point(edge.to))
                let on = hovered != nil && (edge.from == hovered || edge.to == hovered)
                context.stroke(path, with: .color(on ? Palette.accent.opacity(0.9) : Palette.muted.opacity(hovered == nil ? 0.28 : 0.1)),
                    lineWidth: on ? 1.8 : 0.8)
            }
            for (i, node) in graph.nodes.enumerated() {
                let center = point(i)
                let r = radius(node) * min(max(t.scale, 0.6), 1.6)
                let dim = hovered != nil && !lit.contains(i)
                let fill = node.distance == 0 ? Palette.accent : color(of: node.group)
                if node.distance == 0 || hovered == i {
                    context.fill(Path(ellipseIn: CGRect(x: center.x - r * 2.2, y: center.y - r * 2.2, width: r * 4.4, height: r * 4.4)),
                        with: .radialGradient(Gradient(colors: [fill.opacity(0.45), fill.opacity(0)]), center: center, startRadius: r, endRadius: r * 2.2))
                }
                context.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)), with: .color(fill.opacity(dim ? 0.25 : 1)))
                let labelled = showAll || node.distance == 0 || lit.contains(i) || node.degree >= 12
                if labelled {
                    let text = Text(node.title)
                        .font(.system(size: node.distance == 0 ? 13 : 10.5, weight: node.distance == 0 || hovered == i ? .semibold : .regular))
                        .foregroundStyle(dim ? Palette.muted.opacity(0.4) : node.distance == 0 ? Palette.accent : Color.primary.opacity(0.85))
                    context.draw(text, at: CGPoint(x: center.x, y: center.y + r + 8), anchor: .top)
                }
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): hovered = nearest(to: location, layout, t)
            case .ended: hovered = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { pan = CGSize(width: settledPan.width + $0.translation.width, height: settledPan.height + $0.translation.height) }
                .onEnded { _ in settledPan = pan })
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { zoom = min(max(settledZoom * $0.magnification, 0.2), 8) }
                .onEnded { _ in settledZoom = zoom })
        .onTapGesture { location in
            guard let i = nearest(to: location, layout, t) else { return }
            model.open(graph.nodes[i].path, store: store)
            dismiss()
        }
        .overlay(alignment: .bottomTrailing) {
            if let hovered, graph.nodes.indices.contains(hovered) {
                let node = graph.nodes[hovered]
                VStack(alignment: .trailing, spacing: 2) {
                    Text(node.title).font(.callout.weight(.semibold))
                    Text("\(node.degree) \(node.degree == 1 ? "link" : "links") · \(node.path)").font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color(of: node.group).opacity(0.6)))
                .padding(12)
            }
        }
    }

    private func nearest(to location: CGPoint, _ layout: GraphLayout, _ t: (scale: CGFloat, dx: CGFloat, dy: CGFloat)) -> Int? {
        var best: (Int, CGFloat)?
        for i in graph.nodes.indices {
            let distance = hypot(layout.x[i] * t.scale + t.dx - location.x, layout.y[i] * t.scale + t.dy - location.y)
            if distance < max(12, radius(graph.nodes[i]) + 4), best == nil || distance < best!.1 { best = (i, distance) }
        }
        return best?.0
    }

    // MARK: Data

    private func build() async {
        let index = store.index
        let excluded = store.excluded
        let whole = wholeVault || model.path == nil
        let center = model.path
        let depth = self.depth
        layout = nil
        let (built, laidOut) = await Task.detached(priority: .userInitiated) { () -> (NoteGraph, GraphLayout) in
            let graph = whole || center == nil ? NoteGraph.vault(index, excluded: excluded) : NoteGraph.local(index, center: center!, depth: depth)
            var layout = GraphLayout(graph, pin: whole ? nil : 0)
            layout.run(graph.nodes.count > 800 ? 160 : 300)
            return (graph, layout)
        }.value
        guard !Task.isCancelled else { return }
        graph = built
        layout = laidOut
        hovered = nil
    }
}
