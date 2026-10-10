import Foundation
import Testing
@testable import ArchTrip

/// RF-02: changing a Trip's dates never moves its Events; the editor only warns.
struct TripDatesWarningTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func event(_ id: String, _ start: Date, _ end: Date) -> Event {
        Event(id: id, tripId: "trip", type: .architecture, title: id, startDate: start, endDate: end, createdAt: at(1, 0))
    }

    private var trip: Trip {
        Trip(id: "trip", title: "Sapporo", destination: "Sapporo", startDate: at(15, 0), endDate: at(17, 0))
    }

    private func warning(start: Date, end: Date, events: EventLoadState) -> TripDatesWarning? {
        TripDatesWarning.forDates(start: start, end: end, of: trip, events: events, calendar: calendar)
    }

    @Test func unchangedDatesNeedNoWarning() {
        let outside = event("early", at(5, 10), at(5, 11))
        // Same days, even with a different time of day, and even with an Event already outside.
        #expect(warning(start: at(15, 9), end: at(17, 18), events: .loaded([outside], complete: true)) == nil)
        #expect(warning(start: at(15, 0), end: at(17, 0), events: .loading) == nil)
    }

    @Test func noWarningWhenEveryEventStillFits() {
        let inside = event("inside", at(16, 9), at(16, 10))
        #expect(warning(start: at(16, 0), end: at(16, 0), events: .loaded([inside], complete: true)) == nil)
    }

    @Test func countsEventsLeftOutside() {
        let kept = event("kept", at(15, 9), at(15, 10))
        let dropped = event("dropped", at(17, 9), at(17, 10))
        let alreadyOutside = event("early", at(5, 10), at(5, 11))
        let result = warning(start: at(15, 0), end: at(16, 0), events: .loaded([kept, dropped, alreadyOutside], complete: true))
        #expect(result == .outside(count: 2, complete: true))
    }

    @Test func partialLoadIsNeverSilent() {
        #expect(warning(start: at(15, 0), end: at(16, 0), events: .loaded([], complete: false)) == .outside(count: 0, complete: false))
        let dropped = event("dropped", at(17, 9), at(17, 10))
        #expect(warning(start: at(15, 0), end: at(16, 0), events: .loaded([dropped], complete: false)) == .outside(count: 1, complete: false))
    }

    /// G6: an all-day Event counts by the days it applies to (a stay by its nights).
    @Test func allDayEventsAreCountedByTheirDays() {
        let stay = Event(
            id: "stay", tripId: "trip", type: .hotel, title: "stay",
            startDate: at(16, 0), endDate: at(18, 0), createdAt: at(1, 0), isAllDay: true
        ) // nights 16, 17
        #expect(warning(start: at(16, 0), end: at(17, 0), events: .loaded([stay], complete: true)) == nil)
        #expect(warning(start: at(15, 0), end: at(16, 0), events: .loaded([stay], complete: true)) == .outside(count: 1, complete: true))
    }

    @Test func unknownWhileLoadingOrAfterFailure() {
        #expect(warning(start: at(15, 0), end: at(16, 0), events: .loading) == .unknown)
        #expect(warning(start: at(15, 0), end: at(16, 0), events: .failed) == .unknown)
    }
}
