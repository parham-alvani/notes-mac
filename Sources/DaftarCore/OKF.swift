import Foundation

/// The Open Knowledge Format (OKF 0.3) as Daftar reads it in any note: a
/// note whose front matter has a `type` is a **concept**, and its front
/// matter says who wrote it, who confirmed it and when it goes stale. The
/// vault stays what it is; nothing here refuses a note, and a note with no
/// `type` is read as before. The rules are
/// `docs/specs/open-knowledge-format.md` in notes-linux; §N is OKF's own.
public enum OKF {
    /// A time of the front matter: a date-time with an offset, or a day
    /// alone, which is the start of that day in UTC. Anything else is malformed.
    public enum Time: Sendable, Equatable {
        case at(Date)
        /// As written.
        case malformed(String)

        public var date: Date? {
            if case .at(let date) = self { return date }
            return nil
        }
    }

    public enum Status: Sendable, Equatable {
        case draft, stable, deprecated
        /// Any other value, kept as written: it is not stable.
        case other(String)

        public var isStable: Bool { self == .stable }

        /// The chip's word; nil for `stable`, which shows none.
        public var title: String? {
            switch self {
            case .stable: nil
            case .draft: "Draft"
            case .deprecated: "Deprecated"
            case .other(let raw): raw
            }
        }
    }

    /// The trust tier (§5.3), from the current events only.
    public enum Tier: Sendable, Equatable {
        case unverified, machineConfirmed, humanReviewed

        public var title: String {
            switch self {
            case .unverified: "Unverified"
            case .machineConfirmed: "Machine-confirmed"
            case .humanReviewed: "Human-reviewed"
            }
        }
    }

    /// `generated`: the actor that wrote the text and when it last changed.
    public struct Generated: Sendable, Equatable {
        public var by: String?
        public var at: Time?
    }

    /// One `verified` event: who confirmed the text, and when.
    public struct Event: Sendable, Equatable {
        public var by: String
        public var at: Time
    }

    public struct Concept: Sendable, Equatable {
        /// The kind, any text; no list of kinds is known.
        public var type: String
        public var title: String?
        public var description: String?
        public var resource: String?
        public var tags: [String] = []
        public var status = Status.stable
        /// A path, by the rules of a Markdown link; used only with `deprecated`.
        public var supersededBy: String?
        public var staleAfter: Time?
        public var generated: Generated?
        public var verified: [Event] = []

        /// The events at or after `generated.at`, or all of them with no `generated`.
        public var currentEvents: [Event] {
            guard let generated else { return verified.filter { $0.at.date != nil } }
            switch generated.at {
            case nil: return verified.filter { $0.at.date != nil }
            // A time that cannot be read is no time to be after.
            case .malformed: return []
            case .at(let written): return verified.filter { $0.at.date.map { $0 >= written } ?? false }
            }
        }

        public var tier: Tier {
            let current = currentEvents
            if current.isEmpty { return .unverified }
            return current.contains { OKF.isPerson($0.by) } ? .humanReviewed : .machineConfirmed
        }

        /// The last current event, for the tier chip's tooltip.
        public var lastVerified: Event? {
            currentEvents.max { ($0.at.date ?? .distantPast) < ($1.at.date ?? .distantPast) }
        }

        /// Stale when now is at or after `stale_after`. A malformed one is
        /// stale, never fresh.
        public func isStale(now: Date = Date()) -> Bool {
            switch staleAfter {
            case nil: false
            case .malformed: true
            case .at(let date): now >= date
            }
        }

        public var staleIsMalformed: Bool {
            if case .malformed = staleAfter { return true }
            return false
        }

        public var isDeprecated: Bool { status == .deprecated }

        /// "Stale since <day>" or "Stale: bad date"; nil for a fresh concept.
        public func staleTitle(now: Date = Date()) -> String? {
            guard isStale(now: now) else { return nil }
            guard let date = staleAfter?.date else { return "Stale: bad date" }
            return "Stale since \(OKF.day(date))"
        }
    }

