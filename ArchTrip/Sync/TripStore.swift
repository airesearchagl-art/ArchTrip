import FirebaseFirestore
import Foundation

struct TripSnapshot {
    var trips: [Trip]
    var isFromCache: Bool
    var hasPendingWrites: Bool
}

/// Thin Firestore wrapper. Offline behavior comes from the SDK's persistent cache.
final class TripStore {
    private let db: Firestore

    init(db: Firestore = Firestore.firestore()) {
        self.db = db
    }

    private func collection(uid: String) -> CollectionReference {
        db.collection(TripPath.collection(uid: uid))
    }

    /// Writes to the local cache immediately. The completion fires once the
    /// server acknowledges, which can be much later while offline.
    func save(_ trip: Trip, uid: String, serverAcknowledged: @escaping (Error?) -> Void) throws {
        try collection(uid: uid).document(trip.id).setData(from: trip, completion: serverAcknowledged)
    }

    /// One-shot read. `.default` falls back to the cache while offline.
    func fetch(uid: String, source: FirestoreSource = .default) async throws -> TripSnapshot {
        let snapshot = try await collection(uid: uid)
            .order(by: "createdAt", descending: true)
            .getDocuments(source: source)
        return Self.decode(snapshot)
    }

    func listen(uid: String, onChange: @escaping (Result<TripSnapshot, Error>) -> Void) -> ListenerRegistration {
        collection(uid: uid)
            .order(by: "createdAt", descending: true)
            .addSnapshotListener(includeMetadataChanges: true) { snapshot, error in
                if let snapshot {
                    onChange(.success(Self.decode(snapshot)))
                } else if let error {
                    onChange(.failure(error))
                }
            }
    }

    func setNetworkEnabled(_ enabled: Bool) async throws {
        if enabled {
            try await db.enableNetwork()
        } else {
            try await db.disableNetwork()
        }
    }

    private static func decode(_ snapshot: QuerySnapshot) -> TripSnapshot {
        TripSnapshot(
            trips: snapshot.documents.compactMap { try? $0.data(as: Trip.self) },
            isFromCache: snapshot.metadata.isFromCache,
            hasPendingWrites: snapshot.metadata.hasPendingWrites
        )
    }
}
