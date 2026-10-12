import MapKit
import SwiftUI

extension Building {
    var priorityLabel: LocalizedStringKey {
        switch priority {
        case 3: "High"
        case 1: "Low"
        default: "Normal"
        }
    }

    var priorityColor: Color {
        switch priority {
        case 3: .red
        case 1: .gray
        default: .orange
        }
    }

    /// The stored coordinates of an unlinked Building. A linked Building's coordinates
    /// come from its fetched place (`BuildingLocation`), never from here.
    var coordinate: CLLocationCoordinate2D? {
        guard !hasPlace, let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Opens the Building in Apple Maps: a linked Building through its fetched place, an
    /// unlinked one through its stored coordinates. Does nothing without either.
    func openInMaps(place: ResolvedPlace?) {
        if hasPlace {
            guard let place else { return }
            if let item = place.mapItem {
                item.openInMaps(launchOptions: nil)
            } else {
                open(coordinate: place.coordinate, address: place.address ?? "")
            }
            return
        }
        guard let coordinate else { return }
        open(coordinate: coordinate, address: address)
    }

    private func open(coordinate: CLLocationCoordinate2D, address: String) {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let item: MKMapItem
        if #available(iOS 26.0, *) {
            item = MKMapItem(location: location, address: address.isEmpty ? nil : MKAddress(fullAddress: address, shortAddress: nil))
        } else {
            item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        }
        item.name = name
        item.openInMaps(launchOptions: nil)
    }
}

extension ResolvedPlace {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// A MapKit search result, shown while the editor is open and then discarded. Only its
/// Place ID can be kept (on a Building); the name, address and coordinates are never saved.
struct PlaceResult: Identifiable {
    let id = UUID()
    let name: String
    let address: String
    let latitude: Double
    let longitude: Double
    /// `MKMapItem.Identifier.rawValue` exactly as given, or nil when the result has none.
    let identifier: String?
    let alternateIdentifiers: Set<String>
    let item: MKMapItem

    init(_ item: MKMapItem) {
        let coordinate: CLLocationCoordinate2D
        let address: String?
        if #available(iOS 26.0, *) {
            coordinate = item.location.coordinate
            address = item.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true)
                ?? item.address?.fullAddress
        } else {
            coordinate = item.placemark.coordinate
            address = item.placemark.title
        }
        self.name = item.name ?? ""
        self.address = address ?? ""
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.identifier = item.identifier?.rawValue
        self.alternateIdentifiers = Set(item.alternateIdentifiers.map(\.rawValue))
        self.item = item
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Nil when the result can be linked to a Building.
    var linkIssue: PlaceLink.Issue? { PlaceLink.issue(forIdentifier: identifier) }

    /// Every ID MapKit says refers to this place, for the duplicate check.
    var allIdentifiers: Set<String> {
        identifier.map { alternateIdentifiers.union([$0]) } ?? alternateIdentifiers
    }

    static func search(_ query: String) async throws -> [PlaceResult] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.map(PlaceResult.init)
    }
}

/// Small, non-interactive map preview around one coordinate.
struct MapPreview: View {
    let title: String
    let coordinate: CLLocationCoordinate2D

    var body: some View {
        Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 600, longitudinalMeters: 600))) {
            Marker(title, systemImage: "building.columns.fill", coordinate: coordinate)
        }
        .allowsHitTesting(false)
        // A new coordinate (the place arriving after the view appeared) re-centres the preview.
        .id("\(coordinate.latitude),\(coordinate.longitude)")
    }
}

/// One line about a linked Building's place: what the user needs to know on a list row,
/// without the place's address (that is shown together with a map, in the detail view).
struct PlaceStatusLabel: View {
    let state: PlaceDirectory.State

    @Environment(\.locale) private var locale

    var body: some View {
        switch state {
        case .idle, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Fetching place…")
            }
            .foregroundStyle(.secondary)
        case .resolved(_, let fetchedAt, let stale):
            HStack(spacing: 6) {
                Label("Apple Maps place", systemImage: "mappin.circle.fill")
                    .foregroundStyle(.green)
                if stale {
                    Text("Fetched at \(DateFormatting.time(fetchedAt, locale: locale))")
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(.offline, _, _):
            Label("Place not available offline", systemImage: "wifi.slash")
                .foregroundStyle(.secondary)
        case .failed(.notFound, _, _):
            Label("Not found in Apple Maps", systemImage: "mappin.slash")
                .foregroundStyle(.orange)
        case .failed(.timeout, _, _), .failed(.transport, _, _), .failed(.throttled, _, _), .failed(.server, _, _):
            Label("Couldn't fetch the place", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }
}
