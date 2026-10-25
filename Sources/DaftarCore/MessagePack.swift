import Foundation

/// MessagePack, the wire format of Neovim's RPC. Only what that protocol
/// sends: nil, booleans, integers, floats, strings, binary, arrays, maps, and
/// the ext type Neovim uses for buffer, window and tab handles.
public indirect enum MessagePackValue: Sendable, Hashable {
    case `nil`
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case binary(Data)
    case array([MessagePackValue])
    case map([MessagePackValue: MessagePackValue])
    case ext(Int8, Data)

    public var intValue: Int? {
        switch self {
        case .int(let value): Int(value)
        case .uint(let value): Int(value)
        // A handle (buffer, window) is an ext holding a packed integer.
        case .ext(_, let data): (try? MessagePack.decode(data))?.intValue
        default: nil
        }
    }

    public var stringValue: String? {
        switch self {
        case .string(let text): text
        case .binary(let data): String(data: data, encoding: .utf8)
        default: nil
        }
    }

    public var arrayValue: [MessagePackValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let flag) = self { return flag }
        return nil
    }

    public subscript(key: String) -> MessagePackValue? {
        if case .map(let map) = self { return map[.string(key)] }
        return nil
    }
}

extension MessagePackValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(Int64(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: MessagePackValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (MessagePackValue, MessagePackValue)...) {
        self = .map(Dictionary(elements) { a, _ in a })
    }
    public init(nilLiteral: ()) { self = .nil }
}

public enum MessagePack {
    public enum Failure: Error { case truncated, unknownType(UInt8) }

    public static func encode(_ value: MessagePackValue) -> Data {
        var out = Data()
        write(value, into: &out)
        return out
    }

    private static func write(_ value: MessagePackValue, into out: inout Data) {
        switch value {
        case .nil: out.append(0xC0)
        case .bool(let flag): out.append(flag ? 0xC3 : 0xC2)
        case .int(let number):
            if number >= 0 { write(.uint(UInt64(number)), into: &out) }
            else if number >= -32 { out.append(UInt8(bitPattern: Int8(number))) }
            else if number >= Int64(Int8.min) { out.append(0xD0); out.append(UInt8(bitPattern: Int8(number))) }
            else if number >= Int64(Int16.min) { out.append(0xD1); append(UInt16(bitPattern: Int16(number)), &out) }
            else if number >= Int64(Int32.min) { out.append(0xD2); append(UInt32(bitPattern: Int32(number)), &out) }
            else { out.append(0xD3); append(UInt64(bitPattern: number), &out) }
        case .uint(let number):
            if number < 0x80 { out.append(UInt8(number)) }
            else if number <= UInt64(UInt8.max) { out.append(0xCC); out.append(UInt8(number)) }
            else if number <= UInt64(UInt16.max) { out.append(0xCD); append(UInt16(number), &out) }
            else if number <= UInt64(UInt32.max) { out.append(0xCE); append(UInt32(number), &out) }
            else { out.append(0xCF); append(number, &out) }
        case .double(let number):
            out.append(0xCB)
            append(number.bitPattern, &out)
        case .string(let text):
            let bytes = Data(text.utf8)
            if bytes.count < 32 { out.append(0xA0 | UInt8(bytes.count)) }
            else if bytes.count <= Int(UInt8.max) { out.append(0xD9); out.append(UInt8(bytes.count)) }
            else if bytes.count <= Int(UInt16.max) { out.append(0xDA); append(UInt16(bytes.count), &out) }
            else { out.append(0xDB); append(UInt32(bytes.count), &out) }
            out.append(bytes)
        case .binary(let data):
            if data.count <= Int(UInt8.max) { out.append(0xC4); out.append(UInt8(data.count)) }
            else if data.count <= Int(UInt16.max) { out.append(0xC5); append(UInt16(data.count), &out) }
            else { out.append(0xC6); append(UInt32(data.count), &out) }
            out.append(data)
        case .array(let items):
            if items.count < 16 { out.append(0x90 | UInt8(items.count)) }
            else if items.count <= Int(UInt16.max) { out.append(0xDC); append(UInt16(items.count), &out) }
            else { out.append(0xDD); append(UInt32(items.count), &out) }
            for item in items { write(item, into: &out) }
        case .map(let map):
            if map.count < 16 { out.append(0x80 | UInt8(map.count)) }
            else if map.count <= Int(UInt16.max) { out.append(0xDE); append(UInt16(map.count), &out) }
            else { out.append(0xDF); append(UInt32(map.count), &out) }
            for (key, item) in map {
                write(key, into: &out)
                write(item, into: &out)
            }
        case .ext(let type, let data):
            switch data.count {
            case 1: out.append(0xD4)
            case 2: out.append(0xD5)
            case 4: out.append(0xD6)
            case 8: out.append(0xD7)
            case 16: out.append(0xD8)
            default:
                if data.count <= Int(UInt8.max) { out.append(0xC7); out.append(UInt8(data.count)) }
                else if data.count <= Int(UInt16.max) { out.append(0xC8); append(UInt16(data.count), &out) }
                else { out.append(0xC9); append(UInt32(data.count), &out) }
            }
            out.append(UInt8(bitPattern: type))
            out.append(data)
        }
    }

