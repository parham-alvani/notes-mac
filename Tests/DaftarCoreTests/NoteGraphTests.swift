import Foundation
import Testing

@testable import DaftarCore

// Every fixture here is made up. The repository is public; the vault is not.

@Suite struct NoteGraphTests {
    func makeIndex() -> VaultIndex {
        var index = VaultIndex()
        let notes = [
            "Home.md": "[[Alpha]] and [[Beta]]",
            "Projects/Alpha.md": "[[Plan]] and ![[diagram.png]]",
            "Projects/Plan.md": "Plan, back to [[Alpha]].",
            "Work/Beta.md": "Beta.",
            "Work/Far.md": "[[Plan]]",
            "Lonely.md": "Nothing.",
        ]
        for (path, text) in notes {
            index.notes[path] = NoteEntry(path: path, modified: Date(), parsed: NoteParser.parse(text))
        }
        index.files = Set(notes.keys).union(["uploads/diagram.png"])
        index.derive()
        return index
    }

    @Test func theWholeVault() {
        let graph = NoteGraph.vault(makeIndex())
        #expect(graph.nodes.count == 6)
        // Attachments are not nodes; a link both ways is one edge.
        #expect(graph.edges.count == 4)
        let alpha = graph.nodes.first { $0.path == "Projects/Alpha.md" }
        #expect(alpha?.degree == 2)
        #expect(alpha?.group == "Projects")
        #expect(graph.nodes.first { $0.path == "Lonely.md" }?.degree == 0)
    }

    @Test func aroundOneNote() {
        let index = makeIndex()
        let one = NoteGraph.local(index, center: "Projects/Alpha.md", depth: 1)
        #expect(one.nodes.map(\.path) == ["Projects/Alpha.md", "Home.md", "Projects/Plan.md"])
        #expect(one.nodes.map(\.distance) == [0, 1, 1])
        let two = NoteGraph.local(index, center: "Projects/Alpha.md", depth: 2)
        #expect(Set(two.nodes.map(\.path)) == ["Projects/Alpha.md", "Home.md", "Projects/Plan.md", "Work/Beta.md", "Work/Far.md"])
    }

    @Test func linkedNotesEndUpCloser() {
        let graph = NoteGraph.vault(makeIndex())
        var layout = GraphLayout(graph)
        layout.run(300)
        #expect(layout.x.allSatisfy { $0.isFinite } && layout.y.allSatisfy { $0.isFinite })
        func distance(_ a: String, _ b: String) -> Double {
            let i = graph.nodes.firstIndex { $0.path == a }!, j = graph.nodes.firstIndex { $0.path == b }!
            return hypot(layout.x[i] - layout.x[j], layout.y[i] - layout.y[j])
        }
        #expect(distance("Projects/Alpha.md", "Projects/Plan.md") < distance("Projects/Alpha.md", "Lonely.md"))
        // Nothing sits on top of anything else.
        for i in graph.nodes.indices {
            for j in graph.nodes.indices where j > i {
                #expect(hypot(layout.x[i] - layout.x[j], layout.y[i] - layout.y[j]) > 10)
            }
        }
    }

    @Test func aThousandNotesLayOutQuickly() {
        var index = VaultIndex()
        for n in 0..<1000 {
            let path = "Notes/N\(n).md"
            index.notes[path] = NoteEntry(path: path, modified: Date(), parsed: NoteParser.parse("[[N\((n * 7 + 1) % 1000)]] [[N\(n / 2)]]"))
        }
        index.files = Set(index.notes.keys)
        index.derive()
        let graph = NoteGraph.vault(index)
        var layout = GraphLayout(graph)
        let start = Date()
        layout.run(200)
        // A guard against a layout that never ends, not a speed test: CI
        // runs debug builds on slow machines. A release build lays out a
        // 2,600-note vault in about 0.2 s.
        #expect(Date().timeIntervalSince(start) < 30)
        #expect(layout.x.allSatisfy { $0.isFinite })
    }
}
