import Foundation

/// A `.canvas` file: Obsidian's board, in the JSON Canvas 1.0 format
/// (jsoncanvas.org). Cards -- text, a file of the vault, a web link, or a
/// group around others -- at a place and a size, and arrows between them.
///
/// The app only reads a canvas, and reads what it can: a key it does not
/// know is skipped, a node of an unknown type or without an id is left out,
/// an edge to a node that is not there is left out, and a file that is not
/// JSON is an empty board. Nothing in the file can stop the app.
public struct Canvas: Codable, Sendable, Equatable {
    public struct Node: Codable, Sendable, Equatable {
        public var id: String
        /// `text`, `file`, `link` or `group`.
        public var type: String
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        /// `"1"` to `"6"`, a preset colour, or `#rrggbb`.
        public var color: String?
        /// A text card's Markdown.
        public var text: String?
        /// A file card's vault path, and a heading or block in it (`#Part`).
        public var file: String?
        public var subpath: String?
        /// A link card's address.
        public var url: String?
        /// A group's title, and its background picture.
        public var label: String?
        public var background: String?
        public var backgroundStyle: String?

        public init(id: String, type: String, x: Double = 0, y: Double = 0, width: Double = 250, height: Double = 60) {
            self.id = id
            self.type = type
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        enum CodingKeys: String, CodingKey {
            case id, type, x, y, width, height, color, text, file, subpath, url, label, background, backgroundStyle
        }

        public init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: CodingKeys.self)
            guard let id = keys.lossyString(.id), !id.isEmpty, let type = keys.lossyString(.type), Canvas.types.contains(type) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a node the app draws"))
            }
            self.init(id: id, type: type)
            x = keys.lossyNumber(.x) ?? 0
            y = keys.lossyNumber(.y) ?? 0
            // A card is never too small to see or too large to draw.
            width = min(max(keys.lossyNumber(.width) ?? 250, 10), Canvas.largest)
            height = min(max(keys.lossyNumber(.height) ?? 60, 10), Canvas.largest)
            color = keys.lossyString(.color)
            text = keys.lossyString(.text)
            file = keys.lossyString(.file)
            subpath = keys.lossyString(.subpath)
            url = keys.lossyString(.url)
            label = keys.lossyString(.label)
            background = keys.lossyString(.background)
            backgroundStyle = keys.lossyString(.backgroundStyle)
        }
    }

    public struct Edge: Codable, Sendable, Equatable {
        public var id: String
        public var fromNode: String
        public var toNode: String
        /// `top`, `right`, `bottom` or `left`; nil lets the app choose.
        public var fromSide: String?
        public var toSide: String?
        /// `none` or `arrow`. An edge has an arrow at its end, not its start,
        /// unless it says otherwise.
        public var fromEnd: String
        public var toEnd: String
        public var color: String?
        public var label: String?

        public init(id: String, fromNode: String, toNode: String) {
            self.id = id
            self.fromNode = fromNode
            self.toNode = toNode
            fromEnd = "none"
            toEnd = "arrow"
        }

        enum CodingKeys: String, CodingKey {
            case id, fromNode, toNode, fromSide, toSide, fromEnd, toEnd, color, label
        }

        public init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: CodingKeys.self)
            guard let from = keys.lossyString(.fromNode), let to = keys.lossyString(.toNode) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "an edge needs two ends"))
            }
            self.init(id: keys.lossyString(.id) ?? "\(from)->\(to)", fromNode: from, toNode: to)
            fromSide = keys.lossyString(.fromSide).flatMap { Canvas.sides.contains($0) ? $0 : nil }
            toSide = keys.lossyString(.toSide).flatMap { Canvas.sides.contains($0) ? $0 : nil }
            if let end = keys.lossyString(.fromEnd), Canvas.ends.contains(end) { fromEnd = end }
            if let end = keys.lossyString(.toEnd), Canvas.ends.contains(end) { toEnd = end }
            color = keys.lossyString(.color)
            label = keys.lossyString(.label)
        }
    }

    public var nodes: [Node] = []
    public var edges: [Edge] = []

    public init(nodes: [Node] = [], edges: [Edge] = []) {
        self.nodes = nodes
        self.edges = edges
    }

    enum CodingKeys: String, CodingKey { case nodes, edges }

    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: CodingKeys.self)
        nodes = (try? keys.decode([Lossy<Node>].self, forKey: .nodes))?.compactMap(\.value) ?? []
        // The first node with an id wins; a second one is a mistake.
        var seen = Set<String>()
        nodes = nodes.filter { seen.insert($0.id).inserted }
        edges = ((try? keys.decode([Lossy<Edge>].self, forKey: .edges))?.compactMap(\.value) ?? [])
            .filter { seen.contains($0.fromNode) && seen.contains($0.toNode) }
    }

    static let types: Set<String> = ["text", "file", "link", "group"]
    static let sides: Set<String> = ["top", "right", "bottom", "left"]
    static let ends: Set<String> = ["none", "arrow"]
    /// Far past any real board; a bigger number is a broken file.
    static let largest = 1_000_000.0

    /// A canvas from a file's text; an empty one when it is not JSON.
    public static func parse(_ text: String) -> Canvas {
        guard let data = text.data(using: .utf8), let canvas = try? JSONDecoder().decode(Canvas.self, from: data) else { return Canvas() }
        return canvas
    }

    public static func isCanvas(_ path: String) -> Bool { path.lowercased().hasSuffix(".canvas") }

    /// A node's or an edge's colour as the page draws it: Obsidian's six
    /// presets by name (`1` red, `2` orange, `3` yellow, `4` green, `5`
    /// cyan, `6` purple), each in the palette's own colour, or a `#hex`.
    /// Nil for no colour, or one the app cannot read.
    public static func color(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces) else { return nil }
        let presets = ["1": "red", "2": "orange", "3": "yellow", "4": "green", "5": "cyan", "6": "purple"]
        if let name = presets[value] { return name }
        return value.wholeMatch(of: hex) != nil ? value : nil
    }

    nonisolated(unsafe) private static let hex = /#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})/

    /// The vault file each file card shows, by node id: the path as written
    /// when the vault has it, else what a link to it resolves to.
    public func files(in index: VaultIndex, from path: String) -> [String: String] {
        var out: [String: String] = [:]
        for node in nodes where node.type == "file" {
            guard let file = node.file, !file.isEmpty else { continue }
            if index.files.contains(file) {
                out[node.id] = file
            } else if let found = index.resolve(file, from: path) {
                out[node.id] = found
            }
        }
        return out
    }

    /// The links in the text cards, resolved as a note's are.
    public func links(in index: VaultIndex, from path: String) -> [String: String] {
        var out: [String: String] = [:]
        for node in nodes where node.type == "text" {
            guard let text = node.text else { continue }
            out.merge(index.resolvedLinks(in: NoteParser.parse(text), from: path)) { first, _ in first }
        }
        return out
    }
}

/// One element of a list that may not decode; nil then, not a failed list.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

extension KeyedDecodingContainer {
    /// A string, or a number written where a string was meant (`"id": 3`).
    fileprivate func lossyString(_ key: Key) -> String? {
        if let text = try? decodeIfPresent(String.self, forKey: key) { return text }
        if let number = try? decodeIfPresent(Double.self, forKey: key), number.isFinite {
            return number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
        }
        return nil
    }

    /// A finite number, or a string that is one (`"x": "120"`).
    fileprivate func lossyNumber(_ key: Key) -> Double? {
        let number = (try? decodeIfPresent(Double.self, forKey: key)) ?? (try? decodeIfPresent(String.self, forKey: key)).flatMap { $0.flatMap(Double.init) }
        guard let number, number.isFinite else { return nil }
        return min(max(number, -Canvas.largest), Canvas.largest)
    }
}
