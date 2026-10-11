import Foundation
import Testing
@testable import ArchTrip

/// G6-UX-07: pickup / return markers are derived from a rental car's optional clock times
/// and are never stored. The return day is a day of the rental, so the return marker is on
/// the last day itself, not the day after as a stay's check-out is. Fixture text only.
struct RentalCarMarkerTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    private func at(_ day: Int, _ hour: Int = 0, _ minute: Int = 0, month: Int = 10, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// An all-day rental car from `pickup` through `return` (both days included).
    private func rental(
        _ id: String = "car", pickup: Int, return returnDay: Int, in pickupMinutes: Int? = nil, out returnMinutes: Int? = nil,
        location: String = "", note: String = ""
    ) -> Event {
        let dates = AllDaySchedule.dates(firstDay: at(pickup), lastDay: at(returnDay), calendar: calendar)
        return Event(
            id: id, tripId: "trip", type: .car, title: "Fixture rental", startDate: dates.start, endDate: dates.end,
            locationName: location, note: note, createdAt: at(1), isAllDay: true,
            pickupMinutes: pickupMinutes, returnMinutes: returnMinutes
        )
    }

    private func stay(_ id: String, checkIn: Int, checkOut: Int, in checkInMinutes: Int? = nil, out checkOutMinutes: Int? = nil) -> Event {
        let dates = AllDaySchedule.dates(checkIn: at(checkIn), checkOut: at(checkOut), calendar: calendar)
        return Event(
            id: id, tripId: "trip", type: .hotel, title: "Fixture hotel", startDate: dates.start, endDate: dates.end,
            createdAt: at(1), isAllDay: true, checkInMinutes: checkInMinutes, checkOutMinutes: checkOutMinutes
        )
    }

    private func markers(_ event: Event) -> [EventMarker] {
        EventMarker.markers(for: event, calendar: calendar)
    }

    @Test func rentalWithoutClockTimesHasNoMarkers() {
        #expect(markers(rental(pickup: 15, return: 17)).isEmpty)
        #expect(rental(pickup: 15, return: 17).isValid)
    }

    @Test func pickupMarkerOnTheFirstDay() {
        let car = rental(pickup: 15, return: 17, in: 18 * 60 + 30)
        let result = markers(car)
        #expect(result.map(\.kind) == [.pickup])
        #expect(result.first?.time == at(15, 18, 30))
        #expect(result.first?.id == "marker-car-pickup")
        #expect(result.first?.event == car, "the marker opens the one canonical rental")
        #expect(EventMarker.markers(on: at(15), from: [car], calendar: calendar).map(\.kind) == [.pickup])
        #expect(EventMarker.markers(on: at(16), from: [car], calendar: calendar).isEmpty)
    }

    /// The return day is included in the rental (unlike a stay's check-out day), so the
    /// marker and the all-day row share that day.
    @Test func returnMarkerOnTheInclusiveLastDay() {
        let car = rental(pickup: 15, return: 17, out: 14 * 60)
        let result = markers(car)
        #expect(result.map(\.kind) == [.return])
        #expect(result.first?.time == at(17, 14))
        #expect(result.first?.id == "marker-car-return")
        #expect(AllDaySchedule.lastDay(of: car, calendar: calendar) == at(17))
        #expect(AllDaySchedule.applies(car, on: at(17), calendar: calendar))
        #expect(EventMarker.markers(on: at(17), from: [car], calendar: calendar).map(\.kind) == [.return])
        #expect(EventMarker.markers(on: at(18), from: [car], calendar: calendar).isEmpty)
        #expect(EventMarker.markers(on: at(16), from: [car], calendar: calendar).isEmpty)
    }

    /// The worked example: pickup 10-15 18:30, return 10-17 14:00 on all three days.
    @Test func pickupAndReturnOverThreeDays() {
        let car = rental(pickup: 15, return: 17, in: 18 * 60 + 30, out: 14 * 60)
        #expect(markers(car).map(\.kind) == [.pickup, .return])
        #expect(markers(car).map(\.time) == [at(15, 18, 30), at(17, 14)])
        for day in 15...17 {
            #expect(AllDaySchedule.applies(car, on: at(day), calendar: calendar), "day \(day)")
        }
        #expect(EventMarker.markers(on: at(16), from: [car], calendar: calendar).isEmpty, "no marker on a middle day")
    }

    @Test func oneDayRentalHasBothMarkersOnThatDay() {
        let car = rental(pickup: 15, return: 15, in: 9 * 60, out: 18 * 60)
        let result = EventMarker.markers(on: at(15), from: [car], calendar: calendar)
        #expect(result.map(\.kind) == [.pickup, .return])
        #expect(result.map(\.time) == [at(15, 9), at(15, 18)])
        // Times entered the other way round still list in time order.
        let odd = rental(pickup: 15, return: 15, in: 18 * 60, out: 9 * 60)
        #expect(markers(odd).map(\.kind) == [.return, .pickup])
    }

    @Test func identityIsStableAcrossEdits() {
        var car = rental(pickup: 15, return: 17, in: 10 * 60, out: 17 * 60)
        let before = markers(car).map(\.id)
        car.title = "Renamed"
        car.pickupMinutes = 11 * 60
        car.updatedAt = at(2)
        #expect(markers(car).map(\.id) == before)
        #expect(markers(car).first?.time == at(15, 11))
    }

    @Test func clearingATimeRemovesOnlyItsMarker() {
        var car = rental(pickup: 15, return: 17, in: 10 * 60, out: 17 * 60)
        car.returnMinutes = nil
        #expect(markers(car).map(\.kind) == [.pickup])
        car.pickupMinutes = nil
        #expect(markers(car).isEmpty)
        var other = rental(pickup: 15, return: 17, in: 10 * 60, out: 17 * 60)
        other.pickupMinutes = nil
        #expect(markers(other).map(\.kind) == [.return])
    }

    @Test func markersDisappearWithTheSourceEvent() {
        let car = rental(pickup: 15, return: 17, in: 10 * 60, out: 17 * 60)
        #expect(!EventMarker.markers(on: at(15), from: [car], calendar: calendar).isEmpty)
        #expect(EventMarker.markers(on: at(15), from: [], calendar: calendar).isEmpty)
        #expect(EventMarker.markers(on: at(17), from: [], calendar: calendar).isEmpty)
    }

    @Test func midnightAndLastMinuteOfTheDay() {
        let result = markers(rental(pickup: 15, return: 17, in: 0, out: 23 * 60 + 59))
        #expect(result.map(\.time) == [at(15, 0), at(17, 23, 59)])
    }

    @Test func outOfRangeMinutesYieldNoMarkerAndAreInvalid() {
        let low = rental(pickup: 15, return: 17, in: -1)
        let high = rental(pickup: 15, return: 17, out: 24 * 60)
        #expect(markers(low).isEmpty && markers(high).isEmpty)
        #expect(!low.isValid && !high.isValid)
        #expect(rental(pickup: 15, return: 17, in: 0, out: 24 * 60 - 1).isValid)
    }

    @Test func monthAndYearBoundary() {
        let dates = AllDaySchedule.dates(firstDay: at(31, month: 12), lastDay: at(2, month: 1, year: 2027), calendar: calendar)
        let car = Event(
            id: "ny", tripId: "trip", type: .car, title: "Fixture rental", startDate: dates.start, endDate: dates.end,
            createdAt: at(1), isAllDay: true, pickupMinutes: 10 * 60, returnMinutes: 15 * 60
        )
        #expect(markers(car).map(\.time) == [at(31, 10, month: 12), at(2, 15, month: 1, year: 2027)])
        #expect(AllDaySchedule.applies(car, on: at(2, month: 1, year: 2027), calendar: calendar))
    }

    @Test func daylightSavingDay() {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        func ny(_ day: Int, _ hour: Int = 0) -> Date {
            newYork.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour))!
        }
        // 2026-03-08 has 23 hours; the markers are local clock times on their days regardless.
        let dates = AllDaySchedule.dates(firstDay: ny(7), lastDay: ny(8), calendar: newYork)
        let car = Event(
            id: "dst", tripId: "trip", type: .car, title: "Fixture rental", startDate: dates.start, endDate: dates.end,
            createdAt: ny(1), isAllDay: true, pickupMinutes: 10 * 60, returnMinutes: 15 * 60
        )
        let result = EventMarker.markers(for: car, calendar: newYork)
        #expect(result.map(\.time) == [ny(7, 10), ny(8, 15)])
        #expect(ny(8, 15).timeIntervalSince(ny(7, 10)) == 28 * 3_600, "one hour shorter than the clock difference")
    }

    /// Clock times belong to their own type: a timed car, a car carrying hotel times and a
    /// stay carrying rental times are invalid and yield nothing; legacy cars are untouched.
    @Test func wrongTypeOrTimedEventsHaveNoMarkersAndAreInvalid() {
        var timedCar = rental(pickup: 15, return: 17, in: 10 * 60)
        timedCar.isAllDay = nil
        #expect(markers(timedCar).isEmpty && !timedCar.isValid)
        var falseFlag = rental(pickup: 15, return: 17, out: 17 * 60)
        falseFlag.isAllDay = false
        #expect(markers(falseFlag).isEmpty && !falseFlag.isValid)
        var carWithHotelTimes = rental(pickup: 15, return: 17)
        carWithHotelTimes.checkInMinutes = 15 * 60
        #expect(markers(carWithHotelTimes).isEmpty && !carWithHotelTimes.isValid)
        var stayWithRentalTimes = stay("stay", checkIn: 15, checkOut: 17)
        stayWithRentalTimes.pickupMinutes = 10 * 60
        #expect(markers(stayWithRentalTimes).isEmpty && !stayWithRentalTimes.isValid)
        var otherType = rental(pickup: 15, return: 17, in: 10 * 60)
        otherType.type = .other
        #expect(markers(otherType).isEmpty && !otherType.isValid)
        // Legacy cars: timed, and all-day without the fields.
        let timedLegacy = Event(id: "old", tripId: "trip", type: .car, title: "Pickup", startDate: at(15, 10), endDate: at(15, 10, 30), createdAt: at(1))
        #expect(markers(timedLegacy).isEmpty && timedLegacy.isValid)
        let allDayLegacy = rental("g6", pickup: 15, return: 17)
        #expect(markers(allDayLegacy).isEmpty && allDayLegacy.isValid)
    }

    /// At one instant, ends (check-out, return) come before starts (check-in, pickup), each
    /// group by Event id, whatever the input order.
    @Test func sameInstantOrderingAcrossStaysAndRentals() {
        let endingStay = stay("b-stay", checkIn: 15, checkOut: 17, out: 10 * 60)
        let endingCar = rental("a-car", pickup: 15, return: 17, out: 10 * 60)
        let startingStay = stay("d-stay", checkIn: 17, checkOut: 18, in: 10 * 60)
        let startingCar = rental("c-car", pickup: 17, return: 18, in: 10 * 60)
        let events = [startingCar, endingStay, startingStay, endingCar]
        let ids = EventMarker.markers(on: at(17), from: events, calendar: calendar).map(\.id)
        #expect(ids == ["marker-a-car-return", "marker-b-stay-checkOut", "marker-c-car-pickup", "marker-d-stay-checkIn"])
        #expect(EventMarker.markers(on: at(17), from: events.reversed(), calendar: calendar).map(\.id) == ids)
        // Hotel markers are unchanged by the rental ones.
        #expect(EventMarker.markers(on: at(17), from: [endingStay, startingStay], calendar: calendar).map(\.id) == ["marker-b-stay-checkOut", "marker-d-stay-checkIn"])
    }

    // MARK: Row details (shared with hotel markers)

    @Test func bothMarkersShowTheRentalsLocationAndNotePreview() {
        let car = rental(pickup: 15, return: 17, in: 10 * 60, out: 17 * 60, location: "Fixture counter 1F", note: "Fixture note\nSecond line\nThird line")
        let result = markers(car)
        #expect(result.count == 2)
        for marker in result {
            #expect(marker.locationName == "Fixture counter 1F")
            #expect(marker.notePreview == "Fixture note\nSecond line…")
            #expect(marker.event == car)
        }
        for marker in markers(rental(pickup: 15, return: 17, in: 10 * 60, out: 17 * 60, location: " ", note: "\n")) {
            #expect(marker.locationName == nil && marker.notePreview == nil)
        }
    }
}
