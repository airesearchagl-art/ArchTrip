import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import Testing
@testable import ArchTrip

/// Live checks against the configured Firebase project (G1 acceptance B–F).
/// Opt-in: `TEST_RUNNER_ARCHTRIP_FIREBASE_INTEGRATION=1 xcodebuild test ...`
@MainActor
@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["ARCHTRIP_FIREBASE_INTEGRATION"] == "1"),
    .timeLimit(.minutes(1))
)
struct FirebaseIntegrationTests {
    private func signedInUID() async throws -> String {
        if let user = Auth.auth().currentUser { return user.uid }
        return try await Auth.auth().signInAnonymously().user.uid
    }

    /// Whole seconds, so values survive Firestore's microsecond timestamps unchanged.
    private func makeTrip() -> Trip {
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        return Trip(
            title: "G1 integration \(Int(now.timeIntervalSince1970))",
            destination: "Osaka",
            startDate: now,
            endDate: now.addingTimeInterval(86_400),
            createdAt: now
        )
    }

    private func save(_ trip: Trip, uid: String, store: TripStore) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try store.save(trip, uid: uid) { error in
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

    private func isPermissionDenied(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == FirestoreErrorDomain
            && error.code == FirestoreErrorCode.permissionDenied.rawValue
    }

    @Test func b_firebaseInitialized() throws {
        let app = try #require(FirebaseApp.app())
        #expect(app.options.projectID == "archtrip-dev")
        #expect(app.options.bundleID == "art.airesearchagl.ArchTrip")
    }

    @Test func c_anonymousSignIn() async throws {
        let uid = try await signedInUID()
        let user = try #require(Auth.auth().currentUser)
        #expect(!uid.isEmpty)
        #expect(user.uid == uid)
        #expect(user.isAnonymous)
        print("G1-EVIDENCE auth uid=\(uid.prefix(6))… anonymous=\(user.isAnonymous)")
    }

    @Test func e_f_writeAndReadBackFromServer() async throws {
        let uid = try await signedInUID()
        let store = TripStore()
        let trip = makeTrip()

        try await save(trip, uid: uid, store: store)
        print("G1-EVIDENCE write acknowledged path=users/\(uid.prefix(6))…/trips/\(trip.id)")

        let snapshot = try await store.fetch(uid: uid, source: .server)
        #expect(!snapshot.isFromCache)
        let read = try #require(snapshot.trips.first { $0.id == trip.id })
        #expect(read == trip)
        print("G1-EVIDENCE read fromCache=\(snapshot.isFromCache) match=\(read == trip) count=\(snapshot.trips.count)")

        // Leave no integration data behind.
        try await Firestore.firestore().document(TripPath.document(uid: uid, tripID: trip.id)).delete()
        let afterDelete = try await store.fetch(uid: uid, source: .server)
        #expect(!afterDelete.trips.contains { $0.id == trip.id })
    }

    @Test func d_accessIsScopedToOwner() async throws {
        let uid = try await signedInUID()
        let store = TripStore()
        let otherUID = "g1-other-\(UUID().uuidString)"

        // Other user's path: read and write denied.
        await #expect(throws: (any Error).self) {
            do {
                _ = try await store.fetch(uid: otherUID, source: .server)
            } catch {
                #expect(isPermissionDenied(error), "\(error)")
                throw error
            }
        }
        await #expect(throws: (any Error).self) {
            do {
                try await save(makeTrip(), uid: otherUID, store: store)
            } catch {
                #expect(isPermissionDenied(error), "\(error)")
                throw error
            }
        }

        // Own path, but invalid Trip (endDate < startDate): denied by rules validation.
        var invalid = makeTrip()
        invalid.endDate = invalid.startDate.addingTimeInterval(-1)
        await #expect(throws: (any Error).self) {
            do {
                try await save(invalid, uid: uid, store: store)
            } catch {
                #expect(isPermissionDenied(error), "\(error)")
                throw error
            }
        }

        // Unauthenticated client (separate app instance, never signed in): read denied.
        let probeName = "unauthenticatedProbe"
        if FirebaseApp.app(name: probeName) == nil {
            FirebaseApp.configure(name: probeName, options: try #require(FirebaseApp.app()).options)
        }
        let probe = try #require(FirebaseApp.app(name: probeName))
        #expect(Auth.auth(app: probe).currentUser == nil)
        let probeDB = Firestore.firestore(app: probe)
        let settings = probeDB.settings
        settings.cacheSettings = MemoryCacheSettings()
        probeDB.settings = settings
        await #expect(throws: (any Error).self) {
            do {
                _ = try await TripStore(db: probeDB).fetch(uid: uid, source: .server)
            } catch {
                #expect(isPermissionDenied(error), "\(error)")
                throw error
            }
        }
        print("G1-EVIDENCE denied: other-user read, other-user write, invalid trip, unauthenticated read")
    }
}
