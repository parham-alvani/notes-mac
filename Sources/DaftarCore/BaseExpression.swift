import Foundation

/// A value in an Obsidian Bases expression.
public indirect enum BaseValue {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    /// [time] is false for a date without a time of day, such as `2026-10-25`.
    case date(Date, time: Bool)
    case duration(BaseSpan)
    case list([BaseValue])
    /// A link as written, and the vault path it goes to when it goes anywhere.
    case link(target: String, path: String?, display: String?)
    case file(String)
    case object([(key: String, value: BaseValue)])
    case regex(NSRegularExpression, global: Bool)
}

/// A length of time: whole months, which have no fixed length, and milliseconds.
public struct BaseSpan: Sendable, Equatable {
    public var months = 0
    public var milliseconds: Double = 0

    public static func + (a: BaseSpan, b: BaseSpan) -> BaseSpan {
        BaseSpan(months: a.months + b.months, milliseconds: a.milliseconds + b.milliseconds)
    }

    public static prefix func - (a: BaseSpan) -> BaseSpan { BaseSpan(months: -a.months, milliseconds: -a.milliseconds) }

    /// For arithmetic and comparison, a month counts as 30 days.
    public var approximateMilliseconds: Double { milliseconds + Double(months) * 30 * 86_400_000 }

    /// `"30 days"`, `"1d"`, `"1M 4h"`, `"-2 weeks"`: units y, M, w, d, h, m, s,
    /// ms, or their names.
    public static func parse(_ text: String) -> BaseSpan? {
        let units: [String: (months: Int, ms: Double)] = [
            "y": (12, 0), "year": (12, 0), "years": (12, 0),
            "M": (1, 0), "month": (1, 0), "months": (1, 0),
            "w": (0, 604_800_000), "week": (0, 604_800_000), "weeks": (0, 604_800_000),
            "d": (0, 86_400_000), "day": (0, 86_400_000), "days": (0, 86_400_000),
            "h": (0, 3_600_000), "hour": (0, 3_600_000), "hours": (0, 3_600_000),
            "m": (0, 60_000), "minute": (0, 60_000), "minutes": (0, 60_000),
            "s": (0, 1000), "second": (0, 1000), "seconds": (0, 1000),
            "ms": (0, 1), "millisecond": (0, 1), "milliseconds": (0, 1),
        ]
        var span = BaseSpan()
        var found = false
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        while !rest.isEmpty {
            guard let match = rest.prefixMatch(of: /\s*([+-]?\d+(?:\.\d+)?)\s*([A-Za-z]+)\s*,?/) else { return nil }
            guard let amount = Double(match.1) else { return nil }
            let name = String(match.2)
            guard let unit = units[name] ?? (name.count > 1 ? units[name.lowercased()] : nil) else { return nil }
            if unit.months != 0 {
                guard amount == amount.rounded() else { return nil }
                span.months += Int(amount) * unit.months
            } else {
                span.milliseconds += amount * unit.ms
            }
            found = true
            rest = rest[match.range.upperBound...]
        }
        return found ? span : nil
    }
}

/// An expression as it is parsed, before it meets a file.
public indirect enum BaseExpr {
    case value(BaseValue)
    case list([BaseExpr])
    case name(String)
    case member(BaseExpr, String)
    case index(BaseExpr, BaseExpr)
    /// A global function: `if(…)`, `now()`.
    case call(String, [BaseExpr])
    case method(BaseExpr, String, [BaseExpr])
    case unary(String, BaseExpr)
    case binary(String, BaseExpr, BaseExpr)
}

public struct BaseParseError: Error, CustomStringConvertible {
    public var message: String
    public var description: String { message }
}

/// The expression language of a `.base` file, as Obsidian documents it: the
/// operators `|| && == != < > <= >= + - * / % !`, method calls, `[index]`,
/// strings, numbers, lists and regular expressions.
public enum BaseParser {
    enum Token: Equatable {
        case number(Double)
        case string(String)
        case regex(String, String)
        case name(String)
        case symbol(String)
    }

    public static func parse(_ source: String) throws -> BaseExpr {
        var parser = Parser(tokens: try tokenize(source))
        let expression = try parser.or()
        guard parser.at == parser.tokens.count else {
            throw BaseParseError(message: "Unexpected \(parser.describe(parser.tokens[parser.at]))")
        }
        return expression
    }

