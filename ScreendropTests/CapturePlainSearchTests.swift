import Foundation
import Testing

/// The parts of plain-words Library search that need no model. The model
/// itself runs in `scripts/check-capture-plain-search.py`.
struct CapturePlainSearchTests {
    @Test func theModelIsToldTodaysDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 9)))
        let instructions = CapturePlainSearch.instructions(now: now, calendar: calendar, locale: Locale(identifier: "en_US"))
        #expect(instructions.contains("today is Tuesday, November 10, 2026."))
    }

    @Test func eachCaptureIsListedOnceInTheOrderFound() {
        #expect(CapturePlainSearch.unique(["b", "a", "b", "c", "a"], limit: 20) == ["b", "a", "c"])
        #expect(CapturePlainSearch.unique(["b", "a", "b", "c"], limit: 2) == ["b", "a"])
    }
}
