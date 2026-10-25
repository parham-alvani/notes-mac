import Testing

@testable import DaftarCore

@Suite struct TaskFieldsTests {
    @Test func readsEveryPart() throws {
        let fields = try #require(TaskLine.fields("    - [/] Call [[Alpha]] #work 🔼 🔁 every week 🆔 abc ⏳ 2026-10-24 📅 2026-10-30 ^block-1"))
        #expect(fields.status == "/")
        #expect(fields.text == "Call [[Alpha]] #work")
        #expect(fields.priority == "🔼")
        #expect(fields.recurring == "every week")
        #expect(fields.scheduled == "2026-10-24")
        #expect(fields.due == "2026-10-30")
        #expect(fields.other == [TaskMetadata.Meta(emoji: "🆔", value: "abc")])
        #expect(TaskLine.fields("Just a line") == nil)
    }

    @Test func writesInThePluginsOrderAndKeepsTheRest() throws {
        let raw = "    - [/] Call [[Alpha]] #work 🔼 🔁 every week 🆔 abc ⏳ 2026-10-24 📅 2026-10-30 ^block-1"
        var fields = try #require(TaskLine.fields(raw))
        // Unchanged fields write the same line.
        #expect(TaskLine.edited(raw, fields) == raw)
        fields.due = "2026-11-02"
        fields.priority = "⏫"
        fields.start = "2026-10-26"
        fields.recurring = nil
        #expect(TaskLine.edited(raw, fields) == "    - [/] Call [[Alpha]] #work ⏫ 🆔 abc 🛫 2026-10-26 ⏳ 2026-10-24 📅 2026-11-02 ^block-1")
    }

    @Test func aFieldClearedLeavesNoEmoji() throws {
        var fields = try #require(TaskLine.fields("> - [ ] Pay 📅 2026-10-30"))
        fields.due = nil
        fields.text = "Pay the rent"
        #expect(TaskLine.edited("> - [ ] Pay 📅 2026-10-30", fields) == "> - [ ] Pay the rent")
    }

    @Test func theEditIsRefusedWhenTheLineChanged() throws {
        let text = "# Tasks\n- [ ] One 📅 2026-10-30\n- [ ] Two\n"
        let before = try #require(TaskLine.fields("- [ ] One 📅 2026-10-30"))
        var after = before
        after.due = "2026-11-01"
        #expect(try VaultEdits.editTask(in: text, line: 1, before: before, fields: after) == "# Tasks\n- [ ] One 📅 2026-11-01\n- [ ] Two\n")
        #expect(throws: VaultEdits.Failure.taskMoved) { try VaultEdits.editTask(in: text, line: 2, before: before, fields: after) }
    }

    @Test func aPriorityTakesNoValueAndADateOnlyADate() throws {
        let urgent = "- [ ] 🔺 urgent thing"
        let fields = try #require(TaskLine.fields(urgent))
        #expect(fields.priority == nil)
        #expect(fields.text == "🔺 urgent thing")
        #expect(TaskLine.edited(urgent, fields) == urgent)
        let split = TaskMetadata.split("Call 📅 tomorrow morning ⏫")
        #expect(split.text == "Call 📅 tomorrow morning")
        #expect(split.meta == [.init(emoji: "⏫", value: "")])
        // The recurrence keeps its words.
        #expect(TaskMetadata.split("Gym 🔁 every week").meta == [.init(emoji: "🔁", value: "every week")])
    }

    @Test func twoFieldsOfOneKindDropNothing() throws {
        for raw in ["- [ ] Move 📅 2026-10-25 then 📅 2026-10-26", "- [ ] Run 🔁 every day or 🔁 every week", "- [ ] Pick 🔼 ⏫"] {
            let fields = try #require(TaskLine.fields(raw))
            #expect(TaskLine.edited(raw, fields) == raw)
        }
    }

    @Test func onCompletionIsAField() throws {
        let fields = try #require(TaskLine.fields("- [ ] Bins 🔁 every day 🏁 delete 📅 2026-10-25"))
        #expect(fields.text == "Bins")
        #expect(fields.recurring == "every day")
        #expect(fields.due == "2026-10-25")
        #expect(fields.other == [TaskMetadata.Meta(emoji: "🏁", value: "delete")])
        #expect(TaskLine.edited("- [ ] Bins 🔁 every day 🏁 delete 📅 2026-10-25", fields) == "- [ ] Bins 🔁 every day 🏁 delete 📅 2026-10-25")
    }
}
