import Foundation

/// Normalisation shared by the resolver and the index: NFC, and case folded
/// without a locale, so a Turkish dotted I in a file name still matches.
public enum Slugs {
    public static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
    }

    public static func fold(_ text: String) -> String {
        // ASCII is its own NFC, and folds to its small letters: no trip through
        // NSString for the paths and tags that are most of a vault.
        if text.utf8.allSatisfy({ $0 < 0x80 }) {
            guard text.utf8.contains(where: { $0 >= 0x41 && $0 <= 0x5A }) else { return text }
            return String(decoding: text.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }, as: UTF8.self)
        }
        return normalize(text).lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    /// [fold], and Persian as people type it on different keyboards made
    /// one: Arabic Yeh and Kaf as the Persian letters, the hamza forms of
    /// Alef, Waw and Yeh as the letters under them, Persian and Arabic
    /// digits as ASCII ones, and what a word may or may not be written
    /// with taken out: the half space (ZWNJ), the vowel marks and the
    /// tatweel ([isPersianMark]). Each character stays one, so offsets
    /// into the folded text are offsets into the text: Swift counts a ZWNJ
    /// or a vowel mark as part of the letter before it, so it goes rather
    /// than becoming a space as on Linux, and a mark that is a character
    /// of its own (a tatweel, a ZWNJ after a space) becomes a space. For
    /// matching only: a link still resolves by [fold].
    public static func search(_ text: String) -> String {
        let folded = fold(text)
        guard holdsPersian(folded) else { return folded }
        var out = ""
        for character in folded {
            var scalars = String.UnicodeScalarView()
            for scalar in character.unicodeScalars where !isPersianMark(scalar) { scalars.append(persianLetter(scalar)) }
            out.append(scalars.isEmpty ? " " : String(scalars))
        }
        return out
    }

    /// [text] with its Persian as [search] makes it one, the marks gone
    /// altogether: `كِتـاب` and `کتاب` are the same letters. The text is
    /// shorter than it was, so this is for a text that is only matched
    /// (a full-text column, a quick-open name), never for offsets.
    public static func persian(_ text: String) -> String {
        guard holdsPersian(text) else { return text }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !isPersianMark(scalar) { scalars.append(persianLetter(scalar)) }
        return String(scalars)
    }

    /// [fold] and [persian]: the one form quick open, link completion and
    /// full-text search match in, whatever keyboard the text came from.
    public static func matching(_ text: String) -> String { persian(fold(text)) }

    private static func holdsPersian(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) || $0.value == 0x200C }
    }

    /// What a Persian word may be written with or without: the half space
    /// (ZWNJ), the vowel marks (harakat, U+064B to U+0652, and the marks
    /// U+0653 to U+0655 a decomposed آ or أ leaves), the superscript alef
    /// (U+0670) and the tatweel that stretches a word (U+0640).
    public static func isPersianMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200C, 0x0640, 0x064B...0x0655, 0x0670: true
        default: false
        }
    }

    /// The letter a Persian search finds [scalar] as: see [search].
    public static func persianLetter(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar {
        case "\u{064A}", "\u{0649}", "\u{0626}": return "\u{06CC}"  // ي ى ئ as ی
        case "\u{0643}": return "\u{06A9}"  // ك as ک
        case "\u{0629}": return "\u{0647}"  // ة as ه
        case "\u{0623}", "\u{0625}", "\u{0622}", "\u{0671}": return "\u{0627}"  // أ إ آ ٱ as ا
        case "\u{0624}": return "\u{0648}"  // ؤ as و
        case "\u{06F0}"..."\u{06F9}": return Unicode.Scalar(0x30 + scalar.value - 0x06F0)!
        case "\u{0660}"..."\u{0669}": return Unicode.Scalar(0x30 + scalar.value - 0x0660)!
        default: return scalar
        }
    }

    /// A heading as `[[Note#Heading]]` names it: Obsidian matches the text,
    /// so this only folds case and collapses white space.
    public static func heading(_ text: String) -> String {
        fold(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Resolves `[[wikilink]]` targets to vault paths, the way Obsidian does.
///
/// The same rules as Daftar on Android (`LinkResolver.kt`): a target is a
/// suffix of the file's vault path, aligned on `/`, with `.md` optional on the
/// last segment. A folder note `X/X.md` also answers to `X`. Case is folded
/// only when the exact match misses, and an alias is asked last, because
/// Obsidian gives a real name priority over an alias.
public struct LinkResolver: Sendable {
    private var exact: [String: [String]] = [:]
    private var folded: [String: [String]] = [:]
    private var aliased: [String: [String]] = [:]

    public init(paths: some Collection<String>, aliases: [String: [String]] = [:]) {
        for path in paths { register(Slugs.normalize(path)) }
        for (path, names) in aliases {
            let normalized = Slugs.normalize(path)
            for name in names {
                let key = Slugs.fold(name.trimmingCharacters(in: .whitespaces))
                guard !key.isEmpty else { continue }
                if !(aliased[key]?.contains(normalized) ?? false) { aliased[key, default: []].append(normalized) }
            }
        }
    }

    private mutating func register(_ path: String) {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        indexSuffixes(segments, path)
        let name = segments.last!.removingSuffix(".md")
        if segments.count >= 2, segments[segments.count - 2] == name {
            indexSuffixes(Array(segments.dropLast()), path)
        }
    }

    private mutating func indexSuffixes(_ segments: [String], _ path: String) {
        for from in segments.indices {
            let slice = Array(segments[from...])
            put(slice.joined(separator: "/"), path)
            if let last = slice.last, last.hasSuffix(".md") {
                put((slice.dropLast() + [last.removingSuffix(".md")]).joined(separator: "/"), path)
            }
        }
    }

    private mutating func put(_ key: String, _ path: String) {
        if !(exact[key]?.contains(path) ?? false) { exact[key, default: []].append(path) }
        let lower = Slugs.fold(key)
        if !(folded[lower]?.contains(path) ?? false) { folded[lower, default: []].append(path) }
    }

    /// The vault path [target] refers to, seen from [source], or nil for a
    /// broken link. With [aliases] false, only a file's name or path answers.
    public func resolve(_ target: String, from source: String, aliases: Bool = true) -> String? {
        if target.isEmpty { return source }
        var cleaned = Slugs.normalize(target).trimmingCharacters(in: .whitespaces)
        while cleaned.hasSuffix("/") { cleaned.removeLast() }
        if cleaned.isEmpty { return source }

        if cleaned.hasPrefix("./") || cleaned.hasPrefix("../"), let found = relative(cleaned, source) {
            return found
        }
        guard let candidates = exact[cleaned] ?? folded[Slugs.fold(cleaned)] ?? (aliases ? aliased[Slugs.fold(cleaned)] : nil) else {
            return nil
        }
        return candidates.count == 1 ? candidates[0] : disambiguate(candidates, source)
    }

    private func relative(_ target: String, _ source: String) -> String? {
        var base = source.split(separator: "/").dropLast().map(String.init)
        for segment in target.split(separator: "/") {
            switch segment {
            case ".": continue
            case "..":
                guard !base.isEmpty else { return nil }
                base.removeLast()
            default: base.append(String(segment))
            }
        }
        let joined = base.joined(separator: "/")
        return exact[joined]?.first ?? exact[joined + ".md"]?.first
    }

    /// The candidate that shares the longest folder prefix with the source,
    /// then the shallowest, the shortest, and the first by name, so that the
    /// guess is at least stable.
    private func disambiguate(_ candidates: [String], _ source: String) -> String {
        let sourceDirs = source.split(separator: "/").dropLast()
        func shared(_ path: String) -> Int {
            let dirs = path.split(separator: "/").dropLast()
            return zip(sourceDirs, dirs).prefix { $0 == $1 }.count
        }
        return candidates.min { a, b in
            let sa = shared(a), sb = shared(b)
            if sa != sb { return sa > sb }
            let da = a.filter { $0 == "/" }.count, db = b.filter { $0 == "/" }.count
            if da != db { return da < db }
            if a.count != b.count { return a.count < b.count }
            return a < b
        } ?? candidates[0]
    }
}

extension String {
    func removingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
