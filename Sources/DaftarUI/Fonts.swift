import AppKit

/// The fonts of the reader, the editor and the terminal, from the settings.
/// Persian goes to Vazirmatn wherever it appears, as on the phone: the system
/// would otherwise draw it in Geeza Pro.
@MainActor
enum Fonts {
    /// A family name, or Apple's own faces by the names people know them by.
    static func text(size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
        let name = AppSettings.shared.font
        let key = "t|\(name)|\(size)|\(weight.rawValue)|\(italic)"
        if let made = cache[key] { return made }
        let font = makeText(name: name, size: size, weight: weight, italic: italic)
        keep(font, as: key)
        return font
    }

    /// The fonts made so far, by setting, size and style: the editor asks
    /// for one for every span it styles, at every key, and making one goes
    /// through the font manager and three descriptors.
    private static var cache: [String: NSFont] = [:]

    private static func keep(_ font: NSFont, as key: String) {
        // Sizes and settings change rarely; a cache that grew past this is started again.
        if cache.count > 256 { cache.removeAll() }
        cache[key] = font
    }

    private static func makeText(name: String, size: CGFloat, weight: NSFont.Weight, italic: Bool) -> NSFont {
        var font: NSFont
        switch name.lowercased() {
        case "new york", "ui-serif", "serif":
            font = system(size, weight, design: .serif)
        case "sf pro", "system", "", "-apple-system":
            font = alternates(system(size, weight, design: .default))
        case "sf pro rounded", "rounded":
            font = system(size, weight, design: .rounded)
        default:
            let manager = NSFontManager.shared
            font = manager.font(withFamily: name, traits: weight >= .semibold ? .boldFontMask : [], weight: weight >= .semibold ? 9 : 5, size: size)
                ?? system(size, weight, design: .default)
        }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return withPersian(font)
    }

    static func code(size: CGFloat) -> NSFont {
        let name = AppSettings.shared.codeFont
        let key = "c|\(name)|\(size)"
        if let made = cache[key] { return made }
        let font = makeCode(name: name, size: size)
        keep(font, as: key)
        return font
    }

    private static func makeCode(name: String, size: CGFloat) -> NSFont {
        if !name.isEmpty, name.lowercased() != "sf mono",
            let font = NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size)
        {
            return withPersian(font)
        }
        return withPersian(NSFont.monospacedSystemFont(ofSize: size, weight: .regular))
    }

    /// The CSS font stacks for the reader, with the same choices.
    static var css: (text: String, code: String) {
        let name = AppSettings.shared.font
        let text: String = switch name.lowercased() {
        case "new york", "ui-serif", "serif": "ui-serif, \"New York\""
        case "sf pro", "system", "", "-apple-system": "-apple-system, BlinkMacSystemFont"
        case "sf pro rounded", "rounded": "ui-rounded"
        default: "\"\(name)\", -apple-system"
        }
        let code = AppSettings.shared.codeFont
        let mono = code.isEmpty || code.lowercased() == "sf mono" ? "ui-monospace, \"SF Mono\"" : "\"\(code)\", ui-monospace"
        return ("\(text), \"Persian Fallback\", sans-serif", "\(mono), \"Persian Fallback\", monospace")
    }

    private static func system(_ size: CGFloat, _ weight: NSFont.Weight, design: NSFontDescriptor.SystemDesign) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// SF Pro's stylistic sets 1 and 7, as the Cupertino theme sets them in
    /// Obsidian: the open 4 and 6 and 9, and the straight-legged l.
    private static func alternates(_ font: NSFont) -> NSFont {
        let sets = [1, 7].map { set -> [NSFontDescriptor.FeatureKey: Int] in
            [.typeIdentifier: kStylisticAlternativesType, .selectorIdentifier: set * 2]
        }
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: sets])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    private static func withPersian(_ font: NSFont) -> NSFont {
        let persian = NSFontDescriptor(fontAttributes: [.family: "Vazirmatn"])
        let descriptor = font.fontDescriptor.addingAttributes([.cascadeList: [persian]])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
}
