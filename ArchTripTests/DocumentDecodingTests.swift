import FirebaseFirestore
import Foundation
import Testing
@testable import ArchTrip

struct DocumentDecodingTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    private func tripFields(id: String) throws -> [String: Any] {
        try Firestore.Encoder().encode(Trip(id: id, title: "t", destination: "d", startDate: date, endDate: date, createdAt: date))
    }

    @Test func malformedDocumentIsReportedNotDropped() throws {
        var malformed = try tripFields(id: "bad")
        malformed.removeValue(forKey: "title")
        let result = DocumentDecoding.decode(
            [(id: "good", data: try tripFields(id: "good")), (id: "bad", data: malformed)],
            as: Trip.self
        )
        #expect(result.items.map(\.id) == ["good"])
        #expect(result.failures.map(\.documentID) == ["bad"])
        #expect(!result.failures[0].reason.isEmpty)
    }

    @Test func wrongTypeIsReported() throws {
        var fields = try tripFields(id: "t1")
        fields["startDate"] = "yesterday"
        let result = DocumentDecoding.decode([(id: "t1", data: fields)], as: Trip.self)
        #expect(result.items.isEmpty)
        #expect(result.failures.map(\.documentID) == ["t1"])
    }

    @Test func idMismatchIsReported() throws {
        let result = DocumentDecoding.decode([(id: "doc-id", data: try tripFields(id: "other-id"))], as: Trip.self)
        #expect(result.items.isEmpty)
        #expect(result.failures.first?.reason == "id field does not match document ID")
    }

    @Test func validatorRejectionIsReported() throws {
        let event = Event(id: "e1", tripId: "other-trip", type: .food, title: "Lunch", startDate: date, endDate: date, createdAt: date)
        let result = DocumentDecoding.decode(
            [(id: "e1", data: try Firestore.Encoder().encode(event))],
            as: Event.self,
            validate: { $0.tripId == "trip" ? nil : "tripId mismatch" }
        )
        #expect(result.items.isEmpty)
        #expect(result.failures == [DecodeFailure(documentID: "e1", reason: "tripId mismatch")])
    }

    @Test func allValidDocumentsDecode() throws {
        let result = DocumentDecoding.decode(
            [(id: "a", data: try tripFields(id: "a")), (id: "b", data: try tripFields(id: "b"))],
            as: Trip.self
        )
        #expect(result.items.map(\.id) == ["a", "b"])
        #expect(result.failures.isEmpty)
    }
}
