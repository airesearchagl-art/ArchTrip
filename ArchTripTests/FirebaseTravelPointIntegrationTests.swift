import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import Testing
@testable import ArchTrip

/// Live checks of the travel point rules and the two-field update, on disposable test
/// users only. Firestore only: the Place IDs are fixed strings never looked up in MapKit.
///
/// They need the candidate `firebase/firestore.rules` from this branch to be PUBLISHED,
/// which is a separate Human Gate, so they are gated twice: `ARCHTRIP_FIREBASE_INTEGRATION=1`
/// like every live suite, plus `ARCHTRIP_TRAVELPOINT_RULES_PUBLISHED=1` once the rules are
/// live. Until then every write carrying the field is denied (`FirebaseTravelPointBaselineTests`).
/// Opt-in: `TEST_RUNNER_ARCHTRIP_FIREBASE_INTEGRATION=1 TEST_RUNNER_ARCHTRIP_TRAVELPOINT_RULES_PUBLISHED=1 xcodebuild test ...`
@MainActor
@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["ARCHTRIP_FIREBASE_INTEGRATION"] == "1"
            && ProcessInfo.processInfo.environment["ARCHTRIP_TRAVELPOINT_RULES_PUBLISHED"] == "1"
    ),
    .timeLimit(.minutes(2))
)
struct FirebaseTravelPointIntegrationTests {
    private let store = TripStore()
    private var db: Firestore { Firestore.firestore() }

    @Test func rulesValidateTheTravelPoint() async throws {
        try await TravelPointLive.withTestTrip(store: store) { uid, trip in
            let event = TravelPointLive.makeEvent(tripID: trip.id)
            var fields = try Firestore.Encoder().encode(event)
            func write(_ travelPoint: Any?) async throws {
                var copy = fields
                if let travelPoint { copy["travelPoint"] = travelPoint }
                try await TravelPointLive.rawWrite(copy, uid: uid, tripID: trip.id, eventID: event.id)
            }
            try await write(nil) // the shape every Event had before this field
            try await write(["kind": "place", "placeId": "A"])
            try await write(["kind": "place", "placeId": String(repeating: "A", count: TravelPointSetting.placeIdMaxLength)])
            try await write(["kind": "place", "placeId": TravelPointLive.unusualIdentifier])
            try await write(["kind": "query", "query": "架"])
            try await write(["kind": "query", "query": String(repeating: "Q", count: TravelPointSetting.queryMaxLength)])
            fields["title"] = "Fixture travel point rules"

            let denied: [(String, Any)] = [
                ("\(TravelPointSetting.placeIdMaxLength + 1) character ID", ["kind": "place", "placeId": String(repeating: "A", count: TravelPointSetting.placeIdMaxLength + 1)]),
                ("\(TravelPointSetting.queryMaxLength + 1) character query", ["kind": "query", "query": String(repeating: "Q", count: TravelPointSetting.queryMaxLength + 1)]),
                ("empty ID", ["kind": "place", "placeId": ""]),
                ("empty query", ["kind": "query", "query": ""]),
                ("place with a name", ["kind": "place", "placeId": "A", "name": "Fixture"]),
                ("place with coordinates", ["kind": "place", "placeId": "A", "latitude": 43.0, "longitude": 141.0]),
                ("both values", ["kind": "place", "placeId": "A", "query": "x"]),
                ("unknown kind", ["kind": "coordinate", "latitude": 43.0]),
                ("missing kind", ["placeId": "A"]),
                ("kind as number", ["kind": 1, "placeId": "A"]),
                ("ID as number", ["kind": "place", "placeId": 12_345]),
                ("string value", "A"),
                ("array value", ["kind", "place"]),
                ("explicit null", NSNull()),
            ]
            for (label, value) in denied {
                await TravelPointLive.expectPermissionDenied(label) { try await write(value) }
            }
            print("TRAVELPOINT-EVIDENCE rules: absent, place 1/\(TravelPointSetting.placeIdMaxLength)/unusual, query 1/\(TravelPointSetting.queryMaxLength) accepted; \(denied.count) invalid shapes denied")
        }
    }

