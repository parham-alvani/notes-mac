import Foundation

/// Rich text pasted from a web page or a document, as Markdown, the way
/// Obsidian converts a paste: headings, emphasis, links, pictures, lists,
/// quotes, code and tables keep their meaning; colours and fonts do not.
public enum HTMLMarkdown {
    /// The tags that make a paste worth converting. Code editors copy
    /// coloured `div` and `span` lines, which stay plain text.
    private static let meaningful: Set<String> = [
        "h1", "h2", "h3", "h4", "h5", "h6", "a", "strong", "b", "em", "i", "ul", "ol", "li", "table",
        "blockquote", "pre", "code", "img", "p", "del", "s", "strike", "hr",
    ]

    /// [html] as Markdown, or nil when it holds nothing a plain paste would lose.
    public static func convert(_ html: String) -> String? {
        guard let document = try? XMLDocument(xmlString: html, options: [.documentTidyHTML]),
            let root = document.rootElement()
        else { return nil }
        let body = (try? root.nodes(forXPath: "//body").first) ?? root
        guard hasMeaning(body) else { return nil }
        var writer = Writer()
        writer.block(body, depth: 0)
        let text = writer.finish()
        return text.isEmpty ? nil : text
    }

    private static func hasMeaning(_ node: XMLNode) -> Bool {
        if let name = node.name?.lowercased(), node.kind == .element, meaningful.contains(name) { return true }
        if let style = (node as? XMLElement)?.attribute(forName: "style")?.stringValue?.lowercased(),
            style.contains("font-weight:700") || style.contains("font-weight: 700") || style.contains("font-weight:bold")
                || style.contains("font-style:italic") || style.contains("font-style: italic")
        {
            return true
        }
        return node.children?.contains(where: hasMeaning) ?? false
    }

    private struct Writer {
        var blocks: [String] = []

        mutating func finish() -> String {
            blocks.map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: "\n\n")
        }

        /// The block elements of [node], each a paragraph of its own.
        mutating func block(_ node: XMLNode, depth: Int) {
            var inline = ""
            func flush() {
                let text = Writer.tidy(inline)
                if !text.isEmpty { blocks.append(text) }
                inline = ""
            }
            for child in node.children ?? [] {
                let name = child.kind == .element ? child.name?.lowercased() ?? "" : ""
                switch name {
                case "h1", "h2", "h3", "h4", "h5", "h6":
                    flush()
                    let level = Int(name.dropFirst())!
                    blocks.append(String(repeating: "#", count: level) + " " + Writer.tidy(Writer.inline(child)))
                case "p":
                    flush()
                    blocks.append(Writer.tidy(Writer.inline(child)))
                case "ul", "ol":
                    flush()
                    blocks.append(Writer.list(child, ordered: name == "ol", depth: 0))
                case "blockquote":
                    flush()
                    var inner = Writer()
                    inner.block(child, depth: depth + 1)
                    blocks.append(inner.finish().split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n"))
                case "pre":
                    flush()
                    let code = child.stringValue ?? ""
                    let language = Writer.language(of: child)
                    blocks.append("```\(language)\n" + code.trimmingCharacters(in: .newlines) + "\n```")
                case "hr":
                    flush()
                    blocks.append("---")
                case "table":
                    flush()
                    if let table = Writer.table(child) { blocks.append(table) }
                case "div", "section", "article", "main", "header", "footer", "figure", "body", "center":
                    flush()
                    block(child, depth: depth)
                case "head", "style", "script", "meta", "title", "link":
                    continue
                default:
                    if Writer.holdsBlocks(child) {
                        // Google Docs wraps the whole paste in a `<b>` of normal weight.
                        flush()
                        block(child, depth: depth)
                    } else {
                        inline += Writer.inline(child)
                    }
                }
            }
            flush()
        }

        static let blockNames: Set<String> = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "table", "blockquote", "pre", "hr", "section"]

        static func holdsBlocks(_ node: XMLNode) -> Bool {
            node.children?.contains { $0.kind == .element && blockNames.contains($0.name?.lowercased() ?? "") } ?? false
        }

