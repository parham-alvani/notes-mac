import Foundation
import Testing

@testable import DaftarCore

@Suite struct LinkCompletionTests {
    func query(_ text: String) -> (String, LinkCompletion.Query)? {
        let ns = text as NSString
        return LinkCompletion.query(in: ns, at: ns.length).map { (ns.substring(with: $0.range), $0.query) }
    }

    @Test func whatALinkAsksFor() {
        #expect(query("See [[Kube")?.1 == .note("Kube"))
        #expect(query("See [[Kube")?.0 == "Kube")
        #expect(query("See [[Kubernetes#Ins")?.1 == .heading(note: "Kubernetes", query: "Ins"))
        #expect(query("See [[Kubernetes#Ins")?.0 == "Kubernetes#Ins")
        #expect(query("[[#")?.1 == .heading(note: "", query: ""))
        #expect(query("[[Kubernetes#^pod")?.1 == .block(note: "Kubernetes", query: "pod"))
        #expect(query("[[Kubernetes^")?.1 == .block(note: "Kubernetes", query: ""))
        #expect(query("[[#^")?.1 == .block(note: "", query: ""))
        #expect(query("[[Note|alias") == nil)
        #expect(query("[[Note]] and") == nil)
        #expect(query("no link") == nil)
        // The link is on the cursor's line.
        #expect(query("[[Open\nNext") == nil)
    }

    @Test func headingsAreIndentedByLevelAndInOrder() {
        let headings = [Heading(level: 1, text: "Kubernetes", line: 0), Heading(level: 2, text: "Install", line: 2),
            Heading(level: 3, text: "On a Mac", line: 4), Heading(level: 2, text: "Pods", line: 8)]
        let all = LinkCompletion.headings(headings, matching: "", note: "Kubernetes")
        #expect(all.map(\.label) == ["Kubernetes", "  Install", "    On a Mac", "  Pods"])
        #expect(all[2].insert == "Kubernetes#On a Mac")
        let found = LinkCompletion.headings(headings, matching: "pod", note: "K8s")
        #expect(found.first == LinkCompletion.Item(label: "  Pods", insert: "K8s#Pods"))
        // `[[#`: the note's own headings, with no note before the `#`.
        #expect(LinkCompletion.headings(headings, matching: "", note: "")[1].insert == "#Install")
    }

    @Test func aHeadingLosesTheMarksOfALink() {
        #expect(LinkCompletion.anchor("A | B # C ^ D") == "A B C D")
        #expect(LinkCompletion.anchor("See [[Other]] too") == "See Other too")
        #expect(LinkCompletion.anchor("Plain") == "Plain")
    }

    @Test func aliasesGetRowsOfTheirOwn() {
        let notes = [LinkCompletion.Note(name: "Kubernetes", aliases: ["k8s", "kube"]), LinkCompletion.Note(name: "Kafka")]
        let rows = LinkCompletion.notes(notes, matching: "k8s")
        #expect(rows.first == LinkCompletion.Item(label: "k8s → Kubernetes", insert: "Kubernetes|k8s"))
        #expect(rows.contains(LinkCompletion.Item(label: "Kubernetes", insert: "Kubernetes")))
        // The name matches too: the note first, then its alias.
        let both = LinkCompletion.notes(notes, matching: "kube")
        #expect(both.prefix(2).map(\.label) == ["Kubernetes", "kube → Kubernetes"])
        // No query: the notes alone.
        #expect(LinkCompletion.notes(notes, matching: "").map(\.label) == ["Kubernetes", "Kafka"])
    }

