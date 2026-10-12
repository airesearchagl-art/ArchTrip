import Foundation

/// Pure rules for linking a Building to an Apple Maps place (v0.2).
nonisolated enum PlaceLink {
    /// Why a search result cannot be linked. The result is still shown, greyed out.
    enum Issue: Equatable, Sendable {
        /// MapKit gave the result no identifier.
        case noIdentifier
        /// Longer than `Building.applePlaceIdMaxLength`: this version cannot store it.
        case identifierTooLong
    }

    static func issue(forIdentifier identifier: String?) -> Issue? {
        guard let identifier, !identifier.isEmpty else { return .noIdentifier }
        return identifier.count > Building.applePlaceIdMaxLength ? .identifierTooLong : nil
    }

    /// Buildings already linked to the same place, by the candidate's own ID or any of
    /// its alternate IDs (Apple: several IDs may refer to one place). A warning, not a block.
    static func duplicates(of identifiers: Set<String>, in buildings: [Building], excluding buildingID: String? = nil) -> [Building] {
        BuildingOrdering.sorted(
            buildings.filter { building in
                building.id != buildingID && building.applePlaceId.map(identifiers.contains) == true
            }
        )
    }
}

/// Where a Building is shown on a map. A linked Building uses only its fetched place:
/// when the fetch has not succeeded it has no location, even if legacy coordinates are
/// still stored beside the link (no fallback, so unknown-provenance coordinates are never
/// presented as the place). An unlinked Building shows its stored coordinates as before.
nonisolated enum BuildingLocation: Equatable {
    case none
    /// The stored coordinates of an unlinked Building (provenance unknown, displayed as before).
    case stored(latitude: Double, longitude: Double)
    /// The linked place, as fetched now.
    case place(latitude: Double, longitude: Double)

    static func resolve(_ building: Building, place: ResolvedPlace?) -> BuildingLocation {
        if building.hasPlace {
            guard let place else { return .none }
            return .place(latitude: place.latitude, longitude: place.longitude)
        }
        if let latitude = building.latitude, let longitude = building.longitude {
            return .stored(latitude: latitude, longitude: longitude)
        }
        return .none
    }

    var coordinates: (latitude: Double, longitude: Double)? {
        switch self {
        case .none: nil
        case .stored(let latitude, let longitude), .place(let latitude, let longitude): (latitude, longitude)
        }
    }
}
