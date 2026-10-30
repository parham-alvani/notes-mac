import Foundation

/// The colours of a line of code in the editor: comments, strings, numbers
/// and keywords, by the language a fence names. One line at a time, as the
/// editor styles a code block line by line; a comment or a string that goes
/// over lines is coloured on its first line only. The reader colours code
/// with highlight.js; this is the editor's small share of that.
public enum CodeTokens {
    public enum Kind: Equatable, Sendable {
        case comment, string, number, keyword
    }

    public struct Token: Equatable, Sendable {
        public let kind: Kind
        /// UTF-16 offsets in the line.
        public let range: NSRange
    }

    /// What starts a comment to the end of the line, in [language].
    static func lineComments(_ language: String) -> [String] {
        switch language.lowercased() {
        case "python", "py", "bash", "sh", "shell", "zsh", "fish", "yaml", "yml", "toml", "ruby", "rb", "r", "perl",
            "make", "makefile", "dockerfile", "nix", "elixir", "ex", "conf", "ini", "powershell", "ps1", "hcl", "terraform", "tf":
            ["#"]
        case "lua", "sql", "haskell", "hs", "elm":
            ["--"]
        case "lisp", "clojure", "clj", "scheme", "asm", "nasm":
            [";"]
        case "markdown", "md", "text", "txt", "plain", "":
            []
        default:
            ["//"]
        }
    }

    static let keywords: Set<String> = [
        "if", "else", "elif", "for", "while", "do", "return", "function", "func", "fn", "def", "class", "struct", "enum",
        "interface", "protocol", "extension", "impl", "trait", "let", "var", "const", "val", "import", "from", "export",
        "package", "module", "use", "mod", "pub", "public", "private", "protected", "static", "case", "switch", "match",
        "break", "continue", "in", "of", "new", "try", "catch", "finally", "throw", "throws", "raise", "except", "async",
        "await", "yield", "with", "as", "is", "not", "and", "or", "lambda", "nil", "null", "None", "true", "false", "True",
        "False", "self", "this", "super", "local", "then", "end", "fi", "done", "esac", "guard", "defer", "go", "select",
        "chan", "type", "where", "SELECT", "FROM", "WHERE", "INSERT", "UPDATE", "DELETE", "JOIN", "AND", "OR", "NOT",
    ]

    public static func tokens(in line: String, language: String) -> [Token] {
        let text = Array(line.utf16)
        let comments = lineComments(language).map { Array($0.utf16) }
        let slashStar = comments == [Array("//".utf16)]
        var out: [Token] = []
        var at = 0
        func starts(_ needle: [UInt16], _ index: Int) -> Bool {
            index + needle.count <= text.count && Array(text[index..<index + needle.count]) == needle
        }
        func isWord(_ unit: UInt16) -> Bool {
            (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95
        }
        while at < text.count {
            let unit = text[at]
            // A comment to the end of the line; `#` only where a word could start.
            if let comment = comments.first(where: { starts($0, at) }), comment != [35] || at == 0 || !isWord(text[at - 1]) {
                out.append(Token(kind: .comment, range: NSRange(location: at, length: text.count - at)))
                break
            }
            if slashStar, starts(Array("/*".utf16), at) {
                var end = at + 2
                while end < text.count, !starts(Array("*/".utf16), end) { end += 1 }
                end = min(text.count, end + 2)
                out.append(Token(kind: .comment, range: NSRange(location: at, length: end - at)))
                at = end
                continue
            }
            // A string, to its closing quote or the end of the line.
            if unit == 34 || unit == 39 || unit == 96 {
                // An apostrophe in a word, as `don't` in a comment-less line, is not a string.
                if unit == 39, at > 0, isWord(text[at - 1]) {
                    at += 1
                    continue
                }
                var end = at + 1
                while end < text.count, text[end] != unit {
                    end += text[end] == 92 ? 2 : 1
                }
                end = min(text.count, end + 1)
                out.append(Token(kind: .string, range: NSRange(location: at, length: end - at)))
                at = end
                continue
            }
            if isWord(unit) {
                var end = at
                while end < text.count, isWord(text[end]) || text[end] == 46 && end + 1 < text.count && isWord(text[end + 1]) && (48...57).contains(text[at]) {
                    end += 1
                }
                let word = String(utf16CodeUnits: Array(text[at..<end]), count: end - at)
                if (48...57).contains(unit) {
                    out.append(Token(kind: .number, range: NSRange(location: at, length: end - at)))
                } else if keywords.contains(word) {
                    out.append(Token(kind: .keyword, range: NSRange(location: at, length: end - at)))
                }
                at = end
                continue
            }
            at += 1
        }
        return out
    }
}
