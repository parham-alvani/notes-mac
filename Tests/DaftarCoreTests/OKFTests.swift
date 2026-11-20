import Foundation
import Testing

@testable import DaftarCore

/// `docs/specs/open-knowledge-format.md` in notes-linux, section 6, tests 1 to 7, by name.
@Suite struct OKFTests {
    func note(_ front: String, body: String = "# Title\n\ntext\n") -> String { "---\n\(front)\n---\n\(body)" }
    func concept(_ front: String) -> OKF.Concept? { OKF.concept(frontMatter: front) }
    func instant(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    @Test func aNoteWithATypeIsAConcept() {
        #expect(OKF.concept(note: note("type: Metric"), path: "Metrics/Revenue.md")?.type == "Metric")
        #expect(concept("type: Metric")?.type == "Metric")
        #expect(concept("type: \"Data Table\"\ntitle: Orders")?.type == "Data Table")
        // No front matter, no `type`, an empty one and a null one are none.
        #expect(OKF.concept(note: "# Title\n\ntype: Metric\n", path: "A.md") == nil)
        for front in ["title: Revenue", "type:", "type: \"\"", "type: null", "type: ~", "type: []", "types: Metric"] {
            #expect(concept(front) == nil, "\(front)")
            #expect(OKF.concept(note: note(front), path: "A.md") == nil, "\(front)")
        }
        // `index.md` and `log.md` are never concepts, whatever their front matter.
        for path in ["index.md", "log.md", "Docs/index.md", "Docs/sub/log.md"] {
            #expect(OKF.concept(note: note("type: Metric"), path: path) == nil, "\(path)")
        }
        #expect(OKF.concept(note: note("type: Metric"), path: "Docs/index-note.md") != nil)
        // The index says the same of the files of a vault.
        var index = VaultIndex()
        for path in ["Docs/index.md", "Docs/log.md", "Docs/Revenue.md", "Docs/Plain.md"] {
            index.files.insert(path)
            index.notes[path] = NoteEntry(path: path, modified: Date(), parsed: NoteParser.parse(note(path.hasSuffix("Plain.md") ? "title: Plain" : "type: Metric")))
        }
        index.derive()
        #expect(index.concept(of: "Docs/Revenue.md")?.type == "Metric")
        #expect(index.concept(of: "Docs/index.md") == nil && index.concept(of: "Docs/log.md") == nil && index.concept(of: "Docs/Plain.md") == nil)
        // The other keys are read as written; no title is the note's name, which the app gives.
        let full = concept("type: Metric\ntitle: Revenue\ndescription: Money in.\nresource: https://example.com/r\ntags: [finance, kpi]\nowner: data")
        #expect(full?.title == "Revenue" && full?.description == "Money in." && full?.resource == "https://example.com/r")
        #expect(full?.tags == ["finance", "kpi"])
        #expect(concept("type: Metric")?.title == nil)
    }

    @Test func theTrustTierComesFromCurrentEvents() {
        // No `verified` is unverified.
        #expect(concept("type: Metric")?.tier == .unverified)
        // A bare mapping is a list of one.
        let human = "verified: { by: \"human:parham\", at: \"2026-06-25T09:00:00Z\" }"
        #expect(concept("type: Metric\n\(human)")?.tier == .humanReviewed)
        #expect(concept("type: Metric\nverified:\n  by: \"human:parham\"\n  at: \"2026-06-25T09:00:00Z\"")?.tier == .humanReviewed)
        // Written again after it, the text is unverified: the event is history.
        let generated = "generated: { by: claude-code/2.1, at: \"2026-06-26T00:00:00Z\" }"
        let rewritten = concept("type: Metric\n\(generated)\n\(human)")
        #expect(rewritten?.tier == .unverified)
        #expect(rewritten?.verified.count == 1 && rewritten?.generated?.by == "claude-code/2.1")
        // A process's event after that is machine-confirmed.
        let nightly = "type: Metric\n\(generated)\nverified:\n  - { by: \"human:parham\", at: \"2026-06-25T09:00:00Z\" }\n  - by: \"process:nightly\"\n    at: \"2026-06-27T03:00:00Z\""
        #expect(concept(nightly)?.tier == .machineConfirmed)
        #expect(concept(nightly)?.lastVerified?.by == "process:nightly")
        // A team is not a person.
        #expect(concept("type: Metric\nverified: { by: \"team:x\", at: \"2026-06-25T09:00:00Z\" }")?.tier == .machineConfirmed)
        #expect(concept("type: Metric\nverified: [{ by: \"team:x\", at: 2026-06-25 }, { by: \"human:sara\", at: 2026-06-26 }]")?.tier == .humanReviewed)
        // An event with no `at`, or no `by`, is left out.
        for event in ["{ by: \"human:parham\" }", "{ at: \"2026-06-25T09:00:00Z\" }", "{ by: \"\", at: \"2026-06-25T09:00:00Z\" }", "{ by: \"human:parham\", at: null }"] {
            let left = concept("type: Metric\nverified: \(event)")
            #expect(left?.verified.isEmpty == true, "\(event)")
            #expect(left?.tier == .unverified, "\(event)")
        }
        // An event at the very second of `generated.at` is current.
        #expect(concept("type: Metric\n\(generated)\nverified: { by: \"human:parham\", at: \"2026-06-26T00:00:00Z\" }")?.tier == .humanReviewed)
        #expect(concept("type: Metric\n\(generated)\nverified: { by: \"human:parham\", at: \"2026-06-25T23:59:59Z\" }")?.tier == .unverified)
        // Only `human:` is a person.
        #expect(OKF.isPerson("human:parham") && !OKF.isPerson("team:data") && !OKF.isPerson("process:nightly") && !OKF.isPerson("claude-code/2.1") && !OKF.isPerson("human:"))
    }

    @Test func aTimeHasAnOffsetOrIsADay() {
        let two = instant("2026-06-30T14:00:00Z")
        #expect(OKF.time("2026-06-30T14:00:00Z") == .at(two))
        #expect(OKF.time("2026-06-30T16:00:00+02:00") == .at(two))
        #expect(OKF.time("2026-06-30T09:30:00-04:30") == .at(two))
        // Quoted or as YAML's own unquoted form, the same instant.
        for front in ["stale_after: \"2026-06-30T14:00:00Z\"", "stale_after: 2026-06-30T14:00:00Z", "stale_after: '2026-06-30T16:00:00+02:00'", "stale_after: 2026-06-30 16:00:00 +02:00"] {
            #expect(concept("type: Metric\n\(front)")?.staleAfter == .at(two), "\(front)")
        }
        // A day alone is the start of that day in UTC.
        let day = instant("2026-06-30T00:00:00Z")
        #expect(OKF.time("2026-06-30") == .at(day))
        for front in ["stale_after: 2026-06-30", "stale_after: \"2026-06-30\""] {
            #expect(concept("type: Metric\n\(front)")?.staleAfter == .at(day), "\(front)")
        }
        // A date-time without an offset, or anything else, is malformed.
        for bad in ["2026-06-30T14:00:00", "30/06/2026", "soon", "2026-02-30", "2026-13-01", "2026-06-30T25:00:00Z", "2026-6-30", "2026-06-30T14:00:00+2"] {
            #expect(OKF.time(bad) == .malformed(bad), "\(bad)")
        }
        #expect(OKF.stamp(two) == "2026-06-30T14:00:00Z")
        #expect(OKF.day(two) == "2026-06-30")
    }

    @Test func aConceptIsStaleAtItsInstant() {
        let now = instant("2026-09-23T00:00:00Z")
        let at = concept("type: Metric\nstale_after: \"2026-09-23T00:00:00Z\"")
        #expect(at?.isStale(now: now) == true)
        #expect(at?.staleTitle(now: now) == "Stale since 2026-09-23")
        #expect(concept("type: Metric\nstale_after: 2026-09-23")?.isStale(now: now) == true)
        // A second later is fresh.
        let later = concept("type: Metric\nstale_after: \"2026-09-23T00:00:01Z\"")
        #expect(later?.isStale(now: now) == false && later?.staleTitle(now: now) == nil)
        // Absent, null and empty are fresh.
        for front in ["type: Metric", "type: Metric\nstale_after:", "type: Metric\nstale_after: null", "type: Metric\nstale_after: \"\""] {
            let fresh = concept(front)
            #expect(fresh?.staleAfter == nil, "\(front)")
            #expect(fresh?.isStale(now: now) == false, "\(front)")
        }
        // A malformed one is stale, never fresh, and is shown as malformed.
        let soon = concept("type: Metric\nstale_after: soon")
        #expect(soon?.isStale(now: now) == true)
        #expect(soon?.staleIsMalformed == true)
        #expect(soon?.staleAfter == .malformed("soon"))
        #expect(soon?.staleTitle(now: now) == "Stale: bad date")
    }

    @Test func anUnknownStatusIsNotStable() {
        #expect(concept("type: Metric")?.status == .stable)
        #expect(concept("type: Metric\nstatus:")?.status == .stable)
        #expect(concept("type: Metric\nstatus: draft")?.status == .draft)
        #expect(concept("type: Metric\nstatus: stable")?.status == .stable)
        #expect(concept("type: Metric\nstatus: deprecated")?.status == .deprecated)
        let archived = concept("type: Metric\nstatus: archived")
        #expect(archived?.status == .other("archived"))
        #expect(archived?.status.isStable == false)
        #expect(archived?.status.title == "archived")
        #expect(OKF.Status.stable.title == nil && OKF.Status.draft.title == "Draft" && OKF.Status.deprecated.title == "Deprecated")
        // A scalar `tags` is one tag, never split at commas.
        #expect(concept("type: Metric\ntags: a, b")?.tags == ["a, b"])
        #expect(concept("type: Metric\ntags:\n  - a\n  - b")?.tags == ["a", "b"])
        #expect(concept("type: Metric\ntags: []")?.tags == [])
        // `superseded_by` is a path, kept as written.
        #expect(concept("type: Metric\nstatus: deprecated\nsuperseded_by: /metrics/net-revenue.md")?.supersededBy == "/metrics/net-revenue.md")
    }

    @Test func aMarkdownLinkResolvesAsOKFSays() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "daftar-okf-\(UUID().uuidString)")
        let root = base.appending(path: "vault")
        defer { try? FileManager.default.removeItem(at: base) }
        func write(_ text: String, _ path: String) throws {
            let file = root.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        try write("---\nokf_version: \"0.3\"\n---\n# Notes\n", "Docs/index.md")
        try write("---\ntype: Table\n---\n# Orders\n", "Docs/tables/orders.md")
        try write(
            "---\ntype: Metric\n---\n# Revenue\n\n## Definition\n\n[a](/tables/orders.md) [b](../tables/orders.md) [c](./revenue.md#Definition) [d](my%20note.md) [e](../../../etc/passwd) [f](/../x.md) [g](https://example.com/x.md)\n",
            "Docs/metrics/revenue.md")
        try write("# My note\n", "Docs/metrics/my note.md")
        try write("[orders](/Docs/tables/orders.md) [up](/../x.md)\n", "Other/x.md")
        try write("# x at the top\n", "x.md")
        // A file outside the vault, which no link may reach.
        try "secret".write(to: base.appending(path: "passwd"), atomically: true, encoding: .utf8)
        let index = Vault.index(root)
        #expect(index.bundleRoots == ["Docs"])
        let from = "Docs/metrics/revenue.md"
        func link(_ href: String, from source: String) -> (path: String?, anchor: String?) {
            guard let (target, anchor) = NoteParser.destination(href, bracketed: false) else { return (nil, nil) }
            return (index.resolve(markdown: target, from: source), anchor)
        }
        // A `/` path resolves from the bundle root, any other from the note's folder.
        #expect(link("/tables/orders.md", from: from).path == "Docs/tables/orders.md")
        #expect(link("../tables/orders.md", from: from).path == "Docs/tables/orders.md")
        let own = link("./revenue.md#Definition", from: from)
        #expect(own.path == from && own.anchor == "Definition")
        #expect(index.notes[from]?.parsed.headings.contains { $0.text == "Definition" } == true)
        #expect(link("my%20note.md", from: from).path == "Docs/metrics/my note.md")
        // With no bundle above the note, a `/` path is from the vault's root.
        #expect(link("/Docs/tables/orders.md", from: "Other/x.md").path == "Docs/tables/orders.md")
        // What leaves the vault, or its bundle by a `/` path, resolves to nothing.
        #expect(link("../../../etc/passwd", from: from).path == nil)
        #expect(link("../../../passwd", from: from).path == nil)
        #expect(link("/../x.md", from: from).path == nil)
        #expect(link("/../x.md", from: "Other/x.md").path == nil)
        #expect(OKF.resolve("../../../etc/passwd", from: from, files: index.files, roots: index.bundleRoots) == nil)
        // A web address is no file.
        #expect(NoteParser.destination("https://example.com/x.md", bracketed: false) == nil)
        #expect(NoteParser.destination("mailto:a@b.c", bracketed: false) == nil)
        // A resolved Markdown link is a link: it is in the backlinks, and the broken ones are not.
        #expect((index.backlinks["Docs/tables/orders.md"] ?? []).map(\.source).sorted() == [from, "Other/x.md"])
        #expect((index.backlinks["Docs/metrics/my note.md"] ?? []).map(\.source) == [from])
        #expect(index.backlinks["x.md"] == nil)
        #expect(NoteGraph.neighbours(of: from, in: index).sorted() == ["Docs/metrics/my note.md", "Docs/tables/orders.md"])
        // `superseded_by` resolves by the same rules.
        try write("---\ntype: Metric\nstatus: deprecated\nsuperseded_by: /metrics/revenue.md\n---\n# Old\n", "Docs/metrics/old.md")
        #expect(Vault.index(root).superseding("Docs/metrics/old.md") == from)
        // A move writes the link again in the form it had, percent-encoded.
        try VaultMoves.perform("Docs/tables/orders.md", to: "Docs/tables/all orders.md", index: index, root: root)
        let text = try String(contentsOf: root.appending(path: from), encoding: .utf8)
        #expect(text.contains("[a](/tables/all%20orders.md) [b](../tables/all%20orders.md)"))
        #expect(try String(contentsOf: root.appending(path: "Other/x.md"), encoding: .utf8).hasPrefix("[orders](/Docs/tables/all%20orders.md)"))
        #expect(text.contains("[e](../../../etc/passwd) [f](/../x.md)"))
    }

