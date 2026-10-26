import DaftarCore
import Foundation
import QuickLookUI
import UniformTypeIdentifiers

/// Finder's space bar on a note: the note as Daftar's reader draws it.
/// The extension's Resources hold `quicklook.js` and the reader's styles,
/// copied in by `just app`.
@objc(DaftarPreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let script = try String(contentsOf: resources.appendingPathComponent("quicklook.js"), encoding: .utf8)
        let styles = try ["reader.css", "tasks.css", "callouts.css"]
            .map { try String(contentsOf: resources.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
        guard let renderer = QuickLookPreview.Renderer(script: script) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let page = try QuickLookPreview.page(of: request.fileURL, renderer: renderer, styles: styles)
        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 820, height: 1000)) { reply in
            reply.stringEncoding = .utf8
            reply.attachments = page.attachments.compactMapValues { file in
                guard let data = try? Data(contentsOf: file) else { return nil }
                let type = UTType(filenameExtension: file.pathExtension) ?? .data
                return QLPreviewReplyAttachment(data: data, contentType: type)
            }
            return Data(page.html.utf8)
        }
        reply.title = request.fileURL.deletingPathExtension().lastPathComponent
        return reply
    }
}
