import Foundation
import Testing

@testable import DaftarCore

@Suite struct DetectedTests {
    @Test func addressesAndPhonesAreFound() {
        let text = """
            ---
            phone: +34 612 345 678
            ---
            Call the office at +34 612 345 678 before noon.
            The flat is at 1 Infinite Loop, Cupertino, CA 95014.
            - [ ] Pay rent 📅 2026-10-30 at 10:30
            `+34 699 999 999` and [[Note +34 655 555 555]]
            """
        let found = Detected.find(in: text)
        let phones = found.filter { $0.kind == .phone }
        #expect(phones.map(\.text) == ["+34 612 345 678"])
        #expect(phones.first?.value == "+34612345678")
        #expect(phones.first?.line == 3)
        let places = found.filter { $0.kind == .address }
        #expect(places.count == 1)
        #expect(places.first?.text.hasPrefix("1 Infinite Loop") == true)
    }

    @Test func datesAndShortNumbersAreNotPhones() {
        #expect(!Detected.isPhone("2026-10-30"))
        #expect(!Detected.isPhone("12345"))
        #expect(Detected.isPhone("(021) 8888 1234"))
    }
}
