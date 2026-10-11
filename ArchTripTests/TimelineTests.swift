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

    /// An all-day Event stored at local midnight, applying to [start, end).
    private func allDay(_ id: String, _ type: EventType, _ start: Date, _ end: Date) -> Event {
        Event(id: id, tripId: "trip", type: type, title: id, startDate: start, endDate: end, createdAt: at(1, 0), isAllDay: true)
    }

    private func ids(_ items: [TimelineItem]) -> [String] {
        items.map { item in
            switch item {
            case .event(let event): event.id
            case .freeTime(let start, let end):
                "free(\(calendar.component(.hour, from: start)):\(calendar.component(.minute, from: start))-\(calendar.component(.hour, from: end)):\(calendar.component(.minute, from: end)))"
            case .now(let date):
                "now(\(calendar.component(.hour, from: date)):\(calendar.component(.minute, from: date)))"
            case .marker(let marker):
                marker.id
            }
        }
    }

    /// Travel / Free Time seconds in `items`, to check that splitting changes nothing.
    private func freeSeconds(_ items: [TimelineItem]) -> TimeInterval {
        items.reduce(0) { total, item in
            if case .freeTime(let start, let end) = item { return total + end.timeIntervalSince(start) }
            return total
        }
    }

    private func noNegativeOrEmptyGaps(_ items: [TimelineItem]) -> Bool {
        items.allSatisfy { item in
            if case .freeTime(let start, let end) = item { return end > start }
            return true
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

    @Test func dayOutsideTripDates() {
        let trip = Trip(id: "trip", title: "t", destination: "d", startDate: at(15, 0), endDate: at(17, 0))
        #expect(TimelineBuilder.isOutside(at(14, 23, 59), trip: trip, calendar: calendar))
        #expect(!TimelineBuilder.isOutside(at(15, 0), trip: trip, calendar: calendar))
        #expect(!TimelineBuilder.isOutside(at(17, 23, 30), trip: trip, calendar: calendar))
        #expect(TimelineBuilder.isOutside(at(18, 0), trip: trip, calendar: calendar))
    }

    @Test func eventsOutsideTripDates() {
        let trip = Trip(id: "trip", title: "t", destination: "d", startDate: at(15, 0), endDate: at(17, 0))
        let before = event("before", at(5, 10), at(5, 11))
        let inside = event("inside", at(16, 9), at(16, 10))
        let spillsOver = event("spills", at(17, 22), at(18, 7))
        let endsAtMidnight = event("midnight", at(17, 22), at(18, 0))
        let after = event("after", at(20, 9), at(20, 10))
        let marker = event("marker", at(14, 0), at(14, 0))
        let outside = TimelineBuilder.events(
            outside: trip, from: [after, inside, before, spillsOver, endsAtMidnight, marker], calendar: calendar
        )
        #expect(outside.map(\.id) == ["before", "marker", "spills", "after"])
        #expect(TimelineBuilder.events(outside: trip, from: [inside, endsAtMidnight], calendar: calendar).isEmpty)
    }

    // MARK: All-day (G6)

    @Test func allDayEventsNeverEnterTheTimedTimelineOrItsGaps() {
        let stay = allDay("stay", .hotel, at(15, 0), at(17, 0))
        let a = event("a", at(16, 9), at(16, 10))
        let b = event("b", at(16, 11), at(16, 12))
        let items = TimelineBuilder.items(for: at(16, 0), events: [stay, a, b], calendar: calendar)
        #expect(ids(items) == ["a", "free(10:0-11:0)", "b"], "the gap is unchanged by the stay")
        #expect(TimelineBuilder.events(on: at(16, 0), from: [stay], calendar: calendar).isEmpty)
        #expect(TimelineBuilder.items(for: at(15, 0), events: [stay], calendar: calendar).isEmpty)
        // A stored false is timed, like a missing flag.
        var flaggedFalse = event("f", at(16, 13), at(16, 14))
        flaggedFalse.isAllDay = false
        #expect(TimelineBuilder.events(on: at(16, 0), from: [flaggedFalse], calendar: calendar).map(\.id) == ["f"])
        #expect(TimelineBuilder.allDayEvents(on: at(16, 0), from: [flaggedFalse], calendar: calendar).isEmpty)
    }

    @Test func allDayEventsOnADayInSectionOrder() {
        let stay = allDay("stay", .hotel, at(15, 0), at(17, 0)) // nights 15, 16
        let car = allDay("car", .car, at(15, 0), at(18, 0)) // days 15–17
        let laterNote = allDay("note-b", .other, at(16, 0), at(17, 0))
        let earlierNote = allDay("note-a", .business, at(15, 0), at(17, 0))
        let timed = event("timed", at(16, 9), at(16, 10))
        let all = [laterNote, timed, car, earlierNote, stay]
        #expect(TimelineBuilder.allDayEvents(on: at(16, 0), from: all, calendar: calendar).map(\.id) == ["stay", "car", "note-a", "note-b"])
        #expect(TimelineBuilder.allDayEvents(on: at(15, 0), from: all, calendar: calendar).map(\.id) == ["stay", "car", "note-a"])
        #expect(TimelineBuilder.allDayEvents(on: at(17, 0), from: all, calendar: calendar).map(\.id) == ["car"])
        #expect(TimelineBuilder.allDayEvents(on: at(18, 0), from: all, calendar: calendar).isEmpty)
        #expect(TimelineBuilder.allDayEvents(on: at(14, 0), from: all, calendar: calendar).isEmpty)
    }

    @Test func tripDaysReachEveryDayOfAnAllDayEvent() {
        let trip = Trip(id: "trip", title: "t", destination: "d", startDate: at(15, 0), endDate: at(16, 0))
        let car = allDay("car", .car, at(19, 0), at(22, 0)) // 19, 20, 21
        let days = TimelineBuilder.days(for: trip, events: [car], calendar: calendar)
        #expect(days == [at(15, 0), at(16, 0), at(19, 0), at(20, 0), at(21, 0)])
    }

    @Test func allDayEventsOutsideTripDatesAreFlagged() {
        let trip = Trip(id: "trip", title: "t", destination: "d", startDate: at(15, 0), endDate: at(17, 0))
        let inside = allDay("inside", .hotel, at(15, 0), at(17, 0)) // nights 15, 16
        let spills = allDay("spills", .hotel, at(17, 0), at(19, 0)) // nights 17, 18
        let before = allDay("before", .car, at(13, 0), at(15, 0)) // 13, 14
        let outside = TimelineBuilder.events(outside: trip, from: [inside, spills, before], calendar: calendar)
        #expect(outside.map(\.id) == ["before", "spills"])
        // Check-out the day after the Trip ends is still inside: the last night is the 17th.
        let lastNight = allDay("last", .hotel, at(17, 0), at(18, 0))
        #expect(TimelineBuilder.events(outside: trip, from: [lastNight], calendar: calendar).isEmpty)
    }

    @Test func firstAndLastDayForTimedAndAllDayEvents() {
        let overnight = event("night", at(15, 22), at(16, 7))
        #expect(TimelineBuilder.firstDay(of: overnight, calendar: calendar) == at(15, 0))
        #expect(TimelineBuilder.lastDay(of: overnight, calendar: calendar) == at(16, 0))
        let atMidnight = event("late", at(15, 23), at(16, 0))
        #expect(TimelineBuilder.lastDay(of: atMidnight, calendar: calendar) == at(15, 0))
        let stay = allDay("stay", .hotel, at(15, 0), at(17, 0))
        #expect(TimelineBuilder.firstDay(of: stay, calendar: calendar) == at(15, 0))
        #expect(TimelineBuilder.lastDay(of: stay, calendar: calendar) == at(16, 0))
    }

    // MARK: Current time (G6-UX-06)

    private var dayPlan: [Event] {
        [
            event("a", at(16, 9), at(16, 10)),
            event("b", at(16, 11), at(16, 12)), // 60 min gap before: Travel / Free Time
            event("c", at(16, 12, 15), at(16, 13)), // 15 min gap before: no row
            event("d", at(16, 15), at(16, 16)), // 120 min gap before
        ]
    }

    private func items(now: Date?) -> [TimelineItem] {
        TimelineBuilder.items(for: at(16, 0), events: dayPlan, calendar: calendar, now: now)
    }

    @Test func withoutNowTheTimelineIsUnchanged() {
        #expect(ids(items(now: nil)) == ["a", "free(10:0-11:0)", "b", "c", "free(13:0-15:0)", "d"])
    }

    @Test func nowBeforeTheFirstEvent() {
        #expect(ids(items(now: at(16, 8, 30))) == ["now(8:30)", "a", "free(10:0-11:0)", "b", "c", "free(13:0-15:0)", "d"])
    }

    @Test func nowBetweenEventsWithoutAGapRow() {
        #expect(ids(items(now: at(16, 12, 5))) == ["a", "free(10:0-11:0)", "b", "now(12:5)", "c", "free(13:0-15:0)", "d"])
    }

    @Test func nowInsideAGapSplitsItsDisplayOnly() {
        let result = items(now: at(16, 10, 20))
        #expect(ids(result) == ["a", "free(10:0-10:20)", "now(10:20)", "free(10:20-11:0)", "b", "c", "free(13:0-15:0)", "d"])
        #expect(freeSeconds(result) == freeSeconds(items(now: nil)), "the total gap time is unchanged")
        #expect(noNegativeOrEmptyGaps(result))
    }

    @Test func nowDuringAnOngoingEventFollowsIt() {
        #expect(ids(items(now: at(16, 9, 30))) == ["a", "now(9:30)", "free(10:0-11:0)", "b", "c", "free(13:0-15:0)", "d"])
    }

    @Test func nowExactlyAtAnEventStartFollowsIt() {
        #expect(ids(items(now: at(16, 11))) == ["a", "free(10:0-11:0)", "b", "now(11:0)", "c", "free(13:0-15:0)", "d"])
    }

    @Test func nowExactlyAtAnEventEndSitsBeforeTheGapWithoutSplitting() {
        let result = items(now: at(16, 10))
        #expect(ids(result) == ["a", "now(10:0)", "free(10:0-11:0)", "b", "c", "free(13:0-15:0)", "d"])
        #expect(noNegativeOrEmptyGaps(result))
        // The Event ending exactly now is still active, one second later it is completed.
        #expect(!TimelineBuilder.isCompleted(dayPlan[0], at: at(16, 10)))
        #expect(TimelineBuilder.isCompleted(dayPlan[0], at: at(16, 10).addingTimeInterval(1)))
    }

    @Test func nowAfterTheLastEvent() {
        #expect(ids(items(now: at(16, 23, 59))) == ["a", "free(10:0-11:0)", "b", "c", "free(13:0-15:0)", "d", "now(23:59)"])
    }

    @Test func nowOnAnEmptyOrAllDayOnlyDay() {
        #expect(ids(TimelineBuilder.items(for: at(16, 0), events: [], calendar: calendar, now: at(16, 13))) == ["now(13:0)"])
        let stay = allDay("stay", .hotel, at(15, 0), at(17, 0))
        #expect(ids(TimelineBuilder.items(for: at(16, 0), events: [stay], calendar: calendar, now: at(16, 13))) == ["now(13:0)"])
        #expect(TimelineBuilder.allDayEvents(on: at(16, 0), from: [stay], calendar: calendar).map(\.id) == ["stay"])
    }

    @Test func nowAppearsOnItsOwnDayOnly() {
        #expect(ids(items(now: at(17, 10))) == ids(items(now: nil)))
        #expect(ids(items(now: at(15, 23, 59))) == ids(items(now: nil)))
        #expect(ids(TimelineBuilder.items(for: at(17, 0), events: dayPlan, calendar: calendar, now: at(17, 10))) == ["now(10:0)"])
    }

    @Test func nowWithCrossMidnightEvents() {
        let overnight = event("night", at(15, 22), at(16, 7))
        let morning = event("morning", at(16, 9), at(16, 10))
        let early = TimelineBuilder.items(for: at(16, 0), events: [overnight, morning], calendar: calendar, now: at(16, 6))
        #expect(ids(early) == ["night", "now(6:0)", "free(7:0-9:0)", "morning"])
        #expect(!TimelineBuilder.isCompleted(overnight, at: at(16, 6)))
        let later = TimelineBuilder.items(for: at(16, 0), events: [overnight, morning], calendar: calendar, now: at(16, 8))
        #expect(ids(later) == ["night", "free(7:0-8:0)", "now(8:0)", "free(8:0-9:0)", "morning"])
        #expect(TimelineBuilder.isCompleted(overnight, at: at(16, 8)))
        // The day before shows the overnight Event as ongoing from 22:00.
        let eve = TimelineBuilder.items(for: at(15, 0), events: [overnight], calendar: calendar, now: at(15, 23))
        #expect(ids(eve) == ["night", "now(23:0)"])
    }

    @Test func completedStylingState() {
        let past = event("past", at(16, 9), at(16, 10))
        let ongoing = event("ongoing", at(16, 9), at(16, 11))
        let future = event("future", at(16, 12), at(16, 13))
        let marker = event("marker", at(16, 10, 30), at(16, 10, 30))
        let now = at(16, 10, 30)
        #expect(TimelineBuilder.isCompleted(past, at: now))
        #expect(!TimelineBuilder.isCompleted(ongoing, at: now))
        #expect(!TimelineBuilder.isCompleted(future, at: now))
        #expect(!TimelineBuilder.isCompleted(marker, at: now), "a zero-length Event ending now is not past yet")
        // All-day stays and rental cars are never greyed by their midnight boundaries.
        let stay = allDay("stay", .hotel, at(15, 0), at(16, 0))
        let car = allDay("car", .car, at(14, 0), at(16, 0))
        #expect(!TimelineBuilder.isCompleted(stay, at: at(16, 10)))
        #expect(!TimelineBuilder.isCompleted(car, at: at(16, 10)))
    }

    @Test func nowIsNeverDuplicatedAndKeepsOrderWithIdenticalStarts() {
        let a = event("a", at(16, 9), at(16, 10))
        let b = event("b", at(16, 9), at(16, 11))
        let items = TimelineBuilder.items(for: at(16, 0), events: [b, a], calendar: calendar, now: at(16, 9))
        #expect(ids(items) == ["a", "b", "now(9:0)"])
        #expect(items.filter { if case .now = $0 { return true } else { return false } }.count == 1)
    }

    @Test func insertSplitsOnlyStrictlyInsideAGap() {
        var items: [TimelineItem] = [.freeTime(start: at(16, 10), end: at(16, 11))]
        TimelineBuilder.insert(.now(at(16, 10)), at: at(16, 10), afterTies: true, into: &items)
        #expect(ids(items) == ["now(10:0)", "free(10:0-11:0)"])
        items = [.freeTime(start: at(16, 10), end: at(16, 11))]
        TimelineBuilder.insert(.now(at(16, 11)), at: at(16, 11), afterTies: true, into: &items)
        #expect(ids(items) == ["free(10:0-11:0)", "now(11:0)"])
        items = []
        TimelineBuilder.insert(.now(at(16, 11)), at: at(16, 11), afterTies: true, into: &items)
        #expect(ids(items) == ["now(11:0)"])
    }

    // MARK: Hotel markers (G6-UX-05)

    private func stay(
        _ id: String, checkIn: Int, checkOut: Int, in checkInMinutes: Int? = nil, out checkOutMinutes: Int? = nil
    ) -> Event {
        Event(
            id: id, tripId: "trip", type: .hotel, title: id, startDate: at(checkIn, 0), endDate: at(checkOut, 0),
            createdAt: at(1, 0), isAllDay: true, checkInMinutes: checkInMinutes, checkOutMinutes: checkOutMinutes
        )
    }

    @Test func markersJoinTheTimedTimelineOnTheirDays() {
        let hotel = stay("stay", checkIn: 15, checkOut: 17, in: 17 * 60, out: 9 * 60)
        let flight = event("flight", at(15, 13), at(15, 14))
        let dinner = event("dinner", at(15, 18, 30), at(15, 20))
        let day15 = TimelineBuilder.items(for: at(15, 0), events: [hotel, flight, dinner], calendar: calendar)
        #expect(ids(day15) == ["flight", "free(14:0-17:0)", "marker-stay-checkIn", "free(17:0-18:30)", "dinner"])
        #expect(freeSeconds(day15) == 270 * 60, "the gap total is unchanged by the marker")
        #expect(noNegativeOrEmptyGaps(day15))
        // The last night has no marker; the check-out day shows only the marker.
        #expect(TimelineBuilder.items(for: at(16, 0), events: [hotel], calendar: calendar).isEmpty)
        #expect(ids(TimelineBuilder.items(for: at(17, 0), events: [hotel], calendar: calendar)) == ["marker-stay-checkOut"])
        #expect(TimelineBuilder.allDayEvents(on: at(17, 0), from: [hotel], calendar: calendar).isEmpty)
        #expect(TimelineBuilder.allDayEvents(on: at(16, 0), from: [hotel], calendar: calendar).map(\.id) == ["stay"])
    }

    @Test func markersNeverCreateOrShortenGaps() {
        let hotel = stay("stay", checkIn: 15, checkOut: 16, in: 17 * 60)
        let a = event("a", at(15, 16, 50), at(15, 16, 55))
        let b = event("b", at(15, 17, 10), at(15, 18)) // 15 min apart: no gap row, marker between
        #expect(ids(TimelineBuilder.items(for: at(15, 0), events: [hotel, a, b], calendar: calendar)) == ["a", "marker-stay-checkIn", "b"])
        // A marker next to a single Event makes no gap either.
        let late = event("late", at(15, 21), at(15, 22))
        #expect(ids(TimelineBuilder.items(for: at(15, 0), events: [hotel, late], calendar: calendar)) == ["marker-stay-checkIn", "late"])
        // A marker during an ongoing Event follows that Event's row.
        let long = event("long", at(15, 16), at(15, 19))
        #expect(ids(TimelineBuilder.items(for: at(15, 0), events: [hotel, long], calendar: calendar)) == ["long", "marker-stay-checkIn"])
        // Without clock times nothing changes.
        let silent = stay("silent", checkIn: 15, checkOut: 16)
        #expect(ids(TimelineBuilder.items(for: at(15, 0), events: [silent, a, b], calendar: calendar)) == ["a", "b"])
    }

    @Test func markerPrecedesAnEventAtTheSameInstantAndNowFollowsIt() {
        let hotel = stay("stay", checkIn: 15, checkOut: 16, in: 17 * 60)
        let dinner = event("dinner", at(15, 17), at(15, 18))
        #expect(ids(TimelineBuilder.items(for: at(15, 0), events: [hotel, dinner], calendar: calendar)) == ["marker-stay-checkIn", "dinner"])
        let atSeventeen = TimelineBuilder.items(for: at(15, 0), events: [hotel, dinner], calendar: calendar, now: at(15, 17))
        #expect(ids(atSeventeen) == ["marker-stay-checkIn", "dinner", "now(17:0)"])
        let before = TimelineBuilder.items(for: at(15, 0), events: [hotel, dinner], calendar: calendar, now: at(15, 16, 30))
        #expect(ids(before) == ["now(16:30)", "marker-stay-checkIn", "dinner"])
        let late = event("late", at(15, 18, 30), at(15, 19))
        let between = TimelineBuilder.items(for: at(15, 0), events: [hotel, late], calendar: calendar, now: at(15, 17, 30))
        #expect(ids(between) == ["marker-stay-checkIn", "now(17:30)", "late"])
    }

    @Test func markerAndNowInsideTheSameGap() {
        let hotel = stay("stay", checkIn: 15, checkOut: 16, in: 17 * 60)
        let flight = event("flight", at(15, 13), at(15, 14))
        let dinner = event("dinner", at(15, 18, 30), at(15, 20))
        let earlier = TimelineBuilder.items(for: at(15, 0), events: [hotel, flight, dinner], calendar: calendar, now: at(15, 16, 30))
        #expect(ids(earlier) == [
            "flight", "free(14:0-16:30)", "now(16:30)", "free(16:30-17:0)", "marker-stay-checkIn", "free(17:0-18:30)", "dinner",
        ])
        #expect(freeSeconds(earlier) == 270 * 60)
        #expect(noNegativeOrEmptyGaps(earlier))
        let later = TimelineBuilder.items(for: at(15, 0), events: [hotel, flight, dinner], calendar: calendar, now: at(15, 17, 30))
        #expect(ids(later) == [
            "flight", "free(14:0-17:0)", "marker-stay-checkIn", "free(17:0-17:30)", "now(17:30)", "free(17:30-18:30)", "dinner",
        ])
        #expect(freeSeconds(later) == 270 * 60)
        #expect(noNegativeOrEmptyGaps(later))
    }

    @Test func multipleStaysAndIdenticalStarts() {
        let first = stay("a", checkIn: 15, checkOut: 17, in: 15 * 60, out: 15 * 60)
        let second = stay("b", checkIn: 17, checkOut: 18, in: 15 * 60)
        let meeting = event("meeting", at(17, 15), at(17, 16))
        let items = TimelineBuilder.items(for: at(17, 0), events: [meeting, second, first], calendar: calendar, now: at(17, 15))
        #expect(ids(items) == ["marker-a-checkOut", "marker-b-checkIn", "meeting", "now(15:0)"])
        #expect(TimelineBuilder.allDayEvents(on: at(17, 0), from: [first, second], calendar: calendar).map(\.id) == ["b"])
    }

    @Test func tripDaysReachTheCheckOutMarkerDay() {
        let trip = Trip(id: "trip", title: "t", destination: "d", startDate: at(15, 0), endDate: at(16, 0))
        let hotel = stay("stay", checkIn: 15, checkOut: 17, out: 9 * 60)
        #expect(TimelineBuilder.days(for: trip, events: [hotel], calendar: calendar) == [at(15, 0), at(16, 0), at(17, 0)])
        let silent = stay("silent", checkIn: 15, checkOut: 17)
        #expect(TimelineBuilder.days(for: trip, events: [silent], calendar: calendar) == [at(15, 0), at(16, 0)])
        // RF-02 counts the stay by its nights, not by the marker day.
        #expect(TimelineBuilder.events(outside: trip, from: [hotel], calendar: calendar).isEmpty)
    }

    @Test func hoursAndMinutes() {
        #expect(TimelineBuilder.hoursAndMinutes(from: at(16, 9), to: at(16, 11)) == (2, 0))
        #expect(TimelineBuilder.hoursAndMinutes(from: at(16, 9), to: at(16, 9, 45)) == (0, 45))
        #expect(TimelineBuilder.hoursAndMinutes(from: at(16, 9), to: at(16, 10, 30)) == (1, 30))
    }
}
