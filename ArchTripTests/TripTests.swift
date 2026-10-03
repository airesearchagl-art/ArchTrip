import FirebaseFirestore
import Foundation
import Testing
@testable import ArchTrip

struct TripTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeTrip() -> Trip {
        Trip(
            id: "trip-1",
            title: "Kyoto",
            destination: "Kyoto, Japan",
            startDate: start,
            endDate: start.addingTimeInterval(86_400),
            createdAt: start.addingTimeInterval(-3_600)
        )
    }

    @Test func updatedAtDefaultsToCreatedAt() {
        let trip = makeTrip()
        #expect(trip.updatedAt == trip.createdAt)
    }

    @Test func generatedIDIsUUID() {
        let trip = Trip(title: "t", destination: "d", startDate: start, endDate: start)
        #expect(UUID(uuidString: trip.id) != nil)
    }

    @Test func validation() {
        #expect(makeTrip().isValid)

        var reversed = makeTrip()
        reversed.endDate = start.addingTimeInterval(-1)
        #expect(!reversed.isValid)

        var untitled = makeTrip()
        untitled.title = ""
        #expect(!untitled.isValid)

        var longTitle = makeTrip()
        longTitle.title = String(repeating: "a", count: 201)
        #expect(!longTitle.isValid)
    }

    @Test func makeTestProducesValidTrip() {
        #expect(Trip.makeTest(now: start).isValid)
    }

    @Test func jsonRoundTrip() throws {
        let trip = makeTrip()
        let data = try JSONEncoder().encode(trip)
        #expect(try JSONDecoder().decode(Trip.self, from: data) == trip)
    }

    @Test func firestoreEncodingMatchesRulesSchema() throws {
        let fields = try Firestore.Encoder().encode(makeTrip())
        #expect(Set(fields.keys) == ["id", "title", "destination", "startDate", "endDate", "createdAt", "updatedAt"])
        for key in ["startDate", "endDate", "createdAt", "updatedAt"] {
            #expect(fields[key] is Timestamp, "\(key) should be stored as a Firestore Timestamp")
        }
    }

    @Test func firestoreRoundTrip() throws {
        let trip = makeTrip()
        let fields = try Firestore.Encoder().encode(trip)
        #expect(try Firestore.Decoder().decode(Trip.self, from: fields) == trip)
    }

    @Test func paths() {
        #expect(TripPath.collection(uid: "u1") == "users/u1/trips")
        #expect(TripPath.document(uid: "u1", tripID: "t1") == "users/u1/trips/t1")
    }
}
