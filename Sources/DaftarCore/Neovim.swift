import Foundation

/// A Neovim process started with `--embed`, spoken to over msgpack-RPC on its
/// stdin and stdout. Requests wait for their answer; notifications -- buffer
/// changes, the cursor, redraws -- arrive on [notifications].
public final class NeovimClient: @unchecked Sendable {
    public struct Failure: Error, CustomStringConvertible {
        public var message: String
        public var description: String { message }
    }

    public struct Notification: Sendable {
        public var method: String
        public var params: [MessagePackValue]
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    /// Writes come from the main actor and from answers to Neovim at once:
    /// one message goes whole before the next.
    private let writing = NSLock()
    private var nextId: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<MessagePackValue, any Error>] = [:]
    private var stream = MessagePack.Stream()
    private let continuation: AsyncStream<Notification>.Continuation
    public let notifications: AsyncStream<Notification>
    /// Answers Neovim's `rpcrequest`, by method and params; Neovim waits
    /// for it. Set before [start]; without it each request gets nil.
    public var onRequest: (@Sendable (String, [MessagePackValue]) async -> MessagePackValue)?

    /// [arguments] come after `--embed`; [directory] is where it runs.
    public init(executable: URL, arguments: [String] = [], directory: URL? = nil, environment: [String: String]? = nil) {
        process.executableURL = executable
        process.arguments = ["--embed"] + arguments
        process.currentDirectoryURL = directory
        if let environment { process.environment = environment }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        (notifications, continuation) = AsyncStream.makeStream(of: Notification.self)
    }

    /// The first `nvim` on the usual paths, or nil when there is none.
    public static func locate(_ configured: String = "") -> URL? {
        let candidates = (configured.isEmpty ? [] : [(configured as NSString).expandingTildeInPath])
            + ["/opt/homebrew/bin/nvim", "/usr/local/bin/nvim", "/usr/bin/nvim"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(filePath: $0) }
    }

    public func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                self.closed()
                return
            }
            self.received(data)
        }
        process.terminationHandler = { [weak self] _ in self?.closed() }
        try process.run()
    }

    public var isRunning: Bool { process.isRunning }

    public func stop() {
        if process.isRunning { process.terminate() }
        closed()
    }

    deinit { stop() }

    /// Calls an API function and waits for its result.
    @discardableResult
    public func request(_ method: String, _ params: [MessagePackValue] = []) async throws -> MessagePackValue {
        try await withCheckedThrowingContinuation { continuation in
            let id: UInt64 = lock.withLock {
                let id = nextId
                nextId += 1
                pending[id] = continuation
                return id
            }
            send(.array([.uint(0), .uint(id), .string(method), .array(params)]))
        }
    }

    /// Calls an API function without waiting.
    public func notify(_ method: String, _ params: [MessagePackValue] = []) {
        send(.array([.uint(2), .string(method), .array(params)]))
    }

    private func send(_ message: MessagePackValue) {
        let data = MessagePack.encode(message)
        do {
            try writing.withLock { try input.fileHandleForWriting.write(contentsOf: data) }
        } catch {
            closed()
        }
    }

    private func received(_ data: Data) {
        let messages = lock.withLock { stream.feed(data) }
        for message in messages {
            guard let parts = message.arrayValue, let kind = parts.first?.intValue else { continue }
            switch kind {
            case 1 where parts.count == 4:
                let id = UInt64(parts[1].intValue ?? -1)
                let waiter = lock.withLock { pending.removeValue(forKey: id) }
                if parts[2] != .nil {
                    let text = parts[2].arrayValue?.last?.stringValue ?? "\(parts[2])"
                    waiter?.resume(throwing: Failure(message: text))
                } else {
                    waiter?.resume(returning: parts[3])
                }
            case 2 where parts.count == 3:
                continuation.yield(Notification(method: parts[1].stringValue ?? "", params: parts[2].arrayValue ?? []))
            case 0 where parts.count == 4:
                // Neovim asking us something (rpcrequest), and waiting: an
                // answer, or an empty one, never a hang.
                let id = parts[1]
                guard let onRequest else {
                    send(.array([.uint(1), id, .nil, .nil]))
                    continue
                }
                let method = parts[2].stringValue ?? ""
                let params = parts[3].arrayValue ?? []
                Task { [weak self] in
                    let answer = await onRequest(method, params)
                    self?.send(.array([.uint(1), id, .nil, answer]))
                }
            default:
                break
            }
        }
    }

    private func closed() {
        let waiters = lock.withLock {
            let all = pending.values
            pending.removeAll()
            return Array(all)
        }
        for waiter in waiters { waiter.resume(throwing: Failure(message: "Neovim exited")) }
        continuation.finish()
    }
}

