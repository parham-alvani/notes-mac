import AppKit
import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

/// A stand-in `daftar-cli` in a temporary folder: a shell script that keeps
/// its arguments in `calls`, answers `--json` with findings, and formats
/// `--stdin` by turning `*  ` list marks into `- `. With [old] it is a
/// `daftar-cli` before 0.23.0, which refuses the new flags as clap does.
struct FakeCLI {
    let folder: URL
    var path: String { folder.appending(path: "daftar-cli").path }
    var calls: [String] {
        ((try? String(contentsOf: folder.appending(path: "calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    init(old: Bool = false) throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "daftar-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let calls = folder.appending(path: "calls").path
        let script = old ? """
            #!/bin/sh
            echo "$*" >> '\(calls)'
            for a in "$@"; do case "$a" in --json|--stdin|--path=*)
                printf "error: unexpected argument '%s' found\\n\\nUsage: daftar-cli\\n\\nFor more information, try '--help'.\\n" "${a%%=*}" >&2; exit 2;;
            esac; done
            exit 0
            """ : """
            #!/bin/sh
            echo "$*" >> '\(calls)'
            case "$*" in
            *"fmt --check --json"*)
                echo '{"tool":"fmt","level":"error","path":"Home.md","line":0,"column":null,"code":"fmt","message":"not formatted","fixable":true}';;
            *"check --json"*)
                echo '{"tool":"check","level":"error","path":"Notes/Plan.md","line":2,"column":1,"code":"callout-body","message":"the body is joined to the title","fixable":false}'
                echo 'daftar-cli: 1 errors, 0 warnings in 2 notes' >&2
                exit 1;;
            *"lint --json"*)
                echo '{"tool":"lint","level":"warning","path":"Home.md","line":1,"column":null,"code":"MD034","message":"bare URL","fixable":true}';;
            *"fmt --stdin"*)
                sed 's/^\\*  /- /';;
            esac
            exit 0
            """
        try script.write(to: folder.appending(path: "daftar-cli"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }
}

/// The Problems panel's audit and fixes, and format on save, against a
/// stand-in `daftar-cli` on a made-up vault.
@MainActor
@Suite(.serialized) struct ProblemsPanelTests {
    let root: URL
    let store: VaultStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-problems-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Notes"), withIntermediateDirectories: true)
        try "# Plan\n*  item\n".write(to: root.appending(path: "Notes/Plan.md"), atomically: true, encoding: .utf8)
        try "See https://example.com".write(to: root.appending(path: "Home.md"), atomically: true, encoding: .utf8)
        store = VaultStore(settings: AppSettings(url: root.appending(path: "config/config.toml")), openVault: false)
        store.openSynchronously(root)
        store.checks.opened(root)
    }

    func text(_ path: String) throws -> String { try String(contentsOf: root.appending(path: path), encoding: .utf8) }

    func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    // MARK: The runner

    @Test func theRunnerFeedsStdinAndReadsBothPipes() async throws {
        let output = try await DaftarCLI.run("/bin/sh", ["-c", "cat; echo said >&2; exit 3"], input: Data("note text\n".utf8))
        #expect(output.text == "note text\n")
        #expect(output.stderr == "said\n")
        #expect(output.status == 3)
        // More than a pipe holds, both ways, does not stop the command.
        let big = String(repeating: "line of a long note\n", count: 20_000)
        let echoed = try await DaftarCLI.run("/bin/cat", [], input: Data(big.utf8))
        #expect(echoed.text == big)
    }

    @Test func aCancelledRunEndsTheCommand() async throws {
        let started = Date()
        let task = Task { try await DaftarCLI.run("/bin/sleep", ["30"]) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let output = try? await task.value
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(output?.cancelled ?? true)
    }

    @Test func aCommandThatIsNotThereIsAFailure() async {
        await #expect(throws: DaftarCLI.Failure.self) { try await DaftarCLI.run("/nonexistent/daftar-cli", []) }
    }

    /// A `daftar-cli` before 0.23.0 refuses `--json` and `--stdin`: that is
    /// "upgrade", not an error of the vault.
    @Test func anOldCommandLineIsToldApart() {
        func usage(_ line: String) -> DaftarCLI.Output {
            DaftarCLI.Output(status: 2, stdout: Data(), stderr: line + "\n\nUsage: daftar-cli check [OPTIONS]\n\nFor more information, try '--help'.\n")
        }
        #expect(DaftarCLI.tooOld(usage("error: unexpected argument '--json' found")))
        #expect(DaftarCLI.tooOld(usage("error: unexpected argument '--stdin' found\n\n  tip: to pass '--stdin' as a value, use '-- --stdin'")))
        #expect(!DaftarCLI.tooOld(usage("error: unexpected argument '--bad' found")))
        // `check` that fails on an error of the vault is not a usage error.
        #expect(!DaftarCLI.tooOld(DaftarCLI.Output(status: 1, stdout: Data(), stderr: "error: unexpected argument '--json' found\n")))
        #expect(VaultChecks.refusesPaths(usage("error: unexpected argument 'Notes/Plan.md' found"), ["Notes/Plan.md"]))
        #expect(VaultChecks.refusesPaths(usage("error: unexpected argument '--' found"), ["A.md"]))
        #expect(!VaultChecks.refusesPaths(usage("error: unexpected argument '--bad' found"), ["A.md"]))
        #expect(DaftarCLI.failure("error: unexpected argument '--bad' found\n\nUsage: x\n") == "daftar-cli: unexpected argument '--bad' found")
        #expect(DaftarCLI.failure("daftar-cli: no vault at /x\n") == "no vault at /x")
        #expect(DaftarCLI.failure("") == "daftar-cli failed.")
        #expect(VaultChecks.FormatFailure.tooOld.notice == "Problems and Format Note need daftar-cli 0.23.0 or later: brew upgrade parham-alvani/tap/daftar-cli.")
    }

    @Test func theCommandsAreThoseOfJustCheckAuditAndFix() throws {
        let vault = URL(filePath: "/v")
        #expect(VaultChecks.auditArguments(vault: vault, profile: true) == [
            ["--vault", "/v", "check", "--json", "--profile", "audit"],
            ["--vault", "/v", "lint", "--json"],
            ["--vault", "/v", "fmt", "--check", "--json"],
        ])
        #expect(VaultChecks.auditArguments(vault: vault, profile: false)[0] == ["--vault", "/v", "check", "--json"])
        #expect(VaultChecks.fixArguments(vault: vault, tools: Set(Problem.Tool.allCases), paths: []) == [
            ["--vault", "/v", "lint", "--fix"], ["--vault", "/v", "check", "--fix"], ["--vault", "/v", "fmt"],
        ])
        #expect(VaultChecks.fixArguments(vault: vault, tools: [.check], paths: ["-x.md"]) == [["--vault", "/v", "check", "--fix", "--", "-x.md"]])
        #expect(VaultChecks.formatArguments(vault: vault, path: "-x.md") == ["--vault", "/v", "fmt", "--stdin", "--path=-x.md"])
        try "[check]\nmemory = true\n\n[audit]\nquiet_days = 30\n".write(to: root.appending(path: ".daftar.toml"), atomically: true, encoding: .utf8)
        #expect(VaultChecks.hasAuditProfile(root))
        #expect(VaultChecks.usesCLI(root))
    }

    // MARK: The audit

    @Test func theAuditListsWhatTheThreeToolsFound() async throws {
        let cli = try FakeCLI()
        store.checks.locate = { cli.path }
        store.checks.refresh()
        #expect(await eventually { if case .done = store.checks.state { true } else { false } })
        #expect(store.checks.counts == Problems.Counts(errors: 2, warnings: 1))
        #expect(store.checks.grouped(.all).map(\.path) == ["Home.md", "Notes/Plan.md"])
        #expect(store.checks.grouped(.errors).flatMap(\.problems).map(\.code) == ["fmt", "callout-body"])
        #expect(cli.calls.count == 3)
        #expect(cli.calls.allSatisfy { $0.hasPrefix("--vault \(root.path) ") })
    }

    @Test func anOldCommandLineSaysToUpgradeOnce() async throws {
        let cli = try FakeCLI(old: true)
        store.checks.locate = { cli.path }
        store.checks.refresh()
        #expect(await eventually { store.checks.state == .tooOld })
        #expect(store.notice == DaftarCLI.upgrade)
        #expect(store.checks.problems.isEmpty)
        // The background runs after a save do not ask it again.
        store.notice = nil
        store.checks.changed()
        try await Task.sleep(for: .milliseconds(300))
        #expect(cli.calls.count == 1)
        #expect(store.notice == nil)
    }

    @Test func noCommandLineIsSaid() async {
        store.checks.locate = { nil }
        store.checks.refresh()
        #expect(await eventually { store.checks.state == .noCLI })
        #expect(VaultChecks.explanation(.noCLI) == DaftarCLI.missing)
    }

    /// Fix All of a note runs what `just fix` runs, on that note, after the
    /// editors saved; then the vault is checked again.
    @Test func fixAllOfANoteRunsTheThreeFixesAfterTheEditorsSave() async throws {
        let cli = try FakeCLI()
        store.checks.locate = { cli.path }
        final class Editor {
            var saved = false
        }
        let editor = Editor()
        store.flushers[ObjectIdentifier(editor)] = { editor.saved = true }
        defer { store.flushers[ObjectIdentifier(editor)] = nil }
        store.checks.fixAll("Home.md")
        #expect(await eventually { cli.calls.contains { $0.hasSuffix("fmt -- Home.md") } })
        #expect(editor.saved)
        #expect(Array(cli.calls.prefix(3)) == [
            "--vault \(root.path) lint --fix -- Home.md", "--vault \(root.path) check --fix -- Home.md", "--vault \(root.path) fmt -- Home.md",
        ])
        // And the audit runs again.
        #expect(await eventually { cli.calls.contains { $0.hasSuffix("check --json") } })
        #expect(await eventually { !store.checks.fixing })
    }

