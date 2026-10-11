import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import Testing
@testable import ArchTrip

/// Live checks of the G6-UX-07 `pickupMinutes` / `returnMinutes` rules, on disposable
/// test users only.
///
/// They need the candidate `firebase/firestore.rules` from this branch to be PUBLISHED,
/// which is a separate Human Gate, so they are gated twice: `ARCHTRIP_FIREBASE_INTEGRATION=1`
/// like every live suite, plus `ARCHTRIP_UX07_RULES_PUBLISHED=1` once the rules are live.
/// Until then every write carrying the fields is denied by the published rules (see
/// `FirebaseRentalCarTimesBaselineTests`). Opt-in:
/// `TEST_RUNNER_ARCHTRIP_FIREBASE_INTEGRATION=1 TEST_RUNNER_ARCHTRIP_UX07_RULES_PUBLISHED=1 xcodebuild test ...`
@MainActor
@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["ARCHTRIP_FIREBASE_INTEGRATION"] == "1"
            && ProcessInfo.processInfo.environment["ARCHTRIP_UX07_RULES_PUBLISHED"] == "1"
    ),
    .timeLimit(.minutes(1))
)
struct FirebaseRentalCarTimesIntegrationTests {
    private let store = TripStore()
    private var db: Firestore { Firestore.firestore() }
    private let calendar = Calendar.current

    private func now() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    private func makeTrip() -> Trip {
        let now = now()
        let day = calendar.startOfDay(for: now)
        return Trip(title: "UX-07 live trip", destination: "", startDate: day, endDate: day, createdAt: now)
    }

    /// A two-day rental starting today with both clock times.
    private func makeRental(tripID: String) -> Event {
        RentalCarFixtures.rental(tripID: tripID, calendar: calendar, createdAt: now())
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

    @Test func rentalWithClockTimesRoundTripsAndClearsOne() async throws {
        try await withTestTrip { uid, trip in
            let car = makeRental(tripID: trip.id)
            try await acknowledged { try store.createEvent(car, uid: uid, serverAcknowledged: $0) }
            let read = try await store.fetchEvents(uid: uid, tripID: trip.id, source: .server)
            #expect(read.failures.isEmpty)
            #expect(read.items == [car])
            let stored = try await rawEvent(uid: uid, tripID: trip.id, eventID: car.id)
            #expect(stored["pickupMinutes"] as? Int == 10 * 60)
            #expect(stored["returnMinutes"] as? Int == 17 * 60)
            #expect(stored["checkInMinutes"] == nil && stored["checkOutMinutes"] == nil)

            // Clearing one time removes only that field; createdAt is not resent (RF-01 path).
            var edited = try #require(read.items.first)
            edited.returnMinutes = nil
            edited.updatedAt = Date()
            try await acknowledged { try store.updateEvent(edited, replacing: car, uid: uid, serverAcknowledged: $0) }
            let afterEdit = try await rawEvent(uid: uid, tripID: trip.id, eventID: car.id)
            #expect(afterEdit["pickupMinutes"] as? Int == 10 * 60)
            #expect(afterEdit["returnMinutes"] == nil)
            #expect(afterEdit["isAllDay"] as? Bool == true)
            #expect(afterEdit["createdAt"] is Timestamp)
            print("UX07-EVIDENCE rental with clock times create+read ok, clearing return removed the field, pickup kept")
        }
    }

    @Test func rulesValidateRentalClockTimes() async throws {
        try await withTestTrip { uid, trip in
            let base = makeRental(tripID: trip.id)
            let path = TripPath.event(uid: uid, tripID: trip.id, eventID: base.id)
            var fields = try Firestore.Encoder().encode(base)
            fields["pickupMinutes"] = 0
            fields["returnMinutes"] = 24 * 60 - 1
            try await rawWrite(fields, to: path)
            fields.removeValue(forKey: "pickupMinutes")
            fields.removeValue(forKey: "returnMinutes")
            try await rawWrite(fields, to: path) // the G6 all-day car shape

            fields["pickupMinutes"] = 24 * 60
            await expectPermissionDenied("1440") { try await rawWrite(fields, to: path) }
            fields["pickupMinutes"] = -1
            await expectPermissionDenied("-1") { try await rawWrite(fields, to: path) }
            fields["pickupMinutes"] = "10:00"
            await expectPermissionDenied("string") { try await rawWrite(fields, to: path) }
            fields["pickupMinutes"] = 10 * 60
            fields["type"] = "hotel"
            await expectPermissionDenied("non-car") { try await rawWrite(fields, to: path) }
            fields["type"] = "car"
            fields.removeValue(forKey: "isAllDay")
            await expectPermissionDenied("timed car") { try await rawWrite(fields, to: path) }
            fields["isAllDay"] = false
            await expectPermissionDenied("isAllDay false") { try await rawWrite(fields, to: path) }
            fields["isAllDay"] = true
            fields["checkInMinutes"] = 15 * 60
            await expectPermissionDenied("hotel time on a car") { try await rawWrite(fields, to: path) }
            print("UX07-EVIDENCE rules: 0 and 1439 accepted, absent accepted; 1440, -1, string, non-car, timed car, isAllDay false, hotel time on a car denied")
        }
    }

    @Test func otherUserCannotWriteRentalClockTimes() async throws {
        _ = try await LiveTestAuth.defaultUID()
        let otherUID = "ux07-other-\(UUID().uuidString)"
        await expectPermissionDenied("other user") {
            try await acknowledged {
                try store.createEvent(makeRental(tripID: "ux07-other-trip"), uid: otherUID, serverAcknowledged: $0)
            }
        }
        print("UX07-EVIDENCE denied: other-user write with rental clock times")
    }

    /// Offline: clearing the return time of a rental that already exists on the server
    /// keeps the cached rental readable, with the field gone and the write pending, until it
    /// is acknowledged (the G6-UX05 stored-only delete repair applies to the new fields).
    /// Throwaway secondary app and disposable user.
    @Test func offlineClearOfAReturnTimeKeepsTheCachedRentalReadable() async throws {
        let name = "ux07OfflineEdit\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        FirebaseApp.configure(name: name, options: try #require(FirebaseApp.app()).options)
        let app = try #require(FirebaseApp.app(name: name))
        let user = try await Auth.auth(app: app).signInAnonymously().user
        let uid = user.uid
        let db = Firestore.firestore(app: app)
        let store = TripStore(db: db)
        let trip = makeTrip()
        try await acknowledged { try store.createTrip(trip, uid: uid, serverAcknowledged: $0) }
        let car = makeRental(tripID: trip.id)
        try await acknowledged { try store.createEvent(car, uid: uid, serverAcknowledged: $0) }
        let stored = try #require(try await store.fetchEvents(uid: uid, tripID: trip.id, source: .server).items.first)

        try await db.disableNetwork()
        var edited = stored
        edited.returnMinutes = nil
        edited.updatedAt = now().addingTimeInterval(1)
        let pending = PendingWrite()
        try store.updateEvent(edited, replacing: stored, uid: uid, serverAcknowledged: pending.handler)
        let cached = try await store.fetchEvents(uid: uid, tripID: trip.id, source: .cache)
        #expect(cached.isFromCache && cached.hasPendingWrites)
        #expect(cached.failures.isEmpty, "\(cached.failures)")
        #expect(cached.items == [edited])
        #expect(cached.items.first?.pickupMinutes == 10 * 60 && cached.items.first?.returnMinutes == nil)
        var listened: QueryResult<Event>?
        for await result in store.eventUpdates(uid: uid, tripID: trip.id) {
            if case .success(let snapshot) = result { listened = snapshot }
            break
        }
        #expect(listened?.failures.isEmpty == true && listened?.items == [edited] && listened?.hasPendingWrites == true)

        try await db.enableNetwork()
        try await pending.wait()
        let server = try await store.fetchEvents(uid: uid, tripID: trip.id, source: .server)
        #expect(!server.isFromCache && server.failures.isEmpty && server.items == [edited])
        let raw = try await db.document(TripPath.event(uid: uid, tripID: trip.id, eventID: car.id)).getDocument(source: .server).data() ?? [:]
        #expect(raw["pickupMinutes"] as? Int == 10 * 60 && raw["returnMinutes"] == nil && raw["createdAt"] is Timestamp)
        print("UX07-EVIDENCE offline clear of return: cached rental readable with the field gone (pending), listener agrees, acknowledged after reconnect, server matches")

        try? await db.document(TripPath.event(uid: uid, tripID: trip.id, eventID: car.id)).delete()
        try? await db.document(TripPath.document(uid: uid, tripID: trip.id)).delete()
        try? await db.terminate()
        try? await user.delete()
        _ = await app.delete()
    }
}

/// Runs under the CURRENTLY published rules (every live run until the UX-07 rules go
/// live): a rental car carrying the new fields must be denied, so the existing app and
/// data are untouched by this branch until the Rules Gate. Disabled once
/// `ARCHTRIP_UX07_RULES_PUBLISHED=1` says the candidate is live.
@MainActor
@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["ARCHTRIP_FIREBASE_INTEGRATION"] == "1"
            && ProcessInfo.processInfo.environment["ARCHTRIP_UX07_RULES_PUBLISHED"] != "1"
    ),
    .timeLimit(.minutes(1))
)
struct FirebaseRentalCarTimesBaselineTests {
    private let store = TripStore()
    private var db: Firestore { Firestore.firestore() }
    private let calendar = Calendar.current