    @Test func markAsVerifiedWritesOneEvent() throws {
        let text = "---\ntitle: \"Revenue\"   # as shown\ntype: Metric\nverified: { by: \"process:nightly\", at: \"2026-06-25T03:00:00Z\" }\n\ntags:\n    - finance\nowner:   data\n---\n# Revenue\n\n---\n\ntext\n"
        let now = instant("2026-06-30T14:00:05Z")
        let marked = try OKF.markVerified(text, by: "human:parham", at: now)
        // A list of the two, and every other line byte for byte.
        #expect(marked == "---\ntitle: \"Revenue\"   # as shown\ntype: Metric\nverified:\n  - { by: \"process:nightly\", at: \"2026-06-25T03:00:00Z\" }\n  - { by: \"human:parham\", at: \"2026-06-30T14:00:05Z\" }\n\ntags:\n    - finance\nowner:   data\n---\n# Revenue\n\n---\n\ntext\n")
        let concept = try #require(OKF.concept(note: marked))
        #expect(concept.verified.map(\.by) == ["process:nightly", "human:parham"])
        #expect(concept.tier == .humanReviewed)
        // Marking again replaces the person's event, not adds a second.
        let again = try OKF.markVerified(marked, by: "human:parham", at: instant("2026-07-01T08:00:00Z"))
        let twice = try #require(OKF.concept(note: again))
        #expect(twice.verified.map(\.by) == ["process:nightly", "human:parham"])
        #expect(twice.verified.last?.at == .at(instant("2026-07-01T08:00:00Z")))
        #expect(again.replacingOccurrences(of: "2026-07-01T08:00:00Z", with: "2026-06-30T14:00:05Z") == marked)
        // A concept with no `verified` gets the key last; a block list keeps its events.
        #expect(try OKF.markVerified("---\ntype: Metric\n---\nbody", by: "human:parham", at: now) == "---\ntype: Metric\nverified:\n  - { by: \"human:parham\", at: \"2026-06-30T14:00:05Z\" }\n---\nbody")
        let block = "---\r\ntype: Metric\r\nverified:\r\n  - by: \"team:data\"\r\n    at: 2026-06-01\r\n    note: checked\r\nstatus: draft\r\n---\r\nbody\r\n"
        #expect(try OKF.markVerified(block, by: "human:parham", at: now)
            == "---\r\ntype: Metric\r\nverified:\r\n  - { by: \"team:data\", at: \"2026-06-01\", note: \"checked\" }\r\n  - { by: \"human:parham\", at: \"2026-06-30T14:00:05Z\" }\r\nstatus: draft\r\n---\r\nbody\r\n")
        // A note with no `type` is refused, and so are the reserved names.
        #expect(throws: OKF.Failure.notAConcept) { try OKF.markVerified("---\ntitle: Plain\n---\nbody", by: "human:parham", at: now) }
        #expect(throws: OKF.Failure.notAConcept) { try OKF.markVerified("# No front matter\n", by: "human:parham", at: now) }
        #expect(throws: OKF.Failure.notAConcept) { try OKF.markVerified("---\ntype: Metric\n---\n", by: "human:parham", at: now, path: "Docs/index.md") }
        // Who signs: the setting, else the local part of the clone's email, else nobody.
        #expect(OKF.actor(configured: "parham", email: "x@example.com") == "human:parham")
        #expect(OKF.actor(configured: "human:parham", email: nil) == "human:parham")
        #expect(OKF.actor(configured: "  ", email: "sara@example.com") == "human:sara")
        #expect(OKF.actor(configured: "", email: nil) == nil)
        #expect(OKF.actor(configured: "", email: "") == nil)
    }
}
