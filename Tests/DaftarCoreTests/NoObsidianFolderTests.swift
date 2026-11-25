import Foundation
import Testing

@testable import DaftarCore

/// `docs/specs/no-obsidian-folder.md` in notes-linux, section 6, by name: each
/// setting from its new place, `.daftar.toml` or `.daftar/`, first, and from
/// `.obsidian/` only when the new place is not there.
@Suite struct NoObsidianFolderTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-own-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ path: String, _ text: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func remove(_ path: String) throws { try FileManager.default.removeItem(at: root.appending(path: path)) }

    @Test func theNewPlaceWins() throws {
        #expect(DaftarFolder.attachments(root) == "")
        try write(".obsidian/app.json", #"{"attachmentFolderPath": "uploads", "userIgnoreFilters": ["uploads/"]}"#)
        #expect(DaftarFolder.attachments(root) == "uploads")
        #expect(DaftarFolder.ignoreFilters(root) == ["uploads/"])
        try write(".daftar.toml", "[files]\nattachments = \"media\"\nignore = [\"media/\"]\n")
        #expect(DaftarFolder.attachments(root) == "media")
        #expect(DaftarFolder.ignoreFilters(root) == ["media/"])
        // A path that leaves the vault is as not set.
        try write(".daftar.toml", "[files]\nattachments = \"../media\"\n")
        #expect(DaftarFolder.attachments(root) == "uploads")
    }

    @Test func statusesFromTheSettings() throws {
        try write(TaskStatuses.file, #"{"statusSettings":{"customStatuses":[{"symbol":"q","name":"Plugin","nextStatusSymbol":"x","type":"TODO"}]}}"#)
        #expect(TaskStatuses.load(root).status("q").name == "Plugin")
        try write(".daftar.toml", "[tasks.statuses.in_review]\nsymbol = \"r\"\nname = \"In Review\"\nnext = \"x\"\ntype = \"IN_PROGRESS\"\n")
        let statuses = TaskStatuses.load(root)
        #expect(statuses.all.map(\.symbol) == [" ", "x", "/", "-", "r"])
        let review = statuses.status("r")
        #expect(review.name == "In Review" && review.next == "x" && review.type == .inProgress)
        // The plugin's file is not read.
        #expect(statuses.status("q").name == "[q]")
        // A section with one of the four's symbols changes its name.
        try write(".daftar.toml", "[tasks.statuses.todo]\nsymbol = \" \"\nname = \"Open\"\n")
        #expect(TaskStatuses.load(root).status(" ").name == "Open")
        #expect(TaskStatuses.load(root).status(" ").type == .todo)
    }

    @Test func dailyNotesFromTheSettings() throws {
        try write(".obsidian/daily-notes.json", #"{"format": "YYYY-MM-DD", "folder": "Daily"}"#)
        #expect(DailyNotes.read(root: root).folder == "Daily")
        try write(".daftar.toml", "[daily]\nformat = \"YYYY-[W]ww\"\n")
        let daily = DailyNotes.read(root: root)
        // The new place wins whole: the plugin's folder is not taken.
        #expect(daily.folder == "")
        #expect(PeriodicNotes(daily).path(for: Day(year: 2026, month: 11, day: 25)) == "2026-W48.md")
    }

    @Test func iconsFromTheFolder() throws {
        let json = #"{"fileIcons": {"Notes/A.md": {"icon": "lucide-book", "color": "cyan"}}}"#
        try write(Iconic.obsidianFile, json)
        let old = Iconic.load(root).icon(for: "Notes/A.md", folder: false)
        #expect(old?.name == "lucide-book")
        try remove(Iconic.obsidianFile)
        try write(DaftarFolder.icons, json)
        #expect(Iconic.load(root).icon(for: "Notes/A.md", folder: false) == old)
        // With both, `.daftar/` wins.
        try write(Iconic.obsidianFile, #"{"fileIcons": {"Notes/A.md": {"icon": "lucide-car"}}}"#)
        #expect(Iconic.load(root).icon(for: "Notes/A.md", folder: false)?.name == "lucide-book")
    }

    @Test func homeFromTheSettings() throws {
        try write(".obsidian/plugins/beautitab/data.json", #"{"greetingText": "From the plugin", "customQuotes": [{"text": "Old"}], "showQuote": true}"#)
        #expect(Beautitab.read(root: root).greetingText == "From the plugin")
        try write(".daftar.toml", "[home]\ngreeting = \"Hello, Parham.\"\nclock = \"12-hour\"\nshow_quote = true\n")
        try write(DaftarFolder.quotes, #"[{"text": "Hope is a good breakfast.", "author": "Bacon"}]"#)
        let home = Beautitab.read(root: root)
        #expect(home.greetingText == "Hello, Parham.")
        #expect(home.twentyFourHour == false)
        #expect(home.quotes == [Beautitab.Quote(text: "Hope is a good breakfast.", author: "Bacon")])
        #expect(home.showQuote)
    }

    @Test func templatesFromTheSettings() throws {
        try write(".obsidian/templates.json", #"{"folder": "Old", "dateFormat": "DD/MM"}"#)
        #expect(Templates.read(root: root).folder == "Old")
        try write(".daftar.toml", "[templates]\nfolder = \"Templates\"\ntime_format = \"h:mm A\"\n")
        let templates = Templates.read(root: root)
        #expect(templates.folder == "Templates" && templates.timeFormat == "h:mm A" && templates.dateFormat == "YYYY-MM-DD")
    }

    @Test func theFolderIsSkipped() throws {
        try write(".daftar/Note.md", "# Hidden\n")
        try write("Visible.md", "# Visible\n")
        let index = Vault.index(root)
        #expect(index.files == ["Visible.md"])
    }

    @Test func aWriteNeverMakesAnObsidianFolder() throws {
        // A vault with no `.obsidian/` gets the new place.
        #expect(DaftarFolder.written(DaftarFolder.icons, old: Iconic.obsidianFile, in: root).path.hasSuffix(".daftar/icons.json"))
        // One that has it keeps writing there, until `.daftar/` has the file.
        try write(".obsidian/app.json", "{}")
        #expect(DaftarFolder.written(DaftarFolder.icons, old: Iconic.obsidianFile, in: root).path.hasSuffix(Iconic.obsidianFile))
        try write(DaftarFolder.icons, "{}")
        #expect(DaftarFolder.written(DaftarFolder.icons, old: Iconic.obsidianFile, in: root).path.hasSuffix(".daftar/icons.json"))
    }

    @Test func theNewKeysAreAVaultsToSet() {
        let vault = """
            [files]
            attachments = "media"
            [home]
            greeting = "Hi"
            [tasks.statuses.in_review]
            symbol = "r"
            [properties.types]
            job_next = "datetime"
            [folders."Companies/Snapp"]
            template = "T.md"
            [calendar]
            working_day = "08:00-16:30"
            [jobs]
            closed = ["rejected"]
            """
        let settings = ResolvedSettings.resolved(vault: vault, computer: "")
        #expect(settings.refused.isEmpty)
        #expect(settings.string("folders.\"Companies/Snapp\".template") == "T.md")
        #expect(settings.source(of: "calendar.working_day") == .vault)
    }
}
