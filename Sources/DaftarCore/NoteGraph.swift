import Foundation

/// The notes and the links between them, for the graph view: around one
/// note, or the whole vault.
public struct NoteGraph: Sendable, Equatable {
    public struct Node: Sendable, Equatable {
        public var path: String
        public var title: String
        /// The top folder, which gives the node its colour.
        public var group: String
        /// How many links touch it, which gives its size.
        public var degree: Int
        /// Steps from the centre note; 0 is the centre, and the whole vault has none.
        public var distance: Int?
    }

    public struct Edge: Sendable, Equatable, Hashable {
        public var from: Int
        public var to: Int
    }

    public var nodes: [Node] = []
    public var edges: [Edge] = []

    public init() {}

    /// Every note and the links between notes, without the excluded ones.
    public static func vault(_ index: VaultIndex, excluded: ExcludedFiles = ExcludedFiles()) -> NoteGraph {
        let paths = index.notes.keys.filter { !excluded.contains($0) }.sorted()
        return build(index, paths: paths, distances: [:])
    }

    /// [center] and the notes [depth] links away, in either direction.
    public static func local(_ index: VaultIndex, center: String, depth: Int = 2) -> NoteGraph {
        var distances: [String: Int] = [center: 0]
        var frontier = [center]
        for step in 1...max(1, depth) {
            var next: [String] = []
            for path in frontier {
                for neighbour in neighbours(of: path, in: index) where distances[neighbour] == nil {
                    distances[neighbour] = step
                    next.append(neighbour)
                }
            }
            frontier = next
        }
        let paths = distances.keys.sorted { (distances[$0]!, $0) < (distances[$1]!, $1) }
        return build(index, paths: paths, distances: distances)
    }

    /// Notes this one links to, and notes that link to it.
    static func neighbours(of path: String, in index: VaultIndex) -> [String] {
        var out: [String] = []
        for link in index.notes[path]?.parsed.links ?? [] {
            if let target = index.resolve(link.target, from: path), Vault.isNote(target), target != path, !out.contains(target) { out.append(target) }
        }
        for back in index.backlinks[path] ?? [] where !out.contains(back.source) { out.append(back.source) }
        return out
    }

    static func build(_ index: VaultIndex, paths: [String], distances: [String: Int]) -> NoteGraph {
        var graph = NoteGraph()
        var position: [String: Int] = [:]
        for path in paths {
            position[path] = graph.nodes.count
            let group = path.contains("/") ? String(path.split(separator: "/")[0]) : ""
            graph.nodes.append(Node(path: path, title: Vault.title(of: path), group: group, degree: 0, distance: distances[path]))
        }
        var seen = Set<Edge>()
        for path in paths {
            guard let from = position[path] else { continue }
            for link in index.notes[path]?.parsed.links ?? [] {
                guard let target = index.resolve(link.target, from: path), let to = position[target], to != from else { continue }
                let edge = Edge(from: min(from, to), to: max(from, to))
                if seen.insert(edge).inserted { graph.edges.append(edge) }
            }
        }
        for edge in graph.edges {
            graph.nodes[edge.from].degree += 1
            graph.nodes[edge.to].degree += 1
        }
        return graph
    }
}

/// A force layout: links pull, all nodes push, and a weak pull keeps the
/// whole near the middle. The push only counts nodes in nearby cells of a
/// grid, so a vault of thousands of notes lays out in a moment.
public struct GraphLayout: Sendable {
    public var x: [Double]
    public var y: [Double]
    let edges: [NoteGraph.Edge]
    let pinned: Int?

    /// Nodes start on a spiral, so the same graph lays out the same way.
    public init(_ graph: NoteGraph, pin center: Int? = nil) {
        let count = graph.nodes.count
        x = (0..<count).map { cos(Double($0) * 2.399963) * sqrt(Double($0) + 0.5) * 30 }
        y = (0..<count).map { sin(Double($0) * 2.399963) * sqrt(Double($0) + 0.5) * 30 }
        edges = graph.edges
        pinned = center
        if let center, center < count {
            x[center] = 0
            y[center] = 0
        }
    }

    public mutating func run(_ steps: Int = 300) {
        for step in 0..<steps {
            self.step(temperature: 1 - Double(step) / Double(steps))
        }
    }

    public mutating func step(temperature: Double) {
        let count = x.count
        guard count > 1 else { return }
        let spacing = 60.0
        let cell = spacing * 3
        var dx = [Double](repeating: 0, count: count)
        var dy = [Double](repeating: 0, count: count)
        var grid: [Int64: [Int]] = [:]
        let xs = x, ys = y
        func key(_ i: Int) -> (Int64, Int64) { (Int64((xs[i] / cell).rounded(.down)), Int64((ys[i] / cell).rounded(.down))) }
        for i in 0..<count {
            let (cx, cy) = key(i)
            grid[cx &* 1_000_003 &+ cy, default: []].append(i)
        }
        // The push on each node is its own sum, so the nodes are shared
        // out among the cores: a whole vault's thousands of notes gather
        // in crowded cells as the layout cools, and one core took seconds.
        // Each node adds its pushes in the same order as before.
        let pushes = UnsafeMutableBufferPointer<Double>.allocate(capacity: count * 2)
        defer { pushes.deallocate() }
        let chunk = 256
        nonisolated(unsafe) let out = pushes
        DispatchQueue.concurrentPerform(iterations: (count + chunk - 1) / chunk) { part in
            for i in (part * chunk)..<min(count, (part + 1) * chunk) {
                var px = 0.0, py = 0.0
                let (cx, cy) = key(i)
                for ox in -1...1 {
                    for oy in -1...1 {
                        guard let near = grid[(cx + Int64(ox)) &* 1_000_003 &+ (cy + Int64(oy))] else { continue }
                        for j in near where j != i {
                            var ddx = xs[i] - xs[j], ddy = ys[i] - ys[j]
                            var distance = (ddx * ddx + ddy * ddy).squareRoot()
                            if distance < 0.01 {
                                ddx = Double((i * 7919 + j) % 13) - 6
                                ddy = Double((i * 104_729 + j) % 11) - 5
                                distance = 1
                            }
                            let push = spacing * spacing / distance
                            px += ddx / distance * push
                            py += ddy / distance * push
                        }
                    }
                }
                out[i * 2] = px
                out[i * 2 + 1] = py
            }
        }
        for i in 0..<count {
            dx[i] = pushes[i * 2]
            dy[i] = pushes[i * 2 + 1]
        }
        for edge in edges {
            let ddx = x[edge.to] - x[edge.from], ddy = y[edge.to] - y[edge.from]
            let distance = max((ddx * ddx + ddy * ddy).squareRoot(), 0.01)
            let pull = distance * distance / (spacing * 2)
            dx[edge.from] += ddx / distance * pull
            dy[edge.from] += ddy / distance * pull
            dx[edge.to] -= ddx / distance * pull
            dy[edge.to] -= ddy / distance * pull
        }
        let limit = max(2, 40 * temperature)
        for i in 0..<count where i != pinned {
            // A weak pull to the middle keeps parts that do not link apart, but near.
            dx[i] -= x[i] * 0.02
            dy[i] -= y[i] * 0.02
            let length = (dx[i] * dx[i] + dy[i] * dy[i]).squareRoot()
            guard length > 0, length.isFinite else { continue }
            let move = min(length, limit)
            x[i] += dx[i] / length * move
            y[i] += dy[i] / length * move
        }
    }
}