    /// `index.md` and `log.md` are never concepts, whatever their front matter (§3.1).
    public static func isReserved(_ path: String) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return name == "index.md" || name == "log.md"
    }

    /// The concept of [note], a whole note's text at [path]; nil when it is none.
    public static func concept(note: String, path: String? = nil) -> Concept? {
        if let path, isReserved(path) { return nil }
        guard let block = FrontMatterBlock(note) else { return nil }
        return concept(frontMatter: block.lines.joined(separator: "\n"))
    }

    /// The concept a front matter's YAML describes, read with the consumer
    /// rules of §11.2: null, an empty text and an empty list are an absent
    /// key, one item where a list is asked is a list of one, and nothing is
    /// ever refused. Nil with no `type`.
    public static func concept(frontMatter: String) -> Concept? {
        let root = YAML.parse(frontMatter)
        guard case .map = root, let type = text(root["type"]) else { return nil }
        var concept = Concept(type: type)
        concept.title = text(root["title"])
        concept.description = text(root["description"])
        concept.resource = text(root["resource"])
        // A scalar `tags` is one tag, never split at commas.
        concept.tags = (root["tags"]?.items ?? []).compactMap(text)
        if let status = text(root["status"]) {
            concept.status = switch status {
            case "draft": .draft
            case "stable": .stable
            case "deprecated": .deprecated
            default: .other(status)
            }
        }
        concept.supersededBy = text(root["superseded_by"])
        concept.staleAfter = text(root["stale_after"]).map(time)
        if let generated = root["generated"].flatMap(mapping) {
            let by = text(generated["by"]), at = text(generated["at"]).map(time)
            if by != nil || at != nil { concept.generated = Generated(by: by, at: at) }
        }
        // One mapping is a list of one; an event without both keys is left out.
        let events: [YAMLNode] = root["verified"].map { node in mapping(node) != nil ? [node] : node.items } ?? []
        concept.verified = events.compactMap { node in
            guard let event = mapping(node), let by = text(event["by"]), let at = text(event["at"]) else { return nil }
            return Event(by: by, at: time(at))
        }
        return concept
    }

    /// A scalar that says something; null and an empty text are absent.
    private static func text(_ node: YAMLNode?) -> String? {
        guard let text = node?.string?.trimmingCharacters(in: .whitespaces), !text.isEmpty, !isFlowMap(text) else { return nil }
        return text
    }

    private static func isFlowMap(_ text: String) -> Bool { text.hasPrefix("{") && text.hasSuffix("}") }

    /// A mapping as a block or as `{ by: x, at: y }`, which the YAML reader
    /// of the bases leaves as text.
    private static func mapping(_ node: YAMLNode) -> YAMLNode? {
        if case .map(let entries) = node { return entries.isEmpty ? nil : node }
        guard let text = node.string?.trimmingCharacters(in: .whitespaces), isFlowMap(text) else { return nil }
        var entries: [YAMLEntry] = []
        var part = "", quote: Character?
        var parts: [String] = []
        for character in text.dropFirst().dropLast() {
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "," {
                parts.append(part)
                part = ""
                continue
            }
            part.append(character)
        }
        parts.append(part)
        for part in parts {
            guard let (key, value) = YAML.splitKey(part.trimmingCharacters(in: .whitespaces)) else { continue }
            entries.append(YAMLEntry(key: key, value: YAML.inline(value)))
        }
        return entries.isEmpty ? nil : .map(entries)
    }

    // MARK: Times and actors

    nonisolated(unsafe) private static let moment =
        /^(\d{4})-(\d{2})-(\d{2})(?:[Tt ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?[ ]?(Z|z|[+-]\d{2}(?::?\d{2})?))?$/

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// A date-time with an offset (`2026-06-30T14:00:00Z`, `…+02:00`) or a
    /// day alone (the start of that day in UTC). A date-time without an
    /// offset, or anything else, is malformed.
    public static func time(_ text: String) -> Time {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard let match = text.firstMatch(of: moment), let year = Int(match.1), let month = Int(match.2), let day = Int(match.3) else {
            return .malformed(text)
        }
        var parts = DateComponents(year: year, month: month, day: day, hour: 0, minute: 0, second: 0)
        var offset = 0
        if let hour = match.4, let minute = match.5, let zone = match.7 {
            parts.hour = Int(hour)
            parts.minute = Int(minute)
            parts.second = match.6.flatMap { Int($0) } ?? 0
            if zone != "Z", zone != "z" {
                let digits = zone.dropFirst().filter(\.isNumber)
                let hours = Int(digits.prefix(2)) ?? 0, minutes = Int(digits.dropFirst(2)) ?? 0
                guard hours < 24, minutes < 60 else { return .malformed(text) }
                offset = (hours * 3600 + minutes * 60) * (zone.hasPrefix("-") ? -1 : 1)
            }
        }
        // A day that is no day (`2026-02-30`) or an hour that is none is malformed.
        guard (1...12).contains(month), parts.hour! < 24, parts.minute! < 60, parts.second! < 60,
            let date = utc.date(from: parts), utc.component(.day, from: date) == day
        else { return .malformed(text) }
        return .at(date.addingTimeInterval(TimeInterval(-offset)))
    }

    /// Now, in UTC, to the second: `2026-06-30T14:00:00Z`.
    public static func stamp(_ date: Date) -> String {
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", parts.year!, parts.month!, parts.day!, parts.hour!, parts.minute!, parts.second!)
    }

    /// The day of [date] in UTC, `2026-06-30`.
    public static func day(_ date: Date) -> String { String(stamp(date).prefix(10)) }

    /// Only `human:<id>` is a person; `team:`, `process:` and `<producer>/<version>` are not.
    public static func isPerson(_ actor: String) -> Bool {
        actor.hasPrefix("human:") && actor.count > "human:".count
    }

    /// The person Mark as Verified signs as: `okf.actor` of the settings
    /// ([configured], with or without `human:`), else the local part of
    /// the clone's `user.email`; nil when neither says who.
    public static func actor(configured: String, email: String?) -> String? {
        func id(_ text: String) -> String? {
            let text = text.trimmingCharacters(in: .whitespaces)
            let bare = text.hasPrefix("human:") ? String(text.dropFirst("human:".count)) : text
            // One word: an id with a space or a quote would not read back as written.
            guard !bare.isEmpty, !bare.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "\\" || $0 == "," || $0 == "}" }) else { return nil }
            return "human:" + bare
        }
        if let configured = id(configured) { return configured }
        return email.flatMap { $0.split(separator: "@").first }.flatMap { id(String($0)) }
    }

    // MARK: Links

    /// Where a Markdown link's [target] goes from the note [source], as §6
    /// says. The target is already percent-decoded and without its
    /// `#fragment` (`NoteParser.destination`). A target that starts with
    /// `/` resolves from the bundle root: the nearest folder at or above
    /// the note that is in [roots] (the folders whose `index.md` has
    /// `okf_version`), else the vault's root; any other from the note's
    /// folder. Nil when no file of [files] is there, and for a target that
    /// leaves the vault, or leaves the bundle by a `/` path: such a path is
    /// never opened or read from the disk.
    public static func resolve(_ target: String, from source: String, files: Set<String>, roots: Set<String> = []) -> String? {
        let target = Slugs.normalize(target.trimmingCharacters(in: .whitespaces))
        guard !target.isEmpty, !target.contains("\\") else { return nil }
        let folder = source.split(separator: "/").dropLast().map(String.init)
        var base: [String]
        var floor = 0
        if target.hasPrefix("/") {
            base = bundleRoot(of: source, roots: roots).split(separator: "/").map(String.init)
            // A `/` path stays in its bundle.
            floor = base.count
        } else {
            base = folder
        }
        for segment in target.split(separator: "/") {
            switch segment {
            case ".": continue
            case "..":
                guard base.count > floor else { return nil }
                base.removeLast()
            default: base.append(String(segment))
            }
        }
        let path = base.joined(separator: "/")
        guard !path.isEmpty else { return nil }
        if files.contains(path) { return path }
        if files.contains(path + ".md") { return path + ".md" }
        // A folder is its `index.md`, as a bundle's own index links to one.
        if files.contains(path + "/index.md") { return path + "/index.md" }
        return nil
    }

    /// The nearest folder at or above the note [source] that is in [roots]; "" is the vault's root.
    public static func bundleRoot(of source: String, roots: Set<String>) -> String {
        var parts = source.split(separator: "/").dropLast().map(String.init)
        while !parts.isEmpty {
            let folder = parts.joined(separator: "/")
            if roots.contains(folder) { return folder }
            parts.removeLast()
        }
        return ""
    }

    /// Whether a link's address has a scheme (`https:`, `mailto:`): a web
    /// address, never a file of the vault.
    public static func hasScheme(_ address: String) -> Bool {
        guard let colon = address.firstIndex(of: ":"), let first = address.first, first.isASCII, first.isLetter else { return false }
        let scheme = address[..<colon]
        return scheme.count > 1 && scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }
    }

    // MARK: Mark as Verified

    public enum Failure: Error, Equatable, LocalizedError {
        /// The note has no `type`: only a concept is verified.
        case notAConcept
        /// The `verified` key is written in a way that cannot be written again safely.
        case unwritable

        public var errorDescription: String? {
            switch self {
            case .notAConcept: "Only a concept, a note with a type in its properties, can be marked as verified."
            case .unwritable: "The note's verified property is written in a way Daftar cannot add to. Edit it by hand."
            }
        }
    }

    /// [note] with `{ by: <actor>, at: <now, UTC, to the second> }` in its
    /// `verified`: added to the events there, and in the place of an event
    /// of that actor already there. Only the lines of the `verified` key
    /// change; every other line is as it was, byte for byte. Refused for a
    /// note that is no concept.
    public static func markVerified(_ note: String, by actor: String, at now: Date = Date(), path: String? = nil) throws -> String {
        guard concept(note: note, path: path) != nil, let block = FrontMatterBlock(note) else { throw Failure.notAConcept }
        let eol = block.open.hasSuffix("\r") ? "\r" : ""
        var lines = block.lines
        // The lines of the top-level `verified` key: its own, and those under it.
        var range: Range<Int>?
        for (index, line) in lines.enumerated() {
            let bare = line.hasSuffix("\r") ? String(line.dropLast()) : line
            guard let (key, _) = YAML.splitKey(bare), key == "verified", bare.first?.isWhitespace == false else { continue }
            var end = index + 1
            while end < lines.count {
                let next = lines[end].hasSuffix("\r") ? String(lines[end].dropLast()) : lines[end]
                let blank = next.trimmingCharacters(in: .whitespaces).isEmpty
                guard next.first?.isWhitespace == true || next.hasPrefix("- ") || next == "-" || blank else { break }
                end += 1
            }
            // Blank lines after the key stay where they are.
            while end > index + 1, lines[end - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { end -= 1 }
            range = index..<end
            break
        }
        // The events there now, each with its keys as written.
        var events: [[(key: String, value: String)]] = []
        if let range {
            let root = YAML.parse(lines[range].map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }.joined(separator: "\n"))
            let node = root["verified"] ?? .null
            for item in (mapping(node) != nil ? [node] : node.items) {
                guard let event = mapping(item) else {
                    // Text where an event should be: not this command's to drop.
                    if case .null = item { continue }
                    throw Failure.unwritable
                }
                var entries: [(key: String, value: String)] = []
                for entry in event.entries {
                    guard let value = entry.value.string ?? (entry.value == .null ? "" : nil) else { throw Failure.unwritable }
                    entries.append((entry.key, value))
                }
                events.append(entries)
            }
        }
        events.removeAll { event in event.contains { $0.key == "by" && $0.value == actor } }
        events.append([("by", actor), ("at", stamp(now))])
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let written = ["verified:" + eol] + events.map { event in
            "  - { " + event.map { "\($0.key): \(quoted($0.value))" }.joined(separator: ", ") + " }" + eol
        }
        if let range {
            lines.replaceSubrange(range, with: written)
        } else {
            // A new key goes last, before the blank lines the front matter ends with.
            var at = lines.count
            while at > 0, lines[at - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { at -= 1 }
            lines.insert(contentsOf: written, at: at)
        }
        let front = ([block.open] + lines + [block.close]).joined(separator: "\n") + (block.closeNewline ? "\n" : "")
        return front + String(decoding: note.utf8.dropFirst(block.text.utf8.count), as: UTF8.self)
    }
}
