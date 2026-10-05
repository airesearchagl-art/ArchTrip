import FirebaseAuth
import FirebaseFirestore
import Foundation
import Observation

/// App-wide Firebase state: the signed-in user, their Trips and Buildings (one
/// listener each), and write results.
///
/// G4: the app never creates an anonymous user. An existing (persisted) user is used
/// as is; with no user the app shows Email/Password sign-in.
@Observable
final class AppSession {
    enum State: Equatable {
        case notConfigured
        case connecting
        case signedOut
        case ready(uid: String)
    }

    struct SaveFailure: Identifiable {
        let id = UUID()
        let detail: String
    }

    private(set) var state: State = .notConfigured
    private(set) var accountKind: AccountKind?
    private(set) var maskedEmail: String?
    private(set) var trips: [Trip] = []
    private(set) var tripFailures: [DecodeFailure] = []
    private(set) var hasLoadedTrips = false
    private(set) var tripsLoadFailed = false
    private(set) var tripsFromCache = false
    private(set) var tripsHavePendingWrites = false
    private(set) var buildings: [Building] = []
    private(set) var buildingFailures: [DecodeFailure] = []
    private(set) var hasLoadedBuildings = false
    private(set) var buildingsLoadFailed = false
    private(set) var isNetworkEnabled = true
    private(set) var saveFailure: SaveFailure?
    /// Developer diagnostics log (English, not user-facing).
    private(set) var log: [String] = []

    @ObservationIgnored private(set) var store: TripStore?
    @ObservationIgnored private var authHandle: AuthStateDidChangeListenerHandle?
    @ObservationIgnored private var tripsListener: ListenerRegistration?
    @ObservationIgnored private var buildingsListener: ListenerRegistration?

    var uid: String? {
        if case .ready(let uid) = state { return uid }
        return nil
    }

