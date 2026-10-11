import FirebaseFirestore
import Foundation
import Testing
@testable import ArchTrip

/// The update field set never carries `createdAt` and deletes absent optional fields
/// (RF-01). The rules keep validating the merged document, so the key sets below
/// stay aligned with `firebase/firestore.rules`.
struct DocumentUpdateTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeTrip() -> Trip {
        Trip(id: "trip-1", title: "Kyoto", destination: "Kyoto", startDate: date, endDate: date, createdAt: date)
    }

    private func makeEvent(buildingId: String? = nil) -> Event {
        Event(
            id: "event-1", tripId: "trip-1", type: .architecture, title: "Visit",
            startDate: date, endDate: date, createdAt: date, buildingId: buildingId
        )
    }

    @Test func tripUpdateOmitsCreatedAtOnly() throws {
        let fields = try DocumentUpdate.fields(for: makeTrip())
        #expect(Set(fields.keys) == ["id", "title", "destination", "startDate", "endDate", "updatedAt"])
        #expect(fields["updatedAt"] is Timestamp)
        #expect(Trip.optionalFields.isEmpty)
    }

    @Test func eventUpdateDeletesAbsentBuildingLink() throws {
        let unlinked = try DocumentUpdate.fields(for: makeEvent())
        #expect(unlinked["createdAt"] == nil)
        #expect(unlinked["buildingId"] is FieldValue, "nil buildingId must delete the stored field")
        #expect(Set(unlinked.keys) == [
            "id", "tripId", "type", "title", "startDate", "endDate", "locationName", "note", "updatedAt",
            "buildingId", "isAllDay", "checkInMinutes", "checkOutMinutes",
        ])

        let linked = try DocumentUpdate.fields(for: makeEvent(buildingId: "building-1"))
        #expect(linked["buildingId"] as? String == "building-1")
    }

    /// G6: a timed Event's update removes any stored flag (so converting an all-day Event
    /// back to timed deletes it rather than writing false); an all-day update keeps it.
    /// `createdAt` stays out of both.
    @Test func eventUpdateDeletesAbsentAllDayFlag() throws {
        let timed = try DocumentUpdate.fields(for: makeEvent())
        #expect(timed["isAllDay"] is FieldValue, "nil isAllDay must delete the stored field")
        #expect(timed["createdAt"] == nil)

        var stay = makeEvent()
        stay.type = .hotel
        stay.isAllDay = true
        let allDay = try DocumentUpdate.fields(for: stay)
        #expect(allDay["isAllDay"] as? Bool == true)
        #expect(allDay["createdAt"] == nil)
        #expect(Set(allDay.keys) == Set(timed.keys))
    }

    /// G6-UX-05: a cleared clock time deletes its field; a set one is written as an int.
    @Test func eventUpdateDeletesAbsentClockTimes() throws {
        var stay = makeEvent()
        stay.type = .hotel
        stay.buildingId = nil
        stay.isAllDay = true
        stay.checkInMinutes = 17 * 60
        let fields = try DocumentUpdate.fields(for: stay)
        #expect(fields["checkInMinutes"] as? Int == 1_020)
        #expect(fields["checkOutMinutes"] is FieldValue, "nil checkOutMinutes must delete the stored field")
        #expect(fields["createdAt"] == nil)
        let timed = try DocumentUpdate.fields(for: makeEvent())
        #expect(timed["checkInMinutes"] is FieldValue && timed["checkOutMinutes"] is FieldValue)
    }

    @Test func buildingUpdateDeletesAbsentOptionals() throws {
        let minimal = Building(id: "b1", name: "Minimal", createdAt: date)
        let fields = try DocumentUpdate.fields(for: minimal)
        #expect(fields["createdAt"] == nil)
        for key in Building.optionalFields {
            #expect(fields[key] is FieldValue, "\(key) must be deleted when nil")
        }

        let full = Building(id: "b2", name: "Full", completedYear: 1997, latitude: 43.0, longitude: 141.3, createdAt: date)
        let present = try DocumentUpdate.fields(for: full)
        #expect(present["completedYear"] as? Int == 1997)
        #expect(present["latitude"] as? Double == 43.0)
        #expect(present["longitude"] as? Double == 141.3)
    }

    /// Optional field names must be real document keys, or an update would add fields
    /// the rules reject.
    @Test func optionalFieldNamesMatchTheEncodedDocuments() throws {
        // Document shape only; this combination is not valid and never written by the app.
        var full = makeEvent(buildingId: "building-1")
        full.isAllDay = true
        full.checkInMinutes = 1
        full.checkOutMinutes = 2
        let event = try Firestore.Encoder().encode(full)
        #expect(Set(Event.optionalFields).isSubset(of: Set(event.keys)))
        #expect(Event.optionalFields == ["buildingId", "isAllDay", "checkInMinutes", "checkOutMinutes"])

        let building = try Firestore.Encoder().encode(
            Building(id: "b3", name: "Full", completedYear: 2000, latitude: 1, longitude: 2, createdAt: date)
        )
        #expect(Set(Building.optionalFields).isSubset(of: Set(building.keys)))
    }

    /// The decoded `createdAt` of a stored document can re-encode into the previous
    /// microsecond, which the server treats as a change; leaving it out is the only way
    /// to keep updates accepted.
    @Test func decodedCreatedAtWouldNotMatchTheStoredValue() throws {
        var stored = try Firestore.Encoder().encode(makeTrip())
        let createdAt = unstableMicrosecondTimestamp()
        stored["createdAt"] = createdAt
        let decoded = try Firestore.Decoder().decode(Trip.self, from: stored)

        let resent = try #require(try Firestore.Encoder().encode(decoded)["createdAt"] as? Timestamp)
        #expect(resent.nanoseconds / 1_000 == createdAt.nanoseconds / 1_000 - 1)
        #expect(try DocumentUpdate.fields(for: decoded)["createdAt"] == nil)
    }

    /// A microsecond timestamp (what the server stores) whose Date round trip lands in
    /// the previous microsecond.
    private func unstableMicrosecondTimestamp() -> Timestamp {
        var micros: Int32 = 123_456
        while true {
            let timestamp = Timestamp(seconds: 1_790_000_000, nanoseconds: micros * 1_000)
            if Timestamp(date: timestamp.dateValue()).nanoseconds / 1_000 < micros { return timestamp }
            micros += 1
        }
    }
}
