import AppKit
import DaftarCore

/// What the audit found, in the editor's margin: a small dot beside each
/// line with a problem, red for an error and yellow for a warning, and its
/// messages on hover. The marks are of the file as the audit read it; the
/// next audit, a moment after a save, moves them with the text. The text,
/// its attributes and undo never change for them.
extension NoteTextView {
    /// The audit's findings of the note on screen, drawn again when they change.
    func show(problems: [Int: [Problem]]) {
        guard problems != problemMarks else { return }
        problemMarks = problems
        showProblemTips()
        setNeedsDisplay(visibleRect)
    }

    /// Where the dots go: left of the text, and of a quote's bar.
    var problemMarkX: CGFloat {
        max(1, textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0) - 20)
    }

    /// One tooltip for the whole margin, which asks for the line under the pointer.
    func showProblemTips() {
        if let problemTip { removeToolTip(problemTip) }
        problemTip = nil
        guard !problemMarks.isEmpty else { return }
        let width = max(0, textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0) - 4)
        problemTip = addToolTip(NSRect(x: 0, y: 0, width: width, height: max(bounds.height, 1e6)), owner: problemTips, userData: nil)
    }

    /// The dots of the lines on screen.
    func drawProblemMarks(in rect: NSRect) {
        guard !problemMarks.isEmpty, let storage = textStorage, storage.length > 0, let viewport = viewportOffsets() else { return }
        let text = storage.string as NSString
        let end = NSMaxRange(viewport)
        var offset = text.lineRange(for: NSRange(location: viewport.location, length: 0)).location
        var line = line(of: offset, in: text)
        let x = problemMarkX
        while offset <= end {
            if let marks = problemMarks[line], let row = lineRect(at: offset) {
                let dot = NSRect(x: x, y: row.minY + min(row.height, 22) / 2 - 3, width: 6, height: 6)
                if dot.intersects(rect) {
                    (marks.contains { $0.level == .error } ? NSPalette.named("red") : NSPalette.named("yellow")).setFill()
                    NSBezierPath(ovalIn: dot).fill()
                }
            }
            guard offset < text.length else { break }
            offset = NSMaxRange(text.lineRange(for: NSRange(location: offset, length: 0)))
            line += 1
        }
    }

    /// The source line of the line start [offset]: the lines counted from
    /// the place asked last, while the text is the same, not from the top
    /// of the note at every frame of a scroll.
    private func line(of offset: Int, in text: NSString) -> Int {
        let generation = controller?.textGeneration ?? -1
        var line: Int
        if let last = problemLine, last.generation == generation, generation >= 0, last.offset <= text.length {
            let low = min(last.offset, offset), high = max(last.offset, offset)
            let between = EditorController.newlines(in: NSRange(location: low, length: high - low), of: text)
            line = offset >= last.offset ? last.line + between : last.line - between
        } else {
            line = EditorController.line(of: offset, in: text)
        }
        problemLine = (generation, offset, line)
        return line
    }

    /// The messages of the line at [point], one a line.
    func problemText(at point: NSPoint) -> String {
        let offset = characterIndexForInsertion(at: NSPoint(x: textContainerOrigin.x + 4, y: point.y))
        guard offset != NSNotFound else { return "" }
        let line = EditorController.line(of: offset, in: string as NSString)
        return (problemMarks[line] ?? []).map { "\($0.level == .error ? "Error" : "Warning"): \($0.message) (\($0.code))" }.joined(separator: "\n")
    }
}

/// Answers the margin's tooltip for its view: AppKit keeps its owner weakly.
final class ProblemTips: NSObject, NSViewToolTipOwner {
    weak var view: NoteTextView?

    init(view: NoteTextView) { self.view = view }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        MainActor.assumeIsolated { self.view?.problemText(at: point) ?? "" }
    }
}
