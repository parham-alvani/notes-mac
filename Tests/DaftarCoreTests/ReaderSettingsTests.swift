import Foundation
import Testing

@testable import DaftarCore

/// The reader's two settings of part 2 (`docs/specs/look.md` in
/// notes-linux, test 23 of part 2): the link preview and the section bar.
@Suite struct ReaderSettingsTests {
    @Test func theNewSettingsHaveTheirDefaults() {
        let neither = ResolvedSettings.resolved(vault: "", computer: "", root: nil)
        #expect(neither.bool("appearance.link_preview") == true)
        #expect(neither.bool("appearance.section_bar") == true)
        // A vault that sets each is followed, and none is refused.
        let vault = ResolvedSettings.resolved(vault: "[appearance]\nlink_preview = false\nsection_bar = false\n", computer: "", root: nil)
        #expect(vault.bool("appearance.link_preview") == false)
        #expect(vault.bool("appearance.section_bar") == false)
        #expect(vault.refused.isEmpty)
        #expect(Set(vault.fromVault) == ["appearance.link_preview", "appearance.section_bar"])
        // A value of another kind is as not there.
        let wrong = ResolvedSettings.resolved(vault: "[appearance]\nsection_bar = \"yes\"\n", computer: "", root: nil)
        #expect(wrong.bool("appearance.section_bar") == true)
    }
}
