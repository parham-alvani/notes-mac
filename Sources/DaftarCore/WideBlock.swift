import Foundation

/// A table, a code block or a picture wider than the measure grows past it,
/// up to `appearance.block_width` em, centred in the pane
/// (`docs/specs/wide-blocks.md` in notes-linux). The reader does the same in
/// CSS (`[data-wide]` in `web/src/reader.css`): change one, change the other.
public enum WideBlock {
    /// Where a wide block is drawn: its width, and its start from the pane's left edge.
    public struct Place: Equatable, Sendable {
        public let width: Double
        public let offset: Double

        public init(width: Double, offset: Double) {
            self.width = width
            self.offset = offset
        }
    }

    /// The place of a block [natural] wide, in a pane [pane] wide that keeps
    /// [room] at each side, with the measure [measure] and the limit [limit]
    /// (`block_width` em), all in the same unit. Nil when the block keeps the
    /// measure: it fits, the limit is off (0, or no wider than the measure),
    /// there is no measure, or the pane has no room past it.
    public static func place(natural: Double, measure: Double, pane: Double, room: Double, limit: Double) -> Place? {
        guard measure > 0, limit > 0, natural > measure else { return nil }
        let widest = min(limit, pane - 2 * room)
        guard widest > measure else { return nil }
        let width = min(natural, widest)
        return Place(width: width, offset: (pane - width) / 2)
    }
}