    /// The update sends `travelPoint` and `updatedAt` only: every other field keeps its
    /// stored value, `createdAt` included, and clearing removes just the key.
    @Test func theTwoFieldUpdateSetsAndClearsOnlyTheTravelPoint() async throws {
        try await TravelPointLive.withTestTrip(store: store) { uid, trip in
            let event = TravelPointLive.makeEvent(tripID: trip.id)
            try await TravelPointLive.acknowledged { try store.createEvent(event, uid: uid, serverAcknowledged: $0) }
            let before = try await TravelPointLive.rawEvent(uid: uid, tripID: trip.id, eventID: event.id)
            #expect(before["travelPoint"] == nil)

            try await TravelPointLive.acknowledged { try store.setTravelPoint(.place(id: TravelPointLive.identifier), event: event, uid: uid, serverAcknowledged: $0) }
            var raw = try await TravelPointLive.rawEvent(uid: uid, tripID: trip.id, eventID: event.id)
            #expect(raw["travelPoint"] as? [String: String] == ["kind": "place", "placeId": TravelPointLive.identifier])
            for key in ["id", "tripId", "type", "title", "locationName", "note"] {
                #expect(raw[key] as? String == before[key] as? String, "\(key)")
            }
            #expect(raw["createdAt"] as? Timestamp == before["createdAt"] as? Timestamp)
            #expect(raw["startDate"] as? Timestamp == before["startDate"] as? Timestamp)
            let updatedAt = try #require(raw["updatedAt"] as? Timestamp)
            #expect(updatedAt.dateValue() >= (before["updatedAt"] as? Timestamp)!.dateValue())
            var read = try await store.fetchEvents(uid: uid, tripID: trip.id, source: .server)
            #expect(read.failures.isEmpty && read.items.first { $0.id == event.id }?.travelPoint == .place(id: TravelPointLive.identifier))

            let stored = try #require(read.items.first { $0.id == event.id })
            try await TravelPointLive.acknowledged { try store.setTravelPoint(.query("架空駅 北口"), event: stored, uid: uid, serverAcknowledged: $0) }
            raw = try await TravelPointLive.rawEvent(uid: uid, tripID: trip.id, eventID: event.id)
            #expect(raw["travelPoint"] as? [String: String] == ["kind": "query", "query": "架空駅 北口"])

            try await TravelPointLive.acknowledged { try store.setTravelPoint(nil, event: stored, uid: uid, serverAcknowledged: $0) }
            raw = try await TravelPointLive.rawEvent(uid: uid, tripID: trip.id, eventID: event.id)
            #expect(raw["travelPoint"] == nil, "clearing deletes only the key")
            #expect(raw["title"] as? String == event.title && raw["createdAt"] as? Timestamp == before["createdAt"] as? Timestamp)
            read = try await store.fetchEvents(uid: uid, tripID: trip.id, source: .server)
            #expect(read.items.first { $0.id == event.id }?.travelPoint == nil)
            print("TRAVELPOINT-EVIDENCE two-field update: set place, set query, clear; other fields and createdAt unchanged on the server")
        }
    }

    /// The editor's whole-model update (which never carries the field) leaves a stored
    /// travel point in place, and an edit queued before the point, offline, applies with it.
    @Test func theEditorUpdateKeepsTheTravelPoint() async throws {
        try await TravelPointLive.withTestTrip(store: store) { uid, trip in
            let event = TravelPointLive.makeEvent(tripID: trip.id)
            try await TravelPointLive.acknowledged { try store.createEvent(event, uid: uid, serverAcknowledged: $0) }
            try await TravelPointLive.acknowledged { try store.setTravelPoint(.place(id: TravelPointLive.identifier), event: event, uid: uid, serverAcknowledged: $0) }
            let stored = try #require(try await store.fetchEvents(uid: uid, tripID: trip.id, source: .server).items.first { $0.id == event.id })
            #expect(stored.travelPoint == .place(id: TravelPointLive.identifier))

            var edited = stored
            edited.title = "Fixture travel point (edited)"
            edited.note = "Fixture note"
            edited.updatedAt = stored.updatedAt.addingTimeInterval(60)
            edited.travelPoint = nil // the editor's draft is built without it
            try await TravelPointLive.acknowledged { try store.updateEvent(edited, replacing: stored, uid: uid, serverAcknowledged: $0) }
            var raw = try await TravelPointLive.rawEvent(uid: uid, tripID: trip.id, eventID: event.id)
            #expect(raw["title"] as? String == edited.title && raw["note"] as? String == "Fixture note")
            #expect(raw["travelPoint"] as? [String: String] == ["kind": "place", "placeId": TravelPointLive.identifier], "the editor's update keeps the travel point")

            // Offline: an edit and then a point change are queued; both apply after reconnecting.
            let reread = try #require(try await store.fetchEvents(uid: uid, tripID: trip.id, source: .server).items.first { $0.id == event.id })
            try await store.setNetworkEnabled(false)
            var offlineEdit = reread
            offlineEdit.locationName = "Fixture location"
            offlineEdit.updatedAt = reread.updatedAt.addingTimeInterval(60)
            offlineEdit.travelPoint = nil
            let editDone = TravelPointLive.pendingAcknowledgement { try store.updateEvent(offlineEdit, replacing: reread, uid: uid, serverAcknowledged: $0) }
            let pointDone = TravelPointLive.pendingAcknowledgement { try store.setTravelPoint(.query("架空駅"), event: reread, uid: uid, serverAcknowledged: $0) }
            try await store.setNetworkEnabled(true)
            try await editDone.value
            try await pointDone.value
            raw = try await TravelPointLive.rawEvent(uid: uid, tripID: trip.id, eventID: event.id)
            #expect(raw["locationName"] as? String == "Fixture location")
            #expect(raw["travelPoint"] as? [String: String] == ["kind": "query", "query": "架空駅"])
            #expect(raw["title"] as? String == edited.title)
            print("TRAVELPOINT-EVIDENCE editor update kept the travel point; offline edit + point both applied after reconnect")
        }
    }

