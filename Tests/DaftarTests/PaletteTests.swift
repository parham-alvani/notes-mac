import DaftarCore
import SwiftUI
import Testing

@testable import DaftarUI

@MainActor
@Suite struct PaletteTests {
    let commands = ["New Note", "New Folder", "Open Random Note", "Rename", "Sync Now", "Show the Graph"].map { title in
        PaletteCommand(id: title, title: title, group: "Test", symbol: "star", color: .orange) {}
    }

    @Test func ranksByTheMatch() {
        #expect(PaletteCommands.filter(commands, "rn", recent: []).first?.command.title == "Open Random Note")
        #expect(PaletteCommands.filter(commands, "nn", recent: []).first?.command.title == "New Note")
        #expect(PaletteCommands.filter(commands, "graph", recent: []).map(\.command.title) == ["Show the Graph"])
        #expect(PaletteCommands.filter(commands, "zzz", recent: []).isEmpty)
    }

    @Test func recentCommandsComeFirst() {
        #expect(PaletteCommands.filter(commands, "", recent: ["Sync Now"]).first?.command.title == "Sync Now")
        // A recent command wins a near tie.
        #expect(PaletteCommands.filter(commands, "new", recent: ["New Folder"]).first?.command.title == "New Folder")
    }

    @Test func theMatchedLettersAreMarked() {
        let result = PaletteCommands.filter(commands, "sn", recent: [])
        #expect(result.first?.command.title == "Sync Now")
        #expect(result.first?.positions == [0, 5])
    }
}
