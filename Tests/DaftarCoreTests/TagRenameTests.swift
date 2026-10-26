import Foundation
import Testing

@testable import DaftarCore

@Suite struct TagRenameTests {
    @Test func tagsInTheTextAndUnderThemAreRenamed() {
        let text = """
            #project/alpha and #Project too, #projects stays, #project/alpha/x
            (#project) [#project] are not tags in Obsidian, word#project neither
            """
        #expect(TagRename.rename(text, from: "project", to: "work") == """
            #work/alpha and #work too, #projects stays, #work/alpha/x
            (#project) [#project] are not tags in Obsidian, word#project neither
            """)
    }

    @Test func codeLinksAndAddressesAreLeftAlone() {
        let text = """
            Use `#project` and #project.
            [[Note#project]] [label](Note.md#project) https://example.com/#project
            ```
            #project in a block
            ```
            #project after it
            """
        #expect(TagRename.rename(text, from: "#project", to: "#work") == """
            Use `#project` and #work.
            [[Note#project]] [label](Note.md#project) https://example.com/#project
            ```
            #project in a block
            ```
            #work after it
            """)
    }

    @Test func thePropertyIsRenamedInEachOfItsForms() {
        let text = """
            ---
            title: project
            tags: [project, "project/alpha", other]
            tag: project
            aliases:
              - project
            ---
            # project
            """
        #expect(TagRename.rename(text, from: "project", to: "work") == """
            ---
            title: project
            tags: [work, "work/alpha", other]
            tag: work
            aliases:
              - project
            ---
            # project
            """)
        let list = "---\ntags:\n  - project\n  - '#project/x'\n  - other\nup: \"[[project]]\"\n---\n"
        #expect(TagRename.rename(list, from: "project", to: "work") == "---\ntags:\n  - work\n  - '#work/x'\n  - other\nup: \"[[project]]\"\n---\n")
    }

    @Test func aNameThatCannotBeATagChangesNothing() {
        #expect(!TagRename.isValid("2026"))
        #expect(!TagRename.isValid("two words"))
        #expect(!TagRename.isValid("a//b"))
        #expect(!TagRename.isValid(""))
        #expect(TagRename.isValid("#کار/پروژه"))
        #expect(TagRename.rename("#a", from: "a", to: "b c") == "#a")
        #expect(TagRename.rename("#a", from: "a", to: "a") == "#a")
        #expect(TagRename.rename("#کار و #کار/x", from: "کار", to: "work") == "#work و #work/x")
    }
}
