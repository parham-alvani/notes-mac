import Foundation

/// A job search as data, ported from `job_search.rs` in notes-linux: every
/// note with a `job_stage` property is an application
/// (`Companies/Acme/Acme.md`), and its front matter says where it stands.
/// From them: how many are at each stage, how each channel (`job_channel`)
/// did, the booked events ahead (`job_next`) with the company's
/// `Interview Preparation.md` when its folder has one, and which company a
/// meeting of the week notes is with.
///
/// An application "got past applied" when its stage is neither the waiting
/// one (`applied`) nor a closed one (`rejected`, `withdrawn`), or when it is
/// closed but its folder has a preparation note: a rejection after a call
/// is a reply, one without any is not, and the stage alone cannot tell the
/// two apart.
public struct JobSearch: Sendable, Equatable {
    /// By path.
    public var applications: [JobApplication]

    public static let prepNote = "Interview Preparation.md"

    /// The order of the stages a search usually has; others come after, by name.
    public static let order = ["applied", "screening", "interviewing", "offer", "accepted", "rejected", "withdrawn", "declined", "closed"]

    /// How far a meeting's start may be from a company's `job_next`, in
    /// minutes, and still be that event: a long block of busy time holds
    /// many events, and is none.
    static let near = 15

    public init(applications: [JobApplication] = []) {
        self.applications = applications
    }

    /// The applications of [index]'s notes that [keep] keeps.
    public init(index: VaultIndex, keys: JobKeys = JobKeys(), keep: (String) -> Bool = { _ in true }) {
        // A folder's logo, found once for the whole vault rather than a
        // walk of every file for each company.
        var logos: [String: String] = [:]
        for file in index.files {
            let name = (file.split(separator: "/").last.map(String.init) ?? file).lowercased()
            guard Vault.logoNames.contains(name) else { continue }
            let folder = file.contains("/") ? String(file[..<file.lastIndex(of: "/")!]) : ""
            if let known = logos[folder], Vault.logoNames.firstIndex(of: known.split(separator: "/").last!.lowercased())! <= Vault.logoNames.firstIndex(of: name)! {
                continue
            }
            logos[folder] = file
        }
        var applications: [JobApplication] = []
        for note in index.notes.values where keep(note.path) {
            func values(_ key: String) -> [String]? {
                let key = key.lowercased()
                return note.parsed.properties.first { $0.key.lowercased() == key }?.values
            }
            func first(_ key: String) -> String? {
                values(key)?.first.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
            }
            guard let stage = first(keys.stage)?.lowercased() else { continue }
            let folder = note.path.contains("/") ? String(note.path[..<note.path.lastIndex(of: "/")!]) : ""
            let prepPath = folder.isEmpty ? keys.prepNote : folder + "/" + keys.prepNote
            let prep = prepPath != note.path && index.files.contains(prepPath) ? prepPath : nil
            let closed = keys.closed.contains { $0.lowercased() == stage }
            let waiting = keys.waiting.contains { $0.lowercased() == stage }
            let next = first(keys.next).flatMap(LocalTime.read)
            applications.append(JobApplication(
                path: note.path, company: Vault.title(of: note.path), aliases: note.parsed.aliases, stage: stage,
                applied: first(keys.applied), roles: values(keys.roles) ?? [], next: next?.time, nextHasTime: next?.timed ?? false,
                nextStep: first(keys.nextStep), channel: Self.channel(first(keys.channel) ?? ""), prep: prep,
                pastApplied: closed ? prep != nil : !waiting, closed: closed, logo: logos[folder]))
        }
        self.applications = applications.sorted { $0.path < $1.path }
    }

    /// `Kulturo (Someone, LinkedIn)` as `Kulturo`: the text before ` (`,
    /// trimmed, and `unknown` when there is none.
    public static func channel(_ text: String) -> String {
        let name = (text.range(of: " (").map { String(text[..<$0.lowerBound]) } ?? text).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "unknown" : name
    }

    /// The place of [stage] in a search's order: the known ones first.
    static func rank(_ stage: String) -> Int { order.firstIndex(of: stage) ?? order.count }

