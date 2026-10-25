import Testing

@testable import DaftarCore

@Suite struct TagTreeTests {
    @Test func nestsAndCounts() {
        let tree = TagNode.tree(["work": 3, "work/meeting": 2, "work/plan/q4": 1, "home": 4, "Work": 1, "ideas/new": 1])
        #expect(tree.map(\.tag) == ["work", "home", "ideas"])
        let work = tree[0]
        // 3 + 1 of its own (two spellings, one tag), 2 + 1 under it.
        #expect(work.count == 7)
        #expect(work.children?.map(\.tag) == ["work/meeting", "work/plan"])
        #expect(work.children?[1].children?.first?.tag == "work/plan/q4")
        #expect(tree[1].children == nil)
        // A parent with no notes of its own still shows, for its children.
        #expect(tree[2].count == 1 && tree[2].children?.first?.name == "new")
    }

    @Test func theCommonerSpellingNamesTheTag() {
        #expect(TagNode.tree(["Kubernetes": 5, "kubernetes": 2]).map(\.name) == ["Kubernetes"])
    }
}
