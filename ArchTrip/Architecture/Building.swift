import Foundation

/// An architecture visit candidate, reusable across Trips.
/// Stored at `users/{uid}/buildings/{id}`. Optional fields are omitted
/// from the Firestore document when nil (see BuildingTests).
nonisolated struct Building: Codable, Identifiable, Equatable, Hashable, Sendable {
    static let nameMaxLength = 200
    static let architectMaxLength = 200
    static let addressMaxLength = 300
    static let noteMaxLength = 2000
    static let completedYearRange = 1...2100
    static let visitMinutesRange = 5...480
    static let priorityRange = 1...3
    static let defaultVisitMinutes = 60
    static let defaultPriority = 2
    /// This project's defensive bound on `applePlaceId`, not an Apple specification: Apple
    /// documents a Place ID only as an opaque string (observed IDs are 17 characters). The
    /// bound caps document size and rejects corrupt input; it is enforced when writing
    /// (`isWritable`, and the same number in `firebase/firestore.rules`), never when reading,
    /// so raising or lowering it later cannot make stored Buildings unreadable.
    static let applePlaceIdMaxLength = 128

    var id: String
    var name: String
    var architect: String
    var completedYear: Int?
    var address: String
    var latitude: Double?
    var longitude: Double?
    var visitMinutes: Int
    /// 1 = low, 2 = normal, 3 = high.
    var priority: Int
    var visited: Bool
    var note: String
    var createdAt: Date
    var updatedAt: Date
    /// Apple Maps Place ID (`MKMapItem.Identifier.rawValue`), kept exactly as MapKit gave it:
    /// never trimmed, re-cased or truncated. Apple permits storing Place IDs; the place's
    /// name, address and coordinates are fetched from it when shown and are never stored.
    /// Omitted from the document when nil. While it is set, `latitude` / `longitude` and
    /// `address` are not used for display (they stay in the document until the user clears
    /// them); unlinking shows them again.
    var applePlaceId: String?

    init(
        id: String = UUID().uuidString,
        name: String,
        architect: String = "",
        completedYear: Int? = nil,
        address: String = "",
        latitude: Double? = nil,
        longitude: Double? = nil,
        visitMinutes: Int = Building.defaultVisitMinutes,
        priority: Int = Building.defaultPriority,
        visited: Bool = false,
        note: String = "",
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        applePlaceId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.architect = architect
        self.completedYear = completedYear
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.visitMinutes = visitMinutes
        self.priority = priority
        self.visited = visited
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.applePlaceId = applePlaceId
    }

    var hasCoordinate: Bool { latitude != nil && longitude != nil }

    /// Linked to an Apple Maps place: the place is fetched for display, stored fields are not used.
    var hasPlace: Bool { applePlaceId != nil }

    /// Why the Building breaks the constraints mirrored in `firebase/firestore.rules`,
    /// or nil when valid. Developer-facing (used for fail-visible decoding). The Place ID
    /// length is deliberately not checked here: it is a write-time bound (`isWritable`).
    var invalidReason: String? {
        if id.isEmpty { return "empty id" }
        if name.isEmpty || name.count > Self.nameMaxLength { return "invalid name" }
        if architect.count > Self.architectMaxLength { return "architect too long" }
        if address.count > Self.addressMaxLength { return "address too long" }
        if note.count > Self.noteMaxLength { return "note too long" }
        if let completedYear, !Self.completedYearRange.contains(completedYear) { return "completedYear out of range" }
        if (latitude == nil) != (longitude == nil) { return "latitude and longitude must be set together" }
        if let latitude, !(-90...90).contains(latitude) { return "latitude out of range" }
        if let longitude, !(-180...180).contains(longitude) { return "longitude out of range" }
        if !Self.visitMinutesRange.contains(visitMinutes) { return "visitMinutes out of range" }
        if !Self.priorityRange.contains(priority) { return "priority out of range" }
        if updatedAt < createdAt { return "updatedAt before createdAt" }
        if let applePlaceId, applePlaceId.isEmpty { return "empty applePlaceId" }
        return nil
    }

    var isValid: Bool { invalidReason == nil }

    /// A stored Place ID longer than this version's bound. Such a Building is still read and
    /// shown; only saving it is refused until the place is unlinked or the app updated.
    var applePlaceIdExceedsLimit: Bool {
        (applePlaceId?.count ?? 0) > Self.applePlaceIdMaxLength
    }

    /// Whether this version may write the Building (the rules enforce the same bound).
    var isWritable: Bool { isValid && !applePlaceIdExceedsLimit }
}

extension Building: FirestoreDocument {
    static let optionalFields = ["completedYear", "latitude", "longitude", "applePlaceId"]
}

nonisolated enum BuildingPath {
    static func collection(uid: String) -> String {
        "users/\(uid)/buildings"
    }

    static func document(uid: String, buildingID: String) -> String {
        "\(collection(uid: uid))/\(buildingID)"
    }
}
