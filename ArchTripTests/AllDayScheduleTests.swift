import Foundation
import Testing
@testable import ArchTrip

/// G6: all-day Events apply to whole calendar days, [first day, exclusive end), with
/// the hotel check-out day excluded and the rental-car return day included.
struct AllDayScheduleTests {
    private let tokyo: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    private func date(
        _ calendar: Calendar, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, year: Int = 2026, month: Int = 10
    ) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func allDay(_ type: EventType, _ start: Date, _ end: Date) -> Event {
        Event(id: "e", tripId: "t", type: type, title: "x", startDate: start, endDate: end, createdAt: start, isAllDay: true)
    }

    @Test func stayCoversNightsUpToTheDayBeforeCheckOut() {
        // Times of day on the picked dates are ignored.
        let dates = AllDaySchedule.dates(checkIn: date(tokyo, 15, 15, 30), checkOut: date(tokyo, 17, 11), calendar: tokyo)
        #expect(dates.start == date(tokyo, 15))
        #expect(dates.end == date(tokyo, 17))
        let stay = allDay(.hotel, dates.start, dates.end)
        #expect(AllDaySchedule.firstDay(of: stay, calendar: tokyo) == date(tokyo, 15))
        #expect(AllDaySchedule.lastDay(of: stay, calendar: tokyo) == date(tokyo, 16))
        #expect(AllDaySchedule.endExclusive(of: stay, calendar: tokyo) == date(tokyo, 17))
        #expect(AllDaySchedule.applies(stay, on: date(tokyo, 15, 23, 59), calendar: tokyo))
        #expect(AllDaySchedule.applies(stay, on: date(tokyo, 16), calendar: tokyo))
        #expect(!AllDaySchedule.applies(stay, on: date(tokyo, 17), calendar: tokyo), "check-out day is not a night")
        #expect(!AllDaySchedule.applies(stay, on: date(tokyo, 14, 23, 59), calendar: tokyo))
    }

    @Test func stayIsAtLeastOneNight() {
        let same = AllDaySchedule.dates(checkIn: date(tokyo, 15), checkOut: date(tokyo, 15), calendar: tokyo)
        #expect(same.start == date(tokyo, 15) && same.end == date(tokyo, 16))
        let reversed = AllDaySchedule.dates(checkIn: date(tokyo, 15), checkOut: date(tokyo, 10), calendar: tokyo)
        #expect(reversed.start == date(tokyo, 15) && reversed.end == date(tokyo, 16))
    }

    @Test func rentalCarIncludesTheReturnDay() {
        let dates = AllDaySchedule.dates(firstDay: date(tokyo, 15, 10), lastDay: date(tokyo, 17, 18), calendar: tokyo)
        #expect(dates.start == date(tokyo, 15))
        #expect(dates.end == date(tokyo, 18), "return day 17 is included, so the exclusive end is the 18th")
        let car = allDay(.car, dates.start, dates.end)
        #expect(AllDaySchedule.lastDay(of: car, calendar: tokyo) == date(tokyo, 17))
        for day in 15...17 {
            #expect(AllDaySchedule.applies(car, on: date(tokyo, day), calendar: tokyo), "day \(day)")
        }
        #expect(!AllDaySchedule.applies(car, on: date(tokyo, 18), calendar: tokyo))
        #expect(!AllDaySchedule.applies(car, on: date(tokyo, 14), calendar: tokyo))

        // A last day before the first day collapses to one day.
        let single = AllDaySchedule.dates(firstDay: date(tokyo, 15), lastDay: date(tokyo, 12), calendar: tokyo)
        #expect(single.start == date(tokyo, 15) && single.end == date(tokyo, 16))
    }

    @Test func endConventionByType() {
        #expect(AllDaySchedule.endConvention(for: .hotel) == .checkOut)
        for type in EventType.allCases where type != .hotel {
            #expect(AllDaySchedule.endConvention(for: type) == .lastDay, "\(type)")
        }
    }

