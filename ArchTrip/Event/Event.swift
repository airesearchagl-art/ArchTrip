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
    /// G6: true for an all-day Event (hotel stay, rental car, whole-day note). All-day
    /// Events are listed apart from the timed timeline and never count toward
    /// Travel / Free Time; their days come from `AllDaySchedule`. Omitted from the
    /// document when nil, so Events written before G6 decode unchanged and stay timed;
    /// nil and false mean the same thing. Existing Events are never converted.
    var isAllDay: Bool?
    /// G6-UX-05: optional clock times of an all-day hotel stay, as minutes after local
    /// midnight on the check-in day and on the check-out day (`clockMinutesRange`). The
    /// timeline derives check-in / check-out markers from them (`HotelMarker`); nothing
    /// else is stored, and both are omitted from the document when nil.
    var checkInMinutes: Int?
    var checkOutMinutes: Int?

    static let clockMinutesRange = 0..<(24 * 60)

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
        buildingId: String? = nil,
        isAllDay: Bool? = nil,
        checkInMinutes: Int? = nil,
        checkOutMinutes: Int? = nil
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
        self.isAllDay = isAllDay
        self.checkInMinutes = checkInMinutes
        self.checkOutMinutes = checkOutMinutes
    }

    /// Timed Events form the timeline and its Travel / Free Time gaps.
    var isTimed: Bool { isAllDay != true }

    /// Mirrors the constraints enforced by `firebase/firestore.rules`.
    var isValid: Bool {
        !id.isEmpty && !tripId.isEmpty
            && !title.isEmpty && title.count <= Self.titleMaxLength
            && locationName.count <= Self.locationNameMaxLength
            && note.count <= Self.noteMaxLength
            && endDate >= startDate
            && updatedAt >= createdAt
            && hasValidBuildingLink
            && hasValidClockTimes
    }

    private var hasValidBuildingLink: Bool {
        guard let buildingId else { return true }
        return type == .architecture && !buildingId.isEmpty && buildingId.count <= Self.buildingIdMaxLength
    }

    /// Clock times belong to all-day hotel stays only and lie within one day.
    private var hasValidClockTimes: Bool {
        let times = [checkInMinutes, checkOutMinutes].compactMap { $0 }
        if times.isEmpty { return true }
        return type == .hotel && isAllDay == true && times.allSatisfy(Self.clockMinutesRange.contains)
    }
}

extension Event: FirestoreDocument {
    /// Each is removed from the stored document by an update that leaves it nil.
    static let optionalFields = ["buildingId", "isAllDay", "checkInMinutes", "checkOutMinutes"]
}