    /// Each stage with how many applications are at it, in a search's order.
    public func stages() -> [(stage: String, count: Int)] {
        var counts: [String: Int] = [:]
        for application in applications { counts[application.stage, default: 0] += 1 }
        return counts.map { (stage: $0.key, count: $0.value) }
            .sorted { Self.rank($0.stage) != Self.rank($1.stage) ? Self.rank($0.stage) < Self.rank($1.stage) : $0.stage < $1.stage }
    }

    /// Each channel with its applications and how many got past applied,
    /// the most used first.
    public func channels() -> [ChannelCount] {
        var counts: [String: (Int, Int)] = [:]
        for application in applications {
            let (all, past) = counts[application.channel] ?? (0, 0)
            counts[application.channel] = (all + 1, past + (application.pastApplied ? 1 : 0))
        }
        return counts.map { ChannelCount(channel: $0.key, applications: $0.value.0, pastApplied: $0.value.1) }
            .sorted { a, b in
                if a.applications != b.applications { return a.applications > b.applications }
                if a.pastApplied != b.pastApplied { return a.pastApplied > b.pastApplied }
                return a.channel < b.channel
            }
    }

    /// The booked events from [now] on, before [until] when given, the
    /// soonest first. An event of a day alone is ahead all that day.
    public func upcoming(now: LocalTime, until: LocalTime? = nil) -> [JobApplication] {
        applications
            .filter { application in
                guard let next = application.next else { return false }
                let ahead = application.nextHasTime ? next >= now : next.day >= now.day
                return ahead && (until.map { next < $0 } ?? true)
            }
            .sorted { $0.next! != $1.next! ? $0.next! < $1.next! : $0.path < $1.path }
    }

    /// The application a meeting from [start] to [end] (local times) called
    /// [title] is about: a going company whose name or alias the title
    /// holds as a word, the longest name first; else the company whose
    /// `job_next` is within the meeting and at most a quarter of an hour
    /// from its start.
    public func forMeeting(start: LocalTime, end: LocalTime, title: String) -> JobApplication? {
        let title = title.lowercased()
        var named: (length: Int, application: JobApplication)?
        for application in applications where !application.closed || application.next?.day == start.day {
            let lengths = ([application.company] + application.aliases)
                .filter { Self.holdsWord(title, $0.lowercased()) }
                .map(\.count)
            guard let length = lengths.max() else { continue }
            // The longest name; of two as long, the first path.
            if let best = named, best.length > length || (best.length == length && best.application.path < application.path) { continue }
            named = (length, application)
        }
        if let named { return named.application }
        let latest = max(end, start.adding(seconds: 60))
        return applications
            .compactMap { application -> (Int, JobApplication)? in
                guard application.nextHasTime, let next = application.next else { return nil }
                let off = (next.absolute - start.absolute) / 60
                return next >= start && next < latest && off <= Self.near ? (off, application) : nil
            }
            .min { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.path < $1.1.path }?.1
    }

    /// The line, from 1, of [key] in the front matter of [text]; 1 when it is not there.
    public static func propertyLine(_ text: String, key: String) -> Int {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).makeIterator()
        guard let first = lines.next(), trimEnd(first) == "---" else { return 1 }
        var at = 0
        while let line = lines.next() {
            let line = trimEnd(line)
            if line == "---" || line == "..." { break }
            if let colon = line.firstIndex(of: ":"), line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == key.lowercased() {
                return at + 2
            }
            at += 1
        }
        return 1
    }

    static func trimEnd(_ line: Substring) -> String {
        String(line.reversed().drop { $0.isWhitespace }.reversed())
    }

    /// [haystack] holds [word] with no letter or digit right before or after it.
    static func holdsWord(_ haystack: String, _ word: String) -> Bool {
        guard !word.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        var from = haystack.startIndex
        while let found = haystack.range(of: word, range: from..<haystack.endIndex) {
            let before = found.lowerBound > haystack.startIndex ? haystack[haystack.index(before: found.lowerBound)] : nil
            let after = found.upperBound < haystack.endIndex ? haystack[found.upperBound] : nil
            if !(before.map(Self.isWordy) ?? false) && !(after.map(Self.isWordy) ?? false) { return true }
            from = haystack.index(after: found.lowerBound)
        }
        return false
    }

    private static func isWordy(_ character: Character) -> Bool { character.isLetter || character.isNumber }
}

