import Foundation
import Testing

@testable import DaftarCore

// Every fixture here is made up. The repository is public; the vault is not.

@Suite struct UnlinkedMentionsTests {
    @Test func aNameIsFoundAsAWholeWordInAnyCase() {
        let text = "Lunch with acme today.\nAcme's offer came.\nAcmes and Acmeville are other words."
        let found = UnlinkedMentions.find(["Acme"], in: text)
        #expect(found.map(\.line) == [0, 1])
        #expect(found.map(\.text) == ["acme", "Acme"])
        #expect(found[0].column == 11 && found[0].length == 4)
    }

    @Test func linksCodeAndTagsAreNotMentions() {
        let text = """
            ---
            company: Acme
            ---
            See [[Acme]] and [the site](https://acme.example/Acme) and `Acme` and #Acme.
            ```
            Acme in code
            ```
            Only this Acme counts.
            """
        let found = UnlinkedMentions.find(["Acme"], in: text)
        #expect(found.map(\.line) == [7])
        #expect(found[0].excerpt == "Only this Acme counts.")
        #expect((found[0].excerpt as NSString).substring(with: found[0].excerptRange) == "Acme")
    }

    @Test func theLongestNameWinsAndShortNamesAreSkipped() {
        let found = UnlinkedMentions.find(["Acme", "Acme Bank", "AB"], in: "Paid Acme Bank, AB said.")
        #expect(found.map(\.text) == ["Acme Bank"])
        #expect(UnlinkedMentions.find(["Go"], in: "Go is short").isEmpty)
    }

    @Test func persianNamesAreFoundToo() {
        let found = UnlinkedMentions.find(["تهران"], in: "سفر به تهران در پاییز")
        #expect(found.map(\.text) == ["تهران"])
    }

    @Test func aLongLineIsCutAroundTheName() {
        let line = String(repeating: "word ", count: 30) + "Acme" + String(repeating: " word", count: 30)
        let found = UnlinkedMentions.find(["Acme"], in: line)
        let excerpt = found[0].excerpt as NSString
        #expect(found[0].excerpt.hasPrefix("…") && found[0].excerpt.hasSuffix("…"))
        #expect(excerpt.substring(with: found[0].excerptRange) == "Acme")
    }

    @Test func linkingKeepsTheTextAsWritten() throws {
        let text = "Lunch with acme today.\nAcme called."
        let found = UnlinkedMentions.find(["Acme"], in: text)
        #expect(try UnlinkedMentions.link(found[0], to: "Acme", in: text) == "Lunch with [[Acme|acme]] today.\nAcme called.")
        #expect(try UnlinkedMentions.link(found[1], to: "Acme", in: text) == "Lunch with acme today.\n[[Acme]] called.")
        // The file changed since: nothing is written.
        #expect(throws: VaultEdits.Failure.textMoved) { try UnlinkedMentions.link(found[1], to: "Acme", in: "Other text.\nNo name.") }
    }
}
