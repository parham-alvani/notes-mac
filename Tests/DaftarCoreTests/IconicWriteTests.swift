import Foundation
import Testing

@testable import DaftarCore

@Suite struct IconicWriteTests {
    let file = """
        {
          "biggerIcons": "mobile",
          "maxSearchResults": 50,
          "fileIcons": {
            "Banking": {
              "icon": "lucide-piggy-bank",
              "color": "green",
              "unsynced": [
                "0d3e"
              ]
            },
            "Banking/Exchanges.md": {
              "icon": "lucide-shopping-cart"
            }
          },
          "fileRules": [],
          "rememberDeletedItems": false
        }
        """

    @Test func theFileComesBackAsItWas() throws {
        #expect(try OrderedJSON.parse(file).text == file)
        let tricky = #"{"a": "x\u00e9\n\"y\"", "b": [1.5, -2e3, null, true]}"#
        // Unicode written as itself, escapes as JavaScript writes them, numbers as they were.
        let expected = #"""
            {
              "a": "xé\n\"y\"",
              "b": [
                1.5,
                -2e3,
                null,
                true
              ]
            }
            """#
        #expect(try OrderedJSON.parse(tricky).text == expected)
    }

    @Test func settingAnIconChangesItsLinesOnly() throws {
        let set = String(decoding: try Iconic.setting("Banking/Exchanges.md", icon: "lucide-euro", color: "blue", in: Data(file.utf8)), as: UTF8.self)
        #expect(set == file.replacingOccurrences(of: #""icon": "lucide-shopping-cart""# + "\n", with: #""icon": "lucide-euro","# + "\n" + #"      "color": "blue""# + "\n"))
        // A new one goes last; Iconic's own keys in an entry stay.
        let added = try Iconic.setting("Cars", icon: "🚗", color: nil, in: Data(file.utf8))
        let json = try OrderedJSON.parse(String(decoding: added, as: UTF8.self))
        #expect(json["fileIcons"]?.keys == ["Banking", "Banking/Exchanges.md", "Cars"])
        let recolored = try OrderedJSON.parse(String(decoding: try Iconic.setting("Banking", icon: "lucide-piggy-bank", color: "pink", in: Data(file.utf8)), as: UTF8.self))
        #expect(recolored["fileIcons"]?["Banking"]?.keys == ["icon", "color", "unsynced"])
        // No icon and no colour: the entry goes.
        let removed = try OrderedJSON.parse(String(decoding: try Iconic.setting("Banking/Exchanges.md", icon: nil, color: nil, in: Data(file.utf8)), as: UTF8.self))
        #expect(removed["fileIcons"]?.keys == ["Banking"])
        #expect(Iconic.parse(added).icon(for: "Cars", folder: true)?.name == "🚗")
    }

    @Test func iconsFollowAMove() throws {
        let moved = try #require(try Iconic.moving([:], folder: ("Banking", "Money/Banking"), in: Data(file.utf8)))
        let json = try OrderedJSON.parse(String(decoding: moved, as: UTF8.self))
        #expect(json["fileIcons"]?.keys == ["Money/Banking", "Money/Banking/Exchanges.md"])
        #expect(try Iconic.moving(["Other.md": "New.md"], folder: nil, in: Data(file.utf8)) == nil)
    }
}
