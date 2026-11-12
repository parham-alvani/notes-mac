import Foundation

/// Export as PDF (⇧⌘E): `daftar-cli export` on the note, to where the person
/// chooses. The command line makes the PDF, with the logos of `export.logo`
/// and of the note's folder, so the app, a script and Daftar for Linux make
/// the same file (`docs/specs/export.md` in notes-linux).
enum PDFExport {
    /// The `daftar-cli` to run (`DaftarCLI.locate`).
    static func cli(
        beside executable: URL? = Bundle.main.executableURL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        DaftarCLI.locate(beside: executable, environment: environment, isExecutable: isExecutable)
    }

    /// The page options Export as PDF asks for, kept in `export.contents`
    /// and `export.landscape`.
    struct Options: Equatable {
        /// `--contents`: a table of the headings before the note.
        var contents = false
        /// `--landscape`: the page on its side.
        var landscape = false

        /// The flags these options add to the command.
        var flags: [String] {
            (contents ? ["--contents"] : []) + (landscape ? ["--landscape"] : [])
        }
    }

    /// The command's arguments for the note at [note] in the vault at [vault].
    /// The note comes last, after `--`: a note at the vault's top whose name
    /// starts with `-` (`-o.md`, `--help.md`) is a note, not an option. The
    /// flags of [options] go before it.
    static func arguments(vault: URL, note: String, output: URL, options: Options = Options()) -> [String] {
        ["--vault", vault.path, "export", "-o", output.path] + options.flags + ["--", note]
    }

    /// What a failed run says: the last line of its stderr, without the
    /// command's name. A usage error (clap's `error:` line, then a usage and
    /// a "try '--help'" line) says its `error:` line, and a `daftar-cli`
    /// without `export` (before 0.9.0), or without the page options (before
    /// 0.21.0), says to upgrade it.
    static func failure(_ errors: String) -> String {
        let lines = errors.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let usage = lines.first(where: { $0.hasPrefix("error: ") }) {
            if usage.hasPrefix("error: unrecognized subcommand 'export'") {
                return "Export as PDF needs daftar-cli 0.9.0 or later: brew upgrade parham-alvani/tap/daftar-cli."
            }
            if ["--contents", "--landscape"].contains(where: { usage.hasPrefix("error: unexpected argument '\($0)'") }) {
                return "Table of contents and Landscape need daftar-cli 0.21.0 or later: brew upgrade parham-alvani/tap/daftar-cli."
            }
        }
        return DaftarCLI.failure(errors)
    }

    /// Runs [cli] off the main thread; nil when the PDF was written, else why not.
    static func run(cli: String, vault: URL, note: String, output: URL, options: Options = Options()) async -> String? {
        do {
            let ran = try await DaftarCLI.run(cli, arguments(vault: vault, note: note, output: output, options: options))
            return ran.status == 0 ? nil : failure(ran.stderr)
        } catch DaftarCLI.Failure.notRun(let why) {
            return "The PDF was not made: \(why)"
        } catch {
            return "The PDF was not made."
        }
    }
}