/// The buffer's lines as Neovim last reported them, and the edit each report
/// makes to the text the view shows: the lines joined with newlines, and one
/// more newline at the end when the file has one.
public struct BufferMirror: Sendable, Equatable {
    public private(set) var lines: [String]
    public var endsWithNewline: Bool
    /// Each line's length in UTF-16, so a position is a sum, not a count of
    /// every line above it at every key.
    private var lengths: [Int]

    public init(lines: [String], endsWithNewline: Bool = true) {
        self.lines = lines.isEmpty ? [""] : lines
        self.endsWithNewline = endsWithNewline
        lengths = self.lines.map(\.utf16.count)
    }

    public var text: String { lines.joined(separator: "\n") + (endsWithNewline ? "\n" : "") }

    /// Where line [index] (from 0) starts in the view's text.
    private func start(of index: Int) -> Int {
        var offset = 0
        for length in lengths[..<min(index, lengths.count)] { offset += length + 1 }
        return offset
    }

    /// Lines [a, b) of [lines] as the view's text says them: with the newline
    /// after each, and after the last one only when more follow or the file
    /// ends with one.
    private func segment(_ lines: [String], _ a: Int, _ b: Int) -> String {
        guard a < b else { return "" }
        return lines[a..<b].joined(separator: "\n") + (b < lines.count || endsWithNewline ? "\n" : "")
    }

    /// `nvim_buf_lines_event`: lines [first, last) became [replacement]; a
    /// [last] of -1 is the end of the buffer. Returns the range of the view's
    /// text that changed (UTF-16) and what it now says. Only the lines that
    /// changed, and the one before them, are read.
    public mutating func apply(first: Int, last: Int, replacement: [String]) -> (range: NSRange, text: String) {
        let end = last < 0 ? lines.count : min(last, lines.count)
        let begin = min(first, lines.count)
        let from = max(0, begin - 1)
        let offset = start(of: from)
        let old = segment(lines, from, end)
        lines.replaceSubrange(begin..<end, with: replacement)
        lengths.replaceSubrange(begin..<end, with: replacement.map(\.utf16.count))
        if lines.isEmpty {
            // No line left: the buffer is one empty line, as Neovim keeps it.
            lines = [""]
            lengths = [0]
            let all = NSRange(location: 0, length: offset + (old as NSString).length)
            return (all, text)
        }
        let new = segment(lines, from, begin + replacement.count) as NSString
        let was = old as NSString
        // The smallest range that differs, so the view keeps its attributes,
        // its scroll and its images everywhere else.
        var prefix = 0
        let limit = min(was.length, new.length)
        while prefix < limit, was.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, was.character(at: was.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) {
            suffix += 1
        }
        let range = NSRange(location: offset + prefix, length: was.length - prefix - suffix)
        return (range, new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix)))
    }

    /// A Neovim position (row from 1, column in UTF-8 bytes from 0) as a
    /// UTF-16 offset into the view's text.
    public func offset(row: Int, byteColumn: Int) -> Int {
        let index = max(0, min(row - 1, lines.count - 1))
        let line = lines[index]
        let bytes = Array(line.utf8.prefix(max(0, byteColumn)))
        let prefix = String(decoding: bytes, as: UTF8.self)
        return start(of: index) + min(prefix.utf16.count, lengths[index])
    }

    /// The other way: a UTF-16 offset as a Neovim (row from 1, byte column).
    public func position(of offset: Int) -> (row: Int, byteColumn: Int) {
        var remaining = offset
        for (index, length) in lengths.enumerated() {
            if remaining <= length {
                let prefix = String(lines[index].utf16.prefix(remaining)) ?? ""
                return (index + 1, prefix.utf8.count)
            }
            remaining -= length + 1
        }
        return (lines.count, lines.last?.utf8.count ?? 0)
    }
}

