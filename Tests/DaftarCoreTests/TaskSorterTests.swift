import Foundation
import Testing

@testable import DaftarCore

/// The vault's Task Sorter plugin: done and cancelled tasks first, in each section.
@Suite struct TaskSorterTests {
    @Test func doneTasksGoFirstWithTheirSubItems() {
        let text = """
            # Plan
            - [ ] Write the report
                - [x] Outline
            - [x] Book the room
            - [-] Call the bank
            	note under the call
            - [ ] Send the slides
            """
        #expect(TaskSorter.sort(text) == """
            # Plan
            - [x] Book the room
            - [-] Call the bank
            	note under the call
            - [ ] Write the report
                - [x] Outline
            - [ ] Send the slides
            """)
    }

    @Test func eachSectionIsSortedOnItsOwnAndOtherLinesStay() {
        let text = """
            - [ ] Open on top
            - [X] Done on top
            ## Next
            Some words.
            - [ ] Open
            Between the tasks.
            - [x] Done
            ## Last
            - [x] Already first
            - [ ] Already last
            """
        #expect(TaskSorter.sort(text) == """
            - [X] Done on top
            - [ ] Open on top
            ## Next
            Some words.
            - [x] Done
            Between the tasks.
            - [ ] Open
            ## Last
            - [x] Already first
            - [ ] Already last
            """)
    }

    @Test func aSortedNoteIsLeftAlone() {
        #expect(TaskSorter.sort("- [x] a\n- [ ] b\n") == nil)
        #expect(TaskSorter.sort("") == nil)
        #expect(TaskSorter.sort("# Only a heading") == nil)
        // In progress, an indented task and a `*` bullet are not root tasks.
        #expect(TaskSorter.sort("- [/] going\n- [x] done\n") == nil)
        #expect(TaskSorter.sort("  - [ ] a\n  - [x] b") == nil)
        #expect(TaskSorter.sort("* [ ] a\n* [x] b") == nil)
    }

    @Test func sortingTwiceChangesNothing() {
        let text = "- [ ] a\n- [x] b\n- [ ] c\n- [-] d"
        let once = TaskSorter.sort(text)
        #expect(once == "- [x] b\n- [-] d\n- [ ] a\n- [ ] c")
        #expect(once.flatMap(TaskSorter.sort) == nil)
    }
}