    @Test func sectionOrderIsStaysCarsThenTheRest() {
        #expect(AllDaySchedule.sectionRank(.hotel) == 0)
        #expect(AllDaySchedule.sectionRank(.car) == 1)
        for type in EventType.allCases where type != .hotel && type != .car {
            #expect(AllDaySchedule.sectionRank(type) == 2, "\(type)")
        }
    }

    @Test func degenerateRangeShowsOnItsStartDay() {
        let zero = allDay(.other, date(tokyo, 15), date(tokyo, 15))
        #expect(AllDaySchedule.firstDay(of: zero, calendar: tokyo) == date(tokyo, 15))
        #expect(AllDaySchedule.lastDay(of: zero, calendar: tokyo) == date(tokyo, 15))
        #expect(AllDaySchedule.endExclusive(of: zero, calendar: tokyo) == date(tokyo, 16))
        #expect(AllDaySchedule.applies(zero, on: date(tokyo, 15), calendar: tokyo))
        #expect(!AllDaySchedule.applies(zero, on: date(tokyo, 16), calendar: tokyo))
        let reversed = allDay(.other, date(tokyo, 15), date(tokyo, 12))
        #expect(AllDaySchedule.lastDay(of: reversed, calendar: tokyo) == date(tokyo, 15))
    }

    @Test func dayArithmeticUsesTheCalendar() {
        #expect(AllDaySchedule.dayAfter(date(tokyo, 15, 18), calendar: tokyo) == date(tokyo, 16))
        #expect(AllDaySchedule.dayBefore(date(tokyo, 15, 18), calendar: tokyo) == date(tokyo, 14))
        #expect(AllDaySchedule.dayCount(from: date(tokyo, 15), to: date(tokyo, 16), calendar: tokyo) == 1)
        #expect(AllDaySchedule.dayCount(from: date(tokyo, 15), to: date(tokyo, 18), calendar: tokyo) == 3)
        #expect(AllDaySchedule.dayCount(from: date(tokyo, 15), to: date(tokyo, 15), calendar: tokyo) == 1)
        #expect(AllDaySchedule.dayCount(from: date(tokyo, 15), to: date(tokyo, 10), calendar: tokyo) == 1)
    }

    @Test func monthAndYearBoundaries() {
        let car = AllDaySchedule.dates(firstDay: date(tokyo, 31), lastDay: date(tokyo, 1, month: 11), calendar: tokyo)
        #expect(car.end == date(tokyo, 2, month: 11))
        #expect(AllDaySchedule.applies(allDay(.car, car.start, car.end), on: date(tokyo, 1, month: 11), calendar: tokyo))

        let stay = AllDaySchedule.dates(checkIn: date(tokyo, 31, month: 12), checkOut: date(tokyo, 2, year: 2027, month: 1), calendar: tokyo)
        let event = allDay(.hotel, stay.start, stay.end)
        #expect(AllDaySchedule.firstDay(of: event, calendar: tokyo) == date(tokyo, 31, month: 12))
        #expect(AllDaySchedule.lastDay(of: event, calendar: tokyo) == date(tokyo, 1, year: 2027, month: 1))
        #expect(AllDaySchedule.applies(event, on: date(tokyo, 1, year: 2027, month: 1), calendar: tokyo))
        #expect(!AllDaySchedule.applies(event, on: date(tokyo, 2, year: 2027, month: 1), calendar: tokyo))
        #expect(AllDaySchedule.dayCount(from: stay.start, to: stay.end, calendar: tokyo) == 2)
    }

