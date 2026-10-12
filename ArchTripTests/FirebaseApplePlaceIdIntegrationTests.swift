import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import Testing
@testable import ArchTrip

/// Live checks of the v0.2 `applePlaceId` Building rules, on disposable test users only.
/// Firestore only: the fixture ID is a fixed string that is never looked up in MapKit.
///
/// They need the candidate `firebase/firestore.rules` from this branch to be PUBLISHED,
/// which is a separate Human Gate, so they are gated twice: `ARCHTRIP_FIREBASE_INTEGRATION=1`
/// like every live suite, plus `ARCHTRIP_PLACEID_RULES_PUBLISHED=1` once the rules are live.
/// Until then every write carrying the field is denied (see `FirebaseApplePlaceIdBaselineTests`).
/// Opt-in: `TEST_RUNNER_ARCHTRIP_FIREBASE_INTEGRATION=1 TEST_RUNNER_ARCHTRIP_PLACEID_RULES_PUBLISHED=1 xcodebuild test ...`
@MainActor
@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["ARCHTRIP_FIREBASE_INTEGRATION"] == "1"
            && ProcessInfo.processInfo.environment["ARCHTRIP_PLACEID_RULES_PUBLISHED"] == "1"
    ),
    .timeLimit(.minutes(1))
)
struct FirebaseApplePlaceIdIntegrationTests {
    private let store = TripStore()
    private var db: Firestore { Firestore.firestore() }

