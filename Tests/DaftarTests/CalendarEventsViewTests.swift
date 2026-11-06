import AppKit
import DaftarCore
import Foundation
import SwiftUI
import Testing

@testable import DaftarUI

/// `calendar.place` in the app (`docs/specs/calendar-events.md` in
/// notes-linux): the setting, the events it shows, the note of each, and
/// the day picker, on a made-up vault.
@MainActor
@Suite(.serialized) struct CalendarEventsViewTests {
    let root: URL
    let store: VaultStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Days"), withIntermediateDirectories: true)
        try "# Three Kings\n".write(to: root.appending(path: "Days/Three Kings' Day.md"), atomically: true, encoding: .utf8)
        store = VaultStore(settings: AppSettings(url: root.appending(path: "config/config.toml")), openVault: false)
        store.openSynchronously(root)
    }

    @Test func thePlaceIsASetting() throws {
        let settings = store.settings
        #expect(settings.place == nil)
        #expect(store.calendarEvents(from: Day("2027-01-01")!, to: Day("2027-01-31")!).isEmpty)
        settings.calendarPlace = "Barcelona"
        #expect(ConfigFile(text: try String(contentsOf: settings.url, encoding: .utf8)).string("calendar.place") == "Barcelona")
        #expect(AppSettings(url: settings.url).place == .barcelona)
        let january = store.calendarEvents(from: Day("2027-01-01")!, to: Day("2027-01-31")!).map(\.event.title)
        #expect(january == ["New Year's Day", "Three Kings' Parade", "Three Kings' Day"])
        settings.calendarPlace = "madrid"
        #expect(settings.place == nil)
        #expect(!settings.persianCalendar)
    }

    @Test func anEventOpensTheNoteByItsTitle() throws {
        let events = CalendarEvents.on(.spain, Day("2027-01-06")!)
        #expect(store.note(of: try #require(events.first)) == "Days/Three Kings' Day.md")
        // No note, no link; the app never makes one.
        #expect(store.note(of: try #require(CalendarEvents.on(.spain, Day("2027-01-01")!).first)) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "New Year's Day.md").path))
    }

    @Test func aDaySaysItsDateAndItsEvents() {
        let day = Day("2027-06-24")!
        let events = CalendarEvents.on(.barcelona, day)
        #expect(DayPicker.long(day) == "Thursday, 24 June 2027")
        #expect(DayPicker.describe(day, in: Month.of(.gregorian, day), events: events) == "Thursday, 24 June 2027\nSant Joan (holiday)")
        let jalali = DayPicker.describe(day, in: Month.of(.jalali, day), events: [])
        #expect(jalali.hasPrefix("Thursday, 24 June 2027\n") && jalali.contains("تیر"))
        #expect(EventRow.short(day) == "Thu 24 Jun")
        let dots = DayPicker.events(.barcelona, Month.of(.gregorian, day).cells.compactMap { $0 })
        #expect(dots[Day("2027-06-23")!]?.map(\.title) == ["Sant Joan's Eve"])
        #expect(DayPicker.events(nil, [day]).isEmpty)
    }

    @Test func thePickerDrawsBothCalendars() {
        for persian in [false, true] {
            store.settings.persianCalendar = persian
            let view = NSHostingView(rootView: DayPicker(selected: Day("2026-11-03")) { _ in }.environment(store))
            view.frame = CGRect(x: 0, y: 0, width: 300, height: 320)
            view.layoutSubtreeIfNeeded()
            #expect(view.fittingSize.width > 200)
        }
        store.settings.persianCalendar = false
    }
}
