import Testing

@testable import DaftarCore

// Every fixture here is made up. The repository is public; the vault is not.

@Suite struct ImageTests {
    @Test func aPictureIsKnownByItsExtensionInAnyCase() {
        for path in ["a.png", "uploads/b.JPG", "c.jpeg", "d.gif", "e.webp", "f.svg", "g.bmp", "h.avif", "i.HEIC", "j.heif", "k.tif", "l.tiff"] {
            #expect(Vault.isImage(path), "\(path)")
        }
        for path in ["note.md", "a.pdf", "film.mov", "png", "folder.png/note", "Board.canvas", "x.base", "a.png.md"] {
            #expect(!Vault.isImage(path), "\(path)")
        }
    }

    @Test func aPictureOpensInTheApp() {
        #expect(Vault.opensInApp("uploads/map.png"))
        #expect(Vault.opensInApp("art/logo.svg"))
        #expect(Vault.opensInApp("Notes/Inbox.md") && Vault.opensInApp("x.base") && Vault.opensInApp("b.canvas"))
        // What WebKit does not draw still goes to its own app.
        #expect(!Vault.opensInApp("paper.pdf"))
        #expect(!Vault.opensInApp("raw.dng"))
        #expect(!Vault.opensInApp("film.mp4"))
    }

    @Test func aPictureStillRanksAfterANoteOfTheSameName() {
        let files: [QuickSwitcher.Candidate] = [
            .init(path: "uploads/map.png", title: "map.png"),
            .init(path: "Notes/Map.md", title: "Map"),
        ]
        #expect(QuickSwitcher.rank("map", in: files) == ["Notes/Map.md", "uploads/map.png"])
    }

    @Test func aLinkToAPictureResolvesToTheFileThatOpens() {
        var index = VaultIndex()
        index.notes["Notes/Trip.md"] = NoteEntry(path: "Notes/Trip.md", modified: .now, parsed: NoteParser.parse("See [[map.png]]."))
        index.files = ["Notes/Trip.md", "uploads/map.png"]
        index.derive()
        let target = index.resolve("map.png", from: "Notes/Trip.md")
        #expect(target == "uploads/map.png")
        #expect(target.map(Vault.opensInApp) == true)
        // The picture's backlinks are the notes that link to it or embed it.
        #expect(index.backlinks["uploads/map.png"]?.map(\.source) == ["Notes/Trip.md"])
    }
}
