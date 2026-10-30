import Foundation
import Testing

@testable import DaftarCore

/// The editor's colours of a code line: what each token is, by language.
@Suite struct CodeTokensTests {
    /// Each token as its kind and its text, in order.
    static func read(_ line: String, _ language: String) -> [String] {
        CodeTokens.tokens(in: line, language: language).map { token in
            "\(token.kind):" + (line as NSString).substring(with: token.range)
        }
    }

    @Test func javascriptHasStringsNumbersKeywordsAndComments() {
        #expect(Self.read(#"const x = "a // b"; // note"#, "js") == [
            "keyword:const", #"string:"a // b""#, "comment:// note",
        ])
        #expect(Self.read("return a + 1.5 /* why */ + 2", "ts") == [
            "keyword:return", "number:1.5", "comment:/* why */", "number:2",
        ])
    }

    @Test func pythonAndShellCommentWithAHash() {
        #expect(Self.read("def f(x):  # double", "python") == ["keyword:def", "comment:# double"])
        // A `#` inside a word is not a comment.
        #expect(Self.read("echo $HOME#1 # note", "bash") == ["number:1", "comment:# note"])
        // `//` is not a comment in Python.
        #expect(Self.read("y = 7 // 2", "py") == ["number:7", "number:2"])
    }

    @Test func otherLanguagesAndNone() {
        #expect(Self.read("local n = 'x' -- why", "lua") == ["keyword:local", "string:'x'", "comment:-- why"])
        #expect(Self.read("SELECT a FROM t -- all", "sql") == ["keyword:SELECT", "keyword:FROM", "comment:-- all"])
        // A fence with no language has strings, numbers and keywords, but no comments.
        #expect(Self.read("if it's 2 # no", "") == ["keyword:if", "number:2"])
    }

    @Test func anOpenStringEndsWithTheLine() {
        #expect(Self.read(#"s = "open \" quote"#, "go") == [#"string:"open \" quote"#])
        #expect(Self.read("", "go").isEmpty)
        // Persian in a comment and a string keeps UTF-16 offsets.
        #expect(Self.read(#"x = "سلام" // یادداشت"#, "js") == [#"string:"سلام""#, "comment:// یادداشت"])
    }
}
