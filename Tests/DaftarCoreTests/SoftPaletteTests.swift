import Foundation
import Testing

@testable import DaftarCore

/// The values are those of `:root[data-palette="soft"]` in `web/src/reader.css`.
struct SoftPaletteTests {
    @Test func softensNazAsTheReaderDoes() {
        #expect(SoftPalette.soften(0xFFB040) == 0xE9B87D)  // accent
        #expect(SoftPalette.soften(0xFFFF88) == 0xE3E499)  // heading 2
        #expect(SoftPalette.soften(0x60D8FF) == 0x7DD5F4)  // heading 3
        #expect(SoftPalette.soften(0x20FFA0) == 0xA3ECBF)  // green
        #expect(SoftPalette.soften(0xFF5070) == 0xE1717E)  // red keeps more strength
    }

    @Test func neutralsAreATable() {
        #expect(SoftPalette.soften(0x323232) == 0x2F2F2D)
        #expect(SoftPalette.soften(0xF5F5F0) == 0xE2E2DD)
    }

    @Test func aGreyStaysAsItIs() {
        #expect(SoftPalette.soften(0xA8A8A0) == 0xA8A8A0)
    }
}

/// Live preview shows the marks of one element while the cursor is in it
/// (`docs/specs/look.md` in notes-linux): a mark names its element.
struct MarkOwnerTests {
    @Test func aMarkNamesItsElement() {
        let text = "## Head **bold** and `code` [[Note|label]]" as NSString
        let marks = MarkdownHighlighter.spans(in: text as String).filter { $0.kind == .markup }
        func owner(_ mark: String, _ nth: Int) -> String?? {
            let found = marks.filter { text.substring(with: $0.range) == mark }
            guard found.indices.contains(nth) else { return nil }
            return .some(found[nth].owner.map { text.substring(with: $0) })
        }
        #expect(owner("##", 0) == .some(nil))
        #expect(owner("**", 0) == .some("**bold**"))
        #expect(owner("**", 1) == .some("**bold**"))
        #expect(owner("`", 1) == .some("`code`"))
        #expect(owner("Note|", 0) == .some("[[Note|label]]"))
    }
}
