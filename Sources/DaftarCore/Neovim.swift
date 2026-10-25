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
    private var nextId: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<MessagePackValue, any Error>] = [:]
    private var stream = MessagePack.Stream()
    private let continuation: AsyncStream<Notification>.Continuation
    public let notifications: AsyncStream<Notification>

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
            try input.fileHandleForWriting.write(contentsOf: data)
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
                // Neovim asking us something (rpcrequest): there is nothing
                // here to answer with, so it gets an empty reply, not a hang.
                send(.array([.uint(1), parts[1], .nil, .nil]))
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

    public init(lines: [String], endsWithNewline: Bool = true) {
        self.lines = lines.isEmpty ? [""] : lines
        self.endsWithNewline = endsWithNewline
    }

    public var text: String { lines.joined(separator: "\n") + (endsWithNewline ? "\n" : "") }

    /// `nvim_buf_lines_event`: lines [first, last) became [replacement]; a
    /// [last] of -1 is the end of the buffer. Returns the range of the view's
    /// text that changed (UTF-16) and what it now says.
    public mutating func apply(first: Int, last: Int, replacement: [String]) -> (range: NSRange, text: String) {
        let old = text as NSString
        let end = last < 0 ? lines.count : min(last, lines.count)
        let start = min(first, lines.count)
        lines.replaceSubrange(start..<end, with: replacement)
        if lines.isEmpty { lines = [""] }
        let new = text as NSString
        // The smallest range that differs, so the view keeps its attributes,
        // its scroll and its images everywhere else.
        var prefix = 0
        let limit = min(old.length, new.length)
        while prefix < limit, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) {
            suffix += 1
        }
        let range = NSRange(location: prefix, length: old.length - prefix - suffix)
        return (range, new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix)))
    }

    /// A Neovim position (row from 1, column in UTF-8 bytes from 0) as a
    /// UTF-16 offset into the view's text.
    public func offset(row: Int, byteColumn: Int) -> Int {
        let index = max(0, min(row - 1, lines.count - 1))
        var offset = 0
        for line in lines[..<index] { offset += line.utf16.count + 1 }
        let line = lines[index]
        let bytes = Array(line.utf8.prefix(max(0, byteColumn)))
        let prefix = String(decoding: bytes, as: UTF8.self)
        return offset + min(prefix.utf16.count, line.utf16.count)
    }

    /// The other way: a UTF-16 offset as a Neovim (row from 1, byte column).
    public func position(of offset: Int) -> (row: Int, byteColumn: Int) {
        var remaining = offset
        for (index, line) in lines.enumerated() {
            let length = line.utf16.count
            if remaining <= length {
                let prefix = String(line.utf16.prefix(remaining)) ?? ""
                return (index + 1, prefix.utf8.count)
            }
            remaining -= length + 1
        }
        return (lines.count, lines.last?.utf8.count ?? 0)
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
}
