import Foundation
import Testing
@testable import ArchTrip

struct TimelineTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func event(_ id: String, _ start: Date, _ end: Date) -> Event {
        Event(id: id, tripId: "trip", type: .business, title: id, startDate: start, endDate: end, createdAt: at(1, 0))
    }

    private func ids(_ items: [TimelineItem]) -> [String] {
        items.map { item in
            switch item {
            case .event(let event): event.id
            case .freeTime(let start, let end):
                "free(\(calendar.component(.hour, from: start)):\(calendar.component(.minute, from: start))-\(calendar.component(.hour, from: end)):\(calendar.component(.minute, from: end)))"
            }
        }
    }

    @Test func chronologicalOrder() {
        let events = [
            event("c", at(16, 15), at(16, 16)),
            event("a", at(16, 9), at(16, 10)),
            event("b", at(16, 10), at(16, 11)),
        ]
        let items = TimelineBuilder.items(for: at(16, 0), events: events, calendar: calendar)
        #expect(ids(items).filter { !$0.hasPrefix("free") } == ["a", "b", "c"])
    }

    @Test func exactThirtyMinuteGapIsFreeTime() {
        let events = [event("a", at(16, 9), at(16, 10)), event("b", at(16, 10, 30), at(16, 11))]
        let items = TimelineBuilder.items(for: at(16, 0), events: events, calendar: calendar)
        #expect(ids(items) == ["a", "free(10:0-10:30)", "b"])
    }

    @Test func gapUnderThirtyMinutesIsNotFreeTime() {
        let events = [event("a", at(16, 9), at(16, 10)), event("b", at(16, 10, 29), at(16, 11))]
        let items = TimelineBuilder.items(for: at(16, 0), events: events, calendar: calendar)
        #expect(ids(items) == ["a", "b"])
    }

    @Test func overlapDoesNotCreateFalseFreeTime() {
        // b is inside a; c starts 30 min after b ends but only 0 min after a ends.
        let events = [
            event("a", at(16, 9), at(16, 12)),
            event("b", at(16, 9, 30), at(16, 10)),
            event("c", at(16, 12), at(16, 13)),
        ]
        let items = TimelineBuilder.items(for: at(16, 0), events: events, calendar: calendar)
        #expect(ids(items) == ["a", "b", "c"])
    }

    @Test func zeroAndNegativeGapsAreNotFreeTime() {
        let events = [
            event("a", at(16, 9), at(16, 10)),
            event("b", at(16, 10), at(16, 11)),
            event("c", at(16, 10, 30), at(16, 12)),
        ]
        let items = TimelineBuilder.items(for: at(16, 0), events: events, calendar: calendar)
        #expect(ids(items) == ["a", "b", "c"])
    }

    @Test func multipleEventsAndGaps() {
        let events = [
            event("a", at(16, 9), at(16, 9, 30)),
            event("b", at(16, 11, 30), at(16, 13)),
            event("c", at(16, 13, 10), at(16, 14)),
            event("d", at(16, 16), at(16, 17)),
        ]
        let items = TimelineBuilder.items(for: at(16, 0), events: events, calendar: calendar)
        #expect(ids(items) == ["a", "free(9:30-11:30)", "b", "c", "free(14:0-16:0)", "d"])
    }

    @Test func noFreeTimeBeforeFirstOrAfterLastEvent() {
        let items = TimelineBuilder.items(for: at(16, 0), events: [event("a", at(16, 12), at(16, 13))], calendar: calendar)
        #expect(ids(items) == ["a"])
        #expect(TimelineBuilder.items(for: at(16, 0), events: [], calendar: calendar).isEmpty)
    }

    @Test func eventsCrossingMidnightAppearOnBothDays() {
        let overnight = event("night", at(15, 22), at(16, 7))
        let morning = event("morning", at(16, 9), at(16, 10))
        let dayBefore = TimelineBuilder.items(for: at(15, 0), events: [overnight, morning], calendar: calendar)
        #expect(ids(dayBefore) == ["night"])
        let day = TimelineBuilder.items(for: at(16, 0), events: [overnight, morning], calendar: calendar)
        #expect(ids(day) == ["night", "free(7:0-9:0)", "morning"])
    }

    @Test func eventEndingAtMidnightIsNotOnNextDay() {
        let late = event("late", at(15, 23), at(16, 0))
        #expect(TimelineBuilder.events(on: at(16, 0), from: [late], calendar: calendar).isEmpty)
        #expect(TimelineBuilder.events(on: at(15, 0), from: [late], calendar: calendar).map(\.id) == ["late"])
    }

    @Test func zeroLengthEventBelongsToItsStartDay() {
        let marker = event("marker", at(16, 0), at(16, 0))
        #expect(TimelineBuilder.events(on: at(16, 0), from: [marker], calendar: calendar).map(\.id) == ["marker"])
        #expect(TimelineBuilder.events(on: at(15, 0), from: [marker], calendar: calendar).isEmpty)
    }

    @Test func otherDaysAreExcluded() {
        let events = [event("a", at(16, 9), at(16, 10)), event("b", at(17, 9), at(17, 10))]
        let items = TimelineBuilder.items(for: at(16, 0), events: events, calendar: calendar)
        #expect(ids(items) == ["a"])
    }

    @Test func tripDaysIncludeRangeAndOutOfRangeEvents() {
        let trip = Trip(id: "trip", title: "t", destination: "d", startDate: at(15, 0), endDate: at(16, 0))
        let outside = event("x", at(20, 9), at(20, 10))
        let days = TimelineBuilder.days(for: trip, events: [outside], calendar: calendar)
        #expect(days == [at(15, 0), at(16, 0), at(20, 0)])
    }

    @Test func hoursAndMinutes() {
        #expect(TimelineBuilder.hoursAndMinutes(from: at(16, 9), to: at(16, 11)) == (2, 0))
        #expect(TimelineBuilder.hoursAndMinutes(from: at(16, 9), to: at(16, 9, 45)) == (0, 45))
        #expect(TimelineBuilder.hoursAndMinutes(from: at(16, 9), to: at(16, 10, 30)) == (1, 30))
    }
}
