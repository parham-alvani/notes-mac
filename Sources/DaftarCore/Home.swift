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

        /// True when the quote reads right to left, by its first strong letter.
        public var isRtl: Bool { TextDirection.startsRtl(text) }

        /// The text in its own script's quotation marks: «…» for Persian,
        /// “…” for the rest. In a line of the text's own direction, the
        /// opening mark is at the side where the reading starts.
        public var quoted: String { isRtl ? "«\(text)»" : "“\(text)”" }
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
    /// The quote is asked for, whether or not there is one to show.
    var wantsQuote = false
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
        quotes = (root["customQuotes"] as? [Any] ?? []).compactMap(Self.quote)
        let source = root["quoteSource"] as? String
        wantsQuote = (flag("showQuote") ?? false) && (source == nil || source == "My quotes")
        showQuote = wantsQuote && !quotes.isEmpty
        let local = (root["localBackgrounds"] as? [Any] ?? []).compactMap { item -> String? in
            if let text = item as? String { return text }
            let object = item as? [String: Any]
            return (object?["path"] ?? object?["url"] ?? object?["src"]) as? String
        }
        backgrounds = ([root["customBackground"] as? String ?? ""] + local)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// The settings of the vault at [root]; the defaults when there are none.
    /// The page's switches and greeting are `home.*` of its `.daftar.toml`
    /// when it sets one of them, and its quotes `.daftar/quotes.json` when
    /// that is there; each else from the plugin's file
    /// (`docs/specs/no-obsidian-folder.md`). The pictures stay the plugin's.
    public static func read(root: URL) -> Beautitab {
        let plugin = (try? Data(contentsOf: root.appending(path: ".obsidian/plugins/beautitab/data.json"))).map(Beautitab.init(json:)) ?? Beautitab()
        var home = Beautitab(settings: DaftarFolder.settings(root)) ?? plugin
        home.backgrounds = plugin.backgrounds
        home.quotes = (try? Data(contentsOf: root.appending(path: DaftarFolder.quotes))).map(Self.quotes) ?? plugin.quotes
        home.showQuote = home.wantsQuote && !home.quotes.isEmpty
        return home
    }

    /// The keys of `[home]` that stand for the plugin's settings.
    static let keys = ["greeting", "clock", "show_time", "show_greeting", "show_search", "show_recent", "show_bookmarks", "show_quote"]

    /// The home page of a vault's `[home]`, when it sets one of `keys`; the
    /// quotes are read by the caller.
    public init?(settings: ConfigFile) {
        guard Self.keys.contains(where: { settings["home." + $0] != nil }) else { return nil }
        self.init()
        showTime = settings.bool("home.show_time") ?? showTime
        switch settings.string("home.clock") {
        case "24-hour": twentyFourHour = true
        case "12-hour": twentyFourHour = false
        default: twentyFourHour = nil
        }
        showGreeting = settings.bool("home.show_greeting") ?? showGreeting
        greetingText = settings.string("home.greeting")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        showSearch = settings.bool("home.show_search") ?? showSearch
        showRecentFiles = settings.bool("home.show_recent") ?? showRecentFiles
        showBookmarks = settings.bool("home.show_bookmarks") ?? showBookmarks
        wantsQuote = settings.bool("home.show_quote") ?? false
    }

    /// `[{"text": "…", "author": "…"}]`, the shape of the plugin's `customQuotes`.
    static func quotes(_ data: Data) -> [Quote] {
        ((try? JSONSerialization.jsonObject(with: data)) as? [Any] ?? []).compactMap(quote)
    }

    static func quote(_ item: Any) -> Quote? {
        guard let item = item as? [String: Any],
            let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        return Quote(text: text, author: (item["author"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
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
