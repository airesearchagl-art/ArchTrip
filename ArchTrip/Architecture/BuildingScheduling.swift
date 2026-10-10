import Foundation

nonisolated enum BuildingScheduling {
    /// Combines the calendar day of `day` with the hour and minute of `time`.
    static func startDate(day: Date, time: Date, calendar: Calendar) -> Date {
        let clock = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.date(
            bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0, second: 0,
            of: calendar.startOfDay(for: day)
        ) ?? day
    }

    /// An architecture Event visiting `building` on `tripID`, linked by `buildingId` with
    /// the name as its title. The address is not copied (Option A: a Building's location
    /// may come from Apple Maps search and must not be persisted into new documents),
    /// and neither is the note. The user can type a location on the Event.
    static func makeEvent(
        visiting building: Building,
        tripID: String,
        start: Date,
        durationMinutes: Int,
        now: Date = Date()
    ) -> Event {
        Event(
            tripId: tripID,
            type: .architecture,
            title: building.name,
            startDate: start,
            endDate: start.addingTimeInterval(TimeInterval(max(0, durationMinutes) * 60)),
            locationName: "",
            note: "",
            createdAt: now,
            buildingId: building.id
        )
    }

    /// The title after picking `selected` in the Event editor: the Building's name,
    /// unless the user typed a title of their own (anything but the previous pick's name).
    static func title(current: String, previous: Building?, selected: Building) -> String {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == previous?.name { return selected.name }
        return current
    }
}

/// How an Event's optional Building link resolves against the user's Buildings.
nonisolated enum BuildingLink: Equatable, Sendable {
    case none
    case available(Building)
    /// The Event points at a Building that no longer exists (e.g. deleted).
    case unavailable(buildingID: String)

    static func resolve(_ event: Event, in buildings: [Building]) -> BuildingLink {
        resolve(buildingID: event.buildingId, in: buildings)
    }

    static func resolve(buildingID: String?, in buildings: [Building]) -> BuildingLink {
        guard let buildingID else { return .none }
        if let building = buildings.first(where: { $0.id == buildingID }) {
            return .available(building)
        }
        return .unavailable(buildingID: buildingID)
    }
}