    /// Writes are independent: the server's rejection of an earlier, invalid write takes
    /// back only that write, and a later valid one stands, on the server and locally.
    @Test func aRejectedEarlierWriteDoesNotUndoALaterOne() async throws {
        try await TravelPointLive.withTestTrip(store: store) { uid, trip in
            let event = TravelPointLive.makeEvent(tripID: trip.id)
            try await TravelPointLive.acknowledged { try store.createEvent(event, uid: uid, serverAcknowledged: $0) }
            try await TravelPointLive.acknowledged { try store.setTravelPoint(.place(id: "FIXTUREPLACEID0FIRST"), event: event, uid: uid, serverAcknowledged: $0) }

            // Sent first, bypassing the client's bound: the rules reject it.
            let invalid: [String: Any] = [
                "travelPoint": ["kind": "place", "placeId": String(repeating: "L", count: TravelPointSetting.placeIdMaxLength + 1)],
                "updatedAt": Timestamp(date: Date()),
            ]
            let path = TripPath.event(uid: uid, tripID: trip.id, eventID: event.id)
            let rejected = TravelPointLive.pendingAcknowledgement { done in self.db.document(path).updateData(invalid, completion: done) }
            // Sent right after, through the app's path: accepted.
            try await TravelPointLive.acknowledged { try store.setTravelPoint(.place(id: TravelPointLive.identifier), event: event, uid: uid, serverAcknowledged: $0) }
            await TravelPointLive.expectPermissionDenied("earlier invalid write") { try await rejected.value }

            let raw = try await TravelPointLive.rawEvent(uid: uid, tripID: trip.id, eventID: event.id)
            #expect(raw["travelPoint"] as? [String: String] == ["kind": "place", "placeId": TravelPointLive.identifier], "the server holds the later, valid write")
            let cached = try await store.fetchEvents(uid: uid, tripID: trip.id, source: .cache)
            #expect(cached.items.first { $0.id == event.id }?.travelPoint == .place(id: TravelPointLive.identifier), "the local view holds it too: only the rejected write was taken back")
            print("TRAVELPOINT-EVIDENCE rejected earlier write did not undo the later one (server and cache)")
        }
    }

    /// The published rules decide this before the server reports the document missing:
    /// `allow update` compares `request.resource.data.createdAt` with `resource.data.createdAt`,
    /// and a deleted document has no `resource`, so the write is denied (permission denied,
    /// code 7), not "not found". Observed on the published rules; the app shows the failure
    /// either way, and `updateData` never recreates the document.
    @Test func settingThePointOfAMissingEventFailsVisibly() async throws {
        try await TravelPointLive.withTestTrip(store: store) { uid, trip in
            let event = TravelPointLive.makeEvent(tripID: trip.id)
            try await TravelPointLive.acknowledged { try store.createEvent(event, uid: uid, serverAcknowledged: $0) }
            try await TravelPointLive.acknowledged { store.deleteEvent(event, uid: uid, serverAcknowledged: $0) }
            await TravelPointLive.expectPermissionDenied("setting the point of a deleted Event") {
                try await TravelPointLive.acknowledged { try store.setTravelPoint(.place(id: TravelPointLive.identifier), event: event, uid: uid, serverAcknowledged: $0) }
            }
            let snapshot = try await db.document(TripPath.event(uid: uid, tripID: trip.id, eventID: event.id)).getDocument(source: .server)
            #expect(!snapshot.exists, "nothing is recreated")
            print("TRAVELPOINT-EVIDENCE setting the point of a deleted Event failed visibly (permission denied by the published rules, not not-found); nothing recreated")
        }
    }
}

