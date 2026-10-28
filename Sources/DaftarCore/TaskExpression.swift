import Foundation

/// The JavaScript of a query's `filter by function` and `group by function`
/// lines: the small part of it such lines use, read without a JavaScript
/// engine. Strings, arrays, `true`/`false`/`null`, the `task.*` properties the
/// index can answer, `===` `!==` `==` `!=`, `&&` `||` `!`, `? :`, brackets,
/// and `includes`, `startsWith`, `endsWith`, `toLowerCase`, `toUpperCase`.
/// Anything else fails to parse, so the line is reported rather than guessed
/// at. The rules are Daftar's on the phone (`TaskExpression.kt`).
public struct TaskExpression: Sendable {
    public indirect enum Value: Sendable, Equatable {
        case null
        case bool(Bool)
        case string(String)
        case list([Value])

        var truthy: Bool {
            switch self {
            case .null: false
            case .bool(let flag): flag
            case .string(let text): !text.isEmpty
            case .list: true
            }
        }

        var display: String {
            switch self {
            case .null: ""
            case .bool(let flag): flag ? "true" : "false"
            case .string(let text): text
            case .list(let items): items.map(\.display).joined(separator: ",")
            }
        }
    }

    typealias Node = @Sendable (QueryTask) -> Value
    private let root: Node

    public func evaluate(_ task: QueryTask) -> Value { root(task) }
    public func test(_ task: QueryTask) -> Bool { root(task).truthy }

    public static func parse(_ source: String) -> TaskExpression? {
        guard let tokens = tokens(source) else { return nil }
        var parser = Parser(tokens: tokens)
        guard let node = parser.expression(), parser.at == tokens.count else { return nil }
        return TaskExpression(root: node)
    }

    /// What `task.<path>` reads, or nil when the index does not keep it.
    static func property(_ path: String) -> Node? {
        switch path {
        case "status.type": { .string($0.state.type) }
        case "status.name": { .string($0.status.name) }
        case "status.symbol": { .string(String($0.status.symbol)) }
        case "reason": { $0.reason.map(Value.string) ?? .null }
        case "description": { .string($0.text) }
        case "heading": { $0.section.trimmingCharacters(in: .whitespaces).isEmpty ? .null : .string($0.section) }
        case "hasHeading": { .bool(!$0.section.trimmingCharacters(in: .whitespaces).isEmpty) }
        case "isDone": { .bool($0.state == .done) }
        case "isRecurring": { .bool($0.recurring != nil) }
        case "file.path": { .string($0.path) }
        case "file.filename": { .string($0.filename) }
        case "file.filenameWithoutExtension": { .string($0.filename.removingSuffix(".md")) }
        case "file.folder": { .string($0.folder) }
        default: nil
        }
    }