/// The properties an application is read from. The default is the `job_` ones.
public struct JobKeys: Sendable, Equatable {
    public var stage = "job_stage"
    public var applied = "job_applied"
    public var roles = "job_roles"
    /// The next booked event, a date-time (`2026-11-10T15:30`) or a day.
    public var next = "job_next"
    public var nextStep = "job_next_step"
    public var channel = "job_channel"
    /// Stages still waiting for a first answer.
    public var waiting = ["applied"]
    /// Stages of an application that is over.
    public var closed = ["rejected", "withdrawn", "declined", "closed"]
    /// The name of a company's preparation note, in its folder.
    public var prepNote = JobSearch.prepNote

    public init() {}
}

/// One company's application, from its note's front matter.
public struct JobApplication: Sendable, Equatable, Identifiable {
    public var path: String
    /// The note's name: the company.
    public var company: String
    public var aliases: [String]
    /// Lower case, as written otherwise.
    public var stage: String
    public var applied: String?
    public var roles: [String]
    /// The next booked event; a day alone is at midnight, with [nextHasTime] false.
    public var next: LocalTime?
    public var nextHasTime: Bool
    public var nextStep: String?
    /// [JobSearch.channel] of `job_channel`.
    public var channel: String
    /// The preparation note in the same folder, when there is one.
    public var prep: String?
    /// The stage is neither waiting nor closed, or it closed after a call.
    public var pastApplied: Bool
    /// The stage is a closed one.
    public var closed: Bool
    /// The folder's `logo.svg` (or `.png`, `.webp`, `.jpg`), as the sidebar draws it.
    public var logo: String?
    /// The `memory-quiet` warning, when [JobSearch.markQuiet] found one.
    public var quiet: QuietNote?

    public var id: String { path }

    /// The note to prepare with: the preparation note, else the company's.
    public var prepOrNote: String { prep ?? path }
}

/// How one channel did.
public struct ChannelCount: Sendable, Equatable {
    public var channel: String
    public var applications: Int
    public var pastApplied: Int

    public init(channel: String, applications: Int, pastApplied: Int) {
        self.channel = channel
        self.applications = applications
        self.pastApplied = pastApplied
    }

    /// The share that got past applied, in percent.
    public var rate: Double { applications == 0 ? 0 : Double(pastApplied) * 100 / Double(applications) }
}

/// A time a note writes with no zone, `2026-11-10T15:30`: a day and the
/// seconds into it. The vault's times are Europe/Madrid's.
public struct LocalTime: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var day: Day
    public var seconds: Int

    public init(day: Day, seconds: Int = 0) {
        self.day = day
        self.seconds = seconds
    }

    /// The zone the vault's times are written in.
    public static let zone = TimeZone(identifier: "Europe/Madrid")!

    /// [date] on the clock of [zone].
    public init(date: Date, in zone: TimeZone = LocalTime.zone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        self.init(day: Day(year: parts.year!, month: parts.month!, day: parts.day!),
                  seconds: parts.hour! * 3600 + parts.minute! * 60 + parts.second!)
    }

    /// The moment this is on the clock of [zone].
    public func date(in zone: TimeZone = LocalTime.zone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(
            year: day.year, month: day.month, day: day.day, hour: seconds / 3600, minute: seconds / 60 % 60, second: seconds % 60))
    }

    nonisolated(unsafe) private static let pattern = /([0-9]{4}-[0-9]{2}-[0-9]{2})[T ]([0-9]{2}):([0-9]{2})(?::([0-9]{2}))?/

    /// `2026-11-10T15:30` (or with seconds, or a space), or a day alone;
    /// with whether it had a time.
    public static func read(_ text: String) -> (time: LocalTime, timed: Bool)? {
        let text = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if let match = text.wholeMatch(of: pattern), let day = Day(String(match.1)),
            let hour = Int(match.2), let minute = Int(match.3), hour < 24, minute < 60 {
            let second = match.4.flatMap { Int($0) } ?? 0
            guard second < 60 else { return nil }
            return (LocalTime(day: day, seconds: hour * 3600 + minute * 60 + second), true)
        }
        return Day(text).map { (LocalTime(day: $0), false) }
    }

    /// Seconds from a fixed start, for differences.
    var absolute: Int { Int(day.date.timeIntervalSince1970) + seconds }

    public func adding(seconds more: Int) -> LocalTime {
        let total = seconds + more
        let days = Int((Double(total) / 86_400).rounded(.down))
        return LocalTime(day: day.adding(days: days), seconds: total - days * 86_400)
    }

    public static func < (a: LocalTime, b: LocalTime) -> Bool {
        a.day != b.day ? a.day < b.day : a.seconds < b.seconds
    }

    public var description: String {
        String(format: "%@T%02d:%02d", day.description, seconds / 3600, seconds / 60 % 60)
    }
}

