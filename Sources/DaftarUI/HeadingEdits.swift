import AppKit
import DaftarCore
import SwiftUI

/// "Rename Heading…": the heading of a note whose sheet is open, and its
/// place among the note's headings when the sheet opened.
struct HeadingTarget: Identifiable {
    let id = UUID()
    var path: String
    var headings: [Heading]
    var index: Int
}

/// The editor goes to [line] when this changes: a click in the outline.
struct EditorJump: Equatable {
    var line: Int
    var id = UUID()
}

// MARK: The store

extension VaultStore {
    /// The lines that change when the headings of [change] are renamed:
    /// in the notes that link to the note, and in the note itself, read
    /// from disk. With [retitle], the heading lines themselves too.
    func headingEdits(_ change: HeadingRename.Change, retitle: Bool = false) async -> [HeadingRename.NoteEdits] {
        guard let root else { return [] }
        let index = index
        var sources = Set((index.backlinks[change.path] ?? []).map(\.source))
        sources.insert(change.path)
        let paths = sources.filter(Vault.isNote).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return await Task.detached {
            paths.compactMap { source -> HeadingRename.NoteEdits? in
                guard let file = Self.file(source, in: root), let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                var edits = HeadingRename.edits(in: text, source: source, change: change) { index.resolve($0, from: source) == change.path }
                if retitle, source == change.path {
                    let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
                    for (at, new) in change.renames {
                        guard change.headings.indices.contains(at) else { continue }
                        let line = change.headings[at].line
                        guard lines.indices.contains(line) else { continue }
                        // The heading's new line takes the place of a link edit on it.
                        edits.removeAll { $0.line == line }
                        edits.append(HeadingRename.Edit(line: line, before: lines[line], after: HeadingRename.retitle(lines[line], to: new), links: 0))
                    }
                    edits.sort { $0.line < $1.line }
                }
                return edits.isEmpty ? nil : HeadingRename.NoteEdits(path: source, edits: edits)
            }
        }.value
    }

    /// Writes the [shown] edits. Each note is read again and refused when
    /// a line is not the one the preview showed; the rest go through
    /// `write`, so the next sync commits them.
    func applyHeadingEdits(_ shown: [HeadingRename.NoteEdits]) -> ReplaceSummary {
        var summary = ReplaceSummary()
        for note in shown {
            do {
                guard let text = text(of: note.path) else { throw HeadingRename.Failure.changed }
                let result = try HeadingRename.apply(note.edits, to: text)
                guard result != text else { continue }
                try write(result, to: note.path)
                summary.notes += 1
                summary.replacements += note.edits.reduce(0) { $0 + $1.links }
            } catch {
                summary.refused.append(note.path)
            }
        }
        return summary
    }

    /// The section of heading [index] of [path] at place [position] among
    /// its siblings, in the file. False when it did not move.
    @discardableResult
    func moveSection(_ path: String, heading index: Int, to position: Int) -> Bool {
        guard let text = text(of: path), let moved = Sections.move(text, heading: index, to: position) else { return false }
        do {
            try write(moved.text, to: path)
            return true
        } catch {
            notice = "\(Vault.title(of: path)) could not be written: \(error.localizedDescription)"
            return false
        }
    }
}

// MARK: The window

extension WindowModel {
    /// "Rename Heading…" on the heading the cursor is in, in the editor or
    /// the reader.
    func renameHeading(store: VaultStore) {
        guard let path, !showsPage else { return }
        let line = focused.cursorLine ?? 0
        Task {
            await store.flushEditors()
            let headings = Sections.headings(in: store.text(of: path) ?? "")
            guard let index = Sections.heading(at: line, in: headings) else {
                store.notice = "Put the cursor in a section to rename its heading."
                return
            }
            headingRename = HeadingTarget(path: path, headings: headings, index: index)
        }
    }

