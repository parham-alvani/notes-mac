import AppKit
import Carbon.HIToolbox
import DaftarCore

/// The editor in Neovim mode: Neovim owns the buffer and the file, and the
/// text view shows what Neovim reports. Keys go to Neovim; the view never
/// edits its own text. This is the model vscode-neovim uses, and it keeps
/// what the native view does well -- direction per paragraph, Persian, the
/// styling, images -- while the editing is the person's real Neovim.
@MainActor
final class NeovimSession {
    enum State: Equatable { case starting, running, failed(String), ended }

    private let client: NeovimClient
    private var path: String
    private let root: URL
    private weak var view: NoteTextView?
    private var mirror = BufferMirror(lines: [""])
    private var listen: Task<Void, Never>?
    private var saveSoon: Task<Void, Never>?
    /// What was typed or pasted before Neovim ran, sent once it does: a note
    /// opened and typed into at once loses nothing.
    private var waiting: [(method: String, params: [MessagePackValue])] = []
    private(set) var state = State.starting
    private(set) var mode = "n"
    /// The command line or the last message, for the bar under the text.
    private(set) var status = ""
    /// The command line while one is open: `:`, `/` or `?` and a prompt,
    /// what is typed, and where its cursor is, in UTF-8 bytes.
    struct CommandLine: Equatable {
        var prefix: String
        var text: String
        var position: Int
    }

    private(set) var commandLine: CommandLine?
    var onChange: (() -> Void)?
    var onRemoteEdit: (() -> Void)?
    /// A file opened inside Neovim, for Daftar to open: its full path.
    var onOpen: ((String) -> Void)?

    /// Nil when there is no `nvim` to run: [locate] finds it, from the setting.
    init?(path: String, root: URL, view: NoteTextView, settings: AppSettings, locate: (String) -> URL? = { NeovimClient.locate($0) }) {
        guard let executable = locate(settings.nvimPath) else { return nil }
        let arguments = Self.arguments(config: settings.nvimConfig)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        client = NeovimClient(executable: executable, arguments: arguments, directory: root, environment: environment)
        self.path = path
        self.root = root
        self.view = view
        textSize = CGFloat(settings.textSize)
    }

    /// The size of the note's body text, which the grid is measured in.
    private let textSize: CGFloat

    /// `nvim_config`: "user" is your init.lua, "clean" is none, and any
    /// other value is a Lua or Vim file to start with instead, as `-u`.
    static func arguments(config: String) -> [String] {
        // `-n`: no swap file. Daftar saves a second after each change, and
        // a swap file left by a Neovim that died made the next one ask
        // what to do with it, before any key could reach it.
        var arguments = ["--cmd", "let g:daftar = 1", "-n"]
        switch config.trimmingCharacters(in: .whitespaces) {
        case "clean": arguments.append("--clean")
        case "user", "": break
        case let file: arguments += ["-u", (file as NSString).expandingTildeInPath]
        }
        return arguments
    }

    /// Who owns the text while this session is the editor's.
    var owner: TextOwner {
        switch state {
        case .starting: .neovimStarting
        case .running: .neovimRunning
        case .failed, .ended: .neovimDead
        }
    }

    /// Neovim was killed, or was ended because it did not answer, and did
    /// not quit: what the view shows was not all written.
    var crashed: Bool { client.crashed || unanswered }

    /// How long Neovim has to start, to write when asked and waited for,
    /// and to write as it is stopped. A Neovim that waits at a question,
    /// or in a plugin that never returns, is ended then: nothing in the
    /// app waits for it for ever.
    static var startLimit = Duration.seconds(15)
    static var saveLimit = Duration.seconds(5)
    static var stopLimit = Duration.seconds(3)

    /// Neovim was ended at one of the limits.
    private(set) var unanswered = false
    /// The buffer a stopped Neovim did not write in time, for the store to
    /// write: its path and its text. The view is another note's by then.
    var onUnwritten: ((String, String) -> Void)?

