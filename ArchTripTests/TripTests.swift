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

    @Test func partitionUpcomingAndPast() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        func day(_ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: d))! }
        let past = Trip(id: "past", title: "p", destination: "", startDate: day(1), endDate: day(2))
        let ongoing = Trip(id: "ongoing", title: "o", destination: "", startDate: day(9), endDate: day(10))
        let later = Trip(id: "later", title: "l", destination: "", startDate: day(20), endDate: day(21))
        let soon = Trip(id: "soon", title: "s", destination: "", startDate: day(12), endDate: day(12))
        let older = Trip(id: "older", title: "o", destination: "", startDate: day(3), endDate: day(4))
        let result = Trip.partition([later, past, soon, ongoing, older], today: day(10).addingTimeInterval(15 * 3600), calendar: calendar)
        #expect(result.upcoming.map(\.id) == ["ongoing", "soon", "later"])
        #expect(result.past.map(\.id) == ["older", "past"])
    }

    @Test func paths() {
        #expect(TripPath.collection(uid: "u1") == "users/u1/trips")
        #expect(TripPath.document(uid: "u1", tripID: "t1") == "users/u1/trips/t1")
    }
}
