import Foundation
import Testing

@testable import DaftarCore

// Every fixture here is made up. The repository is public; the vault is not.

@Suite struct CanvasTests {
    let board = """
        {
          "nodes": [
            {"id": "t1", "type": "text", "text": "# Plan\\nSee [[Inbox]].", "x": -100, "y": 20, "width": 300, "height": 140, "color": "1"},
            {"id": "f1", "type": "file", "file": "Notes/Inbox.md", "subpath": "#Today", "x": 300, "y": 0, "width": 400, "height": 300},
            {"id": "f2", "type": "file", "file": "map.png", "x": 300, "y": 400, "width": 200, "height": 200, "color": "#00AAFF"},
            {"id": "l1", "type": "link", "url": "https://example.com", "x": 0, "y": 400, "width": 250, "height": 60},
            {"id": "g1", "type": "group", "label": "Week", "x": -150, "y": -60, "width": 900, "height": 700, "background": "uploads/map.png", "backgroundStyle": "cover"},
            {"id": "w1", "type": "widget", "x": 0, "y": 0, "width": 10, "height": 10},
            {"type": "text", "text": "no id"},
            {"id": "t1", "type": "text", "text": "the same id again"},
            {"id": "n1", "type": "text", "x": "12", "y": null, "width": -5, "height": 1e400, "plugin": {"deep": [1, 2]}}
          ],
          "edges": [
            {"id": "e1", "fromNode": "t1", "fromSide": "right", "toNode": "f1", "toSide": "left", "label": "next", "color": "4"},
            {"id": "e2", "fromNode": "f1", "toNode": "f2", "fromEnd": "arrow", "toEnd": "none", "fromSide": "middle"},
            {"id": "e3", "fromNode": "t1", "toNode": "gone"},
            {"id": "e4", "fromNode": "t1"},
            "not an edge"
          ],
          "extra": true
        }
        """

    @Test func readsEveryKindOfCardAndEdge() {
        let canvas = Canvas.parse(board)
        #expect(canvas.nodes.map(\.id) == ["t1", "f1", "f2", "l1", "g1", "n1"])
        let text = canvas.nodes[0]
        #expect(text.type == "text" && text.text == "# Plan\nSee [[Inbox]]." && text.x == -100 && text.width == 300 && text.color == "1")
        #expect(canvas.nodes[1].file == "Notes/Inbox.md" && canvas.nodes[1].subpath == "#Today")
        #expect(canvas.nodes[3].url == "https://example.com")
        #expect(canvas.nodes[4].label == "Week" && canvas.nodes[4].backgroundStyle == "cover")
        // A number written as text is read; a size too small is the smallest,
        // and one that is not a number is the default.
        let odd = canvas.nodes[5]
        #expect(odd.x == 12 && odd.y == 0 && odd.width == 10 && odd.height == 60)

        #expect(canvas.edges.map(\.id) == ["e1", "e2"])
        let first = canvas.edges[0]
        #expect(first.fromSide == "right" && first.toSide == "left" && first.label == "next" && first.fromEnd == "none" && first.toEnd == "arrow")
        let second = canvas.edges[1]
        #expect(second.fromSide == nil && second.fromEnd == "arrow" && second.toEnd == "none")
    }

    @Test func notJSONIsAnEmptyBoard() {
        for text in ["", "{", "[]", "null", "{\"nodes\": 3}", "{\"nodes\": [1, \"a\", null]}", "not json"] {
            #expect(Canvas.parse(text) == Canvas())
        }
        #expect(Canvas.parse("{\"nodes\": [{\"id\": \"a\", \"type\": \"text\"}]}").nodes.first?.width == 250)
    }

    @Test func coloursArePresetsOrHex() {
        #expect(["1", "2", "3", "4", "5", "6"].map(Canvas.color) == ["red", "orange", "yellow", "green", "cyan", "purple"])
        #expect(Canvas.color("#00AAFF") == "#00AAFF")
        #expect(Canvas.color("#abc") == "#abc")
        #expect(Canvas.color("7") == nil)
        #expect(Canvas.color("red; x") == nil)
        #expect(Canvas.color(nil) == nil)
    }

    @Test func filesAndLinksResolveInTheVault() {
        var index = VaultIndex()
        for path in ["Notes/Inbox.md", "Home.md"] {
            index.notes[path] = NoteEntry(path: path, modified: Date(), parsed: NoteParser.parse(""))
        }
        index.files = ["Notes/Inbox.md", "Home.md", "uploads/map.png", "Boards/Plan.canvas"]
        index.derive()
        let canvas = Canvas.parse(board)
        #expect(canvas.files(in: index, from: "Boards/Plan.canvas") == ["f1": "Notes/Inbox.md", "f2": "uploads/map.png"])
        #expect(canvas.links(in: index, from: "Boards/Plan.canvas") == ["Inbox": "Notes/Inbox.md"])
        #expect(Canvas.isCanvas("Boards/Plan.canvas") && !Canvas.isCanvas("Plan.md"))
        #expect(Vault.opensInApp("Boards/Plan.canvas"))
    }
}
