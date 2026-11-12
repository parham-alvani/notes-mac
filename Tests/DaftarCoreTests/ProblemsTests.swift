import Foundation
import Testing

@testable import DaftarCore

/// The Problems panel's findings, read from `daftar-cli … --json`, and
/// format on save's rules.
@Suite struct ProblemsTests {
    static let output = """
        {"tool":"check","level":"warning","path":"Notes/Plan.md","line":12,"column":null,"code":"link-heading","message":"no heading Goals","fixable":false}
        {"tool":"lint","level":"error","path":"Notes/Plan.md","line":3,"column":5,"code":"MD034","message":"bare URL","fixable":true}

        daftar-cli: 2 errors, 1 warnings in 2 notes
        {"tool":"check","level":"error","path":"Home.md","line":9,"column":1,"code":"callout-body","message":"the body is joined to the title","fixable":false}
        {"tool":"fmt","level":"error","path":"Notes/Plan.md","line":0,"column":null,"code":"fmt","message":"not formatted","fixable":true}
        {"tool":"spell","level":"error","path":"Home.md","line":1,"code":"x","message":"a tool this does not know"}
        {"tool":"check","level":"info","path":"Home.md","line":1,"code":"x","message":"a level this does not know"}
        {"tool":"check","level":"error","line":1,"code":"x","message":"no path"}
        {"tool":"lint","level":"warning","path":"Home.md","line":true,"column":-2,"code":"MD009","message":"spaces at the end"}
        {not json
        """

    @Test func findingsAreReadAndWhatIsNotOneIsSkipped() {
        let problems = Problems.parse(Self.output)
        #expect(problems.count == 5)
        #expect(problems[0] == Problem(tool: .check, level: .warning, path: "Notes/Plan.md", line: 12, code: "link-heading", message: "no heading Goals"))
        #expect(problems[1] == Problem(tool: .lint, level: .error, path: "Notes/Plan.md", line: 3, column: 5, code: "MD034", message: "bare URL", fixable: true))
        // Line 0 is the whole note: it opens at no line.
        #expect(problems[3].line == 0 && problems[3].sourceLine == nil)
        #expect(problems[1].sourceLine == 2)
        // A line that is not a number, and a column below 1, are not taken as one.
        #expect(problems[4].line == 0 && problems[4].column == nil)
        #expect(Problems.parse("").isEmpty)
        #expect(Problems.parse("error: unexpected argument '--json' found\n").isEmpty)
    }

    @Test func notesWithErrorsComeFirstAndErrorsFirstInEach() {
        let problems = Problems.parse(Self.output)
        let notes = Problems.grouped(problems)
        #expect(notes.map(\.path) == ["Home.md", "Notes/Plan.md"])
        #expect(notes[1].problems.map(\.code) == ["fmt", "MD034", "link-heading"])
        #expect(notes[1].counts == Problems.Counts(errors: 2, warnings: 1))
        #expect(notes[1].fixable)
        // A note with only warnings goes after every note with an error.
        let warned = Problem(tool: .check, level: .warning, path: "A.md", line: 1, code: "w", message: "w")
        #expect(Problems.grouped(problems + [warned]).map(\.path) == ["Home.md", "Notes/Plan.md", "A.md"])
        #expect(Problems.grouped(problems, filter: .errors).flatMap(\.problems).allSatisfy { $0.level == .error })
        #expect(Problems.grouped(problems, filter: .warnings).map(\.path) == ["Home.md", "Notes/Plan.md"])
        // The same finding twice is listed once.
        #expect(Problems.grouped(problems + problems).flatMap(\.problems).count == problems.count)
    }

    @Test func countsAreSaidInWords() {
        let problems = Problems.parse(Self.output)
        #expect(Problems.counts(problems) == Problems.Counts(errors: 3, warnings: 2))
        #expect(Problems.counts(problems).spoken == "3 errors, 2 warnings")
        #expect(Problems.Counts(errors: 1).spoken == "1 error")
        #expect(Problems.Counts(warnings: 1).spoken == "1 warning")
        #expect(Problems.Counts().spoken == "No problems")
    }

    @Test func theMarginGetsTheLinesOfOneNote() {
        let lines = Problems.lines(Problems.parse(Self.output), of: "Notes/Plan.md")
        #expect(lines.keys.sorted() == [2, 11])
        #expect(lines[2]?.map(\.code) == ["MD034"])
    }

    /// Format on save: never while typing; on leaving, with the setting, a
    /// note typed in; the command, any note; never a base or a canvas.
    @Test func formatOnLeaveIsDecidedByTheMoment() {
        for moment in NoteFormat.Moment.allCases {
            let leaving = [.otherNote, .closed, .quit].contains(moment)
            #expect(NoteFormat.formats(at: moment, setting: true, path: "Note.md", edited: true) == (leaving || moment == .command))
            #expect(NoteFormat.formats(at: moment, setting: false, path: "Note.md", edited: true) == (moment == .command))
            #expect(NoteFormat.formats(at: moment, setting: true, path: "Note.md", edited: false) == (moment == .command))
            #expect(!NoteFormat.formats(at: moment, setting: true, path: "Board.canvas", edited: true))
            #expect(!NoteFormat.formats(at: moment, setting: true, path: "Tasks.base", edited: true))
        }
        #expect(!NoteFormat.formats(at: .autosave, setting: true, path: "Note.md", edited: true))
        #expect(!NoteFormat.formats(at: .focusLost, setting: true, path: "Note.md", edited: true))
        #expect(NoteFormat.formats(at: .closed, setting: true, path: "Folder/NOTE.MD", edited: true))
    }

    /// Neovim takes the formatted note as the lines that changed.
    @Test func onlyTheLinesThatChangedAreReplaced() throws {
        #expect(NoteFormat.changedLines(from: "a\nb\n", to: "a\nb\n") == nil)
        let one = try #require(NoteFormat.changedLines(from: "# T\n*  item\ntext\n", to: "# T\n- item\ntext\n"))
        #expect(one.start == 1 && one.end == 2 && one.lines == ["- item"])
        // A line taken out, and one put in.
        let out = try #require(NoteFormat.changedLines(from: "a\n\n\nb\n", to: "a\n\nb\n"))
        #expect(out.end - out.start == 1 && out.lines.isEmpty)
        let added = try #require(NoteFormat.changedLines(from: "# T\ntext\n", to: "# T\n\ntext\n"))
        #expect(added.start == added.end && added.lines == [""])
        #expect(NoteFormat.lines(of: "a\nb\n") == ["a", "b"])
        #expect(NoteFormat.lines(of: "a\nb") == ["a", "b"])
        // Applied to the old lines, the change gives the new ones.
        for (old, new) in [("x\ny\nz\n", "x\nY\nz\n"), ("", "a\n"), ("a\n", ""), ("1\n2\n3\n4\n", "1\n4\n")] {
            var lines = NoteFormat.lines(of: old)
            if let change = NoteFormat.changedLines(from: old, to: new) { lines.replaceSubrange(change.start..<change.end, with: change.lines) }
            #expect(lines == NoteFormat.lines(of: new))
        }
    }
}
