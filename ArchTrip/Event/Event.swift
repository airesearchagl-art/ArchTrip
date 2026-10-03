import Foundation

nonisolated enum EventType: String, Codable, CaseIterable, Identifiable, Sendable {
    case flight
    case train
    case car
    case walk
    case hotel
    case business
    case architecture
    case food
    case other

    var id: String { rawValue }
}

/// An item on a Trip's timeline. Stored at `users/{uid}/trips/{tripId}/events/{id}`.
nonisolated struct Event: Codable, Identifiable, Equatable, Hashable, Sendable {
    static let titleMaxLength = 200
    static let locationNameMaxLength = 200
    static let noteMaxLength = 2000

    var id: String
    var tripId: String
    var type: EventType
    var title: String
    var startDate: Date
    var endDate: Date
    var locationName: String
    var note: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        tripId: String,
        type: EventType,
        title: String,
        startDate: Date,
        endDate: Date,
        locationName: String = "",
        note: String = "",
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.tripId = tripId
        self.type = type
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.locationName = locationName
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// Mirrors the constraints enforced by `firebase/firestore.rules`.
    var isValid: Bool {
        !id.isEmpty && !tripId.isEmpty
            && !title.isEmpty && title.count <= Self.titleMaxLength
            && locationName.count <= Self.locationNameMaxLength
            && note.count <= Self.noteMaxLength
            && endDate >= startDate
            && updatedAt >= createdAt
    }
}
