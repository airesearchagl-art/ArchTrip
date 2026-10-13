import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import Testing
@testable import ArchTrip

/// RF-03 against the real Firestore project (published rules unchanged: owners may delete
/// Trips and Events). Disposable fixtures only; everything created here is removed.
/// Opt-in: `TEST_RUNNER_ARCHTRIP_FIREBASE_INTEGRATION=1 xcodebuild test ...`
@MainActor
@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["ARCHTRIP_FIREBASE_INTEGRATION"] == "1"),
    .timeLimit(.minutes(2))
)
struct FirebaseTripDeletionIntegrationTests {
    private let store = TripStore()
    private var db: Firestore { Firestore.firestore() }

    private func now() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    private func makeTrip() -> Trip {
        let now = now()
        return Trip(title: "RF-03 fixture trip", destination: "架空県", startDate: now, endDate: now, createdAt: now)
    }

    private func makeEvent(tripID: String, title: String, buildingId: String? = nil) -> Event {
        let now = now()
        return Event(
            tripId: tripID, type: buildingId == nil ? .business : .architecture, title: title,
            startDate: now, endDate: now.addingTimeInterval(3_600), locationName: "Fixture location", note: "fixture",
            createdAt: now, buildingId: buildingId
        )
    }

    private func acknowledged(_ write: (@escaping (Error?) -> Void) throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try write { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func settle(_ what: Comment, _ condition: @escaping () -> Bool) async {
        for _ in 0..<600 where !condition() {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(condition(), what)
    }

    private func serverTripExists(uid: String, tripID: String) async throws -> Bool {
        try await db.document(TripPath.document(uid: uid, tripID: tripID)).getDocument(source: .server).exists
    }

    private func serverEventCount(uid: String, tripID: String) async throws -> Int {
        try await db.collection(TripPath.events(uid: uid, tripID: tripID)).getDocuments(source: .server).documents.count
    }

    /// Removes whatever a test left behind (a Trip, its Events, a Building), best effort.
    private func cleanUp(uid: String, tripID: String, buildingID: String?) async {
        if let leftovers = try? await db.collection(TripPath.events(uid: uid, tripID: tripID)).getDocuments(source: .server) {
            for document in leftovers.documents { try? await document.reference.delete() }
        }
        try? await db.document(TripPath.document(uid: uid, tripID: tripID)).delete()
        if let buildingID { try? await db.document(BuildingPath.document(uid: uid, buildingID: buildingID)).delete() }
    }

    /// A Trip with Events, one linked to a Building: the deletion removes the Trip and
    /// every Event on the server and leaves the Building; a second run finds nothing.
    @Test func deletesTripAndEventsAndKeepsTheBuilding() async throws {
        let uid = try await LiveTestAuth.defaultUID()
        let trip = makeTrip()
        let building = Building(name: "Fixture building RF-03", address: "架空県架空市", createdAt: now())
        defer { Task { await cleanUp(uid: uid, tripID: trip.id, buildingID: building.id) } }

        try await acknowledged { try store.createBuilding(building, uid: uid, serverAcknowledged: $0) }
        try await acknowledged { try store.createTrip(trip, uid: uid, serverAcknowledged: $0) }
        let events = [
            makeEvent(tripID: trip.id, title: "Fixture event 1"),
            makeEvent(tripID: trip.id, title: "Fixture event 2", buildingId: building.id),
            makeEvent(tripID: trip.id, title: "Fixture event 3"),
        ]
        for event in events {
            try await acknowledged { try store.createEvent(event, uid: uid, serverAcknowledged: $0) }
        }
        #expect(try await serverEventCount(uid: uid, tripID: trip.id) == 3)

        let run = TripDeletionRun(deleter: store, uid: uid, tripID: trip.id)
        run.check()
        await settle("listing from the server") { run.state == .ready(TripDeletion.Summary(tripExists: true, eventCount: 3, unreadableEventCount: 0)) }
        run.delete()
        await settle("acknowledged") { run.state == .done }

        #expect(try await serverTripExists(uid: uid, tripID: trip.id) == false)
        #expect(try await serverEventCount(uid: uid, tripID: trip.id) == 0)
        let buildings = try await store.fetchBuildings(uid: uid, source: .server)
        #expect(buildings.items.contains { $0.id == building.id }, "the Building linked by an Event is kept")
        print("RF03-EVIDENCE trip+3 events deleted on server, building kept=\(buildings.items.contains { $0.id == building.id })")

        // Running again finds nothing: idempotent, nothing sent twice.
        let again = TripDeletionRun(deleter: store, uid: uid, tripID: trip.id)
        again.check()
        await settle("already gone") { again.state == .done }
    }

    @Test func anEmptyTripIsDeleted() async throws {
        let uid = try await LiveTestAuth.defaultUID()
        let trip = makeTrip()
        defer { Task { await cleanUp(uid: uid, tripID: trip.id, buildingID: nil) } }
        try await acknowledged { try store.createTrip(trip, uid: uid, serverAcknowledged: $0) }

        let run = TripDeletionRun(deleter: store, uid: uid, tripID: trip.id)
        run.check()
        await settle("ready") { run.state == .ready(TripDeletion.Summary(tripExists: true, eventCount: 0, unreadableEventCount: 0)) }
        run.delete()
        await settle("done") { run.state == .done }
        #expect(try await serverTripExists(uid: uid, tripID: trip.id) == false)
        print("RF03-EVIDENCE empty trip deleted on server")
    }

    /// Another user's path: the server-side listing is refused, so nothing is sent; a
    /// direct batch for that path is refused as well.
    @Test func anotherUsersTripIsRefused() async throws {
        _ = try await LiveTestAuth.defaultUID()
        let otherUID = "rf03-other-\(UUID().uuidString)"
        let run = TripDeletionRun(deleter: store, uid: otherUID, tripID: "rf03-other-trip")
        run.check()
        await settle("denied") { run.state == .blocked(.denied) }

        do {
            try await store.delete(eventIDs: ["x"], andTrip: true, uid: otherUID, tripID: "rf03-other-trip", timeout: .seconds(20))
            Issue.record("expected permission denied for another user's batch")
        } catch {
            #expect(TripDeletion.problem(for: error) == .denied, "\(error as NSError)")
        }
        print("RF03-EVIDENCE other user's trip: listing denied, batch denied")
    }
}