    private static func append<T: FixedWidthInteger>(_ value: T, _ out: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { out.append(contentsOf: $0) }
    }

    /// One whole value from [data], which must hold exactly one.
    public static func decode(_ data: Data) throws -> MessagePackValue {
        var reader = Reader(bytes: [UInt8](data))
        return try reader.value()
    }

    /// Values from a stream that may stop in the middle of one. Feed it what
    /// arrives; it hands back every value that is now complete.
    public struct Stream {
        private var buffer: [UInt8] = []

        public init() {}

        public mutating func feed(_ data: Data) -> [MessagePackValue] {
            buffer.append(contentsOf: data)
            var out: [MessagePackValue] = []
            while !buffer.isEmpty {
                var reader = Reader(bytes: buffer)
                guard let value = try? reader.value() else { break }
                out.append(value)
                buffer.removeFirst(reader.at)
            }
            return out
        }
    }

    struct Reader {
        let bytes: [UInt8]
        var at = 0

        mutating func byte() throws -> UInt8 {
            guard at < bytes.count else { throw Failure.truncated }
            defer { at += 1 }
            return bytes[at]
        }

        mutating func take(_ count: Int) throws -> [UInt8] {
            guard count >= 0, at + count <= bytes.count else { throw Failure.truncated }
            defer { at += count }
            return Array(bytes[at..<(at + count)])
        }

        mutating func number<T: FixedWidthInteger>(_: T.Type) throws -> T {
            try take(MemoryLayout<T>.size).reduce(T.zero) { ($0 << 8) | T($1) }
        }

        mutating func string(_ count: Int) throws -> MessagePackValue {
            let raw = try take(count)
            return .string(String(decoding: raw, as: UTF8.self))
        }

        mutating func array(_ count: Int) throws -> MessagePackValue {
            var items: [MessagePackValue] = []
            items.reserveCapacity(count)
            for _ in 0..<count { items.append(try value()) }
            return .array(items)
        }

        mutating func map(_ count: Int) throws -> MessagePackValue {
            var map: [MessagePackValue: MessagePackValue] = [:]
            for _ in 0..<count {
                let key = try value()
                map[key] = try value()
            }
            return .map(map)
        }

        mutating func ext(_ count: Int) throws -> MessagePackValue {
            let type = Int8(bitPattern: try byte())
            return .ext(type, Data(try take(count)))
        }

        mutating func value() throws -> MessagePackValue {
            let head = try byte()
            switch head {
            case 0x00...0x7F: return .uint(UInt64(head))
            case 0x80...0x8F: return try map(Int(head & 0x0F))
            case 0x90...0x9F: return try array(Int(head & 0x0F))
            case 0xA0...0xBF: return try string(Int(head & 0x1F))
            case 0xC0: return .nil
            case 0xC2: return .bool(false)
            case 0xC3: return .bool(true)
            case 0xC4: return .binary(Data(try take(Int(try number(UInt8.self)))))
            case 0xC5: return .binary(Data(try take(Int(try number(UInt16.self)))))
            case 0xC6: return .binary(Data(try take(Int(try number(UInt32.self)))))
            case 0xC7: return try ext(Int(try number(UInt8.self)))
            case 0xC8: return try ext(Int(try number(UInt16.self)))
            case 0xC9: return try ext(Int(try number(UInt32.self)))
            case 0xCA: return .double(Double(Float(bitPattern: try number(UInt32.self))))
            case 0xCB: return .double(Double(bitPattern: try number(UInt64.self)))
            case 0xCC: return .uint(UInt64(try number(UInt8.self)))
            case 0xCD: return .uint(UInt64(try number(UInt16.self)))
            case 0xCE: return .uint(UInt64(try number(UInt32.self)))
            case 0xCF: return .uint(try number(UInt64.self))
            case 0xD0: return .int(Int64(Int8(bitPattern: try number(UInt8.self))))
            case 0xD1: return .int(Int64(Int16(bitPattern: try number(UInt16.self))))
            case 0xD2: return .int(Int64(Int32(bitPattern: try number(UInt32.self))))
            case 0xD3: return .int(Int64(bitPattern: try number(UInt64.self)))
            case 0xD4: return try ext(1)
            case 0xD5: return try ext(2)
            case 0xD6: return try ext(4)
            case 0xD7: return try ext(8)
            case 0xD8: return try ext(16)
            case 0xD9: return try string(Int(try number(UInt8.self)))
            case 0xDA: return try string(Int(try number(UInt16.self)))
            case 0xDB: return try string(Int(try number(UInt32.self)))
            case 0xDC: return try array(Int(try number(UInt16.self)))
            case 0xDD: return try array(Int(try number(UInt32.self)))
            case 0xDE: return try map(Int(try number(UInt16.self)))
            case 0xDF: return try map(Int(try number(UInt32.self)))
            case 0xE0...0xFF: return .int(Int64(Int8(bitPattern: head)))
            default: throw Failure.unknownType(head)
            }
        }
    }
}