    @Test func blocksForTheQuery() {
        let text = "# Title\n\nFirst paragraph about pods.\n\n- an item ^item1\n- another item\n\n```\ncode pods\n```\n"
        let blocks = BlockRefs.blocks(in: text)
        let all = LinkCompletion.blocks(blocks, matching: "")
        #expect(all.map(\.kind) == [.paragraph, .item, .item, .code])
        #expect(LinkCompletion.blocks(blocks, matching: "pods").map(\.text) == ["First paragraph about pods.", "code pods"])
        #expect(LinkCompletion.blocks(blocks, matching: "item1").map(\.id) == ["item1"])
        #expect(LinkCompletion.label(of: all[1]) == "an item  ^item1")
        let long = BlockRefs.Block(kind: .paragraph, start: 0, end: 0, id: nil, text: String(repeating: "a", count: 100))
        #expect(LinkCompletion.label(of: long).count == 70)
    }

    func tag(_ text: String) -> String? {
        let ns = text as NSString
        return LinkCompletion.tagQuery(in: ns, at: ns.length).map { ns.substring(with: $0) }
    }

    @Test func aTagStartsAWord() {
        #expect(tag("Text #") == "")
        #expect(tag("Text #proj") == "proj")
        #expect(tag("Text #project/sub") == "project/sub")
        #expect(tag("#proj") == "proj")
        // A heading's marks, and `#` alone at a line's start, are not a tag.
        #expect(tag("#") == nil)
        #expect(tag("## Head") == nil)
        #expect(tag("##") == nil)
        #expect(tag("word#x") == nil)
        #expect(tag("https://example.com/#frag") == nil)
        #expect(tag("[[Note#Head") == nil)
        #expect(tag("Text #a b") == nil)
    }

    @Test func noTagInCodeOrFrontMatter() {
        #expect(tag("`code #x") == nil)
        #expect(tag("`code` #x") == "x")
        #expect(tag("```\nfenced #x") == nil)
        #expect(tag("```\nfenced\n```\nafter #x") == "x")
        #expect(tag("~~~~\n```\n#x") == nil)
        #expect(tag("---\ntags: #x") == nil)
        #expect(tag("---\ntitle: a\n---\nbody #x") == "x")
    }

    @Test func tagsRankedForTheQuery() {
        let counts = ["project": 9, "project/daftar": 4, "Project": 1, "home/projects": 3, "pizza": 20, "cooking": 2]
        let rows = LinkCompletion.tags(counts, matching: "proj")
        #expect(rows.map(\.insert) == ["project", "project/daftar", "home/projects"])
        // Two spellings are one tag, written as the most used one.
        #expect(rows.first?.label == "#project  10")
        #expect(LinkCompletion.tags(counts, matching: "").first?.insert == "pizza")
        #expect(LinkCompletion.tags(counts, matching: "daftar").map(\.insert) == ["project/daftar"])
        #expect(LinkCompletion.tags(counts, matching: "zzz").isEmpty)
    }
}

@Suite struct BlockRefsTests {
    @Test func blocksOfANote() {
        let text = """
            ---
            aliases: [x]
            ---
            # Heading

            A paragraph
            on two lines ^para

            - item one
              carried on
                - nested
            1. numbered ^num

            | a | b |
            |---|---|
            | 1 | 2 |

            ^table

            > quote

            ```
            - not an item
            ```
            """
        let blocks = BlockRefs.blocks(in: text)
        #expect(blocks.map(\.kind) == [.heading, .paragraph, .item, .item, .item, .table, .quote, .code])
        #expect(blocks[1].id == "para")
        #expect(blocks[1].text == "A paragraph on two lines")
        #expect(blocks[1].start == 5 && blocks[1].end == 6)
        #expect(blocks[2].text == "item one carried on")
        #expect(blocks[2].end == 9)
        #expect(blocks[3].text == "nested")
        #expect(blocks[4].id == "num")
        #expect(blocks[5].id == "table")
        #expect(blocks[6].id == nil)
        #expect(BlockRefs.block(atLine: 9, in: text)?.text == "item one carried on")
        #expect(BlockRefs.block(atLine: 4, in: text) == nil)
        #expect(BlockRefs.block(atLine: 1, in: text) == nil)
        #expect(BlockRefs.block(atLine: 22, in: text)?.kind == .code)
        #expect(BlockRefs.ids(in: text) == ["para", "num", "table"])
    }

