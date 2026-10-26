import Foundation
import Testing

@testable import DaftarCore

@Suite struct HTMLMarkdownTests {
    @Test func aWebPageBecomesMarkdown() throws {
        let html = """
            <html><head><style>p{}</style></head><body>
            <h2>Getting <em>there</em></h2>
            <p>Take the <strong>red</strong> line to <a href="https://example.com/a b">the park</a>.<br>Then walk.</p>
            <ul><li>One</li><li>Two<ul><li>Two and a half</li></ul></li></ul>
            <ol start="3"><li><p>Third</p></li></ol>
            <blockquote><p>Quoted</p></blockquote>
            <pre><code class="language-swift">let a = 1
            let b = 2</code></pre>
            <table><tr><th>Name</th><th>Age</th></tr><tr><td>Ana</td><td>30</td></tr></table>
            <p><img src="https://example.com/x.png" alt="X"> and <code>inline</code></p>
            </body></html>
            """
        let markdown = try #require(HTMLMarkdown.convert(html))
        #expect(markdown == """
            ## Getting *there*

            Take the **red** line to [the park](https://example.com/a%20b).
            Then walk.

            - One
            - Two
                - Two and a half

            3. Third

            > Quoted

            ```swift
            let a = 1
            let b = 2
            ```

            | Name | Age |
            | --- | --- |
            | Ana | 30 |

            ![X](https://example.com/x.png) and `inline`
            """)
    }

    @Test func codeEditorsAndPlainTextStayPlain() {
        #expect(HTMLMarkdown.convert(#"<meta charset="utf-8"><div style="color: #d4d4d4;"><div><span style="color: #569cd6;">let</span> a = 1</div></div>"#) == nil)
        #expect(HTMLMarkdown.convert("just words") == nil)
    }

    @Test func googleDocsBoldSpansCount() {
        let html = #"<b style="font-weight:normal;" id="docs"><p><span style="font-weight:700;">Bold</span> and <span style="font-style:italic;">slanted</span></p></b>"#
        #expect(HTMLMarkdown.convert(html) == "**Bold** and *slanted*")
    }
}