        /// The text of an inline node, with its marks.
        static func inline(_ node: XMLNode) -> String {
            if node.kind == .text { return (node.stringValue ?? "").replacingOccurrences(of: "\n", with: " ") }
            guard node.kind == .element, let element = node as? XMLElement else { return "" }
            let name = element.name?.lowercased() ?? ""
            let inner = (element.children ?? []).map(inline).joined()
            func mark(_ marker: String) -> String {
                let trimmed = inner.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return inner }
                // The mark hugs the words, so `** bold**` does not happen.
                let lead = inner.prefix { $0 == " " }, trail = String(inner.reversed().prefix { $0 == " " })
                return lead + marker + trimmed + marker + trail
            }
            let style = element.attribute(forName: "style")?.stringValue?.lowercased().replacingOccurrences(of: " ", with: "") ?? ""
            switch name {
            case "strong", "b":
                return style.contains("font-weight:normal") || style.contains("font-weight:400") ? inner : mark("**")
            case "em", "i": return mark("*")
            case "del", "s", "strike": return mark("~~")
            case "mark": return mark("==")
            case "code": return "`" + (element.stringValue ?? "") + "`"
            case "br": return "\n"
            case "a":
                guard let href = element.attribute(forName: "href")?.stringValue, !href.isEmpty, !href.hasPrefix("javascript:") else { return inner }
                let label = inner.trimmingCharacters(in: .whitespaces)
                return label.isEmpty || label == href ? "<\(href)>" : "[\(label)](\(href.replacingOccurrences(of: " ", with: "%20")))"
            case "img":
                guard let src = element.attribute(forName: "src")?.stringValue, !src.hasPrefix("data:") else { return "" }
                return "![\(element.attribute(forName: "alt")?.stringValue ?? "")](\(src))"
            case "span":
                var text = inner
                if style.contains("font-weight:700") || style.contains("font-weight:bold") { text = mark("**") }
                if style.contains("font-style:italic") { text = text == inner ? mark("*") : "*" + text + "*" }
                return text
            case "script", "style", "head": return ""
            default: return inner
            }
        }

        static func list(_ node: XMLNode, ordered: Bool, depth: Int) -> String {
            var lines: [String] = []
            var number = Int((node as? XMLElement)?.attribute(forName: "start")?.stringValue ?? "") ?? 1
            for item in node.children ?? [] where item.name?.lowercased() == "li" {
                var text = ""
                var nested: [String] = []
                for child in item.children ?? [] {
                    let name = child.name?.lowercased() ?? ""
                    if child.kind == .element, name == "ul" || name == "ol" {
                        nested.append(list(child, ordered: name == "ol", depth: depth + 1))
                    } else if child.kind == .element, name == "p" {
                        text += (text.isEmpty ? "" : " ") + inline(child)
                    } else {
                        text += inline(child)
                    }
                }
                let indent = String(repeating: "    ", count: depth)
                var marker = ordered ? "\(number). " : "- "
                // A checkbox from a task list.
                if let box = (try? item.nodes(forXPath: "./input[@type='checkbox']"))?.first as? XMLElement {
                    marker = "- [\(box.attribute(forName: "checked") == nil ? " " : "x")] "
                }
                lines.append(indent + marker + tidy(text))
                lines += nested
                number += 1
            }
            return lines.joined(separator: "\n")
        }

        static func table(_ node: XMLNode) -> String? {
            let rows = ((try? node.nodes(forXPath: ".//tr")) ?? []).map { row in
                (row.children ?? []).filter { ["td", "th"].contains($0.name?.lowercased() ?? "") }
                    .map { tidy(inline($0)).replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
            }.filter { !$0.isEmpty }
            guard let first = rows.first else { return nil }
            let width = rows.map(\.count).max() ?? first.count
            func line(_ cells: [String]) -> String { "| " + (cells + Array(repeating: "", count: width - cells.count)).joined(separator: " | ") + " |" }
            return ([line(first), "|" + Array(repeating: " --- |", count: width).joined()] + rows.dropFirst().map(line)).joined(separator: "\n")
        }

        static func language(of pre: XMLNode) -> String {
            let classes = ([pre] + (pre.children ?? [])).compactMap { ($0 as? XMLElement)?.attribute(forName: "class")?.stringValue }.joined(separator: " ")
            return classes.firstMatch(of: /(?:language|lang)-([\w+#-]+)/).map { String($0.1) } ?? ""
        }

        /// Runs of spaces as one, and no space at the ends of a line.
        static func tidy(_ text: String) -> String {
            text.replacing(/[ \t\u{a0}]+/, with: " ")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
