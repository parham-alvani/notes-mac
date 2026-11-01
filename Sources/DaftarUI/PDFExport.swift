import Foundation

/// Export as PDF (⇧⌘E): `daftar-cli export` on the note, to where the person
/// chooses. The command line makes the PDF, with the logos of `export.logo`
/// and of the note's folder, so the app, a script and Daftar for Linux make
/// the same file (`docs/specs/export.md` in notes-linux).
enum PDFExport {
    /// The `daftar-cli` to run: the one beside the app's own binary, else
    /// the first on `$PATH`, else Homebrew's or Cargo's, which an app opened
    /// from the Finder does not have on its `$PATH`.
    static func cli(
        beside executable: URL? = Bundle.main.executableURL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let folders = [executable?.deletingLastPathComponent().path].compactMap { $0 } + path
            + ["/opt/homebrew/bin", "/usr/local/bin", home + "/.cargo/bin", home + "/.local/bin"]
        return folders.map { ($0 as NSString).appendingPathComponent("daftar-cli") }.first(where: isExecutable)
    }

    /// The command's arguments for the note at [note] in the vault at [vault].
    static func arguments(vault: URL, note: String, output: URL) -> [String] {
        ["--vault", vault.path, "export", note, "-o", output.path]
    }

    /// What a failed run says: the last line of its stderr, without the
    /// command's name. A usage error (clap's `error:` line, then a usage and
    /// a "try '--help'" line) says its `error:` line, and a `daftar-cli`
    /// without `export` (before 0.9.0) says to upgrade it.
    static func failure(_ errors: String) -> String {
        let lines = errors.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let usage = lines.first(where: { $0.hasPrefix("error: ") }) {
            if usage.hasPrefix("error: unrecognized subcommand 'export'") {
                return "Export as PDF needs daftar-cli 0.9.0 or later: brew upgrade parham-alvani/tap/daftar-cli."
            }
            return "daftar-cli: " + usage.dropFirst("error: ".count)
        }
        guard let line = lines.last else { return "daftar-cli failed." }
        return line.hasPrefix("daftar-cli: ") ? String(line.dropFirst("daftar-cli: ".count)) : line
    }

    /// Runs [cli] off the main thread; nil when the PDF was written, else why not.
    static func run(cli: String, vault: URL, note: String, output: URL) async -> String? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: cli)
            process.arguments = arguments(vault: vault, note: note, output: output)
            let errors = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors
            do {
                try process.run()
            } catch {
                return "The PDF was not made: \(error.localizedDescription)"
            }
            // Read to the end first, so a full pipe never stops the command.
            let said = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus != 0 else { return nil }
            return failure(String(decoding: said, as: UTF8.self))
        }.value
    }
}