    private func now() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    private func makeBuilding(applePlaceId: String? = ApplePlaceIdFixtures.identifier) -> Building {
        Building(name: "v0.2 live building", architect: "Test Architect", visitMinutes: 45, note: "live test", createdAt: now(), applePlaceId: applePlaceId)
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

    private func rawWrite(_ fields: [String: Any], uid: String, buildingID: String) async throws {
        try await acknowledged { done in
            self.db.document(BuildingPath.document(uid: uid, buildingID: buildingID)).setData(fields, completion: done)
        }
    }

    private func rawBuilding(uid: String, buildingID: String) async throws -> [String: Any] {
        try #require(try await db.document(BuildingPath.document(uid: uid, buildingID: buildingID)).getDocument(source: .server).data())
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

    @Test func linkedBuildingRoundTripsUnlinksAndRelinksVerbatim() async throws {
        let uid = try await LiveTestAuth.defaultUID()
        let linked = makeBuilding()
        try await cleaningUp(uid: uid, buildingIDs: [linked.id]) {
            try await acknowledged { try store.createBuilding(linked, uid: uid, serverAcknowledged: $0) }
            let read = try await store.fetchBuildings(uid: uid, source: .server)
            #expect(read.failures.isEmpty)
            #expect(read.items.first { $0.id == linked.id } == linked)
            var raw = try await rawBuilding(uid: uid, buildingID: linked.id)
            #expect(raw["applePlaceId"] as? String == ApplePlaceIdFixtures.identifier)
            #expect(raw["latitude"] == nil && raw["longitude"] == nil, "a linked Building stores no coordinates")

            // Unlink: only the ID is deleted; createdAt is not resent (RF-01 path).
            var unlinked = try #require(read.items.first { $0.id == linked.id })
            unlinked.applePlaceId = nil
            unlinked.updatedAt = unlinked.updatedAt.addingTimeInterval(60)
            try await acknowledged { try store.updateBuilding(unlinked, replacing: linked, uid: uid, serverAcknowledged: $0) }
            raw = try await rawBuilding(uid: uid, buildingID: linked.id)
            #expect(raw["applePlaceId"] == nil)
            #expect(raw["createdAt"] is Timestamp && raw["name"] as? String == linked.name)

            // Relink with an unusual ID: stored exactly as given, beside legacy coordinates.
            var relinked = unlinked
            relinked.applePlaceId = ApplePlaceIdFixtures.unusualIdentifier
            relinked.latitude = 43.0479
            relinked.longitude = 141.3556
            relinked.updatedAt = relinked.updatedAt.addingTimeInterval(60)
            try await acknowledged { try store.updateBuilding(relinked, replacing: unlinked, uid: uid, serverAcknowledged: $0) }
            raw = try await rawBuilding(uid: uid, buildingID: linked.id)
            #expect(raw["applePlaceId"] as? String == ApplePlaceIdFixtures.unusualIdentifier)
            #expect(raw["latitude"] as? Double == 43.0479 && raw["longitude"] as? Double == 141.3556)
            let reread = try await store.fetchBuildings(uid: uid, source: .server)
            #expect(reread.items.first { $0.id == linked.id } == relinked)
            print("PLACEID-EVIDENCE create with applePlaceId ok, unlink deleted only the key, relink stored verbatim beside legacy coordinates")
        }
    }

    @Test func rulesValidateTheApplePlaceId() async throws {
        let uid = try await LiveTestAuth.defaultUID()
        let base = makeBuilding(applePlaceId: nil)
        try await cleaningUp(uid: uid, buildingIDs: [base.id]) {
            var fields = try Firestore.Encoder().encode(base)
            try await rawWrite(fields, uid: uid, buildingID: base.id) // absent: the G3 shape
            fields["applePlaceId"] = "A"
            try await rawWrite(fields, uid: uid, buildingID: base.id)
            fields["applePlaceId"] = String(repeating: "A", count: Building.applePlaceIdMaxLength)
            try await rawWrite(fields, uid: uid, buildingID: base.id)
            fields["applePlaceId"] = ApplePlaceIdFixtures.unusualIdentifier
            try await rawWrite(fields, uid: uid, buildingID: base.id)

            fields["applePlaceId"] = String(repeating: "A", count: Building.applePlaceIdMaxLength + 1)
            await expectPermissionDenied("\(Building.applePlaceIdMaxLength + 1) characters") { try await rawWrite(fields, uid: uid, buildingID: base.id) }
            fields["applePlaceId"] = ""
            await expectPermissionDenied("empty") { try await rawWrite(fields, uid: uid, buildingID: base.id) }
            fields["applePlaceId"] = 12_345
            await expectPermissionDenied("number") { try await rawWrite(fields, uid: uid, buildingID: base.id) }
            fields["applePlaceId"] = NSNull()
            await expectPermissionDenied("explicit null") { try await rawWrite(fields, uid: uid, buildingID: base.id) }
            fields["applePlaceId"] = ["I", "D"]
            await expectPermissionDenied("array") { try await rawWrite(fields, uid: uid, buildingID: base.id) }
            print("PLACEID-EVIDENCE rules: absent, 1, \(Building.applePlaceIdMaxLength) and unusual strings accepted; \(Building.applePlaceIdMaxLength + 1), empty, number, null, array denied")
        }
    }

    @Test func otherUserCannotWriteAPlaceId() async throws {
        _ = try await LiveTestAuth.defaultUID()
        let otherUID = "placeid-other-\(UUID().uuidString)"
        await expectPermissionDenied("other user") {
            try await acknowledged { try store.createBuilding(makeBuilding(), uid: otherUID, serverAcknowledged: $0) }
        }
        print("PLACEID-EVIDENCE denied: other-user write with applePlaceId")
    }
}

/// Runs under the CURRENTLY published rules (every live run until the v0.2 rules go live):
/// a Building carrying `applePlaceId` must be denied, so the existing app and data are
/// untouched by this branch until the Rules Gate. Disabled once
/// `ARCHTRIP_PLACEID_RULES_PUBLISHED=1` says the candidate is live.
@MainActor
@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["ARCHTRIP_FIREBASE_INTEGRATION"] == "1"
            && ProcessInfo.processInfo.environment["ARCHTRIP_PLACEID_RULES_PUBLISHED"] != "1"
    ),
    .timeLimit(.minutes(1))
)
struct FirebaseApplePlaceIdBaselineTests {
    private let store = TripStore()
    private var db: Firestore { Firestore.firestore() }

    @Test func currentRulesDenyApplePlaceIdUntilPublished() async throws {
        let uid = try await LiveTestAuth.defaultUID()
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let linked = Building(name: "v0.2 baseline building", createdAt: now, applePlaceId: ApplePlaceIdFixtures.identifier)
        await expectPermissionDenied("applePlaceId under the published rules") {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                do {
                    try store.createBuilding(linked, uid: uid) { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        // The same Building without the field is the accepted G3 shape.
        var plain = linked
        plain.applePlaceId = nil
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try store.createBuilding(plain, uid: uid) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        print("PLACEID-EVIDENCE baseline: published rules deny applePlaceId and accept the G3 Building")
        try? await db.document(BuildingPath.document(uid: uid, buildingID: plain.id)).delete()
    }
}

/// Fixed strings for the Firestore suites. Never looked up: the rules only see a string.
enum ApplePlaceIdFixtures {
    static let identifier = "FIXTUREPLACEID0001"
    /// Unusual but legal: whitespace, lower case and symbols must survive verbatim.
    static let unusualIdentifier = " fixture/Place-ID 0002 "
}

/// Asserts a Firestore permission denial, shared by the v0.2 suites.
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