    /// [work], which waits for Neovim; past [limit] Neovim is ended, and
    /// every request that waits for it fails.
    private func within<T>(_ limit: Duration, _ work: () async throws -> T) async rethrows -> T {
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled, let self else { return }
            self.unanswered = true
            self.client.stop()
        }
        defer { watchdog.cancel() }
        return try await work()
    }

    /// Neovim's process, for a test that kills it.
    var processIdentifier: Int32 { client.processIdentifier }

    var isNormal: Bool { !mode.hasPrefix("i") && !mode.hasPrefix("R") && !mode.hasPrefix("v") && !mode.hasPrefix("V") && mode != "\u{16}" }

    var modeName: String {
        switch mode.first {
        case "i": "INSERT"
        case "R": "REPLACE"
        case "v": "VISUAL"
        case "V": "V-LINE"
        case "\u{16}": "V-BLOCK"
        case "c": "COMMAND"
        case "t": "TERMINAL"
        default: "NORMAL"
        }
    }

    func start() async {
        do {
          try await within(Self.startLimit) {
            client.onRequest = { [weak self] method, params in
                await self?.answer(method, params) ?? .nil
            }
            try client.start()
            listen = Self.listen(to: client, for: self)
            let (rows, cols) = size()
            // The cursor goes to the line the reader was on before Neovim
            // reports where it is: a first report from line 1 drew the
            // cursor at the top of the note and slid it down the screen.
            let place = placement()
            // Neovim reads the person's config once a UI attached, and runs
            // what came with the attach before it: the rest waits for the answer.
            try await client.request("nvim_ui_attach", [.int(Int64(cols)), .int(Int64(rows)), [
                "ext_linegrid": true, "ext_cmdline": true, "ext_messages": true, "ext_popupmenu": true, "rgb": true,
            ]])
            // The rest sent at once and answered in order: one round trip,
            // not a dozen, each of which waited for the main thread while
            // it styled the note (85 ms to start in a long note).
            awaitingSnapshot = true
            buffer = 0
            var calls = [
                client.call("nvim_exec_lua", [.string(Self.setup), [.string(path)]]),
                client.call("nvim_exec_lua", [.string(Self.lists), []]),
                client.call("nvim_exec_lua", [.string(Self.links), []]),
            ]
            // Normal mode's keys on the Persian layout too, unless the person's config sets a langmap.
            let langmap = Self.cachedLangmap()
            let mapped = langmap.isEmpty ? nil : client.call("nvim_exec_lua", ["if vim.o.langmap == '' then vim.o.langmap = ... end", [.string(langmap)]])
            calls.append(client.call("nvim_exec_lua", [.string(Self.place), [.int(Int64(place.row)), .int(Int64(place.byteColumn))]]))
            // The buffer's lines come as the first event after the attach,
            // with the `eol` the setup sent before them.
            calls.append(client.call("nvim_buf_attach", [0, true, [:]]))
            // The first cursor report, after the lines it is counted in.
            calls.append(client.call("nvim_exec_lua", ["_G.daftar_state.note()", []]))
            // Answered in order: once the last is, every one is.
            _ = try? await calls[calls.count - 1].value
            for call in calls { _ = try await call.value }
            _ = try? await mapped?.value
            try await snapshot()
            running()
          }
        } catch {
            let reason = unanswered ? "It did not answer in \(Self.startLimit.components.seconds) seconds." : String(describing: error)
            state = .failed(reason)
            status = "Neovim did not start: \(reason)"
        }
        onChange?()
    }

    /// Neovim runs: what was typed while it started goes to it, and the
    /// cursor shows where its first report put it.
    private func running() {
        state = .running
        if let offset = startOffset {
            startOffset = nil
            go(to: offset)
        }
        for (method, params) in waiting { client.notify(method, params) }
        waiting = []
        view?.moveNeovimCursor()
    }

    /// Where the cursor starts, as Neovim counts: the line the editor
    /// opened at ([startOffset], counted in the view's text, which is the
    /// file's), or the first.
    private func placement() -> (row: Int, byteColumn: Int) {
        defer { startOffset = nil }
        guard let offset = startOffset, let view else { return (1, 0) }
        return BufferMirror.position(of: offset, in: view.string as NSString)
    }

    /// Notifications are read off the main thread, and a read's worth --
    /// a buffer's edit, the cursor, the screen's messages -- is handled in
    /// one turn of it. The grid's own events, most of what Neovim sends at
    /// each key, never reach it: the text view is the screen.
    private static func listen(to client: NeovimClient, for session: NeovimSession) -> Task<Void, Never> {
        Task.detached { [weak session] in
            for await batch in client.batches {
                let notes = batch.compactMap(Self.wanted)
                guard !notes.isEmpty else { continue }
                await session?.handle(notes)
            }
            await session?.ended()
        }
    }

    /// The redraw events the session reads; the rest are the grid's.
    nonisolated private static let redrawEvents: Set<String> = [
        "cmdline_show", "cmdline_pos", "cmdline_hide", "msg_show", "msg_clear", "popupmenu_show", "popupmenu_select", "popupmenu_hide",
    ]

    /// [note] with only the redraw events the session reads, or nil when it has none.
    nonisolated private static func wanted(_ note: NeovimClient.Notification) -> NeovimClient.Notification? {
        guard note.method == "redraw" else { return note }
        let batches = note.params.filter { $0.arrayValue?.first?.stringValue.map(redrawEvents.contains) ?? false }
        return batches.isEmpty ? nil : NeovimClient.Notification(method: note.method, params: batches)
    }

    private func handle(_ notes: [NeovimClient.Notification]) {
        for note in notes { handle(note) }
    }

    /// The keyboard's langmap is the same until a layout is added or
    /// removed: worked out once (6 ms of the main thread at each start).
    private static var langmapCache: String?
    private static var layoutsObserver: NSObjectProtocol?

    static func cachedLangmap() -> String {
        if let langmapCache { return langmapCache }
        let langmap = keyboardLangmap()
        langmapCache = langmap
        if layoutsObserver == nil {
            layoutsObserver = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String), object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { NeovimSession.langmapCache = nil } }
        }
        return langmap
    }

    /// The keyboard's layouts beside the Latin one as Neovim's `langmap`
    /// (`VimKeys.langmap`): each key's letter on another enabled layout
    /// paired with its letter on the Latin one, Shift and all.
    static func keyboardLangmap() -> String {
        guard let latinSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            let latin = layoutData(latinSource),
            let list = TISCreateInputSourceList([kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary, false)?
                .takeRetainedValue()
        else { return "" }
        var pairs: [(Character, Character)] = []
        for source in list as NSArray as! [TISInputSource] {
            guard let other = layoutData(source), other != latin else { continue }
            // The keys of the main block; the keypad and the function keys are the same on every layout.
            for keycode in UInt16(0)..<51 {
                for shift in [false, true] {
                    guard let to = character(latin, keycode, shift: shift), let from = character(other, keycode, shift: shift) else { continue }
                    pairs.append((from, to))
                }
            }
        }
        return VimKeys.langmap(pairs)
    }

    /// The letter the key [keycode] types on the Latin layout, for a chord
    /// pressed with another layout on (`VimKeys.chord`).
    static func latinCharacter(keycode: UInt16, shift: Bool) -> Character? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(), let layout = layoutData(source) else { return nil }
        return character(layout, keycode, shift: shift)
    }

    private static func layoutData(_ source: TISInputSource) -> Data? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }

    /// The one character a key types on a layout, with no dead keys.
    private static func character(_ layout: Data, _ keycode: UInt16, shift: Bool) -> Character? {
        layout.withUnsafeBytes { bytes -> Character? in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var dead: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let modifiers = shift ? UInt32((shiftKey >> 8) & 0xFF) : 0
            let status = UCKeyTranslate(
                base, keycode, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &length, &chars)
            guard status == noErr, length == 1, let scalar = Unicode.Scalar(chars[0]) else { return nil }
            return Character(scalar)
        }
    }

    /// The buffer's lines are on their way: the first event after the
    /// attach holds all of them.
    private var awaitingSnapshot = false
    /// The number of the note's buffer in Neovim; 0, the current one, until it is known.
    private var buffer = 0
    /// The file ends with a newline, as Neovim's `eol` says.
    private var eol = true
    private var resyncing = false

    /// Listens to the buffer's lines, and takes all of them: the view shows
    /// the buffer as it is now. Neovim sends the lines itself (`send_buffer`),
    /// as the first event, so they are in order with every edit after them:
    /// lines asked for apart could come back on either side of an edit, and
    /// the mirror then lacked it for good. A buffer still attached sends
    /// none at a second attach, so it is detached first.
    private func takeBuffer() async throws {
        let id = MessagePackValue.int(Int64(buffer))
        awaitingSnapshot = true
        // Its event comes while the lines are awaited, and is not a reload.
        let detach = client.call("nvim_buf_detach", [id])
        let eol = client.call("nvim_exec_lua", ["_G.daftar_state.eol(...)", [id]])
        // An attach that fails (the buffer is not loaded) waits for no lines.
        let attach = client.call("nvim_buf_attach", [id, true, [:]])
        _ = try? await detach.value
        do {
            _ = try await eol.value
            _ = try await attach.value
        } catch {
            awaitingSnapshot = false
            wakeSnapshot()
            throw error
        }
        try await snapshot()
        // The cursor reports that came with the lines were dropped: one more.
        client.notify("nvim_exec_lua", ["_G.daftar_state.note()", []])
    }

    private var snapshotWaiters: [CheckedContinuation<Void, Never>] = []

    /// Until the buffer's lines came, in their turn among the events: a
    /// Neovim that sends none in a second has them asked for.
    private func snapshot() async throws {
        if awaitingSnapshot {
            let limit = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled { self?.wakeSnapshot() }
            }
            await withCheckedContinuation { waiter in
                if awaitingSnapshot { snapshotWaiters.append(waiter) } else { waiter.resume() }
            }
            limit.cancel()
        }
        guard awaitingSnapshot else { return }
        let id = MessagePackValue.int(Int64(max(buffer, 0)))
        let lines = try await client.request("nvim_buf_get_lines", [id, 0, -1, false]).arrayValue?.compactMap(\.stringValue) ?? []
        if awaitingSnapshot { take(lines) }
    }

    private func wakeSnapshot() {
        let waiters = snapshotWaiters
        snapshotWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// All the buffer's lines: the mirror is them, and the view too, by
    /// the one range that differs.
    private func take(_ lines: [String]) {
        awaitingSnapshot = false
        defer { wakeSnapshot() }
        mirror = BufferMirror(lines: lines, endsWithNewline: eol)
        show(mirror)
    }

    /// The view shows [mirror]'s text, by the one range that differs.
    private func show(_ mirror: BufferMirror) {
        guard let view, let storage = view.textStorage else { return }
        let text = mirror.text as NSString
        // Most often the view shows the file Neovim read: one compare.
        guard !text.isEqual(to: storage.string) else { return }
        let edit = EditorController.smallestEdit(from: storage.string as NSString, to: text)
        if edit.range.length > 0 || !edit.text.isEmpty { view.applyRemote(edit.range, edit.text) }
    }

    /// The view and the buffer came apart -- an edit that did not fit, a
    /// text of another length: the buffer is taken again, whole.
    private func resync() {
        guard !resyncing, case .running = state else { return }
        resyncing = true
        Task {
            try? await takeBuffer()
            resyncing = false
            onRemoteEdit?()
        }
    }

    /// The autocommands that tell the view where the cursor is and what mode
    /// Neovim is in, and that it wrote the file.
    /// Lists and tasks go on, as in the plain editor and Obsidian: Enter
    /// and `o`/`O` start the next item, a number one more, a task open;
    /// Enter on an empty item ends the list. A person's own mapping of a
    /// key wins, and the completion menu keeps its Enter.
    static let lists = """
        local function item(line)
          local indent, rest = line:match('^(%s*)(.*)$')
          local marker = rest:match('^[-*+] %[.%] ')
          if marker then return indent, marker, marker:sub(1, 2) .. '[ ] ' end
          marker = rest:match('^[-*+] ')
          if marker then return indent, marker, marker end
          local n, sep = rest:match('^(%d+)([.)] )')
          if n then return indent, n .. sep, (tonumber(n) + 1) .. sep end
          marker = rest:match('^> ')
          if marker then return indent, marker, marker end
        end
        -- The key goes first, before what is typed after it and waits.
        local function plain(keys)
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'ni', false)
        end
        local function enter()
          local row, col = unpack(vim.api.nvim_win_get_cursor(0))
          local line = vim.api.nvim_get_current_line()
          local indent, marker, next = item(line)
          if vim.fn.pumvisible() == 1 or not indent or col < #indent + #marker then return plain('<CR>') end
          if line == indent .. marker then
            vim.api.nvim_set_current_line('')
            vim.api.nvim_win_set_cursor(0, { row, 0 })
            return
          end
          vim.api.nvim_buf_set_lines(0, row - 1, row, true, { line:sub(1, col), indent .. next .. line:sub(col + 1) })
          vim.api.nvim_win_set_cursor(0, { row + 1, #indent + #next })
        end
        local function open(below)
          local row = vim.api.nvim_win_get_cursor(0)[1]
          local indent, marker, next = item(vim.api.nvim_get_current_line())
          if not indent or vim.v.count > 1 then return plain(below and 'o' or 'O') end
          local new = indent .. (below and next or (marker:match('%[') and marker:sub(1, 2) .. '[ ] ' or marker))
          local at = below and row or row - 1
          vim.api.nvim_buf_set_lines(0, at, at, true, { new })
          vim.api.nvim_win_set_cursor(0, { at + 1, #new })
          vim.cmd('startinsert!')
        end
        local function map(buffer)
          local function free(mode, key) return vim.fn.maparg(key, mode) == '' end
          if free('i', '<CR>') then vim.keymap.set('i', '<CR>', enter, { buffer = buffer, desc = 'Daftar: the next list item' }) end
          if free('n', 'o') then vim.keymap.set('n', 'o', function() open(true) end, { buffer = buffer, desc = 'Daftar: a list item below' }) end
          if free('n', 'O') then vim.keymap.set('n', 'O', function() open(false) end, { buffer = buffer, desc = 'Daftar: a list item above' }) end
        end
        vim.api.nvim_create_autocmd('FileType', {
          group = vim.api.nvim_create_augroup('daftar_lists', { clear = true }),
          pattern = 'markdown',
          callback = function(event) map(event.buf) end,
        })
        if vim.bo.filetype == 'markdown' then map(0) end
        """

    /// `[[` and `#` offer the vault's notes, headings and tags as the plain
    /// editor does: Neovim asks Daftar for the rows (`daftar_complete`), as
    /// `completefunc`, from the moment `[[` or a tag's `#` is typed. A
    /// person's own completefunc wins.
    static let links = """
        local chan = _G.daftar_state.chan
        local kind
        function _G.daftar_complete(findstart, base)
          local line = vim.api.nvim_get_current_line()
          local col = vim.api.nvim_win_get_cursor(0)[2]
          local before = line:sub(1, col)
          if findstart == 1 then
            local open = before:match('.*()%[%[')
            if open and not before:sub(open + 2):find('%]%]') and not before:sub(open + 2):find('|', 1, true) then
              kind = 'link'
              return open + 1
            end
            local hash = before:match('.*()#[^%s#]*$')
            if hash and (hash == 1 or before:sub(hash - 1, hash - 1):match('%s')) then
              kind = 'tag'
              return hash
            end
            return -3
          end
          local rows = vim.rpcrequest(chan, 'daftar_complete', kind, kind == 'link' and ('[[' .. base) or base)
          local close = kind == 'link' and line:sub(col + 1, col + 2) ~= ']]'
          local words = {}
          for _, row in ipairs(rows or {}) do
            table.insert(words, { word = row[2] .. (close and ']]' or ''), abbr = row[1], menu = kind == 'link' and 'link' or 'tag', dup = 1 })
          end
          return { words = words, refresh = 'always' }
        end
        local function trigger()
          if vim.fn.pumvisible() == 1 or vim.bo.completefunc ~= 'v:lua.daftar_complete' then return end
          local before = vim.api.nvim_get_current_line():sub(1, vim.api.nvim_win_get_cursor(0)[2])
          if before:match('%[%[[^%]|]*$') or before:match('^#[^%s#]+$') or before:match('%s#[^%s#]+$') then
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-x><C-u>', true, false, true), 'ni', false)
          end
        end
        local function use(buffer)
          if vim.bo[buffer].completefunc ~= '' and vim.bo[buffer].completefunc ~= 'v:lua.daftar_complete' then return end
          vim.bo[buffer].completefunc = 'v:lua.daftar_complete'
          vim.api.nvim_create_autocmd('TextChangedI', { group = vim.api.nvim_create_augroup('daftar_links_' .. buffer, { clear = true }), buffer = buffer, callback = trigger })
        end
        vim.api.nvim_create_autocmd('FileType', {
          group = vim.api.nvim_create_augroup('daftar_links', { clear = true }),
          pattern = 'markdown',
          callback = function(event) use(event.buf) end,
        })
        if vim.bo.filetype == 'markdown' then use(vim.api.nvim_get_current_buf()) end
        """

    /// Neovim's questions to Daftar: the rows of `[[` and `#` completion.
    private func answer(_ method: String, _ params: [MessagePackValue]) -> MessagePackValue {
        guard method == "daftar_complete", params.count > 1, let kind = params[0].stringValue, let typed = params[1].stringValue,
            let controller = view?.controller
        else { return .array([]) }
        let items = controller.neovimCompletions(link: kind == "link" ? typed : nil, tag: kind == "tag" ? typed : nil, body: view?.string ?? "")
        return .array(items.map { .array([.string($0.label), .string($0.insert)]) })
    }

    /// Opens the note and sets the autocommands up. The note's buffer and
    /// Daftar's channel are in `_G.daftar_state`, which `open` and `note`
    /// change when the same Neovim takes another note.
    private static let setup = """
        local path = ...
        local chan
        for _, ui in ipairs(vim.api.nvim_list_uis()) do chan = ui.chan or chan end
        vim.cmd.edit(vim.fn.fnameescape(path))
        local state = { chan = chan, buf = vim.api.nvim_get_current_buf(), switching = false }
        _G.daftar_state = state
        local group = vim.api.nvim_create_augroup('daftar', { clear = true })
        local function send()
          -- Another buffer's cursor is not the note's.
          if vim.api.nvim_get_current_buf() ~= state.buf then return end
          local mode = vim.api.nvim_get_mode().mode
          local cursor = vim.api.nvim_win_get_cursor(0)
          local v = vim.fn.getpos('v')
          -- A block is columns of the screen, not bytes: a Persian letter is
          -- two bytes and an emoji four. Neovim says what the block holds on
          -- each row: its row, the byte its first letter starts at and the last byte of its last.
          local block = vim.NIL
          if mode:sub(1, 1) == '\\22' and vim.fn.getregionpos then
            local ok, rows = pcall(vim.fn.getregionpos, v, vim.fn.getpos('.'), { type = '\\22', eol = true })
            if ok then
              block = {}
              for _, row in ipairs(rows) do table.insert(block, { row[1][2], row[1][3] - 1, row[2][3] - 1 }) end
            end
          end
          vim.rpcnotify(chan, 'daftar_cursor', mode, cursor[1], cursor[2], v[2], v[3] - 1, block)
        end
        -- The note is the current buffer: its cursor is reported from now on.
        function state.note()
          state.buf = vim.api.nvim_get_current_buf()
          send()
        end
        -- Sent before the buffer's lines, in order with them.
        function state.eol(buf)
          if buf == 0 then buf = vim.api.nvim_get_current_buf() end
          vim.rpcnotify(chan, 'daftar_eol', buf, vim.bo[buf].eol)
        end
        vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'ModeChanged', 'BufEnter' }, { group = group, callback = send })
        -- The view shows this one note. Another file opened here -- :e, gf,
        -- a picker -- would take the keys where nothing shows them: Neovim
        -- goes back to the note, and Daftar opens the file as its own note.
        -- A help page, a picker's prompt and the like are not files.
        vim.api.nvim_create_autocmd('BufEnter', { group = group, callback = function(event)
          if state.switching or event.buf == state.buf or vim.bo[event.buf].buftype ~= '' then return end
          local name = vim.api.nvim_buf_get_name(event.buf)
          if name == '' then return end
          vim.schedule(function()
            local buf = state.buf
            if not vim.api.nvim_buf_is_valid(buf) then return end
            if vim.api.nvim_get_current_buf() == event.buf then pcall(vim.api.nvim_set_current_buf, buf) end
            if vim.api.nvim_buf_is_valid(event.buf) and not vim.bo[event.buf].modified then
              pcall(vim.api.nvim_buf_delete, event.buf, {})
            end
            vim.rpcnotify(chan, 'daftar_open', vim.fn.fnamemodify(name, ':p'))
          end)
        end })
        -- zz, <C-e>, <C-d> and the rest move the window: the view follows.
        -- Neovim's lines are not the view's (a heading or code is another
        -- height), so a window that moved for any other key -- j, u, G, a
        -- search -- is not followed: the view keeps the cursor in sight by
        -- itself, and does not jump to where Neovim's top is.
        local scrolls = { ['\\5'] = true, ['\\25'] = true, ['\\4'] = true, ['\\21'] = true, ['\\6'] = true, ['\\2'] = true }
        -- zz, zt and zb say where the cursor's line goes, and the view puts
        -- it there by its own lines; the others move by Neovim's window.
        local zs = { z = 'middle', ['.'] = 'middle', t = 'top', ['\\r'] = 'top', b = 'bottom', ['-'] = 'bottom' }
        local function follow(place)
          vim.schedule(function() vim.rpcnotify(chan, 'daftar_scroll', vim.fn.line('w0'), place or '') end)
        end
        local last = ''
        vim.on_key(function(_, typed)
          if typed == nil or typed == '' then return end
          local mode = vim.api.nvim_get_mode().mode:sub(1, 1)
          if mode == 'i' or mode == 'R' or mode == 'c' then
            last = ''
          elseif last == 'z' and zs[typed] then
            last = ''
            follow(zs[typed])
          else
            last = typed
            if scrolls[typed] then follow() end
          end
        end, vim.api.nvim_create_namespace('daftar'))
        vim.o.autoread = true
        state.eol(state.buf)
        """

    /// The cursor where the editor opened, in the middle of the window, as `zz` puts it.
    private static let place = """
        local row, col = ...
        pcall(vim.api.nvim_win_set_cursor, 0, { row, col })
        vim.cmd('normal! zz')
        """

    // MARK: From Neovim

    private func handle(_ note: NeovimClient.Notification) {
        switch note.method {
        case "nvim_buf_lines_event":
            guard note.params.count >= 5, let first = note.params[2].intValue, let last = note.params[3].intValue else { return }
            let lines = note.params[4].arrayValue?.compactMap(\.stringValue) ?? []
            if awaitingSnapshot {
                // The whole buffer, after an attach; nothing else counts before
                // it. An edit made while it was on its way is in it, and is saved.
                scheduleSave()
                guard first == 0, last == -1 else { return }
                // The one buffer attached: the note's, when the same Neovim took another note.
                if buffer <= 0, let id = note.params[0].intValue { buffer = id }
                guard note.params[0].intValue == buffer else { return }
                take(lines)
                onRemoteEdit?()
                return
            }
            // Only the note's buffer is the view's text.
            guard buffer == 0 || note.params[0].intValue == buffer else { return }
            let edit = mirror.apply(first: first, last: last, replacement: lines)
            if let view {
                let fits = view.applyRemote(edit.range, edit.text)
                if !fits || (view.textStorage?.length ?? 0) != mirror.utf16Count { resync() }
            }
            onRemoteEdit?()
            scheduleSave()
        case "nvim_buf_detach_event":
            // Neovim read the file again -- a sync, a pull, another app --
            // and stopped sending the buffer's lines: the view takes the
            // buffer anew, or it stays as it was while Neovim edits.
            // One of the session's own, before the lines it waits for.
            guard !awaitingSnapshot, case .running = state, buffer == 0 || note.params.first?.intValue == buffer else { return }
            Task {
                try? await takeBuffer()
                onRemoteEdit?()
            }
        case "daftar_open":
            // Another file was opened inside this Neovim (`:e`, `gf`, a
            // picker). The view shows one note, so Neovim went back to it,
            // and Daftar opens the other as it opens any note.
            guard let file = note.params.first?.stringValue else { return }
            resync()
            onOpen?(file)
        case "daftar_eol":
            // The buffer's `eol`, just before its lines.
            if let flag = note.params.count > 1 ? note.params[1].boolValue : nil { eol = flag }
        case "daftar_cursor":
            guard note.params.count >= 5, let row = note.params[1].intValue, let col = note.params[2].intValue else { return }
            // Counted in lines the mirror does not have yet.
            guard !awaitingSnapshot else { return }
            let wasInserting = !isNormal
            mode = note.params[0].stringValue ?? "n"
            // Leaving insert mode is when a pending save can happen.
            if wasInserting, isNormal, saveSoon != nil { scheduleSave() }
            let cursor = mirror.offset(row: row, byteColumn: col)
            if mode == "\u{16}", note.params.count > 5, let rows = note.params[5].arrayValue {
                // Visual block, as Neovim says it: on each row, from its
                // first letter to its last, both whole.
                let text = (view?.string ?? "") as NSString
                let ranges = rows.compactMap { item -> NSRange? in
                    guard let parts = item.arrayValue, parts.count == 3, let line = parts[0].intValue, let from = parts[1].intValue, let to = parts[2].intValue
                    else { return nil }
                    // A row too short for the block: nothing of it, at its end.
                    guard from >= 0, to >= from else { return NSRange(location: mirror.offset(row: line, byteColumn: .max), length: 0) }
                    // [to] is the last byte of the last letter: the end is the byte
                    // after it, and never inside a letter of the view's.
                    let start = mirror.offset(row: line, byteColumn: from)
                    var end = mirror.offset(row: line, byteColumn: to + 1)
                    if end > start, end <= text.length { end = max(end, NSMaxRange(text.rangeOfComposedCharacterSequence(at: end - 1))) }
                    return NSRange(location: start, length: max(0, end - start))
                }
                view?.showSelections(ranges, cursor: cursor)
            } else if let vRow = note.params[3].intValue, let vCol = note.params[4].intValue, mode == "\u{16}" {
                // A Neovim too old to say the block (before `getregionpos`): the bytes of the two corners.
                // Visual block: the same columns on every row, one range each.
                let columns = (min(vCol, col), max(vCol, col))
                let ranges = (min(vRow, row)...max(vRow, row)).map { line -> NSRange in
                    let start = mirror.offset(row: line, byteColumn: columns.0)
                    let end = mirror.offset(row: line, byteColumn: columns.1)
                    let text = (view?.string ?? "") as NSString
                    let lineEnd = NSMaxRange(text.lineRange(for: NSRange(location: min(start, text.length), length: 0)))
                    let last = end < text.length && end < lineEnd && text.character(at: end) != 10 ? text.rangeOfComposedCharacterSequence(at: end).length : 0
                    return NSRange(location: start, length: max(0, end - start + last))
                }
                view?.showSelections(ranges, cursor: cursor)
            } else if let vRow = note.params[3].intValue, let vCol = note.params[4].intValue, !isNormal, mode.first == "v" || mode.first == "V" {
                let anchor = mirror.offset(row: vRow, byteColumn: vCol)
                view?.showSelection(visual(anchor: anchor, cursor: cursor, lines: mode.first == "V", rows: (vRow, row)))
            } else {
                view?.showSelection(NSRange(location: cursor, length: 0))
            }
            onChange?()
        case "daftar_scroll":
            guard let top = note.params.first?.intValue else { return }
            if note.params.count > 1, let place = NoteTextView.Place(rawValue: note.params[1].stringValue ?? "") {
                view?.place(place)
            } else {
                view?.follow(top: mirror.offset(row: top, byteColumn: 0))
            }
        case "redraw":
            redraw(note.params)
        default:
            break
        }
    }

    /// A visual selection as the view draws it: inclusive of the character
    /// under the cursor, or whole lines in line-wise mode.
    private func visual(anchor: Int, cursor: Int, lines: Bool, rows: (Int, Int)) -> NSRange {
        let text = (view?.string ?? "") as NSString
        if lines {
            let start = text.lineRange(for: NSRange(location: min(anchor, cursor), length: 0))
            let end = text.lineRange(for: NSRange(location: max(anchor, cursor), length: 0))
            return NSRange(location: start.location, length: NSMaxRange(end) - start.location)
        }
        let low = min(anchor, cursor), high = max(anchor, cursor)
        let last = high < text.length ? text.rangeOfComposedCharacterSequence(at: high).length : 0
        return NSRange(location: low, length: high - low + last)
    }

    /// The command line and messages, from the UI events; the grid itself is
    /// not drawn, the text view is the screen.
    private func redraw(_ batches: [MessagePackValue]) {
        var changed = false
        for batch in batches {
            guard let items = batch.arrayValue, let name = items.first?.stringValue else { continue }
            for args in items.dropFirst().compactMap(\.arrayValue) {
                switch name {
                case "cmdline_show":
                    // [content, pos, firstc, prompt, indent, level]
                    let content = Self.text(args.first)
                    let position = args.count > 1 ? args[1].intValue ?? content.utf8.count : content.utf8.count
                    let firstc = args.count > 2 ? args[2].stringValue ?? "" : ""
                    let prompt = args.count > 3 ? args[3].stringValue ?? "" : ""
                    commandLine = CommandLine(prefix: firstc + prompt, text: content, position: position)
                    status = ""
                    changed = true
                case "cmdline_pos":
                    if let position = args.first?.intValue { commandLine?.position = position }
                    changed = true
                case "cmdline_hide":
                    commandLine = nil
                    view?.hideNeovimMenu()
                    changed = true
                case "msg_show":
                    let text = Self.text(args.count > 1 ? args[1] : nil)
                    if !text.isEmpty { status = text; changed = true }
                case "msg_clear":
                    status = ""
                    changed = true
                case "popupmenu_show":
                    // [items, selected, row, col, grid]: each item [word, kind, menu, info].
                    let entries = (args.first?.arrayValue ?? []).compactMap { $0.arrayValue }.map { entry in
                        let word = entry.first?.stringValue ?? ""
                        let kind = entry.count > 1 ? entry[1].stringValue ?? "" : ""
                        let menu = entry.count > 2 ? entry[2].stringValue ?? "" : ""
                        return NeovimMenu.Item(word: word, detail: [kind, menu].filter { !$0.isEmpty }.joined(separator: " "))
                    }
                    let selected = args.count > 1 ? args[1].intValue ?? -1 : -1
                    let grid = args.count > 4 ? args[4].intValue ?? 1 : 1
                    view?.showNeovimMenu(entries, selected: selected, forCommandLine: grid == -1)
                case "popupmenu_select":
                    view?.selectNeovimMenu(args.first?.intValue ?? -1)
                case "popupmenu_hide":
                    view?.hideNeovimMenu()
                default:
                    break
                }
            }
        }
        if changed { onChange?() }
    }

    /// `[[attr, text, …], …]`, the chunks a message or a command line is made of.
    private static func text(_ chunks: MessagePackValue?) -> String {
        (chunks?.arrayValue ?? []).compactMap { $0.arrayValue?.count ?? 0 >= 2 ? $0.arrayValue?[1].stringValue : nil }.joined()
    }

    private func ended() {
        if case .running = state { state = .ended }
        onChange?()
    }

    // MARK: To Neovim

    func input(_ keys: String) {
        send("nvim_input", [.string(keys)])
    }

    func paste(_ text: String) {
        send("nvim_paste", [.string(text), true, -1])
    }

    /// Now, or once Neovim runs.
    private func send(_ method: String, _ params: [MessagePackValue]) {
        switch state {
        case .running: client.notify(method, params)
        case .starting: waiting.append((method, params))
        case .failed, .ended: break
        }
    }

    /// A click in the view moves Neovim's cursor there.
    func moveCursor(to offset: Int) {
        guard case .running = state else { return }
        let position = mirror.position(of: offset)
        client.notify("nvim_win_set_cursor", [0, [.int(Int64(position.row)), .int(Int64(position.byteColumn))]])
    }

    func resize() {
        guard case .running = state else { return }
        let (rows, cols) = size()
        client.notify("nvim_ui_try_resize", [.int(Int64(cols)), .int(Int64(rows))])
    }

    /// Rows and columns the view shows, so `<C-d>`, `zz` and `H`/`L` move by
    /// what is on screen.
    private func size() -> (Int, Int) {
        // The body's font: the view's own is its first letter's, and live
        // preview shrinks a heading's `#` away from the cursor.
        guard let view else { return (40, 100) }
        let font = Fonts.text(size: textSize)
        let line = font.ascender - font.descender + font.leading
        // A line of prose holds as many letters as Neovim's columns: the
        // average letter, not the widest.
        let alphabet = "abcdefghijklmnopqrstuvwxyz " as NSString
        let width = alphabet.size(withAttributes: [.font: font]).width / CGFloat(alphabet.length)
        // The scroll view's clip is what shows; the view's visible rect is
        // the whole note until the view is on screen.
        let grid = VimGrid.size(
            height: Double(view.enclosingScrollView?.contentView.bounds.height ?? view.visibleRect.height), width: Double(view.textContainer?.size.width ?? 600),
            lineHeight: line * 1.6, letterWidth: width)
        return (grid.rows, grid.cols)
    }

    /// Neovim writes the file, a moment after the last change, and never in
    /// the middle of an insert: a person's config may format on save (the
    /// author's runs prettier), and that moving text under the cursor while
    /// they type would be worse than a late save. `:update` writes only when
    /// the buffer is modified.
    private func scheduleSave() {
        saveSoon?.cancel()
        saveSoon = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                if self.isNormal { break }
            }
            self?.save()
        }
    }

    func save() {
        guard case .running = state else { return }
        client.notify("nvim_command", ["silent! update"])
    }

    /// Writes the buffer and waits until Neovim has, before the file is
    /// renamed, moved or deleted under it.
    func saveAndWait() async {
        saveSoon?.cancel()
        guard case .running = state else { return }
        _ = try? await within(Self.saveLimit) { try await client.request("nvim_command", ["silent! update"]) }
        // It did not write in time and was ended: the editor hears it now,
        // before the caller reads the file, and saves what the view shows.
        if unanswered { ended() }
    }

    /// Lines [start]..<[end] (from 0) of the note's buffer become [lines],
    /// then the buffer is written: Format Note in Neovim mode. One
    /// `nvim_buf_set_lines` is one step of Neovim's undo, and the cursor,
    /// marks and folds outside those lines stay. False when the buffer is
    /// not the text that was formatted any more ([expected] lines), or
    /// Neovim does not run.
    func replace(lines start: Int, _ end: Int, with lines: [String], expected: [String]) async -> Bool {
        guard case .running = state else { return false }
        saveSoon?.cancel()
        let id = MessagePackValue.int(Int64(buffer))
        let now = try? await client.request("nvim_buf_get_lines", [id, 0, -1, false]).arrayValue?.compactMap(\.stringValue)
        guard now == expected else { return false }
        let replacement = MessagePackValue.array(lines.map { .string($0) })
        guard (try? await client.request("nvim_buf_set_lines", [id, .int(Int64(start)), .int(Int64(end)), false, replacement])) != nil else { return false }
        _ = try? await within(Self.saveLimit) { try await client.request("nvim_command", ["silent! update"]) }
        return true
    }

    /// Where the cursor goes once Neovim runs: the line the reader was on.
    private var startOffset: Int?

    /// The cursor to [offset], with its line in the middle, as `zz` puts it.
    func go(to offset: Int) {
        guard case .running = state else {
            startOffset = offset
            return
        }
        let position = mirror.position(of: offset)
        client.notify("nvim_win_set_cursor", [0, [.int(Int64(position.row)), .int(Int64(position.byteColumn))]])
        client.notify("nvim_command", ["normal! zz"])
    }

    /// The note moved: the buffer takes the new name, so no later save
    /// writes the old file again. Keys typed while the move ran are kept and
    /// written to the new file; with none, the file is read again, for the
    /// links the move rewrote in it.
    func rename(to newPath: String) async {
        saveSoon?.cancel()
        path = newPath
        guard case .running = state else { return }
        // Not `:edit!`: a reload ends the app's attachment to the buffer.
        let lua = """
            local name = ...
            vim.cmd('keepalt file ' .. vim.fn.fnameescape(name))
            if not vim.bo.modified then
              local lines = vim.fn.readfile(name)
              if not vim.deep_equal(lines, vim.api.nvim_buf_get_lines(0, 0, -1, false)) then
                vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
              end
            end
            vim.cmd('silent! write!')
            """
        _ = try? await client.request("nvim_exec_lua", [.string(lua), [.string(newPath)]])
    }

    /// The file changed on disk: Neovim reads it again if the buffer has no
    /// changes of its own, and says so if it has.
    func checkDisk() {
        guard case .running = state else { return }
        client.notify("nvim_command", ["silent! checktime"])
    }

    /// The session lets the view go, at once: the editor shows another note
    /// in the same view, or is a plain editor again, while this Neovim still
    /// writes its file. What it says from now on -- a formatter's edit as it
    /// writes, a cursor, a message -- reaches no view.
    func detach() {
        view = nil
        onChange = nil
        onRemoteEdit = nil
        onOpen = nil
    }

    /// Ends Neovim, and writes the buffer first unless [writing] is false:
    /// after a delete. Neovim's `autoread` marks a buffer whose file went
    /// away as changed, so the `:update` would put the deleted note back.
    func stop(writing: Bool = true) async {
        detach()
        saveSoon?.cancel()
        if writing, case .running = state {
            _ = try? await within(Self.stopLimit) { try await client.request("nvim_command", ["silent! update"]) }
            if unanswered { onUnwritten?(path, mirror.text) }
        }
        state = .ended
        listen?.cancel()
        client.stop()
    }
}
