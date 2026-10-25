import AppKit
import DaftarCore
import SwiftUI

/// A file's Iconic icon, drawn with the SF Symbol nearest to its Lucide one,
/// or as the emoji it is. Iconic's colour names are naz's colours, as on the
/// phone (`IconColors.kt`).
struct IconicImage: View {
    var icon: Iconic.Icon?
    var fallback: String
    var fallbackColor: Color
    /// A folder's `logo.svg` or picture, which wins over any other icon.
    var logo: URL?

    var body: some View {
        Group {
            if let logo, let image = Logo.image(logo) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else if let name = icon?.name, icon?.isEmoji == true {
                Text(name).font(.system(size: 12))
            } else {
                // A Lucide name with no symbol here draws the default, not a gap.
                Image(systemName: icon?.name.flatMap { Self.symbols[$0] }.flatMap(Self.known) ?? fallback)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(icon?.color.flatMap(Self.color) ?? fallbackColor)
            }
        }
        // The same square for every icon: wide symbols (a house, masks)
        // shrink into it instead of pushing the name aside.
        .frame(width: Self.slot, height: Self.slot)
    }

    static let slot: CGFloat = 18

    private static func known(_ symbol: String) -> String? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil ? nil : symbol
    }

    static func color(_ name: String) -> Color? {
        if name.hasPrefix("#"), let value = UInt32(name.dropFirst(), radix: 16) {
            return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
        }
        return switch name.lowercased() {
        case "red": Palette.red
        case "orange": Palette.accent
        case "yellow": Palette.yellow
        case "green": Palette.green
        case "mint": Palette.mint
        case "cyan": Palette.link
        case "blue": Palette.blue
        case "purple": Palette.purple
        case "pink": Palette.pink
        case "gray", "grey": Palette.muted
        default: nil
        }
    }

    /// Lucide names to SF Symbols, for the icons this vault uses and a few more.
    static let symbols: [String: String] = [
        "lucide-apple": "apple.logo", "lucide-baggage-claim": "suitcase.rolling", "lucide-banknote": "banknote",
        "lucide-biceps-flexed": "figure.strengthtraining.traditional", "lucide-book": "book.closed",
        "lucide-book-open": "book", "lucide-book-open-text": "text.book.closed", "lucide-brain": "brain",
        "lucide-briefcase": "briefcase", "lucide-briefcase-medical": "cross.case", "lucide-building": "building.2",
        "lucide-car": "car", "lucide-chart-no-axes-column-increasing": "chart.bar", "lucide-check-square": "checkmark.square",
        "lucide-clapperboard": "movieclapper", "lucide-computer": "desktopcomputer", "lucide-database": "cylinder.split.1x2",
        "lucide-dollar-sign": "dollarsign", "lucide-drama": "theatermasks", "lucide-euro": "eurosign",
        "lucide-flame": "flame", "lucide-glasses": "eyeglasses", "lucide-globe": "globe", "lucide-graduation-cap": "graduationcap",
        "lucide-heart": "heart", "lucide-house": "house", "lucide-house-plus": "house.lodge", "lucide-id-card": "person.text.rectangle",
        "lucide-image": "photo", "lucide-landmark": "building.columns", "lucide-laptop": "laptopcomputer",
        "lucide-lock-keyhole": "lock", "lucide-mail": "envelope", "lucide-map": "map", "lucide-map-pin": "mappin.and.ellipse",
        "lucide-moon": "moon", "lucide-network": "network", "lucide-paw-print": "pawprint", "lucide-piggy-bank": "banknote",
        "lucide-puzzle": "puzzlepiece", "lucide-receipt-euro": "eurosign.square", "lucide-route": "point.topleft.down.to.point.bottomright.curvepath",
        "lucide-shield-check": "checkmark.shield", "lucide-shopping-cart": "cart", "lucide-sigma": "sum",
        "lucide-skull": "exclamationmark.octagon", "lucide-smile-plus": "face.smiling", "lucide-square-check-big": "checkmark.square",
        "lucide-sun": "sun.max", "lucide-train": "tram", "lucide-truck": "truck.box", "lucide-tv": "tv",
        "lucide-utensils": "fork.knife", "lucide-wrench": "wrench.adjustable", "lucide-folder": "folder",
        "lucide-file": "doc", "lucide-file-text": "doc.text", "lucide-calendar": "calendar", "lucide-star": "star",
        "lucide-music": "music.note", "lucide-plane": "airplane", "lucide-code": "chevron.left.forwardslash.chevron.right",
        "lucide-terminal": "terminal", "lucide-user": "person", "lucide-users": "person.2", "lucide-settings": "gearshape",
    ]
}

/// Folder logos, read once and kept until the file changes. An SVG stays a
/// drawing, so it is sharp at every size.
@MainActor
enum Logo {
    private static var cache: [URL: (modified: Date, image: NSImage?)] = [:]

    static func image(_ url: URL) -> NSImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if let known = cache[url], known.modified == modified { return known.image }
        let image = NSImage(contentsOf: url).flatMap { $0.size.width > 0 && $0.size.height > 0 ? $0 : nil }
        cache[url] = (modified, image)
        return image
    }
}