    /// Daylight-saving days are 23 or 25 hours long; the calendar, not 86 400 s, sets the boundaries.
    @Test func daylightSavingDaysAreWholeDays() {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!

        // 2026-03-08 has 23 hours.
        let spring = AllDaySchedule.dates(checkIn: date(newYork, 7, month: 3), checkOut: date(newYork, 9, month: 3), calendar: newYork)
        #expect(spring.end == date(newYork, 9, month: 3))
        #expect(spring.end.timeIntervalSince(spring.start) == 47 * 3_600)
        let springStay = allDay(.hotel, spring.start, spring.end)
        #expect(AllDaySchedule.lastDay(of: springStay, calendar: newYork) == date(newYork, 8, month: 3))
        #expect(AllDaySchedule.applies(springStay, on: date(newYork, 8, month: 3), calendar: newYork))
        #expect(!AllDaySchedule.applies(springStay, on: date(newYork, 9, month: 3), calendar: newYork))

        // 2026-11-01 has 25 hours.
        let fall = AllDaySchedule.dates(firstDay: date(newYork, 31), lastDay: date(newYork, 1, month: 11), calendar: newYork)
        #expect(fall.end == date(newYork, 2, month: 11))
        #expect(fall.end.timeIntervalSince(fall.start) == 49 * 3_600)
        let fallCar = allDay(.car, fall.start, fall.end)
        #expect(AllDaySchedule.firstDay(of: fallCar, calendar: newYork) == date(newYork, 31))
        #expect(AllDaySchedule.lastDay(of: fallCar, calendar: newYork) == date(newYork, 1, month: 11))
        #expect(AllDaySchedule.dayAfter(date(newYork, 1, month: 11), calendar: newYork) == date(newYork, 2, month: 11))
        #expect(AllDaySchedule.dayCount(from: fall.start, to: fall.end, calendar: newYork) == 2)
    }

    /// Entered in Japan and read with a clock up to 12 hours away: the same calendar days.
    /// (Larger offsets, e.g. the Americas, can shift a day; documented limitation.)
    @Test func clockOffsetsUnderTwelveHoursKeepTheDays() {
        let stay = allDay(.hotel, date(tokyo, 15), date(tokyo, 17))
        for identifier in ["UTC", "Europe/London", "Asia/Kolkata", "Pacific/Auckland"] {
            var other = Calendar(identifier: .gregorian)
            other.timeZone = TimeZone(identifier: identifier)!
            #expect(AllDaySchedule.firstDay(of: stay, calendar: other) == date(other, 15), "\(identifier)")
            #expect(AllDaySchedule.lastDay(of: stay, calendar: other) == date(other, 16), "\(identifier)")
            #expect(AllDaySchedule.applies(stay, on: date(other, 16), calendar: other), "\(identifier)")
            #expect(!AllDaySchedule.applies(stay, on: date(other, 17), calendar: other), "\(identifier)")
        }
    }

    /// Converting in the editor: a timed Event's days become the all-day range, and an
    /// all-day Event's stored boundaries are what a timed editor starts from.
    @Test func conversionsKeepTheDays() {
        let overnight = Event(id: "n", tripId: "t", type: .hotel, title: "n", startDate: date(tokyo, 15, 22), endDate: date(tokyo, 16, 7), createdAt: date(tokyo, 1))
        let first = TimelineBuilder.firstDay(of: overnight, calendar: tokyo)
        let last = TimelineBuilder.lastDay(of: overnight, calendar: tokyo)
        let asStay = AllDaySchedule.dates(firstDay: first, endExclusive: AllDaySchedule.dayAfter(last, calendar: tokyo), calendar: tokyo)
        #expect(asStay.start == date(tokyo, 15) && asStay.end == date(tokyo, 17), "two nights, 15 and 16")

        let stay = allDay(.hotel, asStay.start, asStay.end)
        #expect(TimelineBuilder.firstDay(of: stay, calendar: tokyo) == date(tokyo, 15))
        #expect(TimelineBuilder.lastDay(of: stay, calendar: tokyo) == date(tokyo, 16))
        #expect(AllDaySchedule.dayAfter(TimelineBuilder.lastDay(of: stay, calendar: tokyo), calendar: tokyo) == stay.endDate)
    }
}
