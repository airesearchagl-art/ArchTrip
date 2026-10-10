import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import Testing
@testable import ArchTrip

/// G4-B1: runs the production migration code path (`AccountMigrator` with
/// `MigrationSteps.firebase`) end to end against a disposable anonymous user that
/// owns a Trip, an Event and a Building, on a uniquely named secondary FirebaseApp.
/// The default app's user is never used and is asserted unchanged.
///
/// Opt-in: `TEST_RUNNER_ARCHTRIP_FIREBASE_INTEGRATION=1 xcodebuild test ...`
@MainActor
@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["ARCHTRIP_FIREBASE_INTEGRATION"] == "1"),
    .timeLimit(.minutes(2))
)
struct FirebaseAccountMigrationIntegrationTests {
    private func evidence(_ line: String) {
        AuthSpikeDiagnostics.evidence(line, tag: "G4B-EVIDENCE")
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

    @Test func productionMigrationPathOnDisposableUser() async throws {
        let defaultUIDBefore = try await LiveTestAuth.defaultUID()

        let name = "g4bMigration\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        FirebaseApp.configure(name: name, options: try #require(FirebaseApp.app()).options)
        let app = try #require(FirebaseApp.app(name: name))
        let auth = Auth.auth(app: app)
        let isolated = auth !== Auth.auth()
        #expect(isolated)
        let db = Firestore.firestore(app: app)
        let settings = db.settings
        settings.cacheSettings = MemoryCacheSettings()
        db.settings = settings
        let store = TripStore(db: db)
        try? auth.signOut()

        let credential = DisposableCredential.make()
        var uid: String?
        var trip: Trip?
        var event: Event?
        var building: Building?
        var stepError: Error?

        do {
            let anonymousUID = try await auth.signInAnonymously().user.uid
            uid = anonymousUID
            evidence("secondary app isolated=\(isolated) anonymous created")

            // Seed data owned by the disposable user.
            let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            let seededTrip = Trip(title: "G4B migration", destination: "Sapporo", startDate: now, endDate: now, createdAt: now)
            trip = seededTrip
            try await acknowledged { try store.createTrip(seededTrip, uid: anonymousUID, serverAcknowledged: $0) }
            let seededBuilding = Building(name: "G4B building", latitude: 43.06, longitude: 141.35, createdAt: now)
            building = seededBuilding
            try await acknowledged { try store.createBuilding(seededBuilding, uid: anonymousUID, serverAcknowledged: $0) }
            let seededEvent = BuildingScheduling.makeEvent(visiting: seededBuilding, tripID: seededTrip.id, start: now, durationMinutes: 60, now: now)
            event = seededEvent
            try await acknowledged { try store.createEvent(seededEvent, uid: anonymousUID, serverAcknowledged: $0) }

            let steps = MigrationSteps.firebase(auth: auth, store: store, uid: anonymousUID)

            // Preflight: server-backed counts, nothing changed.
            let preflight = await AccountMigrator.preflight(expectedUID: anonymousUID, steps: steps)
            guard case .ready(let snapshot) = preflight else {
                Issue.record("preflight failed: \(preflight)")
                throw AccountError.noCurrentUser
            }
            let countsOK = snapshot.tripCount == 1 && snapshot.eventCount == 1 && snapshot.buildingCount == 1
            evidence("preflight ready counts-match=\(countsOK)")
            #expect(countsOK)

            // Production link + post-link verification.
            let input = EmailPasswordInput(email: credential.email, password: credential.password)
            let result = await AccountMigrator.run(input: input, expectedUID: anonymousUID, steps: steps)
            guard case .completed(let report) = result else {
                Issue.record("migration did not complete: \(result)")
                throw AccountError.noCurrentUser
            }
            evidence("migration completed \(report.evidence)")
            #expect(report.allPassed)

            // A second attempt is refused: the account is no longer anonymous.
            let again = await AccountMigrator.run(input: input, expectedUID: anonymousUID, steps: steps)
            evidence("second attempt refused-not-anonymous=\(again == .refused(.notAnonymous))")
            #expect(again == .refused(.notAnonymous))

            // Sign out and back in with the new credential: same UID, data readable.
            try auth.signOut()
            let signedIn = try await auth.signIn(withEmail: credential.email, password: credential.password)
            let sameUID = signedIn.user.uid == anonymousUID
            let afterSignIn = try await store.serverSnapshot(uid: anonymousUID)
            let dataOK = afterSignIn == snapshot
            evidence("password sign-in uid-preserved=\(sameUID) data-preserved=\(dataOK)")
            #expect(sameUID && dataOK)
        } catch {
            stepError = error
        }

        // Cleanup: documents, then the disposable user, then the secondary app.
        var cleaned = false
        if let uid {
            if auth.currentUser == nil {
                _ = try? await auth.signIn(withEmail: credential.email, password: credential.password)
            }
            if let event { try? await db.document(TripPath.event(uid: uid, tripID: event.tripId, eventID: event.id)).delete() }
            if let trip { try? await db.document(TripPath.document(uid: uid, tripID: trip.id)).delete() }
            if let building { try? await db.document(BuildingPath.document(uid: uid, buildingID: building.id)).delete() }
            if let user = auth.currentUser, user.uid == uid {
                do {
                    try await user.delete()
                    cleaned = true
                } catch {
                    Issue.record("cleanup delete failed: \(AuthSpikeDiagnostics.describe(error, redacting: credential))")
                }
            }
        }
        try? auth.signOut()
        _ = await app.delete()
        evidence("disposable cleanup=\(cleaned)")
        #expect(cleaned)

        let defaultUnchanged = Auth.auth().currentUser?.uid == defaultUIDBefore
        evidence("default user unchanged=\(defaultUnchanged)")
        #expect(defaultUnchanged)

        if let stepError {
            Issue.record("step failed: \(AuthSpikeDiagnostics.describe(stepError, redacting: credential))")
        }
    }
}