// MARK: The board

extension JobSearch {
    /// A column of the board: one stage and its applications.
    public struct Column: Sendable, Equatable, Identifiable {
        public var stage: String
        public var applications: [JobApplication]
        public var id: String { stage }
    }

    /// The stages that are going, in a search's order, each a column even
    /// when empty so a card can be dropped on it; then the closed ones, in
    /// [keys]' order. A stage the order does not know comes after the known
    /// ones, by name. In a column, a booked event comes first, the soonest
    /// first; then the newest application.
    public func board(keys: JobKeys = JobKeys()) -> (going: [Column], closed: [Column]) {
        var byStage: [String: [JobApplication]] = [:]
        for application in applications { byStage[application.stage, default: []].append(application) }
        let isClosed = { (stage: String) in keys.closed.contains { $0.lowercased() == stage } }
        let known = Self.order.filter { !isClosed($0) }
        let others = byStage.keys.filter { !known.contains($0) && !isClosed($0) }.sorted()
        let closed = keys.closed.map { $0.lowercased() }
        let column = { (stage: String) in
            Column(stage: stage, applications: (byStage[stage] ?? []).sorted(by: Self.cardOrder))
        }
        return ((known + others).map(column), closed.map(column))
    }

    static func cardOrder(_ a: JobApplication, _ b: JobApplication) -> Bool {
        switch (a.next, b.next) {
        case (let x?, let y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
        if a.applied != b.applied { return (a.applied ?? "") > (b.applied ?? "") }
        let order = a.company.localizedStandardCompare(b.company)
        return order == .orderedSame ? a.path < b.path : order == .orderedAscending
    }

    /// A stage as a column's title: `interviewing` as `Interviewing`.
    public static func title(_ stage: String) -> String {
        stage.prefix(1).uppercased() + stage.dropFirst()
    }

    /// Why a stage was not written.
    public enum StageFailure: Error, Equatable {
        /// The note's stage is no longer the one the card showed.
        case moved
        /// The front matter is YAML the form cannot write back the same.
        case unwritable(String)
    }

    /// [text] with the [key] property set to [stage], every other byte as
    /// it was: the properties form's writer, which keeps the value's quotes.
    /// Refused when the note's stage is not [from] any more.
    public static func settingStage(in text: String, key: String = JobKeys().stage, from: String, to stage: String) throws -> String {
        guard var sheet = PropertySheet.read(text).sheet else {
            if case .source(let reason) = PropertySheet.read(text) { throw StageFailure.unwritable(reason) }
            throw StageFailure.moved
        }
        guard let property = sheet.properties.first(where: { $0.key.lowercased() == key.lowercased() }),
            property.value.items.first?.trimmingCharacters(in: .whitespaces).lowercased() == from.lowercased()
        else { throw StageFailure.moved }
        sheet.set(property.key, .text(stage))
        return sheet.applied(to: text) ?? text
    }
}

// MARK: Gone quiet

/// The `memory-quiet` warning of `daftar-cli check`, ported from
/// `memory.rs`: a note whose state property says it is still going
/// (`job_stage: applied`) and in which nothing is dated within [QuietRules.days].
public struct QuietNote: Sendable, Equatable {
    /// The line, from 1, of the property that says it is going.
    public var line: Int
    /// `job_stage: applied`.
    public var state: String
    /// The newest date in the note: a property's, the state paragraph's or a history entry's.
    public var newest: Day
    /// Days from [newest] to the day it was checked.
    public var days: Int

    /// The audit's own words.
    public var message: String {
        "\(state), and nothing in the note is dated after \(newest) (\(days) days): record what happened, or close it"
    }
}

/// Which notes are going, and how long they may be quiet: the vault's
/// `.daftar.toml` (`active` and `quiet_days` of `[audit]`, added to
/// `[check]`'s), else applied, screening and interviewing and 30 days.
public struct QuietRules: Sendable, Equatable {
    public var active: [(key: String, value: String)]
    public var days: Int

    public static let standard = QuietRules(
        active: [("job_stage", "applied"), ("job_stage", "screening"), ("job_stage", "interviewing")], days: 30)

    public init(active: [(key: String, value: String)], days: Int) {
        self.active = active
        self.days = days
    }

    /// The rules of a `.daftar.toml` with [text]; [standard] for what it does not set.
    public static func read(_ text: String?) -> QuietRules {
        guard let text else { return standard }
        let file = ConfigFile(text: text)
        let pairs = ((file.strings("check.active") ?? []) + (file.strings("audit.active") ?? [])).compactMap(pair)
        let days = file.int("audit.quiet_days") ?? file.int("check.quiet_days")
        return QuietRules(active: pairs.isEmpty ? standard.active : pairs, days: days ?? standard.days)
    }

    /// `key=value`; nil when it has no `=`.
    public static func pair(_ text: String) -> (key: String, value: String)? {
        guard let equals = text.firstIndex(of: "=") else { return nil }
        return (text[..<equals].trimmingCharacters(in: .whitespaces), text[text.index(after: equals)...].trimmingCharacters(in: .whitespaces))
    }

    public static func == (a: QuietRules, b: QuietRules) -> Bool {
        a.days == b.days && a.active.map(\.key) == b.active.map(\.key) && a.active.map(\.value) == b.active.map(\.value)
    }

    nonisolated(unsafe) static let status = /^\*\*Where it stands \(([0-9]{4}-[0-9]{2}-[0-9]{2})\):?\*\*/
    nonisolated(unsafe) static let entry = /^\*\*([0-9]{4}-[0-9]{2}-[0-9]{2})(?![0-9A-Za-z_])/

    /// The warning for the note with [text] on [today], or nil: the note is
    /// not going, has nothing dated, or has a date within [days].
    public func quiet(_ text: String, today: Day) -> QuietNote? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
        }
        var body = 0
        if lines.first == "---", let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) { body = end + 1 }
        var going: (line: Int, state: String)?
        var newest: Day?
        func see(_ text: Substring) {
            guard let day = Day(String(text.prefix(10))) else { return }
            if newest.map({ day > $0 }) ?? true { newest = day }
        }
        for (at, line) in lines[..<body].enumerated() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if active.contains(where: { $0.key == key && $0.value == value }) { going = (at, "\(key): \(value)") }
            see(Substring(value))
        }
        for line in lines[body...] where line.hasPrefix("**") {
            if let match = line.firstMatch(of: Self.status) { see(match.1) } else if let match = line.firstMatch(of: Self.entry) { see(match.1) }
        }
        guard let going, let newest else { return nil }
        let age = newest.days(to: today)
        return age > days ? QuietNote(line: going.line + 1, state: going.state, newest: newest, days: age) : nil
    }
}

extension JobSearch {
    /// Marks each going application that [rules] call quiet on [today],
    /// reading each note's text with [read]. Closed ones are not read.
    public mutating func markQuiet(_ rules: QuietRules, today: Day, read: (String) -> String?) {
        for index in applications.indices where !applications[index].closed {
            applications[index].quiet = read(applications[index].path).flatMap { rules.quiet($0, today: today) }
        }
    }
}
