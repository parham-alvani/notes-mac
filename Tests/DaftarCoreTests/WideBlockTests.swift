import Foundation
import Testing

@testable import DaftarCore

/// `docs/specs/wide-blocks.md` in notes-linux, section 5: the text size 16,
/// `text_width = 35` (560), 40 of room at each side and `block_width = 60` (960).
struct WideBlockTests {
    func place(_ natural: Double, pane: Double, measure: Double = 560, limit: Double = 960) -> WideBlock.Place? {
        WideBlock.place(natural: natural, measure: measure, pane: pane, room: 40, limit: limit)
    }

    @Test func aBlockThatFitsKeepsTheMeasure() {
        #expect(place(500, pane: 1400) == nil)
        #expect(place(560, pane: 1400) == nil)
    }

    @Test func aWideBlockGrowsToItsOwnWidth() {
        #expect(place(800, pane: 1400) == WideBlock.Place(width: 800, offset: 300))
    }

    @Test func theLimitIsTheSettingOrThePane() {
        #expect(place(1200, pane: 1400) == WideBlock.Place(width: 960, offset: 220))
        #expect(place(1200, pane: 900) == WideBlock.Place(width: 820, offset: 40))
    }

    @Test func aNarrowPaneKeepsTheMeasure() {
        #expect(place(800, pane: 600) == nil)
    }

    @Test func blockWidthZeroIsOff() {
        for natural in [100.0, 800, 5000] {
            #expect(place(natural, pane: 1400, limit: 0) == nil)
            #expect(place(natural, pane: 1400, measure: 0) == nil)
        }
        // A limit no wider than the measure acts as 0.
        #expect(place(800, pane: 1400, limit: 400) == nil)
    }
}
