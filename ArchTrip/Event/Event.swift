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
    static let buildingIdMaxLength = 200

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
    /// Optional link to a Building (architecture Events only). The Event keeps its
    /// own title/location snapshot, so it stays usable if the Building is deleted.
    /// Omitted from the document when nil, so G2 Events decode unchanged.
    var buildingId: String?

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
        updatedAt: Date? = nil,
        buildingId: String? = nil
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
        self.buildingId = buildingId
    }

    /// Mirrors the constraints enforced by `firebase/firestore.rules`.
    var isValid: Bool {
        !id.isEmpty && !tripId.isEmpty
            && !title.isEmpty && title.count <= Self.titleMaxLength
            && locationName.count <= Self.locationNameMaxLength
            && note.count <= Self.noteMaxLength
            && endDate >= startDate
            && updatedAt >= createdAt
            && hasValidBuildingLink
    }

    private var hasValidBuildingLink: Bool {
        guard let buildingId else { return true }
        return type == .architecture && !buildingId.isEmpty && buildingId.count <= Self.buildingIdMaxLength
    }
}

extension Event: FirestoreDocument {
    static let optionalFields = ["buildingId"]
}
