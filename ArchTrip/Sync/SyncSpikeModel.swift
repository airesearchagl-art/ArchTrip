import FirebaseAuth
import FirebaseFirestore
import Foundation
import Observation

/// Developer-only state for the G1 sync spike screen.
@Observable
final class SyncSpikeModel {
    enum AuthState: Equatable {
        case notConfigured
        case signedOut
        case signingIn
        case signedIn(uid: String)
        case failed(String)
    }

    private(set) var authState: AuthState = .notConfigured
    private(set) var trips: [Trip] = []
    private(set) var isFromCache = false
    private(set) var hasPendingWrites = false
    private(set) var isNetworkEnabled = true
    private(set) var log: [String] = []

    @ObservationIgnored private var store: TripStore?
    @ObservationIgnored private var authHandle: AuthStateDidChangeListenerHandle?
    @ObservationIgnored private var listener: ListenerRegistration?

    var uid: String? {
        if case .signedIn(let uid) = authState { return uid }
        return nil
    }

    func start(firebaseConfigured: Bool) {
        guard firebaseConfigured else {
            authState = .notConfigured
            append("GoogleService-Info.plist not bundled; Firebase disabled")
            return
        }
        guard authHandle == nil else { return }
        store = TripStore()
        append("Firebase configured")
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            self?.handleAuthChange(user)
        }
    }

    func signIn() async {
        authState = .signingIn
        do {
            let result = try await Auth.auth().signInAnonymously()
            append("Signed in anonymously uid=\(result.user.uid)")
        } catch {
            authState = .failed(error.localizedDescription)
            append("Sign-in failed: \(error.localizedDescription)")
        }
    }

    func createTestTrip() {
        guard let uid, let store else { return }
        let trip = Trip.makeTest()
        do {
            try store.save(trip, uid: uid) { [weak self] error in
                if let error {
                    self?.append("Server rejected \(trip.id.prefix(8)): \(error.localizedDescription)")
                } else {
                    self?.append("Server acknowledged \(trip.id.prefix(8))")
                }
            }
            append("Wrote \(trip.id.prefix(8)) to local cache")
        } catch {
            append("Encode failed: \(error.localizedDescription)")
        }
    }

    func readTrips() async {
        guard let uid, let store else { return }
        do {
            let snapshot = try await store.fetch(uid: uid)
            append("Read \(snapshot.trips.count) trips (fromCache=\(snapshot.isFromCache))")
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

    private func handleAuthChange(_ user: User?) {
        listener?.remove()
        listener = nil
        trips = []
        guard let user else {
            authState = .signedOut
            return
        }
        authState = .signedIn(uid: user.uid)
        listener = store?.listen(uid: user.uid) { [weak self] result in
            self?.apply(result)
        }
    }

    private func apply(_ result: Result<TripSnapshot, Error>) {
        switch result {
        case .success(let snapshot):
            trips = snapshot.trips
            isFromCache = snapshot.isFromCache
            hasPendingWrites = snapshot.hasPendingWrites
        case .failure(let error):
            append("Listener error: \(error.localizedDescription)")
        }
    }

    private func append(_ message: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        log.insert("\(time) \(message)", at: 0)
        if log.count > 50 { log.removeLast() }
    }
}
