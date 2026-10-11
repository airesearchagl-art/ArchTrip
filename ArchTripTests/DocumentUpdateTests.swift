import FirebaseFirestore
import Foundation
import Testing
@testable import ArchTrip

/// The update field set never carries `createdAt` and deletes an optional field only when
/// the stored document had it and the model no longer does (RF-01, offline cache
/// investigation). The rules keep validating the merged document, so the key sets below
/// stay aligned with `firebase/firestore.rules`.
struct DocumentUpdateTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)
    private let requiredKeys: Set<String> = [
        "id", "tripId", "type", "title", "startDate", "endDate", "locationName", "note", "updatedAt",
    ]

    private func makeTrip() -> Trip {
        Trip(id: "trip-1", title: "Kyoto", destination: "Kyoto", startDate: date, endDate: date, createdAt: date)
    }

    private func makeEvent(buildingId: String? = nil) -> Event {
        Event(
            id: "event-1", tripId: "trip-1", type: .architecture, title: "Visit",
            startDate: date, endDate: date, createdAt: date, buildingId: buildingId
        )
    }

    private func makeStay(checkInMinutes: Int? = nil, checkOutMinutes: Int? = nil) -> Event {
        Event(
            id: "stay-1", tripId: "trip-1", type: .hotel, title: "Hotel", startDate: date, endDate: date,
            createdAt: date, isAllDay: true, checkInMinutes: checkInMinutes, checkOutMinutes: checkOutMinutes
        )
    }

    @Test func tripUpdateOmitsCreatedAtOnly() throws {
        let fields = try DocumentUpdate.fields(for: makeTrip(), replacing: makeTrip())
        #expect(Set(fields.keys) == ["id", "title", "destination", "startDate", "endDate", "updatedAt"])
        #expect(fields["updatedAt"] is Timestamp)
        #expect(Trip.optionalFields.isEmpty)
    }

    /// RF-04: unlinking deletes the stored link; an Event that never had one sends no delete.
    @Test func eventUpdateDeletesAClearedBuildingLink() throws {
        let unlinked = try DocumentUpdate.fields(for: makeEvent(), replacing: makeEvent(buildingId: "building-1"))
        #expect(unlinked["createdAt"] == nil)
        #expect(unlinked["buildingId"] is FieldValue, "a stored buildingId cleared to nil must delete the field")
        #expect(Set(unlinked.keys) == requiredKeys.union(["buildingId"]))

        let neverLinked = try DocumentUpdate.fields(for: makeEvent(), replacing: makeEvent())
        #expect(neverLinked["buildingId"] == nil, "no delete for a field the document never had")
        #expect(Set(neverLinked.keys) == requiredKeys)

        let linked = try DocumentUpdate.fields(for: makeEvent(buildingId: "building-1"), replacing: makeEvent())
        #expect(linked["buildingId"] as? String == "building-1")
    }

    /// G6: converting an all-day Event back to timed deletes the stored flag rather than
    /// writing false; a timed Event edited while timed sends no delete; an all-day update
    /// keeps the flag. `createdAt` stays out of all of them.
    @Test func eventUpdateDeletesAClearedAllDayFlag() throws {
        var stay = makeEvent()
        stay.type = .hotel
        stay.isAllDay = true
        var timed = stay
        timed.isAllDay = nil

        let converted = try DocumentUpdate.fields(for: timed, replacing: stay)
        #expect(converted["isAllDay"] is FieldValue, "the stored flag must be deleted on conversion")
        #expect(converted["createdAt"] == nil)
        #expect(Set(converted.keys) == requiredKeys.union(["isAllDay"]))

        let stillTimed = try DocumentUpdate.fields(for: timed, replacing: timed)
        #expect(stillTimed["isAllDay"] == nil)
        #expect(Set(stillTimed.keys) == requiredKeys)

        let allDay = try DocumentUpdate.fields(for: stay, replacing: stay)
        #expect(allDay["isAllDay"] as? Bool == true)
        #expect(allDay["createdAt"] == nil)
    }

    /// G6-UX-05: a cleared clock time deletes its field; a set one is written as an int; a
    /// time that was never stored is not deleted.
    @Test func eventUpdateDeletesAClearedClockTime() throws {
        let both = makeStay(checkInMinutes: 17 * 60, checkOutMinutes: 9 * 60)
        let cleared = try DocumentUpdate.fields(for: makeStay(checkInMinutes: 17 * 60), replacing: both)
        #expect(cleared["checkInMinutes"] as? Int == 1_020)
        #expect(cleared["checkOutMinutes"] is FieldValue, "a stored checkOutMinutes cleared to nil must delete the field")
        #expect(cleared["createdAt"] == nil)
        #expect(Set(cleared.keys) == requiredKeys.union(["isAllDay", "checkInMinutes", "checkOutMinutes"]))

        let neverSet = try DocumentUpdate.fields(for: makeStay(), replacing: makeStay())
        #expect(neverSet["checkInMinutes"] == nil && neverSet["checkOutMinutes"] == nil)
        #expect(Set(neverSet.keys) == requiredKeys.union(["isAllDay"]))

        let timed = try DocumentUpdate.fields(for: makeEvent(), replacing: makeEvent())
        #expect(timed["checkInMinutes"] == nil && timed["checkOutMinutes"] == nil && timed["isAllDay"] == nil)
    }

    /// Offline cache investigation (2026-10-11): a delete of an optional the document does
    /// not have must never be sent. Combined with the delete of a present field it makes
    /// Firestore's local view skip the later delete and drop `updatedAt`, so the pending
    /// Event fails to decode until the write is acknowledged. Every optional is covered.
    @Test func absentOptionalsAreNeverDeleted() throws {
        for field in Event.optionalFields {
            let fields = try DocumentUpdate.fields(for: makeEvent(), replacing: makeEvent())
            #expect(fields[field] == nil, "\(field) was never stored and must not be deleted")
        }
        // Clearing the check-out time of a stay that has no Building link: exactly one delete.
        let stay = makeStay(checkInMinutes: 17 * 60, checkOutMinutes: 9 * 60)
        let fields = try DocumentUpdate.fields(for: makeStay(checkInMinutes: 17 * 60), replacing: stay)
        let deletes = fields.filter { $0.value is FieldValue }.map(\.key)
        #expect(deletes == ["checkOutMinutes"])

        // Converting the same stay to timed and clearing both times: deletes only what was stored.
        var timed = stay
        timed.isAllDay = nil
        timed.checkInMinutes = nil
        timed.checkOutMinutes = nil
        let converted = try DocumentUpdate.fields(for: timed, replacing: stay)
        #expect(Set(converted.filter { $0.value is FieldValue }.map(\.key)) == ["isAllDay", "checkInMinutes", "checkOutMinutes"])
        #expect(converted["buildingId"] == nil)

        let minimal = Building(id: "b1", name: "Minimal", createdAt: date)
        let building = try DocumentUpdate.fields(for: minimal, replacing: minimal)
        for field in Building.optionalFields {
            #expect(building[field] == nil, "\(field) was never stored and must not be deleted")
        }
    }

    private func makeRental(pickupMinutes: Int? = nil, returnMinutes: Int? = nil) -> Event {
        Event(
            id: "car-1", tripId: "trip-1", type: .car, title: "Rental", startDate: date, endDate: date,
            createdAt: date, isAllDay: true, pickupMinutes: pickupMinutes, returnMinutes: returnMinutes
        )
    }

    /// G6-UX-07: a cleared rental clock time deletes its field; a set one is written as an
    /// int; a time that was never stored is not deleted; hotel fields are never touched.
    @Test func rentalUpdateDeletesAClearedClockTime() throws {
        let both = makeRental(pickupMinutes: 10 * 60, returnMinutes: 17 * 60)
        let cleared = try DocumentUpdate.fields(for: makeRental(pickupMinutes: 10 * 60), replacing: both)
        #expect(cleared["pickupMinutes"] as? Int == 600)
        #expect(cleared["returnMinutes"] is FieldValue, "a stored returnMinutes cleared to nil must delete the field")
        #expect(cleared["createdAt"] == nil)
        #expect(Set(cleared.keys) == requiredKeys.union(["isAllDay", "pickupMinutes", "returnMinutes"]))
        #expect(cleared.filter { $0.value is FieldValue }.map(\.key) == ["returnMinutes"], "exactly one delete")

        let neverSet = try DocumentUpdate.fields(for: makeRental(), replacing: makeRental())
        #expect(neverSet["pickupMinutes"] == nil && neverSet["returnMinutes"] == nil)
        #expect(Set(neverSet.keys) == requiredKeys.union(["isAllDay"]))

        // Converting the rental to timed clears everything that was stored, and only that.
        var timed = both
        timed.isAllDay = nil
        timed.pickupMinutes = nil
        timed.returnMinutes = nil
        let converted = try DocumentUpdate.fields(for: timed, replacing: both)
        #expect(Set(converted.filter { $0.value is FieldValue }.map(\.key)) == ["isAllDay", "pickupMinutes", "returnMinutes"])
        #expect(converted["checkInMinutes"] == nil && converted["checkOutMinutes"] == nil && converted["buildingId"] == nil)

        // Changing the type in the editor leaves the rental times nil: they are deleted, not kept.
        var retyped = both
        retyped.type = .hotel
        retyped.pickupMinutes = nil
        retyped.returnMinutes = nil
        let fields = try DocumentUpdate.fields(for: retyped, replacing: both)
        #expect(fields["pickupMinutes"] is FieldValue && fields["returnMinutes"] is FieldValue)
        #expect(fields["checkInMinutes"] == nil && fields["checkOutMinutes"] == nil)
    }

    @Test func buildingUpdateDeletesClearedOptionals() throws {
        let full = Building(id: "b2", name: "Full", completedYear: 1997, latitude: 43.0, longitude: 141.3, createdAt: date)
        var stripped = full
        stripped.completedYear = nil
        stripped.latitude = nil
        stripped.longitude = nil
        let fields = try DocumentUpdate.fields(for: stripped, replacing: full)
        #expect(fields["createdAt"] == nil)
        for key in Building.optionalFields {
            #expect(fields[key] is FieldValue, "\(key) must be deleted when cleared")
        }

        let present = try DocumentUpdate.fields(for: full, replacing: stripped)
        #expect(present["completedYear"] as? Int == 1997)
        #expect(present["latitude"] as? Double == 43.0)
        #expect(present["longitude"] as? Double == 141.3)

        // Only the year cleared: the coordinates are rewritten, not deleted.
        var yearless = full
        yearless.completedYear = nil
        let partial = try DocumentUpdate.fields(for: yearless, replacing: full)
        #expect(partial["completedYear"] is FieldValue)
        #expect(partial["latitude"] as? Double == 43.0 && partial["longitude"] as? Double == 141.3)
    }

    /// Optional field names must be real document keys, or an update would add fields
    /// the rules reject.
    @Test func optionalFieldNamesMatchTheEncodedDocuments() throws {
        // Document shape only; this combination is not valid and never written by the app.
        var full = makeEvent(buildingId: "building-1")
        full.isAllDay = true
        full.checkInMinutes = 1
        full.checkOutMinutes = 2
        full.pickupMinutes = 3
        full.returnMinutes = 4
        let event = try Firestore.Encoder().encode(full)
        #expect(Set(Event.optionalFields).isSubset(of: Set(event.keys)))
        #expect(Event.optionalFields == ["buildingId", "isAllDay", "checkInMinutes", "checkOutMinutes", "pickupMinutes", "returnMinutes"])

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
        #expect(try DocumentUpdate.fields(for: decoded, replacing: decoded)["createdAt"] == nil)
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
