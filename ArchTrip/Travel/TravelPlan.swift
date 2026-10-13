import CoreLocation
import Foundation
import MapKit
import Observation

/// How to move between two Events. Deliberately not an `EventType`: a transit answer is
/// shown and handed to Apple Maps, never turned into a `train` (or any other) Event.
nonisolated enum TravelMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case car
    case walk
    case transit

    var id: String { rawValue }
}

/// The time a search is anchored to: leave then, or be there by then.
nonisolated enum TravelAnchor: Hashable, Sendable {
    case departAt(Date)
    case arriveBy(Date)

    var date: Date {
        switch self {
        case .departAt(let date), .arriveBy(let date): date
        }
    }
}

/// A point handed to the router: coordinates and a label, plus the Place ID when it is a
/// linked Apple Maps place. Lives only while the travel screen is open.
nonisolated struct TravelPoint: Hashable, Sendable {
    let name: String
    let latitude: Double
    let longitude: Double
    let placeID: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Where one side of the search is. Decided by what the Event and its Building hold,
/// never by guessing: a Building without a Place ID gives no point, and the user picks a
/// candidate on the spot. Stored coordinates of unknown provenance are not used (D-022).
nonisolated enum TravelEndpoint: Hashable, Sendable {
    /// The Event's Building is linked to an Apple Maps place by ID; the place is fetched
    /// while shown (`PlaceDirectory`).
    case linkedPlace(placeID: String, buildingID: String, buildingUpdatedAt: Date)
    /// A search result the user picked for this search only. Never saved anywhere.
    case candidate(PlaceResult)
    /// Nothing usable yet. `hint` is only a suggested query (the Event's location text or
    /// its Building's name); no result is chosen automatically.
    case unresolved(hint: String)

    static func resolve(event: Event, buildings: [Building]) -> TravelEndpoint {
        let building = event.buildingId.flatMap { id in buildings.first { $0.id == id } }
        if let building, let placeID = building.applePlaceId {
            return .linkedPlace(placeID: placeID, buildingID: building.id, buildingUpdatedAt: building.updatedAt)
        }
        let hint = event.locationName.isEmpty ? (building?.name ?? "") : event.locationName
        return .unresolved(hint: hint)
    }

    var isUsable: Bool {
        if case .unresolved = self { return false }
        return true
    }

    var hint: String {
        switch self {
        case .unresolved(let hint): hint
        case .candidate(let result): result.name.isEmpty ? result.address : result.name
        case .linkedPlace: ""
        }
    }
}

/// Everything a result depends on. A result is shown only while the key it was computed
/// for equals the key of what is on screen: a changed Event or Building (`updatedAt`), a
/// changed Place ID, a re-picked point, another mode or another time all make it stale.
nonisolated struct TravelRequestKey: Hashable, Sendable {
    let fromEventID: String
    let fromEventUpdatedAt: Date
    let from: TravelEndpoint
    let toEventID: String
    let toEventUpdatedAt: Date
    let to: TravelEndpoint
    let mode: TravelMode
    let anchor: TravelAnchor
}

nonisolated struct TravelCoordinate: Hashable, Sendable {
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// What Apple Maps answered, kept in memory for display only. Nothing here is ever written
/// to an Event, a Building or Firestore.
nonisolated struct TravelResult: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Car and walking: a route with its path and turn-by-turn instructions.
        case route(distance: CLLocationDistance, steps: [String], path: [TravelCoordinate])
        /// Transit: MapKit estimates the time only; lines and times are in Apple Maps.
        case eta(distance: CLLocationDistance)
    }

    let mode: TravelMode
    let kind: Kind
    let expectedTravelTime: TimeInterval
    let expectedDeparture: Date?
    let expectedArrival: Date?
}

protocol TravelRouting {
    func route(from: TravelPoint, to: TravelPoint, mode: TravelMode, anchor: TravelAnchor) async throws -> TravelResult
}

/// One travel search at a time. Each reply is tagged with the key it was asked for and is
/// applied only if it belongs to the latest request (never-reused token): a reply that
/// arrives after a cancel, a new search or a timeout changes nothing.
@Observable
final class TravelSearch {
    enum State: Equatable {
        case idle
        case searching(TravelRequestKey)
        case result(TravelResult, TravelRequestKey)
        case failed(PlaceFetchFailure, TravelRequestKey)
    }

    private(set) var state: State = .idle
    private let router: any TravelRouting
    private let timeout: Duration
    private var token = 0
    private var task: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var timedOutToken: Int?

    init(router: any TravelRouting, timeout: Duration = .seconds(30)) {
        self.router = router
        self.timeout = timeout
    }

    var isSearching: Bool {
        if case .searching = state { return true }
        return false
    }

    /// The key the shown state belongs to, if any.
    var key: TravelRequestKey? {
        switch state {
        case .idle: nil
        case .searching(let key), .result(_, let key), .failed(_, let key): key
        }
    }

    func isCurrent(_ key: TravelRequestKey) -> Bool {
        self.key == key
    }

