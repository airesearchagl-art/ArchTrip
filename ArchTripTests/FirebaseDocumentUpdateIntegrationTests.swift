import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import Testing
@testable import ArchTrip

/// RF-01: editing documents whose `createdAt` the app wrote with `Date()` precision.
/// Runs against the published rules with disposable test users, never real data.
/// Opt-in: `TEST_RUNNER_ARCHTRIP_FIREBASE_INTEGRATION=1 xcodebuild test ...`
@MainActor
@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["ARCHTRIP_FIREBASE_INTEGRATION"] == "1"),
    .timeLimit(.minutes(1))
)
struct FirebaseDocumentUpdateIntegrationTests {
    private let store = TripStore()
    private var db: Firestore { Firestore.firestore() }

    private func signedInUID() async throws -> String {
        try await LiveTestAuth.defaultUID()
    }

    /// A creation time like the editors' `Date()`, chosen so that the server-stored
    /// (microsecond) value, decoded to a `Date` and re-encoded, lands in the previous
    /// microsecond. The re-encoded value is off by up to ±119 ns and the server keeps
    /// microseconds, so this happens to about half of all values (see
    /// TimestampPrecisionTests); picking one explicitly keeps the tests deterministic.
    private func appLikeCreatedAt() -> Date {
        var date = Date()
        while true {
            let sent = Timestamp(date: date)
            let stored = Timestamp(seconds: sent.seconds, nanoseconds: sent.nanoseconds / 1_000 * 1_000)
            if microseconds(of: Timestamp(date: stored.dateValue())) != microseconds(of: stored) { return date }
            date.addTimeInterval(0.000_001)
        }
    }

    private func microseconds(of timestamp: Timestamp) -> Int64 {
        timestamp.seconds * 1_000_000 + Int64(timestamp.nanoseconds / 1_000)
    }

    private func makeTrip(createdAt: Date) -> Trip {
        let day = Calendar.current.startOfDay(for: createdAt)
        return Trip(title: "RF-01 trip", destination: "Sapporo", startDate: day, endDate: day, createdAt: createdAt)
    }

    private func acknowledged(_ write: (@escaping (Error?) -> Void) throws -> Void) async throws {
        let acknowledgement = Acknowledgement()
        try write(acknowledgement.handler)
        try await acknowledgement.wait()
    }

    @discardableResult
    private func expectPermissionDenied(_ label: String, _ operation: () async throws -> Void) async -> Bool {
        do {
            try await operation()
            Issue.record("\(label): expected permission denied, but the operation succeeded")
            return false
        } catch {
            let error = error as NSError
            let denied = error.domain == FirestoreErrorDomain && error.code == FirestoreErrorCode.permissionDenied.rawValue
            #expect(denied, "\(label): \(error)")
            return denied
        }
    }

    /// Runs `body`, then deletes the Trip and any Events under it even when `body` fails.
    private func cleaningUp(uid: String, tripID: String, db: Firestore? = nil, _ body: () async throws -> Void) async throws {
        let db = db ?? self.db
        var bodyError: Error?
        do {
            try await body()
        } catch {
            bodyError = error
        }
        if let leftovers = try? await db.collection(TripPath.events(uid: uid, tripID: tripID)).getDocuments(source: .server) {
            for document in leftovers.documents {
                try? await document.reference.delete()
            }
        }
        try? await db.document(TripPath.document(uid: uid, tripID: tripID)).delete()
        if let bodyError { throw bodyError }
    }

    private func rawTrip(uid: String, tripID: String) async throws -> [String: Any] {
        let snapshot = try await db.document(TripPath.document(uid: uid, tripID: tripID)).getDocument(source: .server)
        return try #require(snapshot.data())
    }

    private func storedCreatedAt(uid: String, tripID: String) async throws -> Timestamp {
        try #require(try await rawTrip(uid: uid, tripID: tripID)["createdAt"] as? Timestamp)
    }

    private func serverTrip(uid: String, tripID: String, store: TripStore? = nil) async throws -> Trip {
        let store = store ?? self.store
        return try #require(try await store.fetchTrips(uid: uid, source: .server).items.first { $0.id == tripID })
    }

