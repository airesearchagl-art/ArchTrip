import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import Testing
@testable import ArchTrip

/// Live checks of the G6 `isAllDay` rules, on disposable test users only.
///
/// They need the candidate `firebase/firestore.rules` from this branch to be PUBLISHED,
/// which is a separate Human Gate, so they are gated twice: `ARCHTRIP_FIREBASE_INTEGRATION=1`
/// like every live suite, plus `ARCHTRIP_G6_RULES_PUBLISHED=1` once the rules are live.
/// Under the G3 rules every write carrying `isAllDay` is denied (Wave 2 probe), so running
/// them earlier would only report that. Opt-in:
/// `TEST_RUNNER_ARCHTRIP_FIREBASE_INTEGRATION=1 TEST_RUNNER_ARCHTRIP_G6_RULES_PUBLISHED=1 xcodebuild test ...`
@MainActor
@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["ARCHTRIP_FIREBASE_INTEGRATION"] == "1"
            && ProcessInfo.processInfo.environment["ARCHTRIP_G6_RULES_PUBLISHED"] == "1"
    ),
    .timeLimit(.minutes(1))
)
struct FirebaseAllDayIntegrationTests {
    private let store = TripStore()
    private var db: Firestore { Firestore.firestore() }
    private let calendar = Calendar.current

    private func now() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    private func makeTrip() -> Trip {
        let now = now()
        let day = calendar.startOfDay(for: now)
        return Trip(title: "G6 live trip", destination: "", startDate: day, endDate: day, createdAt: now)
    }

