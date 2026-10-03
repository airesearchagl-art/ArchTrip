import FirebaseFirestore
import Foundation

/// Thin Firestore wrapper for Trips and their Events.
/// Offline behavior comes from the SDK's persistent cache.
final class TripStore {
    private let db: Firestore

    init(db: Firestore = Firestore.firestore()) {
        self.db = db
    }

    private func trips(uid: String) -> CollectionReference {
        db.collection(TripPath.collection(uid: uid))
    }

    private func events(uid: String, tripID: String) -> CollectionReference {
        db.collection(TripPath.events(uid: uid, tripID: tripID))
    }

    // MARK: Trips

    /// Writes to the local cache immediately. The completion fires once the
    /// server acknowledges, which can be much later while offline.
    func saveTrip(_ trip: Trip, uid: String, serverAcknowledged: @escaping (Error?) -> Void) throws {
        try trips(uid: uid).document(trip.id).setData(from: trip, completion: serverAcknowledged)
    }

    /// One-shot read. `.default` falls back to the cache while offline.
    func fetchTrips(uid: String, source: FirestoreSource = .default) async throws -> QueryResult<Trip> {
        let snapshot = try await trips(uid: uid)
            .order(by: "createdAt", descending: true)
            .getDocuments(source: source)
        return Self.result(snapshot, as: Trip.self)
    }

    func listenTrips(uid: String, onChange: @escaping (Result<QueryResult<Trip>, Error>) -> Void) -> ListenerRegistration {
        Self.listen(trips(uid: uid).order(by: "createdAt", descending: true), as: Trip.self, onChange: onChange)
    }

    // MARK: Events

    func saveEvent(_ event: Event, uid: String, serverAcknowledged: @escaping (Error?) -> Void) throws {
        try events(uid: uid, tripID: event.tripId).document(event.id)
            .setData(from: event, completion: serverAcknowledged)
    }

    func deleteEvent(_ event: Event, uid: String, serverAcknowledged: @escaping (Error?) -> Void) {
        events(uid: uid, tripID: event.tripId).document(event.id).delete(completion: serverAcknowledged)
    }

    func fetchEvents(uid: String, tripID: String, source: FirestoreSource = .default) async throws -> QueryResult<Event> {
        let snapshot = try await events(uid: uid, tripID: tripID)
            .order(by: "startDate")
            .getDocuments(source: source)
        return Self.result(snapshot, as: Event.self, validate: Self.eventValidator(tripID: tripID))
    }

    func eventUpdates(uid: String, tripID: String) -> AsyncStream<Result<QueryResult<Event>, Error>> {
        AsyncStream { continuation in
            let registration = Self.listen(
                events(uid: uid, tripID: tripID).order(by: "startDate"),
                as: Event.self,
                validate: Self.eventValidator(tripID: tripID)
            ) { continuation.yield($0) }
            continuation.onTermination = { _ in registration.remove() }
        }
    }

    // MARK: Network

    func setNetworkEnabled(_ enabled: Bool) async throws {
        if enabled {
            try await db.enableNetwork()
        } else {
            try await db.disableNetwork()
        }
    }

    // MARK: Decoding

    private static func eventValidator(tripID: String) -> (Event) -> String? {
        { $0.tripId == tripID ? nil : "tripId field does not match parent Trip" }
    }

    private static func listen<Item: Decodable & Identifiable & Sendable>(
        _ query: Query,
        as type: Item.Type,
        validate: @escaping (Item) -> String? = { _ in nil },
        onChange: @escaping (Result<QueryResult<Item>, Error>) -> Void
    ) -> ListenerRegistration where Item.ID == String {
        query.addSnapshotListener(includeMetadataChanges: true) { snapshot, error in
            if let snapshot {
                onChange(.success(result(snapshot, as: type, validate: validate)))
            } else if let error {
                onChange(.failure(error))
            }
        }
    }

    private static func result<Item: Decodable & Identifiable & Sendable>(
        _ snapshot: QuerySnapshot,
        as type: Item.Type,
        validate: (Item) -> String? = { _ in nil }
    ) -> QueryResult<Item> where Item.ID == String {
        let decoded = DocumentDecoding.decode(
            snapshot.documents.map { (id: $0.documentID, data: $0.data()) },
            as: type,
            validate: validate
        )
        return QueryResult(
            items: decoded.items,
            failures: decoded.failures,
            isFromCache: snapshot.metadata.isFromCache,
            hasPendingWrites: snapshot.metadata.hasPendingWrites
        )
    }
}