    @Test func currentRulesDenyRentalClockTimesUntilPublished() async throws {
        let uid = try await LiveTestAuth.defaultUID()
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let day = calendar.startOfDay(for: now)
        let trip = Trip(title: "UX-07 baseline trip", destination: "", startDate: day, endDate: day, createdAt: now)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try store.createTrip(trip, uid: uid) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        let car = RentalCarFixtures.rental(tripID: trip.id, calendar: calendar, createdAt: now)
        await expectPermissionDenied("rental clock times under the published rules") {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                do {
                    try store.createEvent(car, uid: uid) { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        // The same rental without clock times is the accepted G6 shape.
        var plain = car
        plain.pickupMinutes = nil
        plain.returnMinutes = nil
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try store.createEvent(plain, uid: uid) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        print("UX07-EVIDENCE baseline: published rules deny pickupMinutes/returnMinutes and accept the G6 all-day car")
        try? await db.document(TripPath.event(uid: uid, tripID: trip.id, eventID: plain.id)).delete()
        try? await db.document(TripPath.event(uid: uid, tripID: trip.id, eventID: car.id)).delete()
        try? await db.document(TripPath.document(uid: uid, tripID: trip.id)).delete()
    }
}

/// Shared by both suites: a two-day rental starting today, pickup 10:00, return 17:00.
enum RentalCarFixtures {
    static func rental(tripID: String, calendar: Calendar, createdAt: Date) -> Event {
        let today = calendar.startOfDay(for: createdAt)
        let dates = AllDaySchedule.dates(firstDay: today, lastDay: AllDaySchedule.dayAfter(today, calendar: calendar), calendar: calendar)
        return Event(
            tripId: tripID, type: .car, title: "UX-07 live rental", startDate: dates.start, endDate: dates.end,
            note: "live test", createdAt: createdAt, isAllDay: true, pickupMinutes: 10 * 60, returnMinutes: 17 * 60
        )
    }
}

/// Asserts a Firestore permission denial, shared by the UX-07 suites.
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