/// Runs under the CURRENTLY published rules (every live run until the travel point rules
/// go live): an update carrying `travelPoint` must be denied, so the existing app and
/// data are untouched by this branch until the Rules Gate. Disabled once
/// `ARCHTRIP_TRAVELPOINT_RULES_PUBLISHED=1` says the candidate is live.
@MainActor
@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["ARCHTRIP_FIREBASE_INTEGRATION"] == "1"
            && ProcessInfo.processInfo.environment["ARCHTRIP_TRAVELPOINT_RULES_PUBLISHED"] != "1"
    ),
    .timeLimit(.minutes(1))
)
struct FirebaseTravelPointBaselineTests {
    private let store = TripStore()

    @Test func currentRulesDenyTravelPointUntilPublished() async throws {
        try await TravelPointLive.withTestTrip(store: store) { uid, trip in
            let event = TravelPointLive.makeEvent(tripID: trip.id)
            try await TravelPointLive.acknowledged { try store.createEvent(event, uid: uid, serverAcknowledged: $0) }
            await TravelPointLive.expectPermissionDenied("travelPoint under the published rules") {
                try await TravelPointLive.acknowledged { try store.setTravelPoint(.place(id: TravelPointLive.identifier), event: event, uid: uid, serverAcknowledged: $0) }
            }
            await TravelPointLive.expectPermissionDenied("query under the published rules") {
                try await TravelPointLive.acknowledged { try store.setTravelPoint(.query("架空駅"), event: event, uid: uid, serverAcknowledged: $0) }
            }
            let raw = try await TravelPointLive.rawEvent(uid: uid, tripID: trip.id, eventID: event.id)
            #expect(raw["travelPoint"] == nil && raw["title"] as? String == event.title, "the Event is untouched")
            // The same Event edited without the field is still accepted.
            var edited = event
            edited.title = "Fixture travel point baseline (edited)"
            edited.updatedAt = event.updatedAt.addingTimeInterval(60)
            try await TravelPointLive.acknowledged { try store.updateEvent(edited, replacing: event, uid: uid, serverAcknowledged: $0) }
            print("TRAVELPOINT-EVIDENCE baseline: published rules deny travelPoint (place and query) and accept the Event without it")
        }
    }
}

/// Shared helpers of the two suites. Fixed strings only; never looked up in MapKit.
@MainActor
private enum TravelPointLive {
    static let identifier = "FIXTUREPLACEID0001"
    /// Unusual but legal: whitespace, lower case and symbols must survive verbatim.
    static let unusualIdentifier = " fixture/Place-ID 0002 "

    private static var db: Firestore { Firestore.firestore() }

    static func now() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    static func makeEvent(tripID: String) -> Event {
        let now = now()
        return Event(
            tripId: tripID, type: .business, title: "Fixture travel point", startDate: now,
            endDate: now.addingTimeInterval(3_600), locationName: "Fixture hall", note: "live test", createdAt: now
        )
    }

    static func acknowledged(_ write: (@escaping @Sendable (Error?) -> Void) throws -> Void) async throws {
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

    /// Sends the write now and hands back its acknowledgement to await later.
    static func pendingAcknowledgement(_ write: @escaping (@escaping @Sendable (Error?) -> Void) throws -> Void) -> Task<Void, Error> {
        Task { try await acknowledged(write) }
    }

    static func rawWrite(_ fields: [String: Any], uid: String, tripID: String, eventID: String) async throws {
        try await acknowledged { done in
            db.document(TripPath.event(uid: uid, tripID: tripID, eventID: eventID)).setData(fields, completion: done)
        }
    }

    static func rawEvent(uid: String, tripID: String, eventID: String) async throws -> [String: Any] {
        try #require(try await db.document(TripPath.event(uid: uid, tripID: tripID, eventID: eventID)).getDocument(source: .server).data())
    }

    static func expectPermissionDenied(_ label: String, _ operation: () async throws -> Void) async {
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

    /// Creates a Trip, runs `body`, then removes the Trip and any Events left under it,
    /// even when `body` fails.
    static func withTestTrip(store: TripStore, _ body: (String, Trip) async throws -> Void) async throws {
        let uid = try await LiveTestAuth.defaultUID()
        let now = now()
        let trip = Trip(title: "Fixture travel point trip", destination: "架空市", startDate: now, endDate: now, createdAt: now)
        try await acknowledged { try store.createTrip(trip, uid: uid, serverAcknowledged: $0) }
        var bodyError: Error?
        do {
            try await body(uid, trip)
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
