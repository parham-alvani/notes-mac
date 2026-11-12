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
    /// A folder's `logo.svg` or picture, by its vault path, which wins over any other icon.
    var logo: String?

    var body: some View {
        Group {
            if let logo {
                LogoImage(path: logo, cornerRadius: 3, placeholder: AnyView(symbol))
            } else {
                symbol
            }
        }
        // The same square for every icon: wide symbols (a house, masks)
        // shrink into it instead of pushing the name aside.
        .frame(width: Self.slot, height: Self.slot)
    }

    @ViewBuilder private var symbol: some View {
        Group {
            if let name = icon?.name, icon?.isEmoji == true {
                Text(name).font(.system(size: 12))
            } else {
                // A Lucide name with no symbol here draws the default, not a gap.
                Image(systemName: icon?.name.flatMap { Self.symbols[$0] }.flatMap(Self.known) ?? fallback)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(icon?.color.flatMap(Self.color) ?? fallbackColor)
            }
        }
    }

    static let slot: CGFloat = 18

    /// Whether each symbol exists, asked of AppKit once: every row of the tree asks at each drawing.
    private static var knownSymbols: [String: Bool] = [:]

    static func known(_ symbol: String) -> String? {
        if let known = knownSymbols[symbol] { return known ? symbol : nil }
        let exists = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
        knownSymbols[symbol] = exists
        return exists ? symbol : nil
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
        // More of Lucide's common ones, for the icon picker.
        "lucide-archive": "archivebox", "lucide-award": "rosette", "lucide-baby": "figure.and.child.holdinghands",
        "lucide-bell": "bell", "lucide-bike": "bicycle", "lucide-bookmark": "bookmark", "lucide-bot": "cpu",
        "lucide-box": "shippingbox", "lucide-bug": "ant", "lucide-cake": "birthday.cake", "lucide-calculator": "plus.forwardslash.minus",
        "lucide-camera": "camera", "lucide-check": "checkmark", "lucide-clipboard": "clipboard", "lucide-clock": "clock",
        "lucide-cloud": "cloud", "lucide-coffee": "cup.and.saucer", "lucide-coins": "dollarsign.circle", "lucide-compass": "safari",
        "lucide-cpu": "cpu", "lucide-credit-card": "creditcard", "lucide-dumbbell": "dumbbell", "lucide-film": "film",
        "lucide-flag": "flag", "lucide-flask-conical": "flask", "lucide-folder-open": "folder.badge.gearshape", "lucide-gamepad-2": "gamecontroller",
        "lucide-gift": "gift", "lucide-git-branch": "arrow.triangle.branch", "lucide-hammer": "hammer", "lucide-headphones": "headphones",
        "lucide-hospital": "cross.case", "lucide-inbox": "tray", "lucide-key": "key", "lucide-languages": "character.bubble",
        "lucide-leaf": "leaf", "lucide-lightbulb": "lightbulb", "lucide-link": "link", "lucide-list": "list.bullet",
        "lucide-list-todo": "checklist", "lucide-megaphone": "megaphone", "lucide-message-circle": "message", "lucide-mic": "mic",
        "lucide-monitor": "display", "lucide-mountain": "mountain.2", "lucide-newspaper": "newspaper", "lucide-notebook": "book.pages",
        "lucide-package": "shippingbox", "lucide-palette": "paintpalette", "lucide-paperclip": "paperclip", "lucide-pen": "pencil",
        "lucide-phone": "phone", "lucide-pill": "pills", "lucide-pin": "pin", "lucide-rocket": "airplane.departure",
        "lucide-scale": "scalemass", "lucide-school": "building", "lucide-search": "magnifyingglass", "lucide-server": "server.rack",
        "lucide-shield": "shield", "lucide-ship": "ferry", "lucide-shirt": "tshirt", "lucide-smartphone": "iphone",
        "lucide-sparkles": "sparkles", "lucide-sprout": "leaf.arrow.triangle.circlepath", "lucide-stethoscope": "stethoscope",
        "lucide-swords": "shield.lefthalf.filled", "lucide-tag": "tag", "lucide-target": "target", "lucide-tent": "tent",
        "lucide-thumbs-up": "hand.thumbsup", "lucide-trash-2": "trash", "lucide-trending-up": "chart.line.uptrend.xyaxis",
        "lucide-trophy": "trophy", "lucide-umbrella": "umbrella", "lucide-wallet": "wallet.bifold", "lucide-waves": "water.waves",
        "lucide-wifi": "wifi", "lucide-zap": "bolt",
    ]
}