    @Test func theResolverFindsABlockById() {
        let text = "One ^first\n\nTwo\n\n- three ^Third\n"
        #expect(BlockRefs.block(id: "^first", in: text)?.text == "One")
        #expect(BlockRefs.block(id: "third", in: text)?.kind == .item)
        #expect(BlockRefs.block(id: "^missing", in: text) == nil)
    }

    @Test func newIdsAreSixLettersAndFree() {
        var random = RobustnessTests.Seeded(state: 7)
        var taken = Set<String>()
        for _ in 0..<500 {
            let id = BlockRefs.newId(taken: taken, using: &random)
            #expect(id.count == 6)
            #expect(id.allSatisfy { $0.isLowercase || $0.isNumber })
            #expect(!taken.contains(id))
            taken.insert(id)
        }
    }

    func adding(_ id: String, at line: Int, in text: String) -> String? {
        guard let block = BlockRefs.block(atLine: line, in: text) else { return nil }
        return try? BlockRefs.addId(id, toBlockAt: block.start, expected: block.text, in: text)
    }

    @Test func theIdGoesAtTheEndOfAParagraph() {
        #expect(adding("abc123", at: 0, in: "One\ntwo  \n\nNext") == "One\ntwo ^abc123  \n\nNext")
        #expect(adding("abc123", at: 0, in: "Only") == "Only ^abc123")
        #expect(adding("abc123", at: 1, in: "Win\r\nlines\r\n") == "Win\r\nlines ^abc123\r\n")
    }

    @Test func theIdGoesAfterAListItemsText() {
        let text = "- one\n  more\n    - nested\n- two"
        #expect(adding("abc123", at: 0, in: text) == "- one\n  more ^abc123\n    - nested\n- two")
        #expect(adding("abc123", at: 2, in: text) == "- one\n  more\n    - nested ^abc123\n- two")
        #expect(adding("abc123", at: 0, in: "- [ ] a task 📅 2026-10-27") == "- [ ] a task 📅 2026-10-27 ^abc123")
    }

    @Test func aTableQuoteOrCodeGetsItOnItsOwnLine() {
        let table = "| a |\n|---|\n| 1 |\nAfter"
        #expect(adding("abc123", at: 2, in: table) == "| a |\n|---|\n| 1 |\n\n^abc123\n\nAfter")
        #expect(adding("abc123", at: 0, in: "| a |\n|---|\n\nNext") == "| a |\n|---|\n\n^abc123\n\nNext")
        #expect(adding("abc123", at: 0, in: "> quote") == "> quote\n\n^abc123")
        // Never inside the code: after its closing fence.
        #expect(adding("abc123", at: 1, in: "```\ncode\n```\n") == "```\ncode\n```\n\n^abc123\n")
        #expect(BlockRefs.blocks(in: adding("x", at: 1, in: "```\ncode\n```\n") ?? "").first?.id == "x")
    }

    @Test func aHeadingIsLinkedByItsTextNotAnId() {
        #expect(BlockRefs.block(atLine: 0, in: "## Plans")?.kind == .heading)
        #expect(adding("abc123", at: 0, in: "## Plans") == nil)
    }

    @Test func anEditOfAChangedBlockIsRefused() {
        #expect(throws: VaultEdits.Failure.textMoved) { try BlockRefs.addId("a", toBlockAt: 0, expected: "Old", in: "New text") }
        #expect(throws: VaultEdits.Failure.textMoved) { try BlockRefs.addId("a", toBlockAt: 0, expected: "Has", in: "Has ^id") }
        #expect(throws: VaultEdits.Failure.textMoved) { try BlockRefs.addId("a", toBlockAt: 3, expected: "x", in: "x") }
    }
}
