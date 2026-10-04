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
        updatedAt: Date? = nil
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
    }

    var hasCoordinate: Bool { latitude != nil && longitude != nil }

    /// Why the Building breaks the constraints mirrored in `firebase/firestore.rules`,
    /// or nil when valid. Developer-facing (used for fail-visible decoding).
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
        return nil
    }

    var isValid: Bool { invalidReason == nil }
}

nonisolated enum BuildingPath {
    static func collection(uid: String) -> String {
        "users/\(uid)/buildings"
    }

    static func document(uid: String, buildingID: String) -> String {
        "\(collection(uid: uid))/\(buildingID)"
    }
}