/// The grid Neovim is told it draws on, from the editor's size.
public enum VimGrid {
    /// Rows and columns for a view [height] by [width] points, with lines
    /// [lineHeight] apart and letters [letterWidth] wide.
    ///
    /// Whatever the view says, and a view that is not on screen says strange
    /// things: a note deleted under the editor leaves it with no height, and a
    /// text container that does not follow its view is as wide as a CGFloat
    /// goes. `Int(_:)` of an infinite, NaN or too-large value stops the app,
    /// so each side is kept to a sensible grid before it is made an integer.
    public static func size(height: Double, width: Double, lineHeight: Double, letterWidth: Double) -> (rows: Int, cols: Int) {
        (cells(height, each: lineHeight, least: 5, fallback: 40), cells(width, each: letterWidth, least: 20, fallback: 100))
    }

    private static func cells(_ length: Double, each: Double, least: Int, fallback: Int) -> Int {
        guard length.isFinite, length > 0, each.isFinite else { return fallback }
        let count = length / max(each, 1)
        guard count.isFinite else { return fallback }
        return max(least, Int(min(count, 1000).rounded(.down)))
    }
}

/// A key press as Neovim's `nvim_input` spells it: `a`, `<CR>`, `<C-w>`,
/// `<M-Left>`, `<LT>`.
public enum VimKeys {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1)
        public static let control = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    /// AppKit's function-key characters (`NSUpArrowFunctionKey` and the
    /// rest), and the control characters the keyboard sends.
    static let special: [UInt32: String] = [
        0xF700: "Up", 0xF701: "Down", 0xF702: "Left", 0xF703: "Right",
        0xF704: "F1", 0xF705: "F2", 0xF706: "F3", 0xF707: "F4", 0xF708: "F5", 0xF709: "F6",
        0xF70A: "F7", 0xF70B: "F8", 0xF70C: "F9", 0xF70D: "F10", 0xF70E: "F11", 0xF70F: "F12",
        0xF728: "Del", 0xF729: "Home", 0xF72B: "End", 0xF72C: "PageUp", 0xF72D: "PageDown",
        0x0D: "CR", 0x03: "CR", 0x09: "Tab", 0x19: "Tab", 0x1B: "Esc", 0x7F: "BS", 0x08: "BS",
    ]

    /// [characters] is what the key typed with every modifier but Control
    /// (`charactersIgnoringModifiers` with Shift applied); [modifiers] the
    /// ones held.
    public static func notation(characters: String, modifiers: Modifiers) -> String? {
        guard let scalar = characters.unicodeScalars.first else { return nil }
        var prefix = ""
        if modifiers.contains(.control) { prefix += "C-" }
        if modifiers.contains(.option) { prefix += "M-" }
        if modifiers.contains(.command) { prefix += "D-" }
        if let name = special[scalar.value] {
            // Shift matters on a special key (<S-Tab>, <S-Up>), and is
            // already in the character of a printable one.
            let shift = modifiers.contains(.shift) ? "S-" : ""
            return "<\(shift)\(prefix)\(name)>"
        }
        if characters == " " { return prefix.isEmpty ? " " : "<\(prefix)Space>" }
        let key = characters == "<" ? "LT" : characters == "\\" && !prefix.isEmpty ? "Bslash" : characters
        if prefix.isEmpty { return key == "LT" ? "<LT>" : key }
        return "<\(prefix)\(key)>"
    }

    /// Return, Escape, the arrows and the other keys that type no text.
    public static func isSpecial(_ characters: String) -> Bool {
        characters.unicodeScalars.first.map { special[$0.value] != nil } ?? false
    }

    /// Typed text -- from the keyboard or an input method -- for `nvim_input`,
    /// where `<` starts a key name.
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "<", with: "<LT>")
    }

    /// Neovim's `langmap` for a second keyboard layout: each of its letters
    /// as the key in the same place on the Latin layout, so `j` and `dd`
    /// work in Normal mode with the Persian layout on, while Insert mode
    /// still types Persian. [pairs] is (the layout's letter, the Latin one),
    /// from the keyboard; a pair of two Latin letters (Dvorak beside QWERTY)
    /// is left out, as is a letter that comes twice.
    public static func langmap(_ pairs: [(Character, Character)]) -> String {
        var seen = Set<Character>()
        var items: [String] = []
        func escape(_ c: Character) -> String { c == "," || c == ";" || c == "\\" ? "\\\(c)" : String(c) }
        for (from, to) in pairs {
            guard !from.isASCII, to.isASCII, let ascii = to.asciiValue, (0x21...0x7E).contains(ascii), seen.insert(from).inserted else { continue }
            items.append(escape(from) + escape(to))
        }
        return items.joined(separator: ",")
    }
}
