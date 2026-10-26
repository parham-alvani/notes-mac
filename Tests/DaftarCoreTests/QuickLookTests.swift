import Foundation
import Testing

@testable import DaftarCore

// Every fixture here is made up. The repository is public; the vault is not.

/// `just web` builds the renderer; `swift test` alone may run without it.
let quickLookScript: String? = try? String(
    contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../web/dist/quicklook.js").standardizedFileURL,
    encoding: .utf8)

@Suite struct QuickLookTests {
    func makeVault(_ files: [String: String], obsidian: Bool = true) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "daftar-quicklook-\(UUID().uuidString)")
        if obsidian { try FileManager.default.createDirectory(at: root.appending(path: ".obsidian"), withIntermediateDirectories: true) }
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test func theVaultIsTheFolderWithObsidian() throws {
        let root = try makeVault(["Projects/Deep/Note.md": "x"])
        #expect(QuickLookPreview.vaultRoot(of: root.appending(path: "Projects/Deep/Note.md"))?.path == root.standardizedFileURL.path)
        let loose = try makeVault(["Note.md": "x"], obsidian: false)
        #expect(QuickLookPreview.vaultRoot(of: loose.appending(path: "Note.md")) == nil)
    }

    @Test func linksResolveAsInTheApp() {
        let parsed = NoteParser.parse("[[Plan]], [[Missing]] and ![[logo.png|200]]")
        let links = QuickLookPreview.links(in: parsed, from: "Home.md", files: ["Projects/Plan.md", "uploads/logo.png", "Home.md"])
        #expect(links == ["Plan": "Projects/Plan.md", "logo.png": "uploads/logo.png"])
    }

    @Test func vaultPicturesBecomeAttachments() throws {
        let root = try makeVault(["uploads/a b.png": "png", "Notes/local.png": "png", "Notes/Note.md": "x"])
        let body = """
            <img src="vault:///uploads/a%20b.png" alt="a"><img src="local.png"><img src="vault:///uploads/a%20b.png">\
            <img src="vault:///missing.png"><img src="https://example.com/x.png"><img src="../../../etc/hosts">\
            <video class="media" src="vault:///../outside.png">
            """
        let page = QuickLookPreview.attach(body, root: root, path: "Notes/Note.md")
        #expect(page.attachments.count == 2)
        #expect(page.html.components(separatedBy: "src=\"cid:").count - 1 == 3)
        #expect(page.attachments.values.map(\.lastPathComponent).sorted() == ["a b.png", "local.png"])
        #expect(page.html.contains("src=\"vault:///missing.png\""))
        #expect(page.html.contains("src=\"https://example.com/x.png\""))
        #expect(page.html.contains("src=\"../../../etc/hosts\""))
        #expect(page.html.contains("src=\"vault:///../outside.png\""))
    }

    @Test func theInputIsTheReadersNote() throws {
        let json = QuickLookPreview.input(text: "---\nstatus: open\ncssclasses: wide\n---\nBody", path: "Notes/Plan.md", links: [:])
        let note = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(note["title"] as? String == "Plan")
        #expect(note["properties"] as? [[String]] == [["status", "open"]])
    }

    @Test(.enabled(if: quickLookScript != nil)) func aNoteRendersAsTheReaderDrawsIt() throws {
        let renderer = try #require(QuickLookPreview.Renderer(script: quickLookScript!))
        let root = try makeVault([
            "Notes/Note.md": "# Title\n\n> [!warning] Careful\n> ==marked== #tag [[Other]]\n\nسلام دنیا\n\n![[logo.png]]\n",
            "Other.md": "", "uploads/logo.png": "png",
        ])
        let page = try QuickLookPreview.page(of: root.appending(path: "Notes/Note.md"), renderer: renderer, styles: "body {}")
        #expect(page.html.hasPrefix("<!doctype html>"))
        #expect(page.html.contains("<h1 class=\"inline-title\" dir=\"auto\">Note</h1>"))
        #expect(page.html.contains("<div class=\"callout\" data-callout=\"warning\" dir=\"auto\">"))
        #expect(page.html.contains("<mark>marked</mark>"))
        #expect(page.html.contains("--tag-color"))
        #expect(page.html.contains("class=\"internal-link\" href=\"#\" data-path=\"Other.md\""))
        #expect(page.html.contains("<p dir=\"auto\" data-line=\"5\">سلام دنیا</p>"))
        #expect(page.html.contains("<img src=\"cid:file0\""))
        #expect(page.attachments["file0"]?.lastPathComponent == "logo.png")
    }

    @Test func aBrokenScriptIsNoRenderer() {
        #expect(QuickLookPreview.Renderer(script: "this is not javascript (") == nil)
        #expect(QuickLookPreview.Renderer(script: "var x = 1") == nil)
    }
}
