import AppKit
import DaftarCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// What a pane with no note shows: the time, a greeting, a search that opens
/// a note, the notes read last, the bookmarks and a quote, in glass cards
/// over the person's picture. It replaces Obsidian's Beautitab new tab and
/// follows its settings in the vault; the picture is `home.image` in the
/// config file. In a split window each empty pane shows a smaller one.
struct HomeView: View {
    var model: WindowModel
    var pane: NotePane
    /// A pane of a split window: the time, the search and fewer notes.
    var compact = false
    @Environment(VaultStore.self) private var store
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewState private var query = ""
    /// Picked each time the page appears.
    @ViewState private var quote: Beautitab.Quote?

    private var settings: Beautitab { store.beautitab }

    /// The picture: the config file's, else Beautitab's own when it is a file.
    var pictureURL: URL? {
        if !store.settings.homeImage.isEmpty { return Home.pictureURL(store.settings.homeImage, vault: store.root) }
        return settings.backgrounds.lazy.compactMap { Home.pictureURL($0, vault: store.root) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    var body: some View {
        let picture = pictureURL
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: compact ? 14 : 22) {
                    if settings.showTime || settings.showGreeting { clock }
                    if settings.showSearch { search }
                    lists
                    if settings.showQuote, !compact, let quote { quoteCard(quote) }
                }
                .frame(maxWidth: compact ? 360 : 560)
                .padding(compact ? 16 : 40)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background {
            ZStack {
                Palette.background
                if let picture {
                    HomePicture(url: picture)
                    scrim
                }
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
        }
        .onAppear {
            store.refreshBeautitab()
            quote = store.beautitab.quotes.randomElement()
        }
    }

    /// The page's own colour, thin at the top and thick at the bottom, so
    /// the text reads on any picture in either palette; thicker with Reduce
    /// Transparency or Increase Contrast.
    private var scrim: some View {
        let strong = reduceTransparency || contrast == .increased
        return LinearGradient(
            colors: strong ? [Palette.background.opacity(0.6), Palette.background.opacity(0.85)]
                : [Palette.background.opacity(0.15), Palette.background.opacity(0.3), Palette.background.opacity(0.6)],
            startPoint: .top, endPoint: .bottom)
    }

    // MARK: The time and the greeting

    private var clock: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: 4) {
                if settings.showTime {
                    Text(Self.time(context.date, twentyFourHour: settings.twentyFourHour))
                        .font(.system(size: compact ? 48 : 88, weight: .light, design: .rounded))
                        .monospacedDigit()
                    Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(compact ? .callout : .title3)
                        .foregroundStyle(.secondary)
                }
                if settings.showGreeting {
                    Text(Home.greeting(settings.greetingText, hour: Calendar.current.component(.hour, from: context.date)))
                        .font(compact ? .title3 : .title)
                        .fontWeight(.medium)
                        .padding(.top, settings.showTime ? 8 : 0)
                }
            }
            .multilineTextAlignment(.center)
            .shadow(color: Palette.background.opacity(0.7), radius: 10)
            .accessibilityElement(children: .combine)
        }
    }

    /// The hour as Beautitab's setting asks, or as the system does.
    static func time(_ date: Date, twentyFourHour: Bool?) -> String {
        guard let twentyFourHour else { return date.formatted(date: .omitted, time: .shortened) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = twentyFourHour ? "HH:mm" : "h:mm a"
        return formatter.string(from: date)
    }

    // MARK: Search

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Search notes", text: $query, prompt: Text("Find a note"))
                .textFieldStyle(.plain)
                .onSubmit(openBest)
                .accessibilityLabel("Find a note")
            Text("⌘P").font(.callout.monospaced()).faint().accessibilityHidden(true)
        }
        .font(compact ? .body : .title3)
        .padding(.horizontal, 16)
        .padding(.vertical, compact ? 8 : 11)
        .glassEffect(.regular, in: .capsule)
        .help("Return opens the best match; an empty field opens Quick Open")
    }

    /// Return opens the note quick open ranks first, in this pane; with no
    /// text, or no match, quick open takes over with the text.
    private func openBest() {
        let text = query.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty, let best = store.quickOpen(text, recent: model.recent, limit: 1).first {
            query = ""
            model.open(best, in: pane, store: store)
            return
        }
        model.focus(pane)
        model.openSwitcher()
        model.switcherQuery = text
    }

    // MARK: Recent notes and bookmarks

    private var recent: [String] {
        guard settings.showRecentFiles else { return [] }
        return Home.recent(
            opened: model.recent, read: store.places.recentlyRead(40),
            exists: { store.index.files.contains($0) && !store.excluded.contains($0) }, limit: compact ? 5 : 8)
    }

    private var bookmarked: [String] {
        guard settings.showBookmarks, !compact else { return [] }
        return store.bookmarks.entries.filter { !$0.folder && store.index.files.contains($0.path) }.prefix(8).map(\.path)
    }

    @ViewBuilder private var lists: some View {
        let recent = recent, bookmarked = bookmarked
        if !recent.isEmpty || !bookmarked.isEmpty {
            HStack(alignment: .top, spacing: 16) {
                if !recent.isEmpty { noteList("Recent", icon: "clock", paths: recent) }
                if !bookmarked.isEmpty { noteList("Bookmarks", icon: "bookmark", paths: bookmarked) }
            }
        }
    }

    private func noteList(_ title: String, icon: String, paths: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(paths, id: \.self) { path in
                HomeNoteRow(path: path) { model.open(path, in: pane, store: store) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    // MARK: Quote

    private func quoteCard(_ quote: Beautitab.Quote) -> some View {
        VStack(spacing: 6) {
            // Each line in its own direction: in a left-to-right line, the
            // marks of a Persian quote land at the wrong ends. Persian has
            // no italic, so it stays upright.
            Text(quote.quoted).font(.title3).italic(!quote.isRtl)
                .environment(\.layoutDirection, quote.isRtl ? .rightToLeft : .leftToRight)
            if !quote.author.isEmpty {
                Text("— " + quote.author).font(.callout).foregroundStyle(.secondary)
                    .environment(\.layoutDirection, TextDirection.startsRtl(quote.author) ? .rightToLeft : .leftToRight)
            }
        }
        .multilineTextAlignment(.center)
        .padding(18)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }
}

/// A note in a list of the home page: its name, and its folder faint after it.
private struct HomeNoteRow: View {
    var path: String
    var action: () -> Void
    @ViewState private var hover = false

    var body: some View {
        let folder = (path as NSString).deletingLastPathComponent
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: path.hasSuffix(".md") ? "doc.text" : "doc").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(Vault.title(of: path)).lineLimit(1)
                if !folder.isEmpty { Text(folder).lineLimit(1).truncationMode(.head).faint() }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(hover ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(path)
        .accessibilityLabel(folder.isEmpty ? Vault.title(of: path) : "\(Vault.title(of: path)), in \(folder)")
    }
}

/// The home picture, filling its frame and cropped (aspect fill). It is
/// decoded once, off the main thread, and kept (`HomePictures`).
struct HomePicture: View {
    var url: URL
    @ViewState private var loaded: (url: URL, image: NSImage)?

    var body: some View {
        let image = loaded?.url == url ? loaded?.image : HomePictures.shared.cached(url)
        Color.clear
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
                }
            }
            .clipped()
            .task(id: url) { loaded = await HomePictures.shared.image(url).map { (url, $0) } }
            .accessibilityHidden(true)
    }
}