    static func tokenize(_ source: String) throws -> [Token] {
        let characters = Array(source)
        var tokens: [Token] = []
        var at = 0
        func endsValue() -> Bool {
            switch tokens.last {
            case .number, .string, .regex, .name: true
            case .symbol(let symbol): symbol == ")" || symbol == "]"
            case nil: false
            }
        }
        while at < characters.count {
            let character = characters[at]
            if character.isWhitespace {
                at += 1
            } else if character.isNumber && character.isASCII {
                var end = at
                while end < characters.count, characters[end].isASCII, characters[end].isNumber { end += 1 }
                if end + 1 < characters.count, characters[end] == ".", characters[end + 1].isASCII, characters[end + 1].isNumber {
                    end += 1
                    while end < characters.count, characters[end].isASCII, characters[end].isNumber { end += 1 }
                }
                tokens.append(.number(Double(String(characters[at..<end]))!))
                at = end
            } else if character == "\"" || character == "'" {
                var text = ""
                var end = at + 1
                while end < characters.count, characters[end] != character {
                    if characters[end] == "\\", end + 1 < characters.count {
                        end += 1
                        switch characters[end] {
                        case "n": text.append("\n")
                        case "t": text.append("\t")
                        default: text.append(characters[end])
                        }
                    } else {
                        text.append(characters[end])
                    }
                    end += 1
                }
                guard end < characters.count else { throw BaseParseError(message: "A string has no closing \(character)") }
                tokens.append(.string(text))
                at = end + 1
            } else if character == "/", !endsValue() {
                var pattern = ""
                var end = at + 1
                while end < characters.count, characters[end] != "/" {
                    if characters[end] == "\\", end + 1 < characters.count {
                        pattern.append(characters[end])
                        end += 1
                    }
                    pattern.append(characters[end])
                    end += 1
                }
                guard end < characters.count else { throw BaseParseError(message: "A regular expression has no closing /") }
                end += 1
                var flags = ""
                while end < characters.count, characters[end].isLetter {
                    flags.append(characters[end])
                    end += 1
                }
                tokens.append(.regex(pattern, flags))
                at = end
            } else if character.isLetter || character == "_" || character == "$" {
                var end = at
                while end < characters.count, characters[end].isLetter || characters[end].isNumber || characters[end] == "_" || characters[end] == "$" {
                    end += 1
                }
                tokens.append(.name(String(characters[at..<end])))
                at = end
            } else {
                let two = at + 1 < characters.count ? String(characters[at...at + 1]) : ""
                if ["==", "!=", "<=", ">=", "&&", "||"].contains(two) {
                    tokens.append(.symbol(two))
                    at += 2
                } else if "()[],.!+-*/%<>".contains(character) {
                    tokens.append(.symbol(String(character)))
                    at += 1
                } else {
                    throw BaseParseError(message: "Unexpected “\(character)”")
                }
            }
        }
        return tokens
    }

    struct Parser {
        let tokens: [Token]
        var at = 0

        func describe(_ token: Token) -> String {
            switch token {
            case .number(let number): "\(number)"
            case .string(let text): "\"\(text)\""
            case .regex(let pattern, _): "/\(pattern)/"
            case .name(let name): name
            case .symbol(let symbol): "“\(symbol)”"
            }
        }

        mutating func take(_ symbol: String) -> Bool {
            guard at < tokens.count, tokens[at] == .symbol(symbol) else { return false }
            at += 1
            return true
        }

        mutating func expect(_ symbol: String) throws {
            guard take(symbol) else {
                throw BaseParseError(message: at < tokens.count ? "Expected “\(symbol)”, found \(describe(tokens[at]))" : "Expected “\(symbol)” at the end")
            }
        }

        mutating func binary(_ symbols: [String], _ next: (inout Parser) throws -> BaseExpr) throws -> BaseExpr {
            var left = try next(&self)
            while let symbol = symbols.first(where: { take($0) }) {
                left = .binary(symbol, left, try next(&self))
            }
            return left
        }

        mutating func or() throws -> BaseExpr { try binary(["||"]) { try $0.and() } }
        mutating func and() throws -> BaseExpr { try binary(["&&"]) { try $0.equality() } }
        mutating func equality() throws -> BaseExpr { try binary(["==", "!="]) { try $0.comparison() } }
        mutating func comparison() throws -> BaseExpr { try binary(["<=", ">=", "<", ">"]) { try $0.additive() } }
        mutating func additive() throws -> BaseExpr { try binary(["+", "-"]) { try $0.multiplicative() } }
        mutating func multiplicative() throws -> BaseExpr { try binary(["*", "/", "%"]) { try $0.unary() } }

        mutating func unary() throws -> BaseExpr {
            if take("!") { return .unary("!", try unary()) }
            if take("-") { return .unary("-", try unary()) }
            return try postfix()
        }

        mutating func arguments() throws -> [BaseExpr] {
            var items: [BaseExpr] = []
            if take(")") { return items }
            repeat { items.append(try or()) } while take(",")
            try expect(")")
            return items
        }

        mutating func postfix() throws -> BaseExpr {
            var expression = try primary()
            while true {
                if take(".") {
                    guard at < tokens.count, case .name(let name) = tokens[at] else { throw BaseParseError(message: "Expected a name after “.”") }
                    at += 1
                    expression = take("(") ? .method(expression, name, try arguments()) : .member(expression, name)
                } else if take("[") {
                    let key = try or()
                    try expect("]")
                    expression = .index(expression, key)
                } else if take("(") {
                    guard case .name(let name) = expression else { throw BaseParseError(message: "Only a function can be called") }
                    expression = .call(name, try arguments())
                } else {
                    return expression
                }
            }
        }

        mutating func primary() throws -> BaseExpr {
            guard at < tokens.count else { throw BaseParseError(message: "The expression stops too early") }
            let token = tokens[at]
            at += 1
            switch token {
            case .number(let number): return .value(.number(number))
            case .string(let text): return .value(.string(text))
            case .regex(let pattern, let flags):
                var options: NSRegularExpression.Options = []
                if flags.contains("i") { options.insert(.caseInsensitive) }
                if flags.contains("m") { options.insert(.anchorsMatchLines) }
                if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
                guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
                    throw BaseParseError(message: "Not a regular expression: /\(pattern)/")
                }
                return .value(.regex(regex, global: flags.contains("g")))
            case .name("true"): return .value(.bool(true))
            case .name("false"): return .value(.bool(false))
            case .name("null"): return .value(.null)
            case .name(let name): return .name(name)
            case .symbol("("):
                let inner = try or()
                try expect(")")
                return inner
            case .symbol("["):
                var items: [BaseExpr] = []
                if !take("]") {
                    repeat { items.append(try or()) } while take(",")
                    try expect("]")
                }
                return .list(items)
            case .symbol:
                throw BaseParseError(message: "Unexpected \(describe(token))")
            }
        }
    }
}
