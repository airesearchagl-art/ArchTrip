import FirebaseFirestore
import Foundation
import Testing
@testable import ArchTrip

/// Live checks of the G6-UX-05 `checkInMinutes` / `checkOutMinutes` rules, on disposable
/// test users only.
///
/// They need the candidate `firebase/firestore.rules` from this branch to be PUBLISHED,
/// which is a separate Human Gate, so they are gated twice: `ARCHTRIP_FIREBASE_INTEGRATION=1`
/// like every live suite, plus `ARCHTRIP_UX05_RULES_PUBLISHED=1` once the rules are live.
/// Until then every write carrying the fields is denied by the published rules. Opt-in:
/// `TEST_RUNNER_ARCHTRIP_FIREBASE_INTEGRATION=1 TEST_RUNNER_ARCHTRIP_UX05_RULES_PUBLISHED=1 xcodebuild test ...`
@MainActor
@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["ARCHTRIP_FIREBASE_INTEGRATION"] == "1"
            && ProcessInfo.processInfo.environment["ARCHTRIP_UX05_RULES_PUBLISHED"] == "1"
    ),
    .timeLimit(.minutes(1))
)
struct FirebaseHotelTimesIntegrationTests {
    private let store = TripStore()
    private var db: Firestore { Firestore.firestore() }
    private let calendar = Calendar.current

    private func now() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    private func makeTrip() -> Trip {
        let now = now()
        let day = calendar.startOfDay(for: now)
        return Trip(title: "UX-05 live trip", destination: "", startDate: day, endDate: day, createdAt: now)
    }

    /// A one-night stay starting today with both clock times.
    private func makeStay(tripID: String) -> Event {
        let today = calendar.startOfDay(for: now())
        let dates = AllDaySchedule.dates(checkIn: today, checkOut: AllDaySchedule.dayAfter(today, calendar: calendar), calendar: calendar)
        return Event(
            tripId: tripID, type: .hotel, title: "UX-05 live stay", startDate: dates.start, endDate: dates.end,
            note: "live test", createdAt: now(), isAllDay: true, checkInMinutes: 17 * 60, checkOutMinutes: 9 * 60
        )
    }

    private func acknowledged(_ write: (@escaping (Error?) -> Void) throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try write { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func rawWrite(_ fields: [String: Any], to path: String) async throws {
        let document = db.document(path)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.setData(fields) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func expectPermissionDenied(_ label: String, _ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("\(label): expected permission denied, but the operation succeeded")
        } catch {
            let error = error as NSError
            #expect(
                error.domain == FirestoreErrorDomain && error.code == FirestoreErrorCode.permissionDenied.rawValue,
                "\(label): \(error)"
            )
        }
    }

    private func withTestTrip(_ body: (String, Trip) async throws -> Void) async throws {
        let uid = try await LiveTestAuth.defaultUID()
        let trip = makeTrip()
        try await acknowledged { try store.createTrip(trip, uid: uid, serverAcknowledged: $0) }
        var bodyError: Error?
        do {
            try await body(uid, trip)
        } catch {
            bodyError = error
        }
        if let leftovers = try? await db.collection(TripPath.events(uid: uid, tripID: trip.id)).getDocuments(source: .server) {
            for document in leftovers.documents {
                try? await document.reference.delete()
            }
        }
        try? await db.document(TripPath.document(uid: uid, tripID: trip.id)).delete()
        if let bodyError { throw bodyError }
    }

    private func rawEvent(uid: String, tripID: String, eventID: String) async throws -> [String: Any] {
        let path = TripPath.event(uid: uid, tripID: tripID, eventID: eventID)
        return try #require(try await db.document(path).getDocument(source: .server).data())
    }

    @Test func stayWithClockTimesRoundTripsAndClearsOne() async throws {
        try await withTestTrip { uid, trip in
            let stay = makeStay(tripID: trip.id)
            try await acknowledged { try store.createEvent(stay, uid: uid, serverAcknowledged: $0) }
            let read = try await store.fetchEvents(uid: uid, tripID: trip.id, source: .server)
            #expect(read.failures.isEmpty)
            #expect(read.items == [stay])
            let stored = try await rawEvent(uid: uid, tripID: trip.id, eventID: stay.id)
            #expect(stored["checkInMinutes"] as? Int == 17 * 60)
            #expect(stored["checkOutMinutes"] as? Int == 9 * 60)

            // Clearing one time removes only that field; createdAt is not resent (RF-01 path).
            var edited = try #require(read.items.first)
            edited.checkOutMinutes = nil
            edited.updatedAt = Date()
            try await acknowledged { try store.updateEvent(edited, uid: uid, serverAcknowledged: $0) }
            let afterEdit = try await rawEvent(uid: uid, tripID: trip.id, eventID: stay.id)
            #expect(afterEdit["checkInMinutes"] as? Int == 17 * 60)
            #expect(afterEdit["checkOutMinutes"] == nil)
            #expect(afterEdit["isAllDay"] as? Bool == true)
            #expect(afterEdit["createdAt"] is Timestamp)
            print("UX05-EVIDENCE stay with clock times create+read ok, clearing check-out removed the field, check-in kept")
        }
    }

    @Test func rulesValidateClockTimes() async throws {
        try await withTestTrip { uid, trip in
            let base = makeStay(tripID: trip.id)
            let path = TripPath.event(uid: uid, tripID: trip.id, eventID: base.id)
            var fields = try Firestore.Encoder().encode(base)
            fields["checkInMinutes"] = 0
            fields["checkOutMinutes"] = 24 * 60 - 1
            try await rawWrite(fields, to: path)
            fields.removeValue(forKey: "checkInMinutes")
            fields.removeValue(forKey: "checkOutMinutes")
            try await rawWrite(fields, to: path) // the G6 document shape

            fields["checkInMinutes"] = 24 * 60
            await expectPermissionDenied("1440") { try await rawWrite(fields, to: path) }
            fields["checkInMinutes"] = -1
            await expectPermissionDenied("-1") { try await rawWrite(fields, to: path) }
            fields["checkInMinutes"] = "17:00"
            await expectPermissionDenied("string") { try await rawWrite(fields, to: path) }
            fields["checkInMinutes"] = 17 * 60
            fields["type"] = "car"
            await expectPermissionDenied("non-hotel") { try await rawWrite(fields, to: path) }
            fields["type"] = "hotel"
            fields.removeValue(forKey: "isAllDay")
            await expectPermissionDenied("timed hotel") { try await rawWrite(fields, to: path) }
            fields["isAllDay"] = false
            await expectPermissionDenied("isAllDay false") { try await rawWrite(fields, to: path) }
            print("UX05-EVIDENCE rules: 0 and 1439 accepted, absent accepted; 1440, -1, string, non-hotel, timed hotel denied")
        }
    }

    @Test func otherUserCannotWriteClockTimes() async throws {
        _ = try await LiveTestAuth.defaultUID()
        let otherUID = "ux05-other-\(UUID().uuidString)"
        await expectPermissionDenied("other user") {
            try await acknowledged {
                try store.createEvent(makeStay(tripID: "ux05-other-trip"), uid: otherUID, serverAcknowledged: $0)
            }
        }
        print("UX05-EVIDENCE denied: other-user write with clock times")
    }
}
