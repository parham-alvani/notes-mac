import AppKit
import DaftarCore
import ImageIO

extension NSAttributedString.Key {
    /// On the line of an image embed: the image to draw under it.
    static let daftarImage = NSAttributedString.Key("DaftarImage")
}

/// An image the editor draws under the line that embeds it.
final class EmbeddedImage: NSObject {
    let image: NSImage
    let size: NSSize
    /// The frames of an animated GIF, WebP or PNG; `ImageAnimator` moves them on.
    let animation: ImageAnimation?

    init(image: NSImage, size: NSSize, animation: ImageAnimation? = nil) {
        self.image = image
        self.size = size
        self.animation = animation
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
        // An animation draws its current frame; NSImage draws only the first.
        let image = embedded.animation?.image().map { NSImage(cgImage: $0, size: .zero) } ?? embedded.image
        image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
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

/// The frames of an animated picture and how long each one shows, read
/// with ImageIO. A frame is decoded when it is first drawn; a small
/// animation keeps its frames, a large one decodes each as it comes.
final class ImageAnimation {
    private let source: CGImageSource
    let delays: [Double]
    let duration: Double
    /// The frame on screen.
    var frame = 0
    private var frames: [Int: CGImage] = [:]
    private let keepsFrames: Bool

    /// Nil for a still picture, or one of more than 1,000 frames.
    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1, count <= 1000 else { return nil }
        self.source = source
        delays = (0..<count).map { Self.delay(of: source, at: $0) }
        duration = delays.reduce(0, +)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixels = (properties?[kCGImagePropertyPixelWidth] as? Int ?? 0) * (properties?[kCGImagePropertyPixelHeight] as? Int ?? 0)
        keepsFrames = pixels * 4 * count <= 64 << 20
    }

    /// A frame's time, as browsers read it: a delay under 11 ms is 100 ms.
    static func delay(of source: CGImageSource, at index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let kinds: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ]
        for (dictionary, unclamped, clamped) in kinds {
            guard let values = properties[dictionary] as? [CFString: Any] else { continue }
            let delay = (values[unclamped] as? Double) ?? (values[clamped] as? Double) ?? 0
            return delay < 0.011 ? 0.1 : delay
        }
        return 0.1
    }

    /// The frame that shows [time] seconds after the animation began; it loops.
    func frame(at time: Double) -> Int {
        guard duration > 0 else { return 0 }
        var left = time.truncatingRemainder(dividingBy: duration)
        for (index, delay) in delays.enumerated() {
            if left < delay { return index }
            left -= delay
        }
        return delays.count - 1
    }

    /// The current frame's pixels.
    func image() -> CGImage? {
        if let kept = frames[frame] { return kept }
        guard let image = CGImageSourceCreateImageAtIndex(source, frame, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        if keepsFrames { frames[frame] = image }
        return image
    }
}

/// Moves the editor's animated pictures on, about 30 times a second, while
/// the window is on screen: each frame that changed draws its line again.
/// Nothing moves with Reduce Motion; the first frame stays.
@MainActor
final class ImageAnimator {
    weak var view: NSTextView?
    private var animations: [String: ImageAnimation] = [:]
    private var stills: Set<String> = []
    private var timer: Timer?
    private let start = Date()

    /// The animation of the picture at [path], or nil for a still one.
    func animation(for path: String, url: URL) -> ImageAnimation? {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, !stills.contains(path) else { return nil }
        if let found = animations[path] { return found }
        guard let made = ImageAnimation(url: url) else {
            stills.insert(path)
            return nil
        }
        animations[path] = made
        run()
        return made
    }

    private func run() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            // The timer is on the main run loop.
            MainActor.assumeIsolated { self.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func tick() {
        guard let view, view.window?.occlusionState.contains(.visible) == true else { return }
        advance(to: Date().timeIntervalSince(start))
    }

    /// Each animation to its frame at [time]; the lines on screen whose frame changed draw again.
    func advance(to time: Double) {
        var moved = Set<ObjectIdentifier>()
        for animation in animations.values {
            let frame = animation.frame(at: time)
            if frame != animation.frame {
                animation.frame = frame
                moved.insert(ObjectIdentifier(animation))
            }
        }
        guard !moved.isEmpty, let view, let storage = view.textStorage, let layout = view.textLayoutManager,
            let content = layout.textContentManager
        else { return }
        let document = content.documentRange.location
        var shown = NSRange(location: 0, length: storage.length)
        if let viewport = layout.textViewportLayoutController.viewportRange {
            let from = content.offset(from: document, to: viewport.location)
            shown = NSIntersectionRange(shown, NSRange(location: from, length: content.offset(from: viewport.location, to: viewport.endLocation)))
        }
        let origin = view.textContainerOrigin
        storage.enumerateAttribute(.daftarImage, in: shown) { value, range, _ in
            guard let image = value as? EmbeddedImage, let animation = image.animation, moved.contains(ObjectIdentifier(animation)),
                let from = content.location(document, offsetBy: range.location),
                let to = content.location(from, offsetBy: range.length), let textRange = NSTextRange(location: from, end: to)
            else { return }
            layout.invalidateRenderingAttributes(for: textRange)
            layout.enumerateTextLayoutFragments(from: from, options: [.ensuresLayout]) { fragment in
                let frame = fragment.renderingSurfaceBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX + origin.x, dy: fragment.layoutFragmentFrame.minY + origin.y)
                view.setNeedsDisplay(frame)
                return false
            }
        }
    }
}
