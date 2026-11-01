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
        #expect(arguments == ["--vault", "/Users/someone/vault", "export", "Companies/Acme/Acme.md", "-o", "/Users/someone/Desktop/Acme.pdf"])
    }

    @Test func aFailureIsTheLastLineOfStderr() {
        #expect(PDFExport.failure("warning: something\ndaftar-cli: the logo /x.svg is not a file\n\n") == "the logo /x.svg is not a file")
        #expect(PDFExport.failure("") == "daftar-cli failed.")
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
            [ "$4" = "Missing.md" ] && { echo "daftar-cli: no note Missing.md" >&2; exit 1; }
            echo "$@" > "$6"
            """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let output = folder.appending(path: "Note.pdf")
        #expect(await PDFExport.run(cli: cli.path, vault: folder, note: "Note.md", output: output) == nil)
        #expect(try String(contentsOf: output, encoding: .utf8) == "--vault \(folder.path) export Note.md -o \(output.path)\n")
        #expect(await PDFExport.run(cli: cli.path, vault: folder, note: "Missing.md", output: output) == "no note Missing.md")
    }
}