    func search(_ key: TravelRequestKey, from: TravelPoint, to: TravelPoint) {
        if case .searching(let inFlight) = state, inFlight == key { return }
        cancelInFlight()
        let current = token
        state = .searching(key)
        timer = Task { [timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, current == self.token else { return }
            self.timedOutToken = current
            self.task?.cancel()
        }
        task = Task { [router] in
            let outcome: State
            do {
                let result = try await router.route(from: from, to: to, mode: key.mode, anchor: key.anchor)
                outcome = .result(result, key)
            } catch {
                // A cancelled request may surface as CancellationError or as MapKit's own
                // error; only the timer's cancellation becomes a visible failure.
                if Task.isCancelled || error is CancellationError {
                    guard self.timedOutToken == current else { return }
                    outcome = .failed(.timeout, key)
                } else {
                    outcome = .failed(MapKitPlaceFetcher.classify(error), key)
                }
            }
            self.apply(outcome, token: current)
        }
    }

    /// Stops a search in flight; a result or failure already shown stays until the
    /// screen decides it is stale.
    func cancel() {
        cancelInFlight()
        if case .searching = state { state = .idle }
    }

    func reset() {
        cancelInFlight()
        state = .idle
    }

    private func cancelInFlight() {
        token += 1
        timer?.cancel()
        timer = nil
        task?.cancel()
        task = nil
    }

    private func apply(_ outcome: State, token: Int) {
        guard token == self.token else { return }
        timer?.cancel()
        state = outcome
    }
}

/// Apple Maps directions through MapKit. Car and walking return a route; transit is
/// "only supported for estimating time of arrival" (MapKit), so it returns an ETA.
struct MapKitTravelRouter: TravelRouting {
    func route(from: TravelPoint, to: TravelPoint, mode: TravelMode, anchor: TravelAnchor) async throws -> TravelResult {
        let request = MKDirections.Request()
        request.source = Self.mapItem(for: from)
        request.destination = Self.mapItem(for: to)
        request.transportType = Self.transportType(for: mode)
        switch anchor {
        case .departAt(let date): request.departureDate = date
        case .arriveBy(let date): request.arrivalDate = date
        }
        let directions = DirectionsBox(MKDirections(request: request))
        switch mode {
        case .transit:
            let eta = try await withTaskCancellationHandler {
                try await directions.directions.calculateETA()
            } onCancel: {
                directions.cancel()
            }
            try Task.checkCancellation()
            return TravelResult(
                mode: mode,
                kind: .eta(distance: eta.distance),
                expectedTravelTime: eta.expectedTravelTime,
                expectedDeparture: eta.expectedDepartureDate,
                expectedArrival: eta.expectedArrivalDate
            )
        case .car, .walk:
            let response = try await withTaskCancellationHandler {
                try await directions.directions.calculate()
            } onCancel: {
                directions.cancel()
            }
            try Task.checkCancellation()
            guard let route = response.routes.first else { throw MKError(.directionsNotFound) }
            let path = Self.coordinates(of: route.polyline).map { TravelCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
            let times = Self.times(for: anchor, travelTime: route.expectedTravelTime)
            return TravelResult(
                mode: mode,
                kind: .route(distance: route.distance, steps: route.steps.map(\.instructions).filter { !$0.isEmpty }, path: path),
                expectedTravelTime: route.expectedTravelTime,
                expectedDeparture: times.departure,
                expectedArrival: times.arrival
            )
        }
    }

    static func transportType(for mode: TravelMode) -> MKDirectionsTransportType {
        switch mode {
        case .car: .automobile
        case .walk: .walking
        case .transit: .transit
        }
    }

    static func launchDirectionsMode(for mode: TravelMode) -> String {
        switch mode {
        case .car: MKLaunchOptionsDirectionsModeDriving
        case .walk: MKLaunchOptionsDirectionsModeWalking
        case .transit: MKLaunchOptionsDirectionsModeTransit
        }
    }

    /// Departure and arrival implied by the anchor and the travel time (a route has no
    /// times of its own).
    nonisolated static func times(for anchor: TravelAnchor, travelTime: TimeInterval) -> (departure: Date, arrival: Date) {
        switch anchor {
        case .departAt(let date): (date, date.addingTimeInterval(travelTime))
        case .arriveBy(let date): (date.addingTimeInterval(-travelTime), date)
        }
    }

    static func mapItem(for point: TravelPoint) -> MKMapItem {
        let item: MKMapItem
        if #available(iOS 26.0, *) {
            item = MKMapItem(location: CLLocation(latitude: point.latitude, longitude: point.longitude), address: nil)
        } else {
            item = MKMapItem(placemark: MKPlacemark(coordinate: point.coordinate))
        }
        item.name = point.name.isEmpty ? nil : point.name
        return item
    }

    private static func coordinates(of polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        var coordinates = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: polyline.pointCount)
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
        return coordinates
    }

    private nonisolated final class DirectionsBox: @unchecked Sendable {
        let directions: MKDirections

        init(_ directions: MKDirections) {
            self.directions = directions
        }

        func cancel() {
            directions.cancel()
        }
    }
}
