import FirebaseFirestore
import Foundation
import Testing
@testable import ArchTrip

struct EventTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeEvent() -> Event {
        Event(
            id: "event-1",
            tripId: "trip-1",
            type: .architecture,
            title: "Site visit",
            startDate: start,
            endDate: start.addingTimeInterval(3_600),
            locationName: "Umeda",
            note: "Bring helmet",
            createdAt: start.addingTimeInterval(-60)
        )
    }

    @Test func validEvent() {
        let event = makeEvent()
        #expect(event.isValid)
        #expect(event.updatedAt == event.createdAt)
    }

    @Test func zeroLengthEventIsValid() {
        var event = makeEvent()
        event.endDate = event.startDate
        #expect(event.isValid)
    }

    @Test func invalidTitle() {
        var empty = makeEvent()
        empty.title = ""
        #expect(!empty.isValid)

        var long = makeEvent()
        long.title = String(repeating: "a", count: Event.titleMaxLength + 1)
        #expect(!long.isValid)
    }

    @Test func reversedDatesAreInvalid() {
        var event = makeEvent()
        event.endDate = event.startDate.addingTimeInterval(-1)
        #expect(!event.isValid)
    }

    @Test func overlongOptionalFieldsAreInvalid() {
        var location = makeEvent()
        location.locationName = String(repeating: "a", count: Event.locationNameMaxLength + 1)
        #expect(!location.isValid)

        var note = makeEvent()
        note.note = String(repeating: "a", count: Event.noteMaxLength + 1)
        #expect(!note.isValid)
    }

    @Test func updatedBeforeCreatedIsInvalid() {
        var event = makeEvent()
        event.updatedAt = event.createdAt.addingTimeInterval(-1)
        #expect(!event.isValid)
    }

    @Test func jsonRoundTrip() throws {
        let event = makeEvent()
        let data = try JSONEncoder().encode(event)
        #expect(try JSONDecoder().decode(Event.self, from: data) == event)
    }

    @Test func firestoreSchema() throws {
        let fields = try Firestore.Encoder().encode(makeEvent())
        #expect(Set(fields.keys) == [
            "id", "tripId", "type", "title", "startDate", "endDate",
            "locationName", "note", "createdAt", "updatedAt",
        ])
        #expect(fields["type"] as? String == "architecture")
        for key in ["startDate", "endDate", "createdAt", "updatedAt"] {
            #expect(fields[key] is Timestamp, "\(key) should be a Firestore Timestamp")
        }
        #expect(fields["latitude"] == nil && fields["longitude"] == nil)
        #expect(fields["isAllDay"] == nil, "a timed Event's document is unchanged by G6")
    }

    // MARK: All-day (G6)

    @Test func timedEventOmitsTheAllDayFlag() throws {
        let event = makeEvent()
        #expect(event.isAllDay == nil)
        #expect(event.isTimed)
        let fields = try Firestore.Encoder().encode(event)
        #expect(fields["isAllDay"] == nil)
        #expect(fields.count == 10)
    }

    @Test func allDayFlagIsStoredWhenSet() throws {
        var stay = makeEvent()
        stay.type = .hotel
        stay.isAllDay = true
        #expect(!stay.isTimed)
        #expect(stay.isValid)
        let fields = try Firestore.Encoder().encode(stay)
        #expect(fields["isAllDay"] as? Bool == true)
        #expect(fields.count == 11)
        #expect(try Firestore.Decoder().decode(Event.self, from: fields) == stay)
    }

    /// Documents written before G6 have no flag and stay timed; nothing converts them.
    @Test func legacyEventWithoutTheFlagIsTimed() throws {
        var fields = try Firestore.Encoder().encode(makeEvent())
        fields.removeValue(forKey: "isAllDay")
        let decoded = try Firestore.Decoder().decode(Event.self, from: fields)
        #expect(decoded.isAllDay == nil)
        #expect(decoded.isTimed)
        #expect(decoded == makeEvent())
    }

    @Test func storedFalseMeansTimed() throws {
        var fields = try Firestore.Encoder().encode(makeEvent())
        fields["isAllDay"] = false
        let decoded = try Firestore.Decoder().decode(Event.self, from: fields)
        #expect(decoded.isAllDay == false)
        #expect(decoded.isTimed)
        #expect(decoded.isValid)
    }

    @Test func nonBoolFlagFailsToDecode() throws {
        var fields = try Firestore.Encoder().encode(makeEvent())
        fields["isAllDay"] = "yes"
        #expect(throws: (any Error).self) {
            try Firestore.Decoder().decode(Event.self, from: fields)
        }
    }

    /// RF-04 link and G6 flag coexist on an all-day architecture visit.
    @Test func allDayArchitectureVisitKeepsItsBuildingLink() throws {
        var event = makeEvent()
        event.buildingId = "building-1"
        event.isAllDay = true
        #expect(event.isValid)
        let fields = try Firestore.Encoder().encode(event)
        #expect(fields["buildingId"] as? String == "building-1")
        #expect(fields["isAllDay"] as? Bool == true)
        #expect(fields.count == 12)
        #expect(try Firestore.Decoder().decode(Event.self, from: fields) == event)
    }

    @Test func firestoreRoundTrip() throws {
        let event = makeEvent()
        let fields = try Firestore.Encoder().encode(event)
        #expect(try Firestore.Decoder().decode(Event.self, from: fields) == event)
    }

    @Test func eventTypeRawValuesMatchRules() {
        #expect(EventType.allCases.map(\.rawValue) == [
            "flight", "train", "car", "walk", "hotel", "business", "architecture", "food", "other",
        ])
    }

    @Test func unknownTypeFailsToDecode() throws {
        var fields = try Firestore.Encoder().encode(makeEvent())
        fields["type"] = "teleport"
        #expect(throws: (any Error).self) {
            try Firestore.Decoder().decode(Event.self, from: fields)
        }
    }

    @Test func g2EventWithoutBuildingIdStillDecodes() throws {
        var fields = try Firestore.Encoder().encode(makeEvent())
        #expect(fields["buildingId"] == nil)
        fields.removeValue(forKey: "buildingId")
        let decoded = try Firestore.Decoder().decode(Event.self, from: fields)
        #expect(decoded.buildingId == nil)
        #expect(decoded == makeEvent())
        #expect(decoded.isValid)
    }

    @Test func architectureEventWithBuildingIdIsValid() {
        var event = makeEvent()
        event.buildingId = "building-1"
        #expect(event.type == .architecture)
        #expect(event.isValid)
    }

    @Test func nonArchitectureEventWithBuildingIdIsInvalid() {
        var event = makeEvent()
        event.buildingId = "building-1"
        event.type = .food
        #expect(!event.isValid)
    }

    @Test func emptyOrOverlongBuildingIdIsInvalid() {
        var empty = makeEvent()
        empty.buildingId = ""
        #expect(!empty.isValid)
        var long = makeEvent()
        long.buildingId = String(repeating: "b", count: Event.buildingIdMaxLength + 1)
        #expect(!long.isValid)
    }

    @Test func firestoreRoundTripWithBuildingId() throws {
        var event = makeEvent()
        event.buildingId = "building-1"
        let fields = try Firestore.Encoder().encode(event)
        #expect(fields["buildingId"] as? String == "building-1")
        #expect(Set(fields.keys).count == 11)
        #expect(try Firestore.Decoder().decode(Event.self, from: fields) == event)
    }

    // MARK: Hotel clock times (G6-UX-05)

    private func makeStay(checkInMinutes: Int? = nil, checkOutMinutes: Int? = nil) -> Event {
        Event(
            id: "stay-1", tripId: "trip-1", type: .hotel, title: "Hotel", startDate: start,
            endDate: start.addingTimeInterval(86_400), createdAt: start, isAllDay: true,
            checkInMinutes: checkInMinutes, checkOutMinutes: checkOutMinutes
        )
    }

    @Test func clockTimesAreOmittedWhenUnset() throws {
        let fields = try Firestore.Encoder().encode(makeStay())
        #expect(fields["checkInMinutes"] == nil && fields["checkOutMinutes"] == nil)
        #expect(fields.count == 11, "a G6 stay's document is unchanged by UX-05")
        let timed = try Firestore.Encoder().encode(makeEvent())
        #expect(timed["checkInMinutes"] == nil && timed["checkOutMinutes"] == nil && timed.count == 10)
    }

    @Test func clockTimesRoundTrip() throws {
        let stay = makeStay(checkInMinutes: 17 * 60, checkOutMinutes: 9 * 60)
        #expect(stay.isValid)
        let fields = try Firestore.Encoder().encode(stay)
        #expect(fields["checkInMinutes"] as? Int == 1_020)
        #expect(fields["checkOutMinutes"] as? Int == 540)
        #expect(fields.count == 13)
        #expect(try Firestore.Decoder().decode(Event.self, from: fields) == stay)
    }

    @Test func clockTimesRangeMirrorsTheRules() {
        #expect(Event.clockMinutesRange == 0..<1_440)
        #expect(makeStay(checkInMinutes: 0, checkOutMinutes: 1_439).isValid)
        #expect(!makeStay(checkInMinutes: -1).isValid)
        #expect(!makeStay(checkOutMinutes: 1_440).isValid)
    }

    @Test func clockTimesBelongToAllDayHotelStaysOnly() {
        var timed = makeStay(checkInMinutes: 600)
        timed.isAllDay = nil
        #expect(!timed.isValid)
        var flaggedFalse = makeStay(checkInMinutes: 600)
        flaggedFalse.isAllDay = false
        #expect(!flaggedFalse.isValid)
        var car = makeStay(checkOutMinutes: 600)
        car.type = .car
        #expect(!car.isValid)
        #expect(makeStay().isValid, "a stay without clock times is unaffected")
    }

    @Test func g6StayWithoutClockTimesStillDecodes() throws {
        var fields = try Firestore.Encoder().encode(makeStay())
        fields.removeValue(forKey: "checkInMinutes")
        fields.removeValue(forKey: "checkOutMinutes")
        let decoded = try Firestore.Decoder().decode(Event.self, from: fields)
        #expect(decoded.checkInMinutes == nil && decoded.checkOutMinutes == nil)
        #expect(decoded == makeStay())
        #expect(decoded.isValid)
    }

    @Test func nonIntClockTimeFailsToDecode() throws {
        var fields = try Firestore.Encoder().encode(makeStay())
        fields["checkInMinutes"] = "17:00"
        #expect(throws: (any Error).self) {
            try Firestore.Decoder().decode(Event.self, from: fields)
        }
    }

    @Test func eventPaths() {
        #expect(TripPath.events(uid: "u1", tripID: "t1") == "users/u1/trips/t1/events")
        #expect(TripPath.event(uid: "u1", tripID: "t1", eventID: "e1") == "users/u1/trips/t1/events/e1")
    }
}
