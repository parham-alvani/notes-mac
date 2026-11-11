import DaftarCore
import Foundation
import Testing

@testable import DaftarUI

@Suite struct PDFExportTests {
    @Test func theCLIBesideTheAppComesFirst() {
        let found = PDFExport.cli(
            beside: URL(filePath: "/Applications/Daftar.app/Contents/MacOS/Daftar"),
            environment: ["HOME": "/Users/someone", "PATH": "/usr/bin:/opt/tools"],
            isExecutable: { ["/Applications/Daftar.app/Contents/MacOS/daftar-cli", "/opt/tools/daftar-cli"].contains($0) })
        #expect(found == "/Applications/Daftar.app/Contents/MacOS/daftar-cli")
    }

    @Test func thenPathThenHomebrewAndCargo() {
        let environment = ["HOME": "/Users/someone", "PATH": "/usr/bin:/opt/tools"]
        let beside = URL(filePath: "/Applications/Daftar.app/Contents/MacOS/Daftar")
        #expect(PDFExport.cli(beside: beside, environment: environment, isExecutable: { $0 == "/opt/tools/daftar-cli" }) == "/opt/tools/daftar-cli")
        // An app opened from the Finder has no Homebrew on its $PATH.
        #expect(PDFExport.cli(beside: beside, environment: environment, isExecutable: { $0 == "/opt/homebrew/bin/daftar-cli" }) == "/opt/homebrew/bin/daftar-cli")
        #expect(PDFExport.cli(beside: beside, environment: environment, isExecutable: { $0 == "/Users/someone/.cargo/bin/daftar-cli" }) == "/Users/someone/.cargo/bin/daftar-cli")
        #expect(PDFExport.cli(beside: beside, environment: environment, isExecutable: { _ in false }) == nil)
    }

    @Test func theCommandExportsTheNoteToTheChosenFile() {
        let arguments = PDFExport.arguments(vault: URL(filePath: "/Users/someone/vault"), note: "Companies/Acme/Acme.md", output: URL(filePath: "/Users/someone/Desktop/Acme.pdf"))
        #expect(arguments == ["--vault", "/Users/someone/vault", "export", "-o", "/Users/someone/Desktop/Acme.pdf", "--", "Companies/Acme/Acme.md"])
        // A note whose name starts with a dash is still the note: everything after `--` is.
        let dashed = PDFExport.arguments(vault: URL(filePath: "/v"), note: "--help.md", output: URL(filePath: "/o.pdf"))
        #expect(dashed.last == "--help.md")
        #expect(dashed.firstIndex(of: "--") == dashed.count - 2)
    }

    @Test func theArgumentsAddAFlagForEachOptionBeforeTheNote() {
        let vault = URL(filePath: "/vault"), output = URL(filePath: "/tmp/Note.pdf")
        #expect(PDFExport.arguments(vault: vault, note: "Notes/Note.md", output: output, options: .init())
            == ["--vault", "/vault", "export", "-o", "/tmp/Note.pdf", "--", "Notes/Note.md"])
        #expect(PDFExport.arguments(vault: vault, note: "Notes/Note.md", output: output, options: .init(contents: true, landscape: true))
            == ["--vault", "/vault", "export", "-o", "/tmp/Note.pdf", "--contents", "--landscape", "--", "Notes/Note.md"])
        #expect(PDFExport.Options(landscape: true).flags == ["--landscape"])
    }

    @MainActor @Test func theOptionsComeFromTheConfigFileAndGoBackToIt() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "daftar-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "config.toml")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "[export]\ncontents = true\n".write(to: url, atomically: true, encoding: .utf8)
        let settings = AppSettings(url: url)
        #expect(settings.exportContents)
        #expect(!settings.exportLandscape)
        settings.exportLandscape = true
        #expect(ConfigFile(text: try String(contentsOf: url, encoding: .utf8)).bool("export.landscape") == true)
        let template = ConfigFile(text: ConfigFile.template)
        #expect(template.bool("export.contents") == false)
        #expect(template.bool("export.landscape") == false)
    }

    @Test func anOldCLISaysToUpgradeForThePageOptions() {
        let old = "error: unexpected argument '--landscape' found\n\nUsage: daftar-cli export [OPTIONS] <NOTE>\n\nFor more information, try '--help'.\n"
        #expect(PDFExport.failure(old) == "Table of contents and Landscape need daftar-cli 0.21.0 or later: brew upgrade parham-alvani/tap/daftar-cli.")
    }

    @Test func aFailureIsTheLastLineOfStderr() {
        #expect(PDFExport.failure("warning: something\ndaftar-cli: the logo /x.svg is not a file\n\n") == "the logo /x.svg is not a file")
        #expect(PDFExport.failure("") == "daftar-cli failed.")
    }

    /// clap's usage errors end with "try '--help'", which says nothing.
    @Test func aUsageErrorSaysItsErrorLine() {
        let old = "error: unrecognized subcommand 'export'\n\nUsage: daftar-cli [OPTIONS] [COMMAND]\n\nFor more information, try '--help'.\n"
        #expect(PDFExport.failure(old) == "Export as PDF needs daftar-cli 0.9.0 or later: brew upgrade parham-alvani/tap/daftar-cli.")
        let bad = "error: unexpected argument '--bad' found\n\n  tip: to pass '--bad' as a value, use '-- --bad'\n\nUsage: daftar-cli export [OPTIONS] <NOTE>\n\nFor more information, try '--help'.\n"
        #expect(PDFExport.failure(bad) == "daftar-cli: unexpected argument '--bad' found")
    }

    /// A stand-in `daftar-cli` that writes its arguments where `-o` says,
    /// or fails as the real one does.
    @Test func runWaitsForTheCommandAndSaysWhyItFailed() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pdf-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cli = folder.appending(path: "daftar-cli")
        let script = """
            #!/bin/sh
            [ "$7" = "Missing.md" ] && { echo "daftar-cli: no note Missing.md" >&2; exit 1; }
            echo "$@" > "$5"
            """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let output = folder.appending(path: "Note.pdf")
        #expect(await PDFExport.run(cli: cli.path, vault: folder, note: "Note.md", output: output) == nil)
        #expect(try String(contentsOf: output, encoding: .utf8) == "--vault \(folder.path) export -o \(output.path) -- Note.md\n")
        #expect(await PDFExport.run(cli: cli.path, vault: folder, note: "Missing.md", output: output) == "no note Missing.md")
    }
}
