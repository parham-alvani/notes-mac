import Foundation
import Testing

@testable import DaftarCore

/// The home page's rules: Beautitab's settings, the greeting, where the
/// picture is and which notes are recent.
@Suite struct HomeTests {
    @Test func beautitabSettingsAreRead() {
        let json = """
            {"showTime": true, "timeFormat": "12-hour", "showGreeting": true, "greetingText": " Hello, Parham. ",
             "showInlineSearch": false, "showRecentFiles": true, "showBookmarks": true, "showQuote": true,
             "quoteSource": "My quotes", "customQuotes": [{"text": "Less, but better.", "author": "Dieter Rams"}, {"text": "  "}, {"author": "x"}, 3],
             "customBackground": "Attachments/sea.webp", "localBackgrounds": ["/tmp/a.png", {"path": "b.jpg"}, 7, ""], "plugin": {"x": 1}}
            """
        let settings = Beautitab(json: Data(json.utf8))
        #expect(settings.showTime && settings.twentyFourHour == false)
        #expect(settings.greetingText == "Hello, Parham.")
        #expect(!settings.showSearch && settings.showRecentFiles && settings.showBookmarks)
        #expect(settings.showQuote)
        #expect(settings.quotes == [Beautitab.Quote(text: "Less, but better.", author: "Dieter Rams")])
        #expect(settings.backgrounds == ["Attachments/sea.webp", "/tmp/a.png", "b.jpg"])
    }

    @Test func noFileOrOddValuesAreTheDefaults() {
        let none = Beautitab.read(root: FileManager.default.temporaryDirectory.appending(path: "no-vault-\(UUID().uuidString)"))
        #expect(none == Beautitab())
        #expect(none.showTime && none.twentyFourHour == nil && none.showGreeting && none.showSearch && none.showRecentFiles)
        #expect(!none.showQuote && !none.showBookmarks)
        // Numbers are not booleans, and a string is not a list.
        let odd = Beautitab(json: Data(#"{"showTime": 0, "showGreeting": "no", "timeFormat": 24, "customQuotes": "x", "showQuote": 1, "greetingText": false}"#.utf8))
        #expect(odd == Beautitab())
        #expect(Beautitab(json: Data("[1, 2]".utf8)) == Beautitab())
        #expect(Beautitab(json: Data(#"{"timeFormat": "24-hour"}"#.utf8)).twentyFourHour == true)
    }

    @Test func quotesFromTheWebAreOff() {
        let web = Beautitab(json: Data(#"{"showQuote": true, "quoteSource": "Quotable", "customQuotes": [{"text": "A"}]}"#.utf8))
        #expect(!web.showQuote)
        let empty = Beautitab(json: Data(#"{"showQuote": true, "quoteSource": "My quotes", "customQuotes": []}"#.utf8))
        #expect(!empty.showQuote)
    }

    @Test func aQuoteTakesTheMarksOfItsScript() {
        let persian = Beautitab.Quote(text: "خورشید درست وقتی از دست می رود ….")
        #expect(persian.isRtl)
        #expect(persian.quoted == "«خورشید درست وقتی از دست می رود ….»")
        let english = Beautitab.Quote(text: "Less, but better.")
        #expect(!english.isRtl)
        #expect(english.quoted == "“Less, but better.”")
        // The first letter decides, as in a note's lines.
        #expect(Beautitab.Quote(text: "Git یعنی").quoted == "“Git یعنی”")
    }

    @Test func theGreetingFollowsTheHour() {
        #expect(Home.greeting("", hour: 6) == "Good morning")
        #expect(Home.greeting("", hour: 12) == "Good afternoon")
        #expect(Home.greeting("", hour: 23) == "Good evening")
        #expect(Home.greeting("", hour: 2) == "Good evening")
        #expect(Home.greeting("Hello, Parham.", hour: 9) == "Hello, Parham.")
        #expect(Home.greeting("Good {{greeting}}, Parham", hour: 15) == "Good afternoon, Parham")
    }

    @Test func thePictureIsAbsoluteHomeOrInTheVault() {
        let vault = URL(filePath: "/Users/x/org")
        #expect(Home.pictureURL("", vault: vault) == nil)
        #expect(Home.pictureURL("  ", vault: vault) == nil)
        #expect(Home.pictureURL("/a/b.png", vault: vault)?.path == "/a/b.png")
        #expect(Home.pictureURL("~/.config/daftar/home.webp", vault: vault, home: "/Users/x")?.path == "/Users/x/.config/daftar/home.webp")
        #expect(Home.pictureURL("Attachments/sea.jpg", vault: vault)?.path == "/Users/x/org/Attachments/sea.jpg")
        #expect(Home.pictureURL("Attachments/sea.jpg", vault: nil) == nil)
        #expect(Home.pictureURL("file:///a/b.heic", vault: nil)?.path == "/a/b.heic")
        // The page never goes to the network.
        #expect(Home.pictureURL("https://example.com/a.png", vault: vault) == nil)
        #expect(Home.pictureURL("data:image/png;base64,AAAA", vault: vault) == nil)
    }

    @Test func recentNotesAreOpenedThenReadEachOnce() {
        let files: Set = ["A.md", "B.md", "C.md", "D.md"]
        let recent = Home.recent(opened: ["B.md", "Gone.md"], read: ["A.md", "B.md", "C.md", "D.md"], exists: files.contains, limit: 3)
        #expect(recent == ["B.md", "A.md", "C.md"])
        #expect(Home.recent(opened: [], read: [], exists: files.contains, limit: 8).isEmpty)
    }

    @Test func readingPlacesListTheNotesReadLast() {
        var places = ReadingPlaces()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        places.markRead("Old.md", at: start)
        places.markRead("New.md", at: start.addingTimeInterval(60))
        places.markRead("Same second.md", at: start.addingTimeInterval(60))
        places.set("Never read.md", line: 3)
        // A cursor move is not a read.
        places.set("Old.md", line: 9)
        #expect(places.recentlyRead(10) == ["Same second.md", "New.md", "Old.md"])
        #expect(places.recentlyRead(1) == ["Same second.md"])
        #expect(ReadingPlaces(data: places.data).recentlyRead(10) == places.recentlyRead(10))
    }
}
