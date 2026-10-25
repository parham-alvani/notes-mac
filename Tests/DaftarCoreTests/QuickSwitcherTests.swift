import Testing

@testable import DaftarCore

// Every fixture here is made up. The repository is public; the vault is not.

@Suite struct QuickSwitcherTests {
    let notes: [QuickSwitcher.Candidate] = [
        .init(path: "Learning/Infrastructure/Kubernetes/Kubernetes.md", title: "Kubernetes"),
        .init(path: "Learning/Infrastructure/Kubernetes/Firewall rules for Kubernetes.md", title: "Firewall rules for Kubernetes"),
        .init(path: "Learning/Infrastructure/Kubernetes/Kubectl.md", title: "Kubectl"),
        .init(path: "Companies/Docker/Docker.md", title: "Docker"),
        .init(path: "Companies/Docker/Interview.md", title: "Interview"),
        .init(path: "Companies/Acme/Interview.md", title: "Interview"),
        .init(path: "Notes/Inbox.md", title: "Inbox", aliases: ["In tray"]),
        .init(path: "Notes/Bookkeeping.md", title: "Bookkeeping"),
        .init(path: "Notes/Kebab recipes.md", title: "Kebab recipes"),
    ]

    func top(_ query: String, _ recent: [String] = []) -> [String] {
        QuickSwitcher.rank(query, in: notes, recent: recent).map { Vault.title(of: $0) }
    }

    @Test func theExactNameComesFirst() {
        #expect(top("kubernetes").first == "Kubernetes")
        // The exact name first, and the other notes about it still listed.
        #expect(top("kubernetes").contains("Firewall rules for Kubernetes"))
        #expect(top("Docker").first == "Docker")
    }

    @Test func aNameThatStartsWithTheQueryBeatsOneThatHoldsIt() {
        #expect(top("kub").prefix(2) == ["Kubectl", "Kubernetes"] || top("kub").prefix(2) == ["Kubernetes", "Kubectl"])
        #expect((top("kub").firstIndex(of: "Firewall rules for Kubernetes") ?? 99) > 1)
    }

    @Test func wordsMatchInAnyOrder() {
        #expect(top("kub fire").first == "Firewall rules for Kubernetes")
        #expect(top("fire kube").first == "Firewall rules for Kubernetes")
        #expect(top("kub zzz").isEmpty)
    }

    @Test func aFolderNameNarrowsNotesWithTheSameName() {
        // Two notes called Interview: the folder word picks one.
        #expect(QuickSwitcher.rank("docker interview", in: notes).first == "Companies/Docker/Interview.md")
        #expect(QuickSwitcher.rank("acme interv", in: notes).first == "Companies/Acme/Interview.md")
    }

    @Test func anAliasFindsItsNote() {
        #expect(top("in tray").first == "Inbox")
        #expect(top("tray").contains("Inbox"))
    }

    @Test func lettersThatSkipStillMatchButRankLow() {
        #expect(top("kbrnts").first == "Kubernetes")
        // "kb" is a word start in Kebab only loosely; the names that start
        // with k and b in a row come first.
        #expect(top("kebab").first == "Kebab recipes")
    }

    @Test func aRecentNoteWinsATieNotAClearRace() {
        let two = ["Companies/Acme/Interview.md"]
        #expect(QuickSwitcher.rank("interview", in: notes, recent: two).first == "Companies/Acme/Interview.md")
        // Recent, but a weak match, stays below the exact name.
        #expect(top("kubernetes", ["Learning/Infrastructure/Kubernetes/Firewall rules for Kubernetes.md"]).first == "Kubernetes")
    }

    @Test func lettersSpreadOverAPathAreNotResults() {
        // "kebab" is spelled out across "Kubernetes ... Kubectl" paths only loosely.
        #expect(top("kebab") == ["Kebab recipes"])
        #expect(!top("docker").contains("Kubernetes"))
    }

    @Test func anEmptyQueryListsTheRecentNotes() {
        #expect(QuickSwitcher.rank("  ", in: notes, recent: ["Notes/Inbox.md"]) == ["Notes/Inbox.md"])
    }
}
