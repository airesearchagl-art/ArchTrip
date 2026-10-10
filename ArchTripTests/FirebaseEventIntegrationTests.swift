import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import Testing
@testable import ArchTrip

/// Live checks of the G2 Event rules. Requires the candidate `firebase/firestore.rules`
/// to be published. Opt-in: `TEST_RUNNER_ARCHTRIP_FIREBASE_INTEGRATION=1 xcodebuild test ...`
@MainActor
@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["ARCHTRIP_FIREBASE_INTEGRATION"] == "1"),
    .timeLimit(.minutes(1))
)
struct FirebaseEventIntegrationTests {
    private let store = TripStore()
    private var db: Firestore { Firestore.firestore() }

    private func signedInUID() async throws -> String {
        try await LiveTestAuth.defaultUID()
    }

    private func now() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    private func makeTrip() -> Trip {
        let now = now()
        return Trip(title: "G2 integration", destination: "Osaka", startDate: now, endDate: now, createdAt: now)
    }

    private func makeEvent(tripID: String) -> Event {
        let now = now()
        return Event(
            tripId: tripID,
            type: .architecture,
            title: "G2 integration event",
            startDate: now,
            endDate: now.addingTimeInterval(3_600),
            locationName: "Nakanoshima",
            note: "live test",
            createdAt: now
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

    private func expectPermissionDenied(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("Expected permission denied, but the operation succeeded")
        } catch {
            let error = error as NSError
            #expect(error.domain == FirestoreErrorDomain && error.code == FirestoreErrorCode.permissionDenied.rawValue, "\(error)")
        }
    }

    private func rawEventFields(_ event: Event) throws -> [String: Any] {
        try Firestore.Encoder().encode(event)
    }

    /// Creates a Trip, runs `body`, then removes the Trip and any Events left
    /// under it, even when `body` fails.
    private func withTestTrip(_ body: (String, Trip) async throws -> Void) async throws {
        let uid = try await signedInUID()
        let trip = makeTrip()
        try await acknowledged { try store.createTrip(trip, uid: uid, serverAcknowledged: $0) }
        var bodyError: Error?
        do {
            try await body(uid, trip)
        } catch {
            bodyError = error
        }
        // Best effort for Events (listing them is denied until the G2 rules are
        // published); the Trip itself is always removed.
        if let leftovers = try? await db.collection(TripPath.events(uid: uid, tripID: trip.id)).getDocuments(source: .server) {
            for document in leftovers.documents {
                try? await document.reference.delete()
            }
        }
        try await db.document(TripPath.document(uid: uid, tripID: trip.id)).delete()
        if let bodyError { throw bodyError }
    }

    @Test func ownEventRoundTripUpdateAndDelete() async throws {
        try await withTestTrip { uid, trip in
            var event = makeEvent(tripID: trip.id)
            try await acknowledged { try store.createEvent(event, uid: uid, serverAcknowledged: $0) }
            let read = try await store.fetchEvents(uid: uid, tripID: trip.id, source: .server)
            #expect(!read.isFromCache)
            #expect(read.failures.isEmpty)
            #expect(read.items == [event])
            print("G2-EVIDENCE event write+read path=users/\(uid.prefix(6))…/trips/\(trip.id)/events/\(event.id) match=\(read.items == [event])")

            event.title = "G2 integration event (edited)"
            event.updatedAt = event.updatedAt.addingTimeInterval(60)
            let edited = event
            try await acknowledged { try store.createEvent(edited, uid: uid, serverAcknowledged: $0) }
            #expect(try await store.fetchEvents(uid: uid, tripID: trip.id, source: .server).items == [edited])

            var movedCreatedAt = edited
            movedCreatedAt.createdAt = edited.createdAt.addingTimeInterval(-60)
            await expectPermissionDenied {
                try await acknowledged { try store.createEvent(movedCreatedAt, uid: uid, serverAcknowledged: $0) }
            }

            try await acknowledged { store.deleteEvent(edited, uid: uid, serverAcknowledged: $0) }
            #expect(try await store.fetchEvents(uid: uid, tripID: trip.id, source: .server).items.isEmpty)
            print("G2-EVIDENCE event update ok, createdAt change denied, delete ok")
        }
    }

    @Test func invalidEventsAreRejected() async throws {
        try await withTestTrip { uid, trip in
            var reversed = makeEvent(tripID: trip.id)
            reversed.endDate = reversed.startDate.addingTimeInterval(-1)
            await expectPermissionDenied {
                try await acknowledged { try store.createEvent(reversed, uid: uid, serverAcknowledged: $0) }
            }

            var untitled = makeEvent(tripID: trip.id)
            untitled.title = ""
            await expectPermissionDenied {
                try await acknowledged { try store.createEvent(untitled, uid: uid, serverAcknowledged: $0) }
            }

            // Raw writes that the app model cannot produce.
            let base = makeEvent(tripID: trip.id)
            let path = TripPath.event(uid: uid, tripID: trip.id, eventID: base.id)

            var unknownType = try rawEventFields(base)
            unknownType["type"] = "teleport"
            await expectPermissionDenied {
                try await acknowledged { done in self.db.document(path).setData(unknownType, completion: done) }
            }

            var extraField = try rawEventFields(base)
            extraField["latitude"] = 34.69
            await expectPermissionDenied {
                try await acknowledged { done in self.db.document(path).setData(extraField, completion: done) }
            }

            var wrongParent = try rawEventFields(base)
            wrongParent["tripId"] = "some-other-trip"
            await expectPermissionDenied {
                try await acknowledged { done in self.db.document(path).setData(wrongParent, completion: done) }
            }

            // Orphan: parent Trip does not exist.
            let orphan = makeEvent(tripID: "g2-missing-\(UUID().uuidString)")
            await expectPermissionDenied {
                try await acknowledged { try store.createEvent(orphan, uid: uid, serverAcknowledged: $0) }
            }

            print("G2-EVIDENCE denied: reversed dates, empty title, unknown type, extra field, tripId mismatch, orphan")
        }
    }

    @Test func otherUserAndUnauthenticatedAreDenied() async throws {
        let uid = try await signedInUID()
        let otherUID = "g2-other-\(UUID().uuidString)"
        let otherEvent = makeEvent(tripID: "g2-other-trip")

        await expectPermissionDenied {
            _ = try await store.fetchEvents(uid: otherUID, tripID: otherEvent.tripId, source: .server)
        }
        await expectPermissionDenied {
            try await acknowledged { try store.createEvent(otherEvent, uid: otherUID, serverAcknowledged: $0) }
        }

        let probeName = "unauthenticatedEventProbe"
        if FirebaseApp.app(name: probeName) == nil {
            FirebaseApp.configure(name: probeName, options: try #require(FirebaseApp.app()).options)
        }
        let probe = try #require(FirebaseApp.app(name: probeName))
        #expect(Auth.auth(app: probe).currentUser == nil)
        let probeDB = Firestore.firestore(app: probe)
        let settings = probeDB.settings
        settings.cacheSettings = MemoryCacheSettings()
        probeDB.settings = settings
        await expectPermissionDenied {
            _ = try await TripStore(db: probeDB).fetchEvents(uid: uid, tripID: "any-trip", source: .server)
        }
        print("G2-EVIDENCE denied: other-user event read/write, unauthenticated event read")
    }
}
