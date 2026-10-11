import Foundation
import Testing
@testable import ArchTrip

/// G6-UX-05: check-in / check-out markers are derived from a hotel stay's optional clock
/// times and are never stored.
struct HotelMarkerTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    private func at(_ day: Int, _ hour: Int = 0, _ minute: Int = 0, month: Int = 10, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func stay(
        _ id: String = "stay", checkIn: Int, checkOut: Int, in checkInMinutes: Int? = nil, out checkOutMinutes: Int? = nil
    ) -> Event {
        let dates = AllDaySchedule.dates(checkIn: at(checkIn), checkOut: at(checkOut), calendar: calendar)
        return Event(
            id: id, tripId: "trip", type: .hotel, title: "Hotel", startDate: dates.start, endDate: dates.end,
            createdAt: at(1), isAllDay: true, checkInMinutes: checkInMinutes, checkOutMinutes: checkOutMinutes
        )
    }

    private func markers(_ event: Event) -> [HotelMarker] {
        HotelMarker.markers(for: event, calendar: calendar)
    }

    @Test func stayWithoutClockTimesHasNoMarkers() {
        #expect(markers(stay(checkIn: 15, checkOut: 17)).isEmpty)
    }

    @Test func checkInOnly() {
        let result = markers(stay(checkIn: 15, checkOut: 17, in: 17 * 60))
        #expect(result.map(\.kind) == [.checkIn])
        #expect(result.first?.time == at(15, 17))
        #expect(result.first?.id == "marker-stay-checkIn")
        #expect(result.first?.event.id == "stay")
    }

    /// The check-out day is not a night of the stay, yet the check-out marker is on it.
    @Test func checkOutOnlyOnTheCheckOutDay() {
        let event = stay(checkIn: 15, checkOut: 17, out: 9 * 60)
        let result = markers(event)
        #expect(result.map(\.kind) == [.checkOut])
        #expect(result.first?.time == at(17, 9))
        #expect(result.first?.id == "marker-stay-checkOut")
        #expect(!AllDaySchedule.applies(event, on: at(17), calendar: calendar))
        #expect(HotelMarker.markers(on: at(17), from: [event], calendar: calendar).map(\.kind) == [.checkOut])
        #expect(HotelMarker.markers(on: at(16), from: [event], calendar: calendar).isEmpty)
    }

    @Test func bothTimesForOneNight() {
        let result = markers(stay(checkIn: 15, checkOut: 16, in: 17 * 60, out: 9 * 60))
        #expect(result.map(\.kind) == [.checkIn, .checkOut])
        #expect(result.map(\.time) == [at(15, 17), at(16, 9)])
    }

    @Test func multiNightStayChecksOutAfterTheLastNight() {
        let event = stay(checkIn: 15, checkOut: 18, in: 15 * 60, out: 10 * 60 + 30)
        let result = markers(event)
        #expect(result.map(\.time) == [at(15, 15), at(18, 10, 30)])
        #expect(AllDaySchedule.lastDay(of: event, calendar: calendar) == at(17))
        #expect(HotelMarker.markers(on: at(17), from: [event], calendar: calendar).isEmpty)
    }

    @Test func identityIsStableAcrossEdits() {
        var event = stay(checkIn: 15, checkOut: 17, in: 17 * 60, out: 9 * 60)
        let before = markers(event).map(\.id)
        event.title = "Renamed"
        event.checkInMinutes = 18 * 60
        event.updatedAt = at(2)
        #expect(markers(event).map(\.id) == before)
        #expect(markers(event).first?.time == at(15, 18))
    }

    @Test func clearingATimeRemovesOnlyItsMarker() {
        var event = stay(checkIn: 15, checkOut: 17, in: 17 * 60, out: 9 * 60)
        event.checkOutMinutes = nil
        #expect(markers(event).map(\.kind) == [.checkIn])
        event.checkInMinutes = nil
        #expect(markers(event).isEmpty)
    }

    @Test func midnightAndLastMinuteOfTheDay() {
        let result = markers(stay(checkIn: 15, checkOut: 17, in: 0, out: 23 * 60 + 59))
        #expect(result.map(\.time) == [at(15, 0), at(17, 23, 59)])
    }

    @Test func outOfRangeMinutesYieldNoMarkerAndAreInvalid() {
        let low = stay(checkIn: 15, checkOut: 17, in: -1)
        let high = stay(checkIn: 15, checkOut: 17, out: 24 * 60)
        #expect(markers(low).isEmpty && markers(high).isEmpty)
        #expect(!low.isValid && !high.isValid)
        #expect(stay(checkIn: 15, checkOut: 17, in: 0, out: 24 * 60 - 1).isValid)
    }

    @Test func monthAndYearBoundary() {
        let dates = AllDaySchedule.dates(checkIn: at(31, month: 12), checkOut: at(2, month: 1, year: 2027), calendar: calendar)
        let event = Event(
            id: "ny", tripId: "trip", type: .hotel, title: "Hotel", startDate: dates.start, endDate: dates.end,
            createdAt: at(1), isAllDay: true, checkInMinutes: 16 * 60, checkOutMinutes: 10 * 60
        )
        #expect(markers(event).map(\.time) == [at(31, 16, month: 12), at(2, 10, month: 1, year: 2027)])
    }

    @Test func daylightSavingDay() {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        func ny(_ day: Int, _ hour: Int = 0) -> Date {
            newYork.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour))!
        }
        // 2026-03-08 has 23 hours; the markers are local clock times on their days regardless.
        let dates = AllDaySchedule.dates(checkIn: ny(7), checkOut: ny(9), calendar: newYork)
        let event = Event(
            id: "dst", tripId: "trip", type: .hotel, title: "Hotel", startDate: dates.start, endDate: dates.end,
            createdAt: ny(1), isAllDay: true, checkInMinutes: 17 * 60, checkOutMinutes: 9 * 60
        )
        let result = HotelMarker.markers(for: event, calendar: newYork)
        #expect(result.map(\.time) == [ny(7, 17), ny(9, 9)])
        #expect(ny(9, 9).timeIntervalSince(ny(7, 17)) == 39 * 3_600, "one hour shorter than two full days")
    }

    @Test func timedHotelAndNonHotelEventsHaveNoMarkers() {
        var timedHotel = stay(checkIn: 15, checkOut: 17, in: 17 * 60)
        timedHotel.isAllDay = nil
        #expect(markers(timedHotel).isEmpty)
        #expect(!timedHotel.isValid, "clock times belong to all-day stays only")
        var car = stay(checkIn: 15, checkOut: 17, in: 17 * 60)
        car.type = .car
        #expect(markers(car).isEmpty)
        #expect(!car.isValid)
        // A legacy timed hotel Event without the fields is untouched and valid.
        let legacy = Event(id: "old", tripId: "trip", type: .hotel, title: "Check-in", startDate: at(15, 15), endDate: at(15, 15, 30), createdAt: at(1))
        #expect(markers(legacy).isEmpty && legacy.isValid)
    }

    @Test func markersOnADayAcrossStaysAreOrderedWithCheckOutFirstOnTies() {
        let first = stay("a", checkIn: 15, checkOut: 17, in: 15 * 60, out: 15 * 60)
        let second = stay("b", checkIn: 17, checkOut: 18, in: 15 * 60)
        let third = stay("c", checkIn: 17, checkOut: 18, in: 14 * 60)
        let onTheSeventeenth = HotelMarker.markers(on: at(17), from: [second, first, third], calendar: calendar)
        #expect(onTheSeventeenth.map(\.id) == ["marker-c-checkIn", "marker-a-checkOut", "marker-b-checkIn"])
        #expect(HotelMarker.markers(on: at(15), from: [second, first, third], calendar: calendar).map(\.id) == ["marker-a-checkIn"])
    }
}