    /// ⌥⌘↑ and ⌥⌘↓: in the editor as a step to undo, else in the file, at
    /// the reading cursor.
    func moveSection(up: Bool, store: VaultStore) {
        guard let path, !showsPage else { return }
        if editing {
            NSApp.sendAction(up ? #selector(NoteTextView.moveSectionUp(_:)) : #selector(NoteTextView.moveSectionDown(_:)), to: nil, from: nil)
            return
        }
        let headings = Sections.headings(in: store.text(of: path) ?? "")
        guard let index = Sections.heading(at: focused.cursorLine ?? 0, in: headings) else { return NSSound.beep() }
        let siblings = Sections.siblings(of: index, in: headings)
        let at = siblings.firstIndex(of: index)! + (up ? -1 : 1)
        if !store.moveSection(path, heading: index, to: at) { NSSound.beep() }
    }

    /// A heading dropped on another of its level in the outline: its
    /// section takes that one's place. The editor's text is saved first,
    /// and it takes the moved text from the file. The headings are found
    /// again in the file, and nothing moves when they are not there.
    func dropSection(_ heading: Heading, on target: Heading, store: VaultStore) {
        guard let path, heading != target else { return }
        Task {
            await store.flushEditors()
            let headings = Sections.headings(in: store.text(of: path) ?? "")
            guard let index = headings.firstIndex(of: heading), let other = headings.firstIndex(of: target) else { return }
            guard let position = Sections.siblings(of: index, in: headings).firstIndex(of: other) else {
                store.notice = "A section moves among the headings of its level under the same heading."
                return
            }
            store.moveSection(path, heading: index, to: position)
        }
    }

    /// A click on an outline heading: the editor's cursor goes there, or the reader scrolls to it.
    func showHeading(_ heading: Heading, in path: String, store: VaultStore) {
        if editing, focused.path == path {
            focused.editorJump = EditorJump(line: heading.line)
        } else {
            open(path, heading: heading.text, store: store)
        }
    }
}

// MARK: The editor

extension EditorController {
    /// The cursor moved: when it left a heading line, the headings are
    /// compared with those of the last look, and a rename is offered.
    func followHeadingLine() {
        guard let view, session == nil else { return }
        let text = view.string as NSString
        let line = text.lineRange(for: NSRange(location: min(view.selectedRange().location, text.length), length: 0))
        if let headingLine, headingLine != line.location { checkHeadings() }
        headingLine = line.length > 0 && text.character(at: line.location) == UInt16(UInt8(ascii: "#")) ? line.location : nil
    }

    /// Any heading renamed since the last look is offered, with the note
    /// saved, so the links in it are read from the file.
    func checkHeadings() {
        guard let view, let path, session == nil else { return }
        let now = Sections.headings(in: view.string)
        let renames = HeadingRename.renamed(from: headingBaseline, to: now)
        let before = headingBaseline
        headingBaseline = now
        guard !renames.isEmpty else { return }
        saveNow()
        let change = HeadingRename.Change(path: path, headings: before, renames: renames)
        // Not while SwiftUI is taking the view down or drawing.
        DispatchQueue.main.async { [onHeadingsRenamed] in onHeadingsRenamed?(change) }
    }

    /// The outline asked for a heading.
    func jump(_ jump: EditorJump?) {
        guard let jump, jump != lastJump else { return }
        lastJump = jump
        go(toLine: jump.line)
        if let view { view.window?.makeFirstResponder(view) }
    }

    func moveSection(up: Bool) {
        guard let view else { return }
        if session != nil {
            store.notice = "Move Section works in the editor without Neovim mode."
            return
        }
        guard let edit = Sections.moveSection(in: view.string as NSString, selection: view.selectedRange(), up: up) else { return NSSound.beep() }
        view.replace(edit.range, with: edit.text, select: edit.selection)
        view.scrollRangeToVisible(edit.selection)
    }
}

extension NoteTextView {
    @objc func moveSectionUp(_ sender: Any?) { controller?.moveSection(up: true) }

    @objc func moveSectionDown(_ sender: Any?) { controller?.moveSection(up: false) }
}
