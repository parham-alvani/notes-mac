import Foundation

/// Format on save: when a note the editor held is formatted with
/// `daftar-cli fmt --stdin`, and what of it changes.
public enum NoteFormat {
    /// When the editor might format.
    public enum Moment: Sendable, CaseIterable {
        /// The autosave a second after the typing stops.
        case autosave
        /// The editor lost the keys (a click in the sidebar), and still shows the note.
        case focusLost
        /// Another note in the same editor.
        case otherNote
        /// The editor went away: ⌘E back to the reader, or the pane, the
        /// tab or the window closed.
        case closed
        /// The app quits.
        case quit
        /// Edit › Format Note, asked for.
        case command
    }

    /// Whether the note at [path] is formatted at [moment]. Never while the
    /// note is still being typed in (the autosave, a lost focus): text must
    /// not move under the cursor. On leaving, only with `editor.format_on_save`
    /// and only a note that was [edited] there: opening an unformatted note
    /// to read it in the editor does not change it. The command formats any
    /// note. Only Markdown notes are formatted, never a base or a canvas.
    public static func formats(at moment: Moment, setting: Bool, path: String, edited: Bool) -> Bool {
        guard Vault.isNote(path) else { return false }
        switch moment {
        case .autosave, .focusLost: return false
        case .command: return true
        case .otherNote, .closed, .quit: return setting && edited
        }
    }

    /// The smallest run of whole lines that differs between [old] and [new]:
    /// lines `start..<end` of [old] (from 0) become [lines]. Nil when the two
    /// are the same. For Neovim, whose buffer takes lines: replacing only
    /// these keeps its cursor, marks and folds elsewhere, and is one undo step.
    public static func changedLines(from old: String, to new: String) -> (start: Int, end: Int, lines: [String])? {
        guard old != new else { return nil }
        let a = lines(of: old), b = lines(of: new)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        return (prefix, a.count - suffix, Array(b[prefix..<(b.count - suffix)]))
    }

    /// The lines of [text] as Neovim's buffer holds them: split at `\n`,
    /// without the newline that ends the last one.
    public static func lines(of text: String) -> [String] {
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n") { parts.removeLast() }
        return parts
    }
}