/// The decoded home pictures, by file, so a redraw never decodes one again.
/// A file changed on disk is decoded again.
@MainActor
final class HomePictures {
    static let shared = HomePictures()

    /// About a 5K screen's width: the picture is drawn no larger.
    nonisolated static let maxPixels = 5120

    private var images: [String: (stamp: Date?, image: NSImage)] = [:]
    private var loading: [String: Task<CGImage?, Never>] = [:]

    /// The picture of [url] if it was decoded already.
    func cached(_ url: URL) -> NSImage? { images[url.path]?.image }

    /// The picture of [url], decoded now unless it is kept and unchanged.
    func image(_ url: URL) async -> NSImage? {
        let path = url.path
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let kept = images[path], kept.stamp == stamp { return kept.image }
        let task = loading[path] ?? Task.detached(priority: .userInitiated) { Self.decode(url) }
        loading[path] = task
        let decoded = await task.value
        loading[path] = nil
        guard let decoded else {
            images[path] = nil
            return nil
        }
        let image = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
        // One picture is in use at a time; a few are kept for the Settings preview.
        if images.count > 4 { images.removeAll() }
        images[path] = (stamp, image)
        return image
    }

    /// PNG, JPEG, HEIC, WebP and every other format ImageIO reads, turned
    /// as its EXIF says, no larger than [maxPixels] on its long side.
    nonisolated static func decode(_ url: URL, maxPixels: Int = maxPixels) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Settings › Home: the picture, chosen in a panel or cleared.
struct HomeSettings: View {
    @Environment(VaultStore.self) private var store

    var body: some View {
        @Bindable var settings = store.settings
        let url = Home.pictureURL(settings.homeImage, vault: store.root)
        let missing = url.map { !FileManager.default.fileExists(atPath: $0.path) } ?? !settings.homeImage.isEmpty
        Form {
            Section {
                LabeledContent("Picture") {
                    HStack(spacing: 10) {
                        ZStack {
                            Palette.background
                            if let url, !missing { HomePicture(url: url) }
                        }
                        .frame(width: 96, height: 60)
                        .clipShape(.rect(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(settings.homeImage.isEmpty ? "None" : settings.homeImage)
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            if missing { Text("Not found").font(.caption).foregroundStyle(Palette.red) }
                        }
                        Spacer(minLength: 0)
                        Button("Choose…") { choose() }
                        Button("Clear") { settings.homeImage = "" }
                            .disabled(settings.homeImage.isEmpty)
                    }
                }
            } footer: {
                Text("The picture fills the page a window or a pane shows with no note open. PNG, JPEG, HEIC or WebP. A picture in the vault is kept as its path in the vault. The time, the greeting, the lists and the quotes follow the Beautitab plugin's settings in the vault.")
            }
        }
        .formStyle(.grouped)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP, .image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.settings.homeImage = store.vaultPath(of: url) ?? (url.path as NSString).abbreviatingWithTildeInPath
    }
}