    private func close(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) < 0.001
    }

    // MARK: RF-01 reproduction (the pre-fix editor path)

    @Test func fullRewriteOfDecodedTripIsDenied() async throws {
        let uid = try await signedInUID()
        let trip = makeTrip(createdAt: appLikeCreatedAt())
        try await cleaningUp(uid: uid, tripID: trip.id) {
            try await acknowledged { try store.createTrip(trip, uid: uid, serverAcknowledged: $0) }

            let sent = Timestamp(date: trip.createdAt)
            let stored = try await storedCreatedAt(uid: uid, tripID: trip.id)
            print("RF01-EVIDENCE createdAt sent nanos=\(sent.nanoseconds) stored nanos=\(stored.nanoseconds)")
            #expect(stored.nanoseconds % 1_000 == 0)

            // The decoded model re-encodes createdAt into the previous microsecond...
            let read = try await serverTrip(uid: uid, tripID: trip.id)
            let resent = Timestamp(date: read.createdAt)
            print("RF01-EVIDENCE createdAt read back and re-encoded nanos=\(resent.nanoseconds)")
            #expect(microseconds(of: resent) == microseconds(of: stored) - 1)

            // ...so resending the whole document, as the editors did, is rejected.
            var edited = read
            edited.title = "RF-01 trip (edited)"
            edited.updatedAt = Date()
            let denied = await expectPermissionDenied("full rewrite with decoded createdAt") {
                try await acknowledged { try store.createTrip(edited, uid: uid, serverAcknowledged: $0) }
            }
            print("RF01-EVIDENCE full rewrite after read-back: \(denied ? "permission denied" : "ACCEPTED")")
        }
    }

    // MARK: Fix: updates leave createdAt alone

    @Test func decodedTripCanBeUpdatedRepeatedly() async throws {
        let uid = try await signedInUID()
        let trip = makeTrip(createdAt: appLikeCreatedAt())
        try await cleaningUp(uid: uid, tripID: trip.id) {
            try await acknowledged { try store.createTrip(trip, uid: uid, serverAcknowledged: $0) }
            let stored = try await storedCreatedAt(uid: uid, tripID: trip.id)

            // Edit what the listener handed back, as the Trip editor does.
            var edited = try await serverTrip(uid: uid, tripID: trip.id)
            edited.title = "RF-01 trip (edited)"
            edited.endDate = edited.endDate.addingTimeInterval(2 * 86_400)
            edited.updatedAt = Date()
            try await acknowledged { try store.updateTrip(edited, uid: uid, serverAcknowledged: $0) }

            var read = try await serverTrip(uid: uid, tripID: trip.id)
            #expect(read.title == edited.title)
            #expect(read.endDate == edited.endDate)
            #expect(close(read.updatedAt, edited.updatedAt))
            #expect(close(read.createdAt, trip.createdAt))
            #expect(try await storedCreatedAt(uid: uid, tripID: trip.id) == stored)

            // And again from the fresh read-back.
            read.destination = "Sapporo (edited)"
            read.updatedAt = Date()
            try await acknowledged { try store.updateTrip(read, uid: uid, serverAcknowledged: $0) }
            let again = try await serverTrip(uid: uid, tripID: trip.id)
            #expect(again.destination == "Sapporo (edited)")
            #expect(again.title == edited.title)
            #expect(try await storedCreatedAt(uid: uid, tripID: trip.id) == stored)
            print("RF01-EVIDENCE update after read-back: acknowledged twice, createdAt unchanged on server")
        }
    }

    @Test func updateCannotMoveCreatedAt() async throws {
        let uid = try await signedInUID()
        let trip = makeTrip(createdAt: appLikeCreatedAt())
        try await cleaningUp(uid: uid, tripID: trip.id) {
            try await acknowledged { try store.createTrip(trip, uid: uid, serverAcknowledged: $0) }
            let stored = try await storedCreatedAt(uid: uid, tripID: trip.id)

            var moved = try await serverTrip(uid: uid, tripID: trip.id)
            moved.createdAt = moved.createdAt.addingTimeInterval(-3_600)
            moved.updatedAt = Date()
            // Accepted because the client never sends createdAt; the server keeps its value.
            try await acknowledged { try store.updateTrip(moved, uid: uid, serverAcknowledged: $0) }
            #expect(try await storedCreatedAt(uid: uid, tripID: trip.id) == stored)
        }
    }

    @Test func updateQueuedBehindPendingCreateIsApplied() async throws {
        let uid = try await signedInUID()
        let trip = makeTrip(createdAt: appLikeCreatedAt())
        try await cleaningUp(uid: uid, tripID: trip.id) {
            var edited = trip
            edited.title = "RF-01 trip (edited before ack)"
            edited.updatedAt = Date()

            // Both are queued before the server has seen either, like a quick re-edit.
            let create = Acknowledgement()
            let update = Acknowledgement()
            try store.createTrip(trip, uid: uid, serverAcknowledged: create.handler)
            try store.updateTrip(edited, uid: uid, serverAcknowledged: update.handler)
            try await create.wait()
            try await update.wait()

            let read = try await serverTrip(uid: uid, tripID: trip.id)
            #expect(read.title == edited.title)
            #expect(close(read.createdAt, trip.createdAt))
            print("RF01-EVIDENCE update queued behind pending create: both acknowledged")
        }
    }

    /// Offline edit, then reconnect. Uses an isolated app with its own disposable
    /// anonymous user so the shared Firestore instance stays online for other suites.
    @Test func offlineUpdateIsAppliedAfterReconnect() async throws {
        let name = "rf01Offline\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        FirebaseApp.configure(name: name, options: try #require(FirebaseApp.app()).options)
        let app = try #require(FirebaseApp.app(name: name))
        let user = try await Auth.auth(app: app).signInAnonymously().user
        let uid = user.uid
        let db = Firestore.firestore(app: app)
        let store = TripStore(db: db)
        let trip = makeTrip(createdAt: appLikeCreatedAt())

        try await cleaningUp(uid: uid, tripID: trip.id, db: db) {
            try await acknowledged { try store.createTrip(trip, uid: uid, serverAcknowledged: $0) }

            try await db.disableNetwork()
            var edited = try #require(try await store.fetchTrips(uid: uid, source: .cache).items.first { $0.id == trip.id })
            edited.title = "RF-01 trip (edited offline)"
            edited.updatedAt = Date()
            let update = Acknowledgement()
            try store.updateTrip(edited, uid: uid, serverAcknowledged: update.handler)

            // The cache shows the edit as pending while offline.
            let cached = try await store.fetchTrips(uid: uid, source: .cache)
            #expect(cached.hasPendingWrites)
            #expect(cached.items.first { $0.id == trip.id }?.title == edited.title)

            try await db.enableNetwork()
            try await update.wait()
            let read = try await serverTrip(uid: uid, tripID: trip.id, store: store)
            #expect(read.title == edited.title)
            #expect(close(read.createdAt, trip.createdAt))
            print("RF01-EVIDENCE offline update acknowledged after reconnect")
        }
        try? await db.terminate()
        try? await user.delete()
        _ = await app.delete()
    }

    @Test func updateOfMissingDocumentFailsVisibly() async throws {
        let uid = try await signedInUID()
        let ghost = makeTrip(createdAt: Date())
        do {
            try await acknowledged { try store.updateTrip(ghost, uid: uid, serverAcknowledged: $0) }
            Issue.record("update of a missing Trip succeeded")
        } catch {
            let error = error as NSError
            #expect(error.domain == FirestoreErrorDomain)
            #expect(error.code == FirestoreErrorCode.notFound.rawValue || error.code == FirestoreErrorCode.permissionDenied.rawValue)
            print("RF01-EVIDENCE update of missing document failed with code \(error.code)")
        }
        try? await db.document(TripPath.document(uid: uid, tripID: ghost.id)).delete()
    }

    // MARK: Events and Buildings use the same update path

    @Test func eventUpdateRemovesAndRestoresBuildingLink() async throws {
        let uid = try await signedInUID()
        let trip = makeTrip(createdAt: appLikeCreatedAt())
        try await cleaningUp(uid: uid, tripID: trip.id) {
            try await acknowledged { try store.createTrip(trip, uid: uid, serverAcknowledged: $0) }
            let building = Building(id: "rf01-building-\(UUID().uuidString)", name: "Not stored", createdAt: Date())
            let linked = BuildingScheduling.makeEvent(
                visiting: building, tripID: trip.id, start: trip.startDate, durationMinutes: 60, now: appLikeCreatedAt()
            )
            try await acknowledged { try store.createEvent(linked, uid: uid, serverAcknowledged: $0) }
            let path = TripPath.event(uid: uid, tripID: trip.id, eventID: linked.id)

            // Type change drops the link: the stored field must disappear, not become null.
            var read = try #require(try await store.fetchEvents(uid: uid, tripID: trip.id, source: .server).items.first)
            read.type = .business
            read.buildingId = nil
            read.title = "Meeting instead"
            read.updatedAt = Date()
            try await acknowledged { try store.updateEvent(read, uid: uid, serverAcknowledged: $0) }
            var raw = try #require(try await db.document(path).getDocument(source: .server).data())
            #expect(raw["buildingId"] == nil)
            #expect(raw["type"] as? String == "business")
            #expect(raw["title"] as? String == "Meeting instead")

            // Linking again writes the field back.
            read = try #require(try await store.fetchEvents(uid: uid, tripID: trip.id, source: .server).items.first)
            read.type = .architecture
            read.buildingId = building.id
            read.updatedAt = Date()
            try await acknowledged { try store.updateEvent(read, uid: uid, serverAcknowledged: $0) }
            raw = try #require(try await db.document(path).getDocument(source: .server).data())
            #expect(raw["buildingId"] as? String == building.id)
            print("RF01-EVIDENCE event update: link removed then restored, createdAt untouched")
        }
    }

    @Test func buildingUpdateRemovesAndRestoresOptionalFields() async throws {
        let uid = try await signedInUID()
        let building = Building(
            name: "RF-01 building", architect: "Test Architect", completedYear: 1997, address: "札幌",
            latitude: 43.0479, longitude: 141.3556, createdAt: appLikeCreatedAt()
        )
        let path = BuildingPath.document(uid: uid, buildingID: building.id)
        var bodyError: Error?
        do {
            try await acknowledged { try store.createBuilding(building, uid: uid, serverAcknowledged: $0) }

            var read = try #require(try await store.fetchBuildings(uid: uid, source: .server).items.first { $0.id == building.id })
            read.completedYear = nil
            read.latitude = nil
            read.longitude = nil
            read.visited = true
            read.updatedAt = Date()
            try await acknowledged { try store.updateBuilding(read, uid: uid, serverAcknowledged: $0) }
            var raw = try #require(try await db.document(path).getDocument(source: .server).data())
            for key in Building.optionalFields {
                #expect(raw[key] == nil, "\(key) should be removed")
            }
            #expect(raw["visited"] as? Bool == true)

            read = try #require(try await store.fetchBuildings(uid: uid, source: .server).items.first { $0.id == building.id })
            read.latitude = 43.1
            read.longitude = 141.4
            read.updatedAt = Date()
            try await acknowledged { try store.updateBuilding(read, uid: uid, serverAcknowledged: $0) }
            raw = try #require(try await db.document(path).getDocument(source: .server).data())
            #expect(raw["latitude"] as? Double == 43.1)
            #expect(raw["longitude"] as? Double == 141.4)
            #expect(raw["completedYear"] == nil)
            print("RF01-EVIDENCE building update: optionals removed then restored, createdAt untouched")
        } catch {
            bodyError = error
        }
        try? await db.document(path).delete()
        if let bodyError { throw bodyError }
    }
}

/// Captures one Firestore completion so the write can be queued now and awaited later.
@MainActor
private final class Acknowledgement {
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