    /// A two-night stay starting today, stored at local midnight like the editor does.
    private func makeStay(tripID: String) -> Event {
        let today = calendar.startOfDay(for: now())
        let checkOut = AllDaySchedule.dayAfter(AllDaySchedule.dayAfter(today, calendar: calendar), calendar: calendar)
        let dates = AllDaySchedule.dates(checkIn: today, checkOut: checkOut, calendar: calendar)
        return Event(
            tripId: tripID, type: .hotel, title: "G6 live stay", startDate: dates.start, endDate: dates.end,
            note: "live test", createdAt: now(), isAllDay: true
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

    /// Raw `setData`, bypassing the model, for document shapes the app cannot produce.
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

    /// Creates a Trip, runs `body`, then removes the Trip and any Events under it.
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

    @Test func allDayStayRoundTripsAndConvertsBackToTimed() async throws {
        try await withTestTrip { uid, trip in
            let stay = makeStay(tripID: trip.id)
            try await acknowledged { try store.createEvent(stay, uid: uid, serverAcknowledged: $0) }
            let read = try await store.fetchEvents(uid: uid, tripID: trip.id, source: .server)
            #expect(read.failures.isEmpty)
            #expect(read.items == [stay])
            #expect(try await rawEvent(uid: uid, tripID: trip.id, eventID: stay.id)["isAllDay"] as? Bool == true)

            // Editing an all-day Event goes through the RF-01 update path (createdAt not resent).
            var edited = try #require(read.items.first)
            edited.title = "G6 live stay (edited)"
            edited.updatedAt = Date()
            try await acknowledged { try store.updateEvent(edited, uid: uid, serverAcknowledged: $0) }
            let afterEdit = try await rawEvent(uid: uid, tripID: trip.id, eventID: stay.id)
            #expect(afterEdit["isAllDay"] as? Bool == true)
            #expect(afterEdit["title"] as? String == edited.title)

            // Back to timed: the flag is removed from the document, not stored as false.
            var timed = edited
            timed.isAllDay = nil
            timed.endDate = timed.startDate.addingTimeInterval(3_600)
            timed.updatedAt = Date()
            try await acknowledged { try store.updateEvent(timed, uid: uid, serverAcknowledged: $0) }
            let afterConversion = try await rawEvent(uid: uid, tripID: trip.id, eventID: stay.id)
            #expect(afterConversion["isAllDay"] == nil)
            #expect(afterConversion["createdAt"] is Timestamp)
            let reread = try await store.fetchEvents(uid: uid, tripID: trip.id, source: .server).items.first
            #expect(reread?.isTimed == true)
            #expect(reread?.isAllDay == nil)
            print("G6-EVIDENCE all-day create+read ok, all-day update ok, flag removed on conversion to timed")
        }
    }

    @Test func rulesAcceptBoolFlagsAndRejectOtherTypes() async throws {
        try await withTestTrip { uid, trip in
            let base = makeStay(tripID: trip.id)
            let path = TripPath.event(uid: uid, tripID: trip.id, eventID: base.id)
            var fields = try Firestore.Encoder().encode(base)
            #expect(fields["isAllDay"] as? Bool == true)
            try await rawWrite(fields, to: path)
            fields["isAllDay"] = false
            try await rawWrite(fields, to: path)
            fields.removeValue(forKey: "isAllDay")
            try await rawWrite(fields, to: path) // the pre-G6 document shape
            #expect(try await rawEvent(uid: uid, tripID: trip.id, eventID: base.id)["isAllDay"] == nil)

            fields["isAllDay"] = "yes"
            await expectPermissionDenied("string flag") { try await rawWrite(fields, to: path) }
            fields["isAllDay"] = 1
            await expectPermissionDenied("int flag") { try await rawWrite(fields, to: path) }
            // The other Event checks are untouched by the rules change.
            fields["isAllDay"] = true
            fields["title"] = ""
            await expectPermissionDenied("empty title") { try await rawWrite(fields, to: path) }
            print("G6-EVIDENCE rules: isAllDay true/false/absent accepted; string and int denied; empty title still denied")
        }
    }

    @Test func otherUserCannotWriteAllDayEvents() async throws {
        _ = try await LiveTestAuth.defaultUID()
        let otherUID = "g6-other-\(UUID().uuidString)"
        await expectPermissionDenied("other user") {
            try await acknowledged {
                try store.createEvent(makeStay(tripID: "g6-other-trip"), uid: otherUID, serverAcknowledged: $0)
            }
        }
        print("G6-EVIDENCE denied: other-user all-day write")
    }

    /// Offline: an all-day Event created without a connection shows from the cache with
    /// its flag and reaches the server after reconnecting. Uses a throwaway secondary app
    /// and anonymous user, deleted afterwards, so the default app's network stays up.
    @Test func allDayEventCreatedOfflineSyncsAfterReconnect() async throws {
        let name = "g6Offline\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        FirebaseApp.configure(name: name, options: try #require(FirebaseApp.app()).options)
        let app = try #require(FirebaseApp.app(name: name))
        let user = try await Auth.auth(app: app).signInAnonymously().user
        let uid = user.uid
        let db = Firestore.firestore(app: app)
        let store = TripStore(db: db)
        let trip = makeTrip()
        try await acknowledged { try store.createTrip(trip, uid: uid, serverAcknowledged: $0) }

        try await db.disableNetwork()
        let stay = makeStay(tripID: trip.id)
        let pending = PendingWrite()
        try store.createEvent(stay, uid: uid, serverAcknowledged: pending.handler)
        let cached = try await store.fetchEvents(uid: uid, tripID: trip.id, source: .cache)
        #expect(cached.isFromCache)
        #expect(cached.hasPendingWrites)
        #expect(cached.items == [stay])
        #expect(cached.items.first?.isAllDay == true)

        try await db.enableNetwork()
        try await pending.wait()
        let server = try await store.fetchEvents(uid: uid, tripID: trip.id, source: .server)
        #expect(server.items == [stay])
        print("G6-EVIDENCE offline all-day create visible from cache, acknowledged after reconnect")

        try? await db.document(TripPath.event(uid: uid, tripID: trip.id, eventID: stay.id)).delete()
        try? await db.document(TripPath.document(uid: uid, tripID: trip.id)).delete()
        try? await db.terminate()
        try? await user.delete()
        _ = await app.delete()
    }
}

/// Captures one Firestore completion so a write can be queued offline and awaited later.
@MainActor
private final class PendingWrite {
    private var continuation: CheckedContinuation<Void, Error>?
    private var outcome: Result<Void, Error>?

    var handler: (Error?) -> Void {
        { [self] error in
            let result: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
            if let continuation {
                self.continuation = nil
                continuation.resume(with: result)
            } else {
                outcome = result
            }
        }
    }

    func wait() async throws {
        if let outcome { return try outcome.get() }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
}
