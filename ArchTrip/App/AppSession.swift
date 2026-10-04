import FirebaseAuth
import FirebaseFirestore
import Foundation
import Observation

/// App-wide Firebase state: anonymous sign-in, the signed-in user's Trips and
/// Buildings (one listener each), and write results. Anonymous Auth is development identity only (G1/G2).
@Observable
final class AppSession {
    enum State: Equatable {
        case notConfigured
        case connecting
        case ready(uid: String)
        case failed
    }

    struct SaveFailure: Identifiable {
        let id = UUID()
        let detail: String
    }

    private(set) var state: State = .notConfigured
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
    @ObservationIgnored private var isSigningIn = false

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

    /// Signs in anonymously when there is no persisted user. No login UI.
    func signIn() async {
        guard store != nil, !isSigningIn else { return }
        isSigningIn = true
        state = .connecting
        defer { isSigningIn = false }
        do {
            let result = try await Auth.auth().signInAnonymously()
            append("Signed in anonymously uid=\(result.user.uid)")
        } catch {
            state = .failed
            append("Sign-in failed: \(error.localizedDescription)")
        }
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
        guard let user else {
            Task { await signIn() }
            return
        }
        state = .ready(uid: user.uid)
        tripsListener = store?.listenTrips(uid: user.uid) { [weak self] result in
            self?.applyTrips(result)
        }
        buildingsListener = store?.listenBuildings(uid: user.uid) { [weak self] result in
            self?.applyBuildings(result)
        }
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