    func start(firebaseConfigured: Bool) {
        guard firebaseConfigured else {
            state = .notConfigured
            append("GoogleService-Info.plist not bundled; Firebase disabled")
            return
        }
        guard authHandle == nil else { return }
        store = TripStore()
        state = .connecting
        append("Firebase configured")
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            self?.handleAuthChange(user)
        }
    }

    // MARK: Account

    /// Email/Password sign-in for an install without a user (e.g. a second device).
    /// Returns nil on success. The credential is not stored anywhere.
    func signIn(_ input: EmailPasswordInput) async -> SignInFailure? {
        guard store != nil else { return .other(code: 0) }
        do {
            _ = try await Auth.auth().signIn(withEmail: input.email, password: input.password)
            append("Signed in with Email/Password")
            return nil
        } catch {
            let failure = SignInFailure(error: error)
            append("Email/Password sign-in failed: \(failure)")
            return failure
        }
    }

    /// Migration operations bound to the current default user, or nil when not signed in.
    func migrationSteps() -> MigrationSteps? {
        guard let uid, let store else { return nil }
        return .firebase(auth: Auth.auth(), store: store, uid: uid)
    }

    /// Re-reads the current Auth user, e.g. after linking a credential (same UID).
    func refreshAccount() {
        guard store != nil else { return }
        apply(authUser: Auth.auth().currentUser.map(AuthUserSnapshot.init))
    }

    /// Developer log entry with booleans only (no UID, email or document IDs).
    func logMigrationEvidence(_ line: String) {
        append("Migration \(line)")
    }

    func trip(id: String) -> Trip? {
        trips.first { $0.id == id }
    }

    func building(id: String) -> Building? {
        buildings.first { $0.id == id }
    }

    // MARK: Writes

    func saveTrip(_ trip: Trip) {
        guard let uid, let store else { return }
        do {
            try store.saveTrip(trip, uid: uid) { [weak self] error in
                self?.handleServerResult(error, action: "save trip \(trip.id.prefix(8))")
            }
            append("Wrote trip \(trip.id.prefix(8)) to local cache")
        } catch {
            reportSaveFailure("Encode trip failed: \(error.localizedDescription)")
        }
    }

    func saveEvent(_ event: Event) {
        guard let uid, let store else { return }
        do {
            try store.saveEvent(event, uid: uid) { [weak self] error in
                self?.handleServerResult(error, action: "save event \(event.id.prefix(8))")
            }
            append("Wrote event \(event.id.prefix(8)) to local cache")
        } catch {
            reportSaveFailure("Encode event failed: \(error.localizedDescription)")
        }
    }

    func deleteEvent(_ event: Event) {
        guard let uid, let store else { return }
        store.deleteEvent(event, uid: uid) { [weak self] error in
            self?.handleServerResult(error, action: "delete event \(event.id.prefix(8))")
        }
        append("Deleted event \(event.id.prefix(8)) in local cache")
    }

    func saveBuilding(_ building: Building) {
        guard let uid, let store else { return }
        do {
            try store.saveBuilding(building, uid: uid) { [weak self] error in
                self?.handleServerResult(error, action: "save building \(building.id.prefix(8))")
            }
            append("Wrote building \(building.id.prefix(8)) to local cache")
        } catch {
            reportSaveFailure("Encode building failed: \(error.localizedDescription)")
        }
    }

    /// Deletes only the Building; Events that link to it are left untouched.
    func deleteBuilding(_ building: Building) {
        guard let uid, let store else { return }
        store.deleteBuilding(building, uid: uid) { [weak self] error in
            self?.handleServerResult(error, action: "delete building \(building.id.prefix(8))")
        }
        append("Deleted building \(building.id.prefix(8)) in local cache")
    }

    func dismissSaveFailure() {
        saveFailure = nil
    }

    // MARK: Diagnostics

    func readTripsForDiagnostics() async {
        guard let uid, let store else { return }
        do {
            let result = try await store.fetchTrips(uid: uid)
            append("Read \(result.items.count) trips, \(result.failures.count) failures (fromCache=\(result.isFromCache))")
        } catch {
            append("Read failed: \(error.localizedDescription)")
        }
    }

    func setNetworkEnabled(_ enabled: Bool) async {
        guard let store else { return }
        do {
            try await store.setNetworkEnabled(enabled)
            isNetworkEnabled = enabled
            append("Firestore network \(enabled ? "enabled" : "disabled")")
        } catch {
            append("Network toggle failed: \(error.localizedDescription)")
        }
    }

    // MARK: Private

    private func handleAuthChange(_ user: User?) {
        apply(authUser: user.map(AuthUserSnapshot.init))
    }

    /// Applies an Auth state. No user means signed out: there is deliberately no
    /// automatic anonymous sign-in. The same UID (e.g. after linking) keeps listeners.
    func apply(authUser: AuthUserSnapshot?) {
        guard let authUser else {
            detachUserData()
            accountKind = nil
            maskedEmail = nil
            state = .signedOut
            return
        }
        if case .app(let kind) = AuthRoute.route(for: authUser) {
            accountKind = kind
        }
        maskedEmail = authUser.email.map(AccountDisplay.maskedEmail)
        if case .ready(let uid) = state, uid == authUser.uid { return }

        detachUserData()
        state = .ready(uid: authUser.uid)
        append("Signed in (\(accountKind == .anonymous ? "anonymous" : "email/password"))")
        tripsListener = store?.listenTrips(uid: authUser.uid) { [weak self] result in
            self?.applyTrips(result)
        }
        buildingsListener = store?.listenBuildings(uid: authUser.uid) { [weak self] result in
            self?.applyBuildings(result)
        }
    }

    private func detachUserData() {
        tripsListener?.remove()
        tripsListener = nil
        buildingsListener?.remove()
        buildingsListener = nil
        trips = []
        tripFailures = []
        hasLoadedTrips = false
        buildings = []
        buildingFailures = []
        hasLoadedBuildings = false
    }

    private func applyBuildings(_ result: Result<QueryResult<Building>, Error>) {
        switch result {
        case .success(let snapshot):
            buildings = snapshot.items
            buildingFailures = snapshot.failures
            buildingsLoadFailed = false
            hasLoadedBuildings = true
            for failure in snapshot.failures {
                append("Building \(failure.documentID) failed to decode: \(failure.reason)")
            }
        case .failure(let error):
            buildingsLoadFailed = true
            hasLoadedBuildings = true
            append("Buildings listener error: \(error.localizedDescription)")
        }
    }

    private func applyTrips(_ result: Result<QueryResult<Trip>, Error>) {
        switch result {
        case .success(let snapshot):
            trips = snapshot.items
            tripFailures = snapshot.failures
            tripsFromCache = snapshot.isFromCache
            tripsHavePendingWrites = snapshot.hasPendingWrites
            tripsLoadFailed = false
            hasLoadedTrips = true
            for failure in snapshot.failures {
                append("Trip \(failure.documentID) failed to decode: \(failure.reason)")
            }
        case .failure(let error):
            tripsLoadFailed = true
            hasLoadedTrips = true
            append("Trips listener error: \(error.localizedDescription)")
        }
    }

    private func handleServerResult(_ error: Error?, action: String) {
        if let error {
            reportSaveFailure("Server rejected \(action): \(error.localizedDescription)")
        } else {
            append("Server acknowledged \(action)")
        }
    }

    private func reportSaveFailure(_ detail: String) {
        append(detail)
        saveFailure = SaveFailure(detail: detail)
    }

    private func append(_ message: String) {
        let time = Date().formatted(.dateTime.hour().minute().second().locale(Locale(identifier: "en_US_POSIX")))
        log.insert("\(time) \(message)", at: 0)
        if log.count > 100 { log.removeLast() }
    }
}
