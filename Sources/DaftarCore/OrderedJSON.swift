import Foundation

/// JSON that keeps the order of its keys and writes itself back as
/// `JSON.stringify(value, null, 2)` does, so a plugin's `data.json` that the
/// app edits changes by the lines that changed and no others. Numbers keep
/// the text they were written with.
public indirect enum OrderedJSON: Equatable, Sendable {
    case object([(String, OrderedJSON)])
    case array([OrderedJSON])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    public static func == (a: OrderedJSON, b: OrderedJSON) -> Bool {
        switch (a, b) {
        case (.object(let x), .object(let y)): x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case (.array(let x), .array(let y)): x == y
        case (.string(let x), .string(let y)), (.number(let x), .number(let y)): x == y
        case (.bool(let x), .bool(let y)): x == y
        case (.null, .null): true
        default: false
        }
    }

    // MARK: Reading

    public struct Failure: Error {}

    public static func parse(_ text: String) throws -> OrderedJSON {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        let value = try parser.value()
        parser.space()
        guard parser.at == parser.scalars.count else { throw Failure() }
        return value
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var at = 0

        mutating func space() {
            while at < scalars.count, [" ", "\n", "\r", "\t"].contains(scalars[at]) { at += 1 }
        }

        mutating func expect(_ text: String) throws {
            for scalar in text.unicodeScalars {
                guard at < scalars.count, scalars[at] == scalar else { throw Failure() }
                at += 1
            }
        }

        mutating func value() throws -> OrderedJSON {
            space()
            guard at < scalars.count else { throw Failure() }
            switch scalars[at] {
            case "{":
                at += 1
                var members: [(String, OrderedJSON)] = []
                space()
                if at < scalars.count, scalars[at] == "}" { at += 1; return .object([]) }
                while true {
                    space()
                    let key = try string()
                    space()
                    try expect(":")
                    members.append((key, try value()))
                    space()
                    guard at < scalars.count else { throw Failure() }
                    if scalars[at] == "," { at += 1; continue }
                    try expect("}")
                    return .object(members)
                }
            case "[":
                at += 1
                var items: [OrderedJSON] = []
                space()
                if at < scalars.count, scalars[at] == "]" { at += 1; return .array([]) }
                while true {
                    items.append(try value())
                    space()
                    guard at < scalars.count else { throw Failure() }
                    if scalars[at] == "," { at += 1; continue }
                    try expect("]")
                    return .array(items)
                }
            case "\"": return .string(try string())
            case "t": try expect("true"); return .bool(true)
            case "f": try expect("false"); return .bool(false)
            case "n": try expect("null"); return .null
            default:
                let start = at
                while at < scalars.count, "+-0123456789.eE".unicodeScalars.contains(scalars[at]) { at += 1 }
                guard at > start else { throw Failure() }
                var text = ""
                text.unicodeScalars.append(contentsOf: scalars[start..<at])
                return .number(text)
            }
        }

        mutating func string() throws -> String {
            try expect("\"")
            var out = String.UnicodeScalarView()
            while at < scalars.count {
                let scalar = scalars[at]
                at += 1
                if scalar == "\"" { return String(out) }
                guard scalar == "\\" else { out.append(scalar); continue }
                guard at < scalars.count else { throw Failure() }
                let escape = scalars[at]
                at += 1
                switch escape {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "b": out.append("\u{8}")
                case "f": out.append("\u{C}")
                case "u":
                    var unit = try hex()
                    // A pair of surrogates is one scalar.
                    if (0xD800...0xDBFF).contains(unit), at + 1 < scalars.count, scalars[at] == "\\", scalars[at + 1] == "u" {
                        at += 2
                        let low = try hex()
                        unit = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let value = Unicode.Scalar(unit) else { throw Failure() }
                    out.append(value)
                default: out.append(escape)
                }
            }
            throw Failure()
        }

        mutating func hex() throws -> UInt32 {
            guard at + 4 <= scalars.count, let value = UInt32(String(String.UnicodeScalarView(scalars[at..<at + 4])), radix: 16) else { throw Failure() }
            at += 4
            return value
        }
    }

    // MARK: Writing

    /// As `JSON.stringify(value, null, 2)`.
    public var text: String {
        var out = ""
        write(into: &out, depth: 0)
        return out
    }

    private func write(into out: inout String, depth: Int) {
        let pad = String(repeating: "  ", count: depth + 1), close = String(repeating: "  ", count: depth)
        switch self {
        case .object(let members):
            guard !members.isEmpty else { return out += "{}" }
            out += "{\n"
            for (index, (key, value)) in members.enumerated() {
                out += pad + Self.quoted(key) + ": "
                value.write(into: &out, depth: depth + 1)
                out += index < members.count - 1 ? ",\n" : "\n"
            }
            out += close + "}"
        case .array(let items):
            guard !items.isEmpty else { return out += "[]" }
            out += "[\n"
            for (index, item) in items.enumerated() {
                out += pad
                item.write(into: &out, depth: depth + 1)
                out += index < items.count - 1 ? ",\n" : "\n"
            }
            out += close + "]"
        case .string(let text): out += Self.quoted(text)
        case .number(let text): out += text
        case .bool(let value): out += value ? "true" : "false"
        case .null: out += "null"
        }
    }

    /// A string as JavaScript quotes it: only the quote, the backslash and
    /// the control characters are escaped.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{8}": out += "\\b"
            case "\u{C}": out += "\\f"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    // MARK: Editing

    public subscript(key: String) -> OrderedJSON? {
        get {
            guard case .object(let members) = self else { return nil }
            return members.first { $0.0 == key }?.1
        }
        set {
            guard case .object(var members) = self else { return }
            if let index = members.firstIndex(where: { $0.0 == key }) {
                if let newValue { members[index].1 = newValue } else { members.remove(at: index) }
            } else if let newValue {
                members.append((key, newValue))
            }
            self = .object(members)
        }
    }

    public var keys: [String] {
        guard case .object(let members) = self else { return [] }
        return members.map(\.0)
    }
}
