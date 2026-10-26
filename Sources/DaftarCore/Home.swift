import Foundation

/// The settings of Obsidian's Beautitab plugin, the new-tab page the home
/// page replaces: `.obsidian/plugins/beautitab/data.json`. Every key is
/// optional, and a value of the wrong type is the default. Quotes from the
/// web are off: only "My quotes" (`customQuotes`) are shown.
public struct Beautitab: Sendable, Equatable {
    public struct Quote: Sendable, Equatable, Hashable {
        public var text: String
        public var author: String

        public init(text: String, author: String = "") {
            self.text = text
            self.author = author
        }
    }

    public var showTime = true
    /// True for "24-hour", false for "12-hour", nil for the system's choice.
    public var twentyFourHour: Bool?
    public var showGreeting = true
    /// Empty for "Good morning", "Good afternoon" or "Good evening".
    public var greetingText = ""
    public var showSearch = true
    public var showRecentFiles = true
    public var showBookmarks = false
    /// On only when the source is the person's own quotes and there is one.
    public var showQuote = false
    public var quotes: [Quote] = []
    /// `customBackground`, then each of `localBackgrounds`: paths or web
    /// addresses, in the plugin's order. Empty strings are dropped.
    public var backgrounds: [String] = []

    public init() {}

    public init(json: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return }
        // JSON booleans come as NSNumber, as do numbers: only true and false count.
        func flag(_ key: String) -> Bool? {
            guard let number = root[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
        showTime = flag("showTime") ?? showTime
        switch (root["timeFormat"] as? String)?.lowercased() {
        case "24-hour": twentyFourHour = true
        case "12-hour": twentyFourHour = false
        default: twentyFourHour = nil
        }
        showGreeting = flag("showGreeting") ?? showGreeting
        greetingText = (root["greetingText"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        showSearch = flag("showInlineSearch") ?? showSearch
        showRecentFiles = flag("showRecentFiles") ?? showRecentFiles
        showBookmarks = flag("showBookmarks") ?? showBookmarks
        quotes = (root["customQuotes"] as? [Any] ?? []).compactMap { item in
            guard let item = item as? [String: Any],
                let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { return nil }
            return Quote(text: text, author: (item["author"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        let source = root["quoteSource"] as? String
        showQuote = (flag("showQuote") ?? false) && (source == nil || source == "My quotes") && !quotes.isEmpty
        let local = (root["localBackgrounds"] as? [Any] ?? []).compactMap { item -> String? in
            if let text = item as? String { return text }
            let object = item as? [String: Any]
            return (object?["path"] ?? object?["url"] ?? object?["src"]) as? String
        }
        backgrounds = ([root["customBackground"] as? String ?? ""] + local)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// The settings of the vault at [root]; the defaults when there are none.
    public static func read(root: URL) -> Beautitab {
        (try? Data(contentsOf: root.appending(path: ".obsidian/plugins/beautitab/data.json"))).map(Beautitab.init(json:)) ?? Beautitab()
    }
}

/// The home page's rules, apart from its view.
public enum Home {
    /// "morning" from 5 to 12, "afternoon" to 18, else "evening".
    public static func partOfDay(hour: Int) -> String {
        switch hour {
        case 5..<12: "morning"
        case 12..<18: "afternoon"
        default: "evening"
        }
    }

    /// The person's greeting, with `{{greeting}}` as the part of the day,
    /// or "Good morning" and its kind when there is none.
    public static func greeting(_ text: String, hour: Int) -> String {
        let part = partOfDay(hour: hour)
        guard !text.isEmpty else { return "Good " + part }
        return text.replacingOccurrences(of: "{{greeting}}", with: part)
    }

    /// The file of the home picture: [setting] is an absolute path, a `~`
    /// path, a `file://` address, or a path in the vault at [vault]. A web
    /// address is nil: the page never goes to the network.
    public static func pictureURL(_ setting: String, vault: URL?, home: String = NSHomeDirectory()) -> URL? {
        let text = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("file://") { return URL(string: text).flatMap { $0.isFileURL ? $0 : nil } }
        if text.contains("://") || text.hasPrefix("data:") { return nil }
        if text == "~" || text.hasPrefix("~/") { return URL(filePath: home + text.dropFirst()) }
        if text.hasPrefix("/") { return URL(filePath: text) }
        guard let vault else { return nil }
        return vault.appending(path: text)
    }

    /// The notes to list as recent: those opened in the window first, then
    /// the last read, each once and only while it is in the vault.
    public static func recent(opened: [String], read: [String], exists: (String) -> Bool, limit: Int) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for path in opened + read where out.count < limit && exists(path) && seen.insert(path).inserted {
            out.append(path)
        }
        return out
    }
}
