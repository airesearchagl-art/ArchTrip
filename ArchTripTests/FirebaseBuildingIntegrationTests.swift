import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import Testing
@testable import ArchTrip

/// Live checks of the G3 Building rules and the Event `buildingId` rule. Requires the
/// candidate `firebase/firestore.rules` to be published.
/// Opt-in: `TEST_RUNNER_ARCHTRIP_FIREBASE_INTEGRATION=1 xcodebuild test ...`
@MainActor
@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["ARCHTRIP_FIREBASE_INTEGRATION"] == "1"),
    .timeLimit(.minutes(1))
)
struct FirebaseBuildingIntegrationTests {
    private let store = TripStore()
    private var db: Firestore { Firestore.firestore() }

    private func signedInUID() async throws -> String {
        if let user = Auth.auth().currentUser { return user.uid }
        return try await Auth.auth().signInAnonymously().user.uid
    }

    private func now() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    private func makeBuilding() -> Building {
        Building(
            name: "G3 integration building",
            architect: "Test Architect",
            completedYear: 1997,
            address: "札幌市中央区中島公園1-15",
            latitude: 43.0479,
            longitude: 141.3556,
            visitMinutes: 90,
            priority: 3,
            note: "live test",
            createdAt: now()
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

    private func expectPermissionDenied(_ label: String, _ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("\(label): expected permission denied, but the operation succeeded")
        } catch {
            let error = error as NSError
            #expect(error.domain == FirestoreErrorDomain && error.code == FirestoreErrorCode.permissionDenied.rawValue, "\(label): \(error)")
        }
    }

    private func save(_ building: Building, uid: String) async throws {
        try await acknowledged { try store.saveBuilding(building, uid: uid, serverAcknowledged: $0) }
    }

    private func saveRaw(_ fields: [String: Any], uid: String, buildingID: String) async throws {
        try await acknowledged { done in
            self.db.document(BuildingPath.document(uid: uid, buildingID: buildingID)).setData(fields, completion: done)
        }
    }

    /// Runs `body`, then deletes the listed Buildings even when `body` fails.
    private func cleaningUp(uid: String, buildingIDs: [String], _ body: () async throws -> Void) async throws {
        var bodyError: Error?
        do {
            try await body()
        } catch {
            bodyError = error
        }
        for id in buildingIDs {
            try? await db.document(BuildingPath.document(uid: uid, buildingID: id)).delete()
        }
        if let bodyError { throw bodyError }
    }

    // MARK: Building

    @Test func ownBuildingCreateReadUpdateDelete() async throws {
        let uid = try await signedInUID()
        var building = makeBuilding()
        let minimal = Building(name: "G3 minimal building", createdAt: now())
        try await cleaningUp(uid: uid, buildingIDs: [building.id, minimal.id]) {
            try await save(building, uid: uid)
            var read = try await store.fetchBuildings(uid: uid, source: .server)
            #expect(!read.isFromCache)
            #expect(read.items.first { $0.id == building.id } == building)

            // No optional fields at all (omitted keys) is accepted.
            try await save(minimal, uid: uid)
            read = try await store.fetchBuildings(uid: uid, source: .server)
            #expect(read.items.first { $0.id == minimal.id } == minimal)

            building.visited = true
            building.latitude = nil
            building.longitude = nil
            building.updatedAt = building.updatedAt.addingTimeInterval(60)
            let edited = building
            try await save(edited, uid: uid)
            read = try await store.fetchBuildings(uid: uid, source: .server)
            #expect(read.items.first { $0.id == edited.id } == edited)

            var movedCreatedAt = edited
            movedCreatedAt.createdAt = edited.createdAt.addingTimeInterval(-60)
            await expectPermissionDenied("createdAt mutation") { try await save(movedCreatedAt, uid: uid) }

            try await acknowledged { store.deleteBuilding(edited, uid: uid, serverAcknowledged: $0) }
            read = try await store.fetchBuildings(uid: uid, source: .server)
            #expect(!read.items.contains { $0.id == edited.id })
            #expect(read.failures.isEmpty)
        }
    }

    @Test func invalidBuildingsAreRejected() async throws {
        let uid = try await signedInUID()
        let base = makeBuilding()
        try await cleaningUp(uid: uid, buildingIDs: [base.id]) {
            var emptyName = base; emptyName.name = ""
            await expectPermissionDenied("empty name") { try await save(emptyName, uid: uid) }

            var badPriority = base; badPriority.priority = 4
            await expectPermissionDenied("priority 4") { try await save(badPriority, uid: uid) }

            var badVisit = base; badVisit.visitMinutes = 0
            await expectPermissionDenied("visitMinutes 0") { try await save(badVisit, uid: uid) }

            var badLatitude = base; badLatitude.latitude = 91
            await expectPermissionDenied("latitude 91") { try await save(badLatitude, uid: uid) }

            var halfPair = base; halfPair.longitude = nil
            await expectPermissionDenied("latitude without longitude") { try await save(halfPair, uid: uid) }

            var badYear = base; badYear.completedYear = 3000
            await expectPermissionDenied("completedYear 3000") { try await save(badYear, uid: uid) }

            var extraField = try Firestore.Encoder().encode(base)
            extraField["rating"] = 5
            await expectPermissionDenied("extra field") { try await saveRaw(extraField, uid: uid, buildingID: base.id) }

            var explicitNull = try Firestore.Encoder().encode(base)
            explicitNull["completedYear"] = NSNull()
            await expectPermissionDenied("explicit null") { try await saveRaw(explicitNull, uid: uid, buildingID: base.id) }

            let mismatchedID = try Firestore.Encoder().encode(base)
            await expectPermissionDenied("id mismatch") { try await saveRaw(mismatchedID, uid: uid, buildingID: "other-\(base.id)") }
        }
    }

    @Test func otherUserAndSignedOutAreDenied() async throws {
        let uid = try await signedInUID()
        let otherUID = "g3-other-\(UUID().uuidString)"

        await expectPermissionDenied("other-user read") { _ = try await store.fetchBuildings(uid: otherUID, source: .server) }
        await expectPermissionDenied("other-user write") { try await save(makeBuilding(), uid: otherUID) }

        let probeName = "unauthenticatedBuildingProbe"
        if FirebaseApp.app(name: probeName) == nil {
            FirebaseApp.configure(name: probeName, options: try #require(FirebaseApp.app()).options)
        }
        let probe = try #require(FirebaseApp.app(name: probeName))
        #expect(Auth.auth(app: probe).currentUser == nil)
        let probeDB = Firestore.firestore(app: probe)
        let settings = probeDB.settings
        settings.cacheSettings = MemoryCacheSettings()
        probeDB.settings = settings
        await expectPermissionDenied("signed-out read") { _ = try await TripStore(db: probeDB).fetchBuildings(uid: uid, source: .server) }
    }

    // MARK: Event buildingId

    @Test func eventBuildingLinkRules() async throws {
        let uid = try await signedInUID()
        let trip = Trip(title: "G3 integration", destination: "Sapporo", startDate: now(), endDate: now(), createdAt: now())
        try await acknowledged { try store.saveTrip(trip, uid: uid, serverAcknowledged: $0) }
        var bodyError: Error?
        do {
            // G2-shaped Event without buildingId remains valid.
            let plain = Event(tripId: trip.id, type: .business, title: "G3 plain", startDate: now(), endDate: now(), createdAt: now())
            try await acknowledged { try store.saveEvent(plain, uid: uid, serverAcknowledged: $0) }

            // Architecture Event linking a Building that does not exist: accepted by design.
            let building = Building(id: "g3-missing-\(UUID().uuidString)", name: "Not stored", address: "札幌", createdAt: now())
            let linked = BuildingScheduling.makeEvent(visiting: building, tripID: trip.id, start: now(), durationMinutes: 60, now: now())
            try await acknowledged { try store.saveEvent(linked, uid: uid, serverAcknowledged: $0) }

            let read = try await store.fetchEvents(uid: uid, tripID: trip.id, source: .server)
            #expect(read.failures.isEmpty)
            #expect(Set(read.items) == [plain, linked])
            #expect(read.items.first { $0.id == linked.id }?.buildingId == building.id)

            var wrongType = linked
            wrongType.id = UUID().uuidString
            wrongType.type = .food
            await expectPermissionDenied("buildingId on non-architecture") {
                try await acknowledged { try store.saveEvent(wrongType, uid: uid, serverAcknowledged: $0) }
            }

            var emptyLink = linked
            emptyLink.id = UUID().uuidString
            emptyLink.buildingId = ""
            await expectPermissionDenied("empty buildingId") {
                try await acknowledged { try store.saveEvent(emptyLink, uid: uid, serverAcknowledged: $0) }
            }
        } catch {
            bodyError = error
        }
        if let leftovers = try? await db.collection(TripPath.events(uid: uid, tripID: trip.id)).getDocuments(source: .server) {
            for document in leftovers.documents {
                try? await document.reference.delete()
            }
        }
        try await db.document(TripPath.document(uid: uid, tripID: trip.id)).delete()
        if let bodyError { throw bodyError }
    }
}
