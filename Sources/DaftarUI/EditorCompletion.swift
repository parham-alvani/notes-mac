import AppKit
import DaftarCore

/// What the open completion list offers: what each row shows, and what
/// choosing it writes. `LinkCompletion` (core) makes the rows.
struct CompletionState {
    enum Kind { case link, tag }

    struct Choice {
        var insert: String
        /// A block with no id yet: it gets the one its link names when chosen.
        var block: NewBlock?
    }

    struct NewBlock {
        var path: String
        var line: Int
        var text: String
        var id: String
    }

    var kind: Kind?
    var choices: [String: Choice] = [:]
    /// The list is on screen: it follows the typing by itself, and a
    /// second `complete` would close it.
    var open = false

    func insert(for word: String) -> String { choices[word]?.insert ?? word }
}

extension VaultStore {
    /// The shortest name that still finds [path] from [source], as Obsidian writes a link.
    func linkName(of path: String, from source: String) -> String {
        let title = Vault.title(of: path)
        if index.resolve(title, from: source) == path { return title }
        return Vault.isNote(path) ? String(path.dropLast(3)) : path
    }

    /// Copy Block Link from the file: for the reader, and for Neovim mode,
    /// where Neovim owns the buffer. The block at [line] gets an id when it
    /// has none, written as any edit of the app's own.
    func copyBlockLink(_ path: String, line: Int) {
        guard let text = text(of: path) else { return }
        let name = linkName(of: path, from: path)
        guard let block = BlockRefs.block(atLine: line, in: text) else {
            notice = "Put the cursor in a paragraph or a list item first."
            return
        }
        if block.kind == .heading { return copyLink("[[\(name)#\(LinkCompletion.anchor(block.text))]]") }
        if let id = block.id { return copyLink("[[\(name)#^\(id)]]") }
        let id = BlockRefs.newId(taken: BlockRefs.ids(in: text))
        if addBlockId(id, to: path, line: block.start, text: block.text) { copyLink("[[\(name)#^\(id)]]") }
    }

    /// Where Copy Block Link puts the link; a test gives its own.
    static var linkPasteboard = NSPasteboard.general

    func copyLink(_ link: String) {
        Self.linkPasteboard.clearContents()
        Self.linkPasteboard.setString(link, forType: .string)
        notice = "Copied \(link)"
    }
}

extension WindowModel {
    /// ⌥⌘B: a link to the block at the cursor on the pasteboard, the block
    /// given an id first when it has none.
    func copyBlockLink(store: VaultStore) {
        guard let path, !showsPage, Vault.isNote(path) else { return }
        if editing, NSApp.sendAction(#selector(NoteTextView.copyBlockLink(_:)), to: nil, from: nil) { return }
        guard let line = focused.cursorLine else {
            store.notice = "Click the paragraph to link to first."
            return
        }
        Task {
            await store.flushEditors()
            store.copyBlockLink(path, line: line)
        }
    }
}

extension EditorController {
    /// The rows for the completion at [range] of [view]; each row's text to
    /// write goes into the view's `completion`.
    func completions(for view: NoteTextView, range: NSRange) -> [String] {
        let text = view.string as NSString
        let source = path ?? ""
        var items: [LinkCompletion.Item] = []
        var blocks: [String: CompletionState.NewBlock] = [:]
        switch view.completion.kind {
        case .tag:
            items = LinkCompletion.tags(store.index.tags, matching: text.substring(with: range))
        case .link:
            guard let query = LinkCompletion.query(in: text, at: NSMaxRange(range))?.query else { break }
            (items, blocks) = linkItems(query, body: view.string, newIds: true)
        case nil:
            break
        }
        view.completion.open = true
        view.completion.choices = Dictionary(items.map { ($0.label, CompletionState.Choice(insert: $0.insert, block: blocks[$0.label])) }) { first, _ in first }
        return items.map(\.label)
    }

    /// The rows for a link typed after `[[`, the plain editor's and
    /// Neovim's alike; [body] is this note as it is typed. A block with no
    /// id gets one when it is chosen, which only [newIds] offers.
    func linkItems(_ query: LinkCompletion.Query, body: String, newIds: Bool) -> ([LinkCompletion.Item], [String: CompletionState.NewBlock]) {
        let source = path ?? ""
        var items: [LinkCompletion.Item] = []
        var blocks: [String: CompletionState.NewBlock] = [:]
        switch query {
        case .note(let typed):
            let notes = store.quickOpen(typed, recent: [], limit: 30).map { path in
                LinkCompletion.Note(name: store.linkName(of: path, from: source), aliases: store.index.notes[path]?.parsed.aliases ?? [])
            }
            items = LinkCompletion.notes(notes, matching: typed)
        case .heading(let note, let typed):
            guard let target = target(of: note) else { break }
            // This note as it is typed, not as it was last saved.
            let headings = target == source ? NoteParser.parse(body).headings : store.index.notes[target]?.parsed.headings ?? []
            items = LinkCompletion.headings(headings, matching: typed, note: note)
        case .block(let note, let typed):
            guard let target = target(of: note), Vault.isNote(target) else { break }
            let text = target == source ? body : store.text(of: target) ?? ""
            var taken = BlockRefs.ids(in: text)
            for block in LinkCompletion.blocks(BlockRefs.blocks(in: text), matching: typed) where newIds || block.id != nil {
                let label = LinkCompletion.label(of: block)
                let id = block.id ?? BlockRefs.newId(taken: taken)
                taken.insert(id)
                items.append(LinkCompletion.Item(label: label, insert: "\(note)#^\(id)"))
                if block.id == nil { blocks[label] = CompletionState.NewBlock(path: target, line: block.start, text: block.text, id: id) }
            }
        }
        return (items, blocks)
    }

