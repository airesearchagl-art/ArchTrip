import Foundation

#if DEBUG
/// Simulator-check hooks for travel point states that cannot be produced through the app
/// or the rules (a stored value over this version's bound, an unreadable one, a result
/// whose ID is too long). Debug builds only, and only when the app is launched with the
/// environment variables below. In-memory only: no document is touched, no UI is added,
/// nothing is compiled into Release.
///
/// - `ARCHTRIP_DEBUG_TRAVEL_POINT_FAULT` = `longStoredId` | `longStoredQuery` | `unreadable`:
///   the earliest timed Event of a Trip is shown as if its document carried that travel
///   point. Clearing the setting from the travel screen ends the replacement for that
///   Event, so the screen then shows what the listener really delivers.
/// - `ARCHTRIP_DEBUG_PLACE_SEARCH_FAULT` = `longIdentifier` | `noIdentifier`: the travel
///   picker's place search adds one result whose ID is one character over this version's
///   bound, or one without any ID (Apple Maps does not promise either on demand).
enum TravelPointFaults {
    static let readKey = "ARCHTRIP_DEBUG_TRAVEL_POINT_FAULT"
    static let searchKey = "ARCHTRIP_DEBUG_PLACE_SEARCH_FAULT"

    enum ReadFault: String {
        case longStoredId
        case longStoredQuery
        case unreadable
    }

    enum SearchFault: String {
        case longIdentifier
        case noIdentifier
    }

    private static var clearedEventIDs: Set<String> = []

    /// `events` with the fault applied to the earliest timed Event, or unchanged.
    static func applied(to events: [Event], environment: [String: String] = ProcessInfo.processInfo.environment) -> [Event] {
        guard let raw = environment[readKey], let fault = ReadFault(rawValue: raw) else { return events }
        guard let target = events.filter(\.isTimed).min(by: TimelineBuilder.chronological), !clearedEventIDs.contains(target.id) else {
            return events
        }
        return events.map { event in
            guard event.id == target.id else { return event }
            var faulty = event
            switch fault {
            case .longStoredId:
                faulty.travelPoint = .place(id: String(repeating: "L", count: TravelPointSetting.placeIdMaxLength + 1))
            case .longStoredQuery:
                faulty.travelPoint = .query(String(repeating: "Q", count: TravelPointSetting.queryMaxLength + 1))
            case .unreadable:
                faulty.travelPoint = .unreadable(reason: "unexpected keys")
            }
            return faulty
        }
    }

    /// The travel screen cleared this Event's setting: stop replacing it.
    static func noteCleared(_ eventID: String) {
        clearedEventIDs.insert(eventID)
    }

    /// The picker's searcher: `base`, wrapped when the search fault is set.
    static func searcher(wrapping base: any PlaceSearching, environment: [String: String] = ProcessInfo.processInfo.environment) -> any PlaceSearching {
        guard let raw = environment[searchKey], let fault = SearchFault(rawValue: raw) else { return base }
        return FaultySearcher(base: base, fault: fault)
    }

    private struct FaultySearcher: PlaceSearching {
        let base: any PlaceSearching
        let fault: SearchFault

        func search(_ query: String, kind: PlaceSearchKind) async throws -> [PlaceResult] {
            let results = try await base.search(query, kind: kind)
            guard kind == .pointOfInterest else { return results }
            let anchor = results.first
            let injected: PlaceResult
            switch fault {
            case .longIdentifier:
                injected = PlaceResult(
                    kind: kind, name: "Fixture long ID", address: "",
                    latitude: anchor?.latitude ?? 43.06, longitude: anchor?.longitude ?? 141.35,
                    identifier: String(repeating: "L", count: TravelPointSetting.placeIdMaxLength + 1)
                )
            case .noIdentifier:
                injected = PlaceResult(
                    kind: kind, name: "Fixture no ID", address: "",
                    latitude: anchor?.latitude ?? 43.06, longitude: anchor?.longitude ?? 141.35,
                    identifier: nil
                )
            }
            return [injected] + results
        }
    }
}
#endif