    // MARK: Format on save

    @Test func leavingANoteTypedInFormatsItsFile() async throws {
        let cli = try FakeCLI()
        store.checks.locate = { cli.path }
        store.checks.formatOnLeave(LeftNote(path: "Notes/Plan.md", loaded: "# Plan\n"), at: .closed)
        #expect(await eventually { (try? text("Notes/Plan.md")) == "# Plan\n- item\n" })
    }

    @Test func aNoteOnlyReadInTheEditorIsLeftAsItIs() async throws {
        let cli = try FakeCLI()
        store.checks.locate = { cli.path }
        let before = try text("Notes/Plan.md")
        store.checks.formatOnLeave(LeftNote(path: "Notes/Plan.md", loaded: before), at: .closed)
        store.checks.formatOnLeave(LeftNote(path: "Notes/Plan.md", loaded: "# Plan\n"), at: .autosave)
        store.settings.formatOnSave = false
        store.checks.formatOnLeave(LeftNote(path: "Notes/Plan.md", loaded: "# Plan\n"), at: .otherNote)
        try await Task.sleep(for: .milliseconds(500))
        #expect(try text("Notes/Plan.md") == before)
        #expect(!cli.calls.contains { $0.contains("--stdin") })
    }

    /// No `daftar-cli` that formats: nothing is written and nothing is said.
    @Test func withAnOldCommandLineLeavingSaysNothing() async throws {
        let cli = try FakeCLI(old: true)
        store.checks.locate = { cli.path }
        store.checks.formatOnLeave(LeftNote(path: "Notes/Plan.md", loaded: "# Plan\n"), at: .closed)
        #expect(await eventually { cli.calls.count == 1 })
        store.checks.formatOnLeave(LeftNote(path: "Notes/Plan.md", loaded: "# Plan\n"), at: .quit)
        try await Task.sleep(for: .milliseconds(300))
        #expect(cli.calls.count == 1)
        #expect(store.notice == nil)
        #expect(try text("Notes/Plan.md") == "# Plan\n*  item\n")
    }

