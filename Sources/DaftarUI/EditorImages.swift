import AppKit
import DaftarCore

extension NSAttributedString.Key {
    /// On the line of an image embed: the image to draw under it.
    static let daftarImage = NSAttributedString.Key("DaftarImage")
}

/// An image the editor draws under the line that embeds it.
final class EmbeddedImage: NSObject {
    let image: NSImage
    let size: NSSize

    init(image: NSImage, size: NSSize) {
        self.image = image
        self.size = size
    }

    static let gap: CGFloat = 8
}

/// A paragraph with an image embed: its text as usual, then the image in the
/// space the paragraph style leaves after it. The text is never changed, so
/// the cursor, undo and the saved file see only `![[name.png]]`.
final class ImageLayoutFragment: NSTextLayoutFragment {
    var embedded: EmbeddedImage?

    private var imageFrame: CGRect {
        guard let embedded else { return .zero }
        let bottom = textLineFragments.last.map { $0.typographicBounds.maxY } ?? 0
        return CGRect(origin: CGPoint(x: 0, y: bottom + EmbeddedImage.gap), size: embedded.size)
    }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(imageFrame)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        guard let embedded else { return }
        let frame = imageFrame.offsetBy(dx: point.x, dy: point.y)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).addClip()
        embedded.image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}

extension EditorController: NSTextLayoutManagerDelegate {
    nonisolated func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let fragment = ImageLayoutFragment(textElement: textElement, range: textElement.elementRange)
        if let paragraph = textElement as? NSTextParagraph {
            let text = paragraph.attributedString
            text.enumerateAttribute(.daftarImage, in: NSRange(location: 0, length: text.length)) { value, _, stop in
                if let image = value as? EmbeddedImage {
                    fragment.embedded = image
                    stop.pointee = true
                }
            }
        }
        return fragment
    }
}