/// Folder logos, read off the main thread once and kept until the file
/// changes. An SVG stays a drawing, so it is sharp at every size; a picture
/// is decoded at the size it is drawn (no more than [pixels] across), not
/// at the size of the file. Expanding `Companies/` asked the disk for every
/// logo's date, and decoded every new one, on the main thread.
@MainActor @Observable
final class Logo {
    static let shared = Logo()

    /// Grows when a logo file changed, so the views showing one ask again.
    private(set) var generation = 0
    @ObservationIgnored private var cache: [String: NSImage?] = [:]
    @ObservationIgnored private var loading: [String: Task<Decoded, Never>] = [:]

    /// An image made off the main thread and not touched there again until it is handed over.
    struct Decoded: @unchecked Sendable {
        var image: NSImage?
    }

    /// The largest side a picture is decoded to: a 26-point card logo on a
    /// Retina screen, with room.
    nonisolated static let pixels = 96

    private static func key(_ path: String, _ root: URL) -> String { root.path + "\u{0}" + path }

    /// The logo at the vault path [path], if it was read already.
    func cached(_ path: String, in root: URL) -> NSImage?? { cache[Self.key(path, root)] }

    /// The logo at the vault path [path], read off the main thread the first time.
    func image(_ path: String, in root: URL) async -> NSImage? {
        let key = Self.key(path, root)
        if let known = cache[key] { return known }
        let task = loading[key] ?? Task.detached(priority: .userInitiated) { Decoded(image: Self.decode(path, in: root)) }
        loading[key] = task
        let image = await task.value.image
        // A change while it was read leaves it out of the cache: it is read again.
        if loading[key] == task {
            loading[key] = nil
            cache[key] = .some(image)
        }
        return image
    }

    /// The logos among [paths] changed on disk: read again when next shown.
    func forget(_ paths: Set<String>) {
        let names = Set(Vault.logoNames)
        let logos = paths.filter { names.contains(($0.split(separator: "/").last.map(String.init) ?? "").lowercased()) }
        guard !logos.isEmpty else { return }
        let suffixes = logos.map { "\u{0}" + $0 }
        for key in Array(cache.keys) + Array(loading.keys) where suffixes.contains(where: key.hasSuffix) {
            cache[key] = nil
            loading[key] = nil
        }
        generation += 1
    }

    nonisolated static func decode(_ path: String, in root: URL) -> NSImage? {
        guard let url = VaultStore.file(path, in: root) else { return nil }
        if url.pathExtension.lowercased() == "svg" {
            return NSImage(contentsOf: url).flatMap { $0.size.width > 0 && $0.size.height > 0 ? $0 : nil }
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
            ] as CFDictionary)
        else { return nil }
        // The point size is the pixel size halved: the frame scales it anyway.
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
    }
}

/// A folder's logo by its vault path: what is known at once, the rest when it is read.
struct LogoImage: View {
    var path: String
    var cornerRadius: CGFloat
    /// Drawn while the logo is read, and when it cannot be.
    var placeholder: AnyView
    @Environment(VaultStore.self) private var store
    @ViewState private var loaded: (path: String, generation: Int, image: NSImage?)?

    var body: some View {
        let logos = Logo.shared
        let generation = logos.generation
        let image: NSImage?? = store.root.flatMap { logos.cached(path, in: $0) }
            ?? loaded.flatMap { $0.path == path && $0.generation == generation ? .some($0.image) : nil }
        Group {
            if let image = image ?? nil {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                placeholder
            }
        }
        .task(id: "\(path)\u{0}\(generation)") {
            guard image == nil, let root = store.root else { return }
            let found = await logos.image(path, in: root)
            loaded = (path, generation, found)
        }
    }
}
