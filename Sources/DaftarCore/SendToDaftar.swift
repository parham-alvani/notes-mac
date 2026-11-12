import Foundation

/// "Send to Daftar" from another app (the macOS Services menu; a desktop
/// action or a share target elsewhere): what a selection or a link becomes
/// in the vault. The spec is `send-to-daftar.md` in notes-linux's `docs/specs`.
public enum SendToDaftar {
    /// The scratchpad's section for [day]: one inbox note, a section for each day.
    public static func heading(on day: Day) -> String { "## \(day)" }

    /// The line a selection adds to the scratchpad: a list item, one line.
    /// A bare web address is written in angle brackets, as the vault's
    /// lint wants; a selection that came with its link (a link selected in
    /// a browser) is a Markdown link. Nil when there is nothing to add.
    public static func scratchpadLine(text: String?, url: String?) -> String? {
        guard let item = item(text: text, url: url) else { return nil }
        return item.hasPrefix("- ") ? item : "- " + item
    }

    /// The text a New Task form starts with: the selection on one line,
    /// with its link when it came with one. Nil when there is nothing.
    public static func taskText(text: String?, url: String?) -> String? {
        guard var item = item(text: text, url: url) else { return nil }
        // A selected list item or task is the text, not its marks.
        for mark in ["- [ ] ", "- [x] ", "- ", "* ", "+ "] where item.hasPrefix(mark) {
            item = String(item.dropFirst(mark.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        return item.isEmpty || ["-", "*", "+", "- [ ]"].contains(item) ? nil : item
    }

    private static func item(text: String?, url: String?) -> String? {
        let words = QuickCapture.line(text ?? "", task: false)
        let link = url.flatMap(webAddress)
        switch (words, link) {
        case (nil, nil): return nil
        case (nil, let link?): return "<\(link)>"
        case (let words?, nil): return webAddress(words).map { "<\($0)>" } ?? words
        case (let words?, let link?):
            if webAddress(words) == link || words == link { return "<\(link)>" }
            return "[\(words.replacingOccurrences(of: "]", with: "\\]"))](\(link))"
        }
    }

    /// [text] when it is one web address and nothing else (`http`, `https`,
    /// `mailto`), without the angle brackets it may have had.
    static func webAddress(_ text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<") && text.hasSuffix(">") { text = String(text.dropFirst().dropLast()) }
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" }),
            let url = URL(string: text), let scheme = url.scheme?.lowercased(),
            ["http", "https", "mailto"].contains(scheme)
        else { return nil }
        if scheme != "mailto" && (url.host ?? "").isEmpty { return nil }
        return text
    }

    /// `daftar://new-task?text=…`: the New Task form, filled with [text].
    /// It only fills the form; the person adds the task.
    public static func newTaskURL(text: String) -> URL? {
        var components = URLComponents()
        components.scheme = "daftar"
        components.host = "new-task"
        components.queryItems = [URLQueryItem(name: "text", value: text)]
        return components.url
    }

    /// The text of a `daftar://new-task` address, one line; nil for any other address.
    public static func newTaskText(_ url: URL) -> String? {
        guard url.scheme == "daftar", url.host == "new-task" else { return nil }
        let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "text" }?.value ?? ""
        return QuickCapture.line(text, task: false) ?? ""
    }
}
