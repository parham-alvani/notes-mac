import Foundation
import JavaScriptCore

/// Finder's Quick Look preview of a note: the reader's own renderer
/// (`web/src/quicklook.js`) in JavaScriptCore, because Quick Look shows an
/// HTML page without running its scripts. The extension gives the result
/// to Quick Look with the vault's pictures as attachments.
public enum QuickLookPreview {
    /// A finished preview: the page, and the files its `cid:` addresses name.
    public struct Page: Sendable {
        public var html: String
        public var attachments: [String: URL]
    }

    /// The vault a note is in: the nearest folder above it that has
    /// `.obsidian`, or nil for a note outside any vault.
    public static func vaultRoot(of note: URL) -> URL? {
        var at = note.deletingLastPathComponent().standardizedFileURL
        while at.path != "/" {
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: at.appendingPathComponent(".obsidian").path, isDirectory: &isFolder), isFolder.boolValue {
                return at
            }
            at = at.deletingLastPathComponent()
        }
        return nil
    }

    /// The files a note's links can name: the whole vault, or only the
    /// note's own folder when it is not in a vault -- a note in Downloads
    /// must not scan the home folder.
    public static func files(in root: URL, isVault: Bool) -> Set<String> {
        if isVault { return Vault.scan(root) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return Set(names.filter { !$0.hasPrefix(".") }.map(Slugs.normalize))
    }

    /// Each wikilink target of the note resolved to a vault path, as the app
    /// resolves them. Links are only drawn: nothing in a preview follows one.
    public static func links(in parsed: ParsedNote, from path: String, files: some Collection<String>) -> [String: String] {
        let resolver = LinkResolver(paths: files)
        var out: [String: String] = [:]
        for link in parsed.links where out[link.target] == nil {
            if let found = resolver.resolve(link.target, from: path) { out[link.target] = found }
        }
        return out
    }

    /// The note as JSON for `daftarPreview`: what `ReaderView` sends the page.
    public static func input(text: String, path: String, links: [String: String]) -> String {
        let parsed = NoteParser.parse(text)
        let note: [String: Any] = [
            "title": Vault.title(of: path),
            "text": text,
            "path": path,
            "links": links,
            "properties": parsed.properties.filter { !Vault.hiddenProperties.contains($0.key) }
                .map { [$0.key, $0.values.joined(separator: ", ")] },
        ]
        let data = (try? JSONSerialization.data(withJSONObject: note)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated(unsafe) private static let source = /(<(?:img|video|audio|source|iframe)\b[^>]*?\ssrc=")([^"]*)(")/

    /// Each `src` of [body] that names a file of the vault -- `vault:///a.png`,
    /// or a path relative to the note -- becomes a `cid:` attachment. A file
    /// outside the vault, or one that is missing, is left as it was and does
    /// not load.
    public static func attach(_ body: String, root: URL, path: String) -> Page {
        let root = root.standardizedFileURL
        let folder = (path as NSString).deletingLastPathComponent
        var attachments: [String: URL] = [:]
        var named: [URL: String] = [:]
        let html = body.replacing(source) { match -> String in
            let (_, open, address, close) = match.output
            let whole = String(open) + address + String(close)
            let decoded = String(address).replacingOccurrences(of: "&amp;", with: "&")
            let vaultPath: String
            if decoded.hasPrefix("vault:///") {
                vaultPath = String(decoded.dropFirst("vault:///".count)).removingPercentEncoding ?? ""
            } else if !decoded.contains(":"), !decoded.hasPrefix("/"), !decoded.isEmpty {
                let plain = decoded.split(separator: "#").first.map(String.init) ?? decoded
                vaultPath = (folder as NSString).appendingPathComponent(plain.removingPercentEncoding ?? plain)
            } else {
                return whole
            }
            let file = root.appendingPathComponent(vaultPath).standardizedFileURL
            guard !vaultPath.isEmpty, file.path.hasPrefix(root.path + "/"), FileManager.default.isReadableFile(atPath: file.path) else {
                return whole
            }
            let name = named[file] ?? "file\(attachments.count)"
            named[file] = name
            attachments[name] = file
            return String(open) + "cid:" + name + String(close)
        }
        return Page(html: html, attachments: attachments)
    }

    /// The whole page: the reader's styles, then the note in `#note`, as in
    /// the reader's `index.html`. The colours follow the system appearance.
    public static func document(body: String, styles: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <style>
        \(styles)
        </style>
        </head>
        <body>
        <main id="note">
        \(body)
        </main>
        </body>
        </html>
        """
    }

    /// Runs `quicklook.js`. One renderer answers one note at a time.
    public final class Renderer {
        private let context: JSContext
        private let render: JSValue

        /// Nil when the script does not load or has no `daftarPreview`.
        public init?(script: String) {
            guard let context = JSContext() else { return nil }
            context.evaluateScript(script)
            guard context.exception == nil, let render = context.objectForKeyedSubscript("daftarPreview"), render.isObject else { return nil }
            self.context = context
            self.render = render
        }

        /// The note's HTML, or nil when the renderer threw.
        public func html(_ input: String) -> String? {
            context.exception = nil
            let result = render.call(withArguments: [input])
            guard context.exception == nil, let result, result.isString else { return nil }
            return result.toString()
        }
    }

    /// The preview of the note at [note]: its text rendered as the reader
    /// draws it, with the pictures it embeds from its vault.
    public static func page(of note: URL, renderer: Renderer, styles: String) throws -> Page {
        let text = try String(contentsOf: note, encoding: .utf8)
        let vault = vaultRoot(of: note)
        let root = vault ?? note.deletingLastPathComponent().standardizedFileURL
        let path = String(note.standardizedFileURL.path.dropFirst(root.path.count + 1))
        let parsed = NoteParser.parse(text)
        // Scanning a vault takes a moment; a note without links needs none.
        let files = parsed.links.isEmpty ? [] : files(in: root, isVault: vault != nil)
        let body = renderer.html(input(text: text, path: path, links: links(in: parsed, from: path, files: files)))
            ?? "<pre>\(text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;"))</pre>"
        var page = attach(body, root: root, path: path)
        page.html = document(body: page.html, styles: styles)
        return page
    }
}
