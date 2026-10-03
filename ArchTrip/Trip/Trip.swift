import Foundation

/// G1 minimal Trip. Stored at `users/{uid}/trips/{id}`.
nonisolated struct Trip: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: String
    var title: String
    var destination: String
    var startDate: Date
    var endDate: Date
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        title: String,
        destination: String,
        startDate: Date,
        endDate: Date,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.destination = destination
        self.startDate = startDate
        self.endDate = endDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// Mirrors the constraints enforced by `firebase/firestore.rules`.
    var isValid: Bool {
        !id.isEmpty
            && !title.isEmpty && title.count <= 200
            && destination.count <= 200
            && endDate >= startDate
            && updatedAt >= createdAt
    }

    static func makeTest(now: Date = Date()) -> Trip {
        let start = Calendar(identifier: .gregorian).startOfDay(for: now)
        return Trip(
            title: "Test Trip \(now.formatted(date: .omitted, time: .standard))",
            destination: "Tokyo",
            startDate: start,
            endDate: start.addingTimeInterval(2 * 24 * 60 * 60),
            createdAt: now
        )
    }
}

nonisolated enum TripPath {
    static func collection(uid: String) -> String {
        "users/\(uid)/trips"
    }

    static func document(uid: String, tripID: String) -> String {
        "\(collection(uid: uid))/\(tripID)"
    }
}