    /// Neovim's `[[` and `#` completion: what is typed from `[[`, or from
    /// the `#` of a tag, to the cursor, and the rows as label and text to
    /// write. A block offered has an id already: giving one writes a file.
    func neovimCompletions(link typed: String?, tag: String?, body: String) -> [LinkCompletion.Item] {
        if let tag { return LinkCompletion.tags(store.index.tags, matching: tag) }
        guard let typed, let query = LinkCompletion.query(in: typed as NSString, at: (typed as NSString).length)?.query else { return [] }
        return linkItems(query, body: body, newIds: false).0
    }

    /// The note a link's note part names: this one when it is empty.
    private func target(of note: String) -> String? {
        note.trimmingCharacters(in: .whitespaces).isEmpty ? path : store.index.resolve(note, from: path ?? "")
    }

    /// A block chosen in the list that had no id gets the one its link
    /// names: in this editor when it is this note, else in its file, read
    /// again first.
    func giveId(_ block: CompletionState.NewBlock, in view: NoteTextView) {
        if block.path == path, session == nil {
            let text = view.string
            guard let found = BlockRefs.blocks(in: text).first(where: { $0.start == block.line && $0.text == block.text && $0.id == nil }),
                let insertion = BlockRefs.insertion(block.id, for: found, in: text)
            else {
                store.notice = "The block changed, so it got no id."
                return
            }
            view.insertKeepingSelection(insertion.text, at: insertion.offset)
            return
        }
        Task {
            await store.flushEditors()
            store.addBlockId(block.id, to: block.path, line: block.line, text: block.text)
        }
    }

    /// ⌥⌘B in the editor: the block at the cursor gets an id, as one step
    /// to undo, and its link goes on the pasteboard.
    func copyBlockLink() {
        guard let view, let path else { return }
        let text = view.string
        let line = text.utf16.prefix(view.selectedRange().location).count { $0 == 0x0A }
        if session != nil {
            Task {
                await flush()
                store.copyBlockLink(path, line: line)
            }
            return
        }
        let name = store.linkName(of: path, from: path)
        guard let block = BlockRefs.block(atLine: line, in: text) else {
            store.notice = "Put the cursor in a paragraph or a list item first."
            return
        }
        if block.kind == .heading { return store.copyLink("[[\(name)#\(LinkCompletion.anchor(block.text))]]") }
        if let id = block.id { return store.copyLink("[[\(name)#^\(id)]]") }
        let id = BlockRefs.newId(taken: BlockRefs.ids(in: text))
        guard let insertion = BlockRefs.insertion(id, for: block, in: text) else { return }
        view.insertKeepingSelection(insertion.text, at: insertion.offset)
        store.copyLink("[[\(name)#^\(id)]]")
    }
}

extension NoteTextView {
    @objc func copyBlockLink(_ sender: Any?) { controller?.copyBlockLink() }

    /// Where completion works and what it offers: a link after `[[`, or a
    /// tag after a `#` at the start of a word. Nil for the system's own.
    func completionRange() -> NSRange? {
        let text = string as NSString
        let at = selectedRange().location
        if let link = LinkCompletion.query(in: text, at: at) {
            completion.kind = .link
            return link.range
        }
        if let tag = LinkCompletion.tagQuery(in: text, at: at) {
            completion.kind = .tag
            return tag
        }
        completion.kind = nil
        return nil
    }

    /// After a key: `#` or `^` in a link opens the note's headings or
    /// blocks, and a `#` at the start of a word the vault's tags -- at the
    /// start of a line once a letter follows it, since `# ` is a heading.
    func completeAfterTyping(_ typed: String) {
        guard !completion.open else { return }
        let text = string as NSString
        let at = selectedRange().location
        if let link = LinkCompletion.query(in: text, at: at) {
            guard typed == "#" || typed == "^" else { return }
            if case .note = link.query { return }
            DispatchQueue.main.async { [weak self] in self?.complete(nil) }
            return
        }
        // The cheap test first: the rest reads the lines above for fences.
        let line = text.lineRange(for: NSRange(location: at, length: 0))
        let lead = text.substring(with: NSRange(location: line.location, length: at - line.location)).drop { $0 == " " || $0 == "\t" }
        guard typed == "#" || (typed.count == 1 && lead == "#" + typed) else { return }
        guard let tag = LinkCompletion.tagQuery(in: text, at: at), typed != "#" || tag.length == 0 else { return }
        DispatchQueue.main.async { [weak self] in self?.complete(nil) }
    }

    /// After a row is chosen: the cursor steps over the `]]` that `[[` put
    /// there, and a block chosen with no id gets one.
    func finishCompletion(_ word: String, movement: Int) {
        let choice = completion.choices[word]
        let kind = completion.kind
        completion = CompletionState()
        guard kind == .link else { return }
        let text = string as NSString
        let at = selectedRange().location
        if at + 2 <= text.length, text.substring(with: NSRange(location: at, length: 2)) == "]]" {
            setSelectedRange(NSRange(location: at + 2, length: 0))
        }
        if movement != NSTextMovement.cancel.rawValue, let block = choice?.block { controller?.giveId(block, in: self) }
    }

    /// Puts [text] at [offset] as a step to undo; the selection stays on the
    /// same characters.
    func insertKeepingSelection(_ text: String, at offset: Int) {
        let range = NSRange(location: offset, length: 0)
        guard shouldChangeText(in: range, replacementString: text) else { return }
        var selection = selectedRange()
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        if selection.location >= offset { selection.location += (text as NSString).length }
        setSelectedRange(selection)
    }
}