    /// A string token keeps its opening quote, so it is never read as a name.
    private static func tokens(_ source: String) -> [String]? {
        let chars = Array(source)
        var out: [String] = []
        var i = 0
        let operators = ["===", "!==", "==", "!=", "&&", "||", "!", "?", ":", "(", ")", "[", "]", ",", "."]
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace {
                i += 1
            } else if c == "\"" || c == "'" {
                guard let end = chars[(i + 1)...].firstIndex(of: c) else { return nil }
                out.append("\"" + String(chars[(i + 1)..<end]))
                i = end + 1
            } else if c.isLetter || c == "_" {
                let start = i
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { i += 1 }
                out.append(String(chars[start..<i]))
            } else if let op = operators.first(where: { op in
                i + op.count <= chars.count && String(chars[i..<(i + op.count)]) == op
            }) {
                out.append(op)
                i += op.count
            } else {
                return nil
            }
        }
        return out
    }

    /// Recursive descent, lowest precedence first: `? :`, `||`, `&&`, equality, `!`.
    private struct Parser {
        let tokens: [String]
        var at = 0

        func peek() -> String? { at < tokens.count ? tokens[at] : nil }

        mutating func take(_ expected: String) -> Bool {
            guard peek() == expected else { return false }
            at += 1
            return true
        }

        mutating func expression() -> Node? {
            guard let condition = or() else { return nil }
            guard take("?") else { return condition }
            guard let yes = expression(), take(":"), let no = expression() else { return nil }
            return { condition($0).truthy ? yes($0) : no($0) }
        }

        mutating func or() -> Node? {
            guard var left = and() else { return nil }
            while take("||") {
                guard let right = and() else { return nil }
                let l = left
                left = { t in let v = l(t); return v.truthy ? v : right(t) }
            }
            return left
        }

        mutating func and() -> Node? {
            guard var left = equality() else { return nil }
            while take("&&") {
                guard let right = equality() else { return nil }
                let l = left
                left = { t in let v = l(t); return v.truthy ? right(t) : v }
            }
            return left
        }

        mutating func equality() -> Node? {
            guard var left = unary() else { return nil }
            while let op = peek(), ["===", "!==", "==", "!="].contains(op) {
                at += 1
                guard let right = unary() else { return nil }
                let negate = op.hasPrefix("!")
                let l = left
                left = { t in .bool((l(t) == right(t)) != negate) }
            }
            return left
        }

        mutating func unary() -> Node? {
            if take("!") {
                guard let inner = unary() else { return nil }
                return { .bool(!inner($0).truthy) }
            }
            guard let base = primary() else { return nil }
            return postfix(base)
        }

        mutating func primary() -> Node? {
            guard let token = peek() else { return nil }
            at += 1
            if token.hasPrefix("\"") {
                let text = String(token.dropFirst())
                return { _ in .string(text) }
            }
            switch token {
            case "true": return { _ in .bool(true) }
            case "false": return { _ in .bool(false) }
            case "null", "undefined": return { _ in .null }
            case "(":
                guard let inner = expression(), take(")") else { return nil }
                return inner
            case "[":
                var items: [Node] = []
                if peek() != "]" {
                    guard let first = expression() else { return nil }
                    items.append(first)
                    while take(",") {
                        guard let next = expression() else { return nil }
                        items.append(next)
                    }
                }
                guard take("]") else { return nil }
                let all = items
                return { t in .list(all.map { $0(t) }) }
            case "task":
                return taskProperty()
            default:
                return nil
            }
        }

        /// `task.a.b`, as long as the dotted names run -- but not into a method.
        mutating func taskProperty() -> Node? {
            var names: [String] = []
            while peek() == ".", at + 1 < tokens.count {
                let candidate = (names + [tokens[at + 1]]).joined(separator: ".")
                guard TaskExpression.property(candidate) != nil || ["status", "file"].contains(candidate) else { break }
                at += 2
                names.append(tokens[at - 1])
            }
            return TaskExpression.property(names.joined(separator: "."))
        }

        mutating func postfix(_ start: @escaping Node) -> Node? {
            var node = start
            while take(".") {
                guard let method = peek() else { return nil }
                at += 1
                guard take("(") else { return nil }
                var args: [Node] = []
                if peek() != ")" {
                    guard let first = expression() else { return nil }
                    args.append(first)
                    while take(",") {
                        guard let next = expression() else { return nil }
                        args.append(next)
                    }
                }
                guard take(")") else { return nil }
                let target = node
                switch method {
                case "includes" where args.count == 1:
                    let arg = args[0]
                    node = { t in
                        switch target(t) {
                        case .list(let items): .bool(items.contains(arg(t)))
                        case .string(let text): if case .string(let part) = arg(t) { .bool(text.contains(part)) } else { .bool(false) }
                        default: .bool(false)
                        }
                    }
                case "startsWith" where args.count == 1, "endsWith" where args.count == 1:
                    let arg = args[0]
                    let starts = method == "startsWith"
                    node = { t in
                        guard case .string(let text) = target(t), case .string(let part) = arg(t) else { return .bool(false) }
                        return .bool(starts ? text.hasPrefix(part) : text.hasSuffix(part))
                    }
                case "toLowerCase", "toUpperCase":
                    let lower = method == "toLowerCase"
                    node = { t in
                        guard case .string(let text) = target(t) else { return .null }
                        return .string(lower ? text.lowercased() : text.uppercased())
                    }
                default:
                    return nil
                }
            }
            return node
        }
    }
}