    /// The editor's margin: the audit's findings by line, their messages on
    /// hover, and nothing in the text changes for them.
    @Test func theMarginSaysTheProblemsOfALine() throws {
        let controller = EditorController(store: store)
        let scroll = NoteTextView.scrollableNoteView()
        let view = scroll.documentView as! NoteTextView
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        defer { window.contentView = nil }
        view.controller = controller
        controller.view = view
        controller.load("Notes/Plan.md")
        let error = Problem(tool: .lint, level: .error, path: "Notes/Plan.md", line: 2, code: "MD004", message: "list style", fixable: true)
        let warning = Problem(tool: .check, level: .warning, path: "Notes/Plan.md", line: 2, code: "w", message: "a warning")
        let before = view.string
        view.show(problems: Problems.lines([error, warning], of: "Notes/Plan.md"))
        #expect(view.problemMarks.keys.sorted() == [1])
        #expect(view.problemTip != nil)
        let row = try #require(view.lineRect(at: ("# Plan\n" as NSString).length))
        #expect(view.problemText(at: NSPoint(x: 2, y: row.midY)) == "Error: list style (MD004)\nWarning: a warning (w)")
        #expect(view.problemText(at: NSPoint(x: 2, y: try #require(view.lineRect(at: 0)).midY)) == "")
        view.display()
        #expect(view.string == before)
        view.show(problems: [:])
        #expect(view.problemTip == nil)
    }

    /// Edit › Format Note in the editor: the text on screen, as one step to undo.
    @Test func formatNoteInTheEditorIsOneUndoStep() async throws {
        let cli = try FakeCLI()
        store.checks.locate = { cli.path }
        let controller = EditorController(store: store)
        let scroll = NoteTextView.scrollableNoteView()
        let view = scroll.documentView as! NoteTextView
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        defer { window.contentView = nil }
        view.controller = controller
        controller.view = view
        controller.load("Notes/Plan.md")
        let undo = try #require(view.undoManager)
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        controller.formatNote()
        #expect(await eventually { view.string == "# Plan\n- item\n" })
        #expect(try text("Notes/Plan.md") == "# Plan\n- item\n")
        undo.undo()
        #expect(view.string == "# Plan\n*  item\n")
        // Formatted already: nothing changes, and it says so.
        undo.redo()
        #expect(view.string == "# Plan\n- item\n")
        controller.formatNote()
        #expect(await eventually { store.notice == "Plan is formatted already." })
        #expect(view.string == "# Plan\n- item\n")
    }
}
