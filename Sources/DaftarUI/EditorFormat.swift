import AppKit
import DaftarCore

/// Format on save and Edit › Format Note in the editor: `daftar-cli fmt
/// --stdin` (`VaultChecks`). Leaving a note formats its file once the
/// editor has saved it; the command formats the text on screen, as one
/// step to undo, and in Neovim mode the buffer, as one step of Neovim's undo.
extension EditorController {
    /// The note on screen, and what it said when this editor took it.
    var leaving: LeftNote? { path.map { LeftNote(path: $0, loaded: loadedText) } }

    /// The editor left [left] at [moment]: the store formats the file once
    /// what was typed is on disk.
    func formatOnLeave(_ left: LeftNote?, at moment: NoteFormat.Moment) {
        guard let left else { return }
        store.checks.formatOnLeave(left, at: moment, after: stopping)
    }

    /// Edit › Format Note (⌥⇧⌘F).
    func formatNote() {
        guard let view, let path else { return }
        let checks = store.checks
        if let session {
            Task {
                // Formatted from the file once Neovim has written it, and put
                // back into the buffer by its lines.
                await flush()
                guard self.session === session, let text = store.text(of: path),
                    let out = await checks.formattedForCommand(text, path: path)
                else { return }
                guard let change = NoteFormat.changedLines(from: text, to: out) else {
                    store.notice = "\(Vault.title(of: path)) is formatted already."
                    return
                }
                let expected = NoteFormat.lines(of: text)
                if !(await session.replace(lines: change.start, change.end, with: change.lines, expected: expected)) {
                    store.notice = "\(Vault.title(of: path)) changed while it was formatted. Nothing was changed."
                }
            }
            return
        }
        let text = view.string
        Task {
            guard let out = await checks.formattedForCommand(text, path: path) else { return }
            guard self.path == path, let view = self.view, owner == .plain, view.string == text else {
                store.notice = "\(Vault.title(of: path)) changed while it was formatted. Nothing was changed."
                return
            }
            guard out != text else {
                store.notice = "\(Vault.title(of: path)) is formatted already."
                return
            }
            apply(out, to: view, named: "Format Note")
            saveNow()
        }
    }

    /// [text] in place of the view's, as one step to undo: only the range
    /// that differs is replaced, the scroll holds and the cursor stays on
    /// its letter.
    func apply(_ text: String, to view: NoteTextView, named name: String) {
        let edit = Self.smallestEdit(from: view.string as NSString, to: text as NSString)
        let length = (edit.text as NSString).length
        let selection = view.selectedRange()
        view.undoManager?.beginUndoGrouping()
        defer { view.undoManager?.endUndoGrouping() }
        guard view.shouldChangeText(in: edit.range, replacementString: edit.text) else { return }
        view.holdScroll(editing: edit.range, with: length)
        view.textStorage?.replaceCharacters(in: edit.range, with: edit.text)
        view.didChangeText()
        view.undoManager?.setActionName(name)
        var cursor = selection.location
        if cursor >= NSMaxRange(edit.range) {
            cursor += length - edit.range.length
        } else if cursor > edit.range.location {
            cursor = edit.range.location + length
        }
        view.setSelectedRange(NSRange(location: min(max(0, cursor), (view.string as NSString).length), length: 0))
    }
}
