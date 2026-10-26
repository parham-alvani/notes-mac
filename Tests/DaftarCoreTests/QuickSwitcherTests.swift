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

    @Test func aPathFindsItsFile() {
        #expect(QuickSwitcher.rank("Companies/Docker/Interview", in: notes).first == "Companies/Docker/Interview.md")
        #expect(QuickSwitcher.rank("acme/interview", in: notes).first == "Companies/Acme/Interview.md")
        // Folders shortened as in VS Code, and a path word with a name word.
        #expect(QuickSwitcher.rank("comp/dock int", in: notes).first == "Companies/Docker/Interview.md")
        #expect(QuickSwitcher.rank("kube/fire", in: notes).first == "Learning/Infrastructure/Kubernetes/Firewall rules for Kubernetes.md")
    }

    @Test func aFolderListsWhatIsInIt() {
        let docker = QuickSwitcher.rank("Companies/Docker/", in: notes)
        #expect(Set(docker) == ["Companies/Docker/Docker.md", "Companies/Docker/Interview.md"])
        #expect(Set(QuickSwitcher.rank("notes/", in: notes)) == ["Notes/Inbox.md", "Notes/Bookkeeping.md", "Notes/Kebab recipes.md"])
    }

    @Test func attachmentsAreFoundAfterNotes() {
        let files = notes + [.init(path: "Companies/Docker/docker.png", title: "docker.png")]
        #expect(QuickSwitcher.rank("docker", in: files).prefix(2) == ["Companies/Docker/Docker.md", "Companies/Docker/docker.png"])
        #expect(QuickSwitcher.rank("docker png", in: files).first == "Companies/Docker/docker.png")
    }

    @Test func theMatchedLettersAreMarked() {
        let marks = QuickSwitcher.highlights("dock/int", title: "Interview", folder: "Companies/Docker")
        #expect(marks.folder == [10, 11, 12, 13, 16])
        #expect(marks.title == [0, 1, 2])
        let plain = QuickSwitcher.highlights("acme int", title: "Interview", folder: "Companies/Acme")
        #expect(plain.title == [0, 1, 2])
        #expect(plain.folder == [10, 11, 12, 13])
    }

    @Test func lettersOnlyAreShownWhenNothingElseMatches() {
        let files = notes + [.init(path: "Cars/Cards of the week.md", title: "Cards of the week"), .init(path: "Car/Insurance.md", title: "Insurance")]
        // A file holds both words: the spread-out ones go.
        let ranked = QuickSwitcher.ranking("car insurance", in: files)
        #expect(ranked.paths == ["Car/Insurance.md"])
        #expect(!ranked.loose)
        // Nothing holds the words: the spread-out letters are all there is, and say so.
        let spread = QuickSwitcher.ranking("car", in: [.init(path: "Reinsurance Group of America.md", title: "Reinsurance Group of America")])
        #expect(spread.loose)
        #expect(spread.paths == ["Reinsurance Group of America.md"])
        // A match so weak that its score is below zero is still listed.
        let long = "abbbbbbbbxbbbbbbbbqbbbbbbbbzbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        #expect(QuickSwitcher.rank("xqz", in: [.init(path: long + ".md", title: long)]) == [long + ".md"])
        // Letters from the start of a word, close together, are a close match.
        #expect(!QuickSwitcher.ranking("kbrnts", in: notes).loose)
    }

    @Test func aHashStartsTheHeadingPart() {
        #expect(QuickSwitcher.heading(in: "Plan#Goals")! == ("Plan", "Goals"))
        #expect(QuickSwitcher.heading(in: "#")! == ("", ""))
        #expect(QuickSwitcher.heading(in: "Plan") == nil)
        let headings = [Heading(level: 1, text: "Plan", line: 0), Heading(level: 2, text: "Goals for the year", line: 3), Heading(level: 2, text: "Budget", line: 9)]
        #expect(QuickSwitcher.headings("", in: headings) == headings)
        #expect(QuickSwitcher.headings("goal", in: headings).map(\.text) == ["Goals for the year"])
        #expect(QuickSwitcher.headings("bud", in: headings).first?.line == 9)
    }
}
