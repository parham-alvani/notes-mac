import AppKit

/// The fonts of the reader, the editor and the terminal, from the settings.
/// Persian goes to Vazirmatn wherever it appears, as on the phone: the system
/// would otherwise draw it in Geeza Pro.
@MainActor
enum Fonts {
    /// A family name, or Apple's own faces by the names people know them by.
    static func text(size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
        let name = AppSettings.shared.font
        var font: NSFont
        switch name.lowercased() {
        case "new york", "ui-serif", "serif":
            font = system(size, weight, design: .serif)
        case "sf pro", "system", "", "-apple-system":
            font = system(size, weight, design: .default)
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

    private static func withPersian(_ font: NSFont) -> NSFont {
        let persian = NSFontDescriptor(fontAttributes: [.family: "Vazirmatn"])
        let descriptor = font.fontDescriptor.addingAttributes([.cascadeList: [persian]])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
}
