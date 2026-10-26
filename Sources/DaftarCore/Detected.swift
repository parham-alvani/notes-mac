import Foundation

/// Street addresses and phone numbers written as plain text in a note, as
/// the system's data detector finds them: the reader makes them links, to
/// Maps and to the phone, and the inspector lists the places a note names.
/// Text in links, code, web addresses, tags and the front matter is left
/// alone, as for unlinked mentions.
public enum Detected {
    public enum Kind: String, Sendable { case address, phone }

    public struct Item: Sendable, Hashable {
        public var kind: Kind
        /// As the note writes it.
        public var text: String
        /// What the link opens: the address on one line, or the number's digits.
        public var value: String
        public var line: Int
    }

    nonisolated(unsafe) private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue | NSTextCheckingResult.CheckingType.phoneNumber.rawValue)
    nonisolated(unsafe) private static let dateLike = /\d{4}-\d{2}-\d{2}|\d{1,2}[\/.]\d{1,2}[\/.]\d{2,4}|\d{1,2}:\d{2}/

    public static func find(in text: String) -> [Item] {
        var found: [Item] = []
        var fenced = false, front = false
        let lines = text.components(separatedBy: "\n")
        for (number, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if number == 0, trimmed == "---" { front = true; continue }
            if front {
                if trimmed == "---" || trimmed == "..." { front = false }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle(); continue }
            if fenced || !trimmed.contains(where: \.isNumber) { continue }
            let string = line as NSString
            let taken = UnlinkedMentions.protected(in: string)
            for match in detector.matches(in: line, range: NSRange(location: 0, length: string.length)) {
                guard !taken.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
                let written = string.substring(with: match.range).trimmingCharacters(in: .whitespaces)
                switch match.resultType {
                case .phoneNumber:
                    guard let phone = match.phoneNumber, isPhone(written) else { continue }
                    found.append(Item(kind: .phone, text: written, value: phone.filter { $0.isNumber || $0 == "+" }, line: number))
                case .address:
                    let value = written.replacingOccurrences(of: "\n", with: ", ")
                    found.append(Item(kind: .address, text: written, value: value, line: number))
                default:
                    continue
                }
            }
        }
        return found
    }

    /// A phone number, not a date, a time or a short count: eight digits or more.
    static func isPhone(_ text: String) -> Bool {
        text.filter(\.isNumber).count >= 8 && text.firstMatch(of: dateLike) == nil
    }
}
