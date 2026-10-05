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

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Opens the Building in Apple Maps. Requires coordinates.
    func openInMaps() {
        guard let latitude, let longitude else { return }
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let item: MKMapItem
        if #available(iOS 26.0, *) {
            item = MKMapItem(location: location, address: address.isEmpty ? nil : MKAddress(fullAddress: address, shortAddress: nil))
        } else {
            item = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
        }
        item.name = name
        item.openInMaps(launchOptions: nil)
    }
}

/// A MapKit search result reduced to what a Building needs.
struct PlaceResult: Identifiable {
    let id = UUID()
    let name: String
    let address: String
    let latitude: Double
    let longitude: Double

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
    }

    static func search(_ query: String) async throws -> [PlaceResult] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.map(PlaceResult.init)
    }
}

/// Small, non-interactive map preview for a Building with coordinates.
struct BuildingMapPreview: View {
    let building: Building

    var body: some View {
        if let coordinate = building.coordinate {
            Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 600, longitudinalMeters: 600))) {
                Marker(building.name, systemImage: "building.columns.fill", coordinate: coordinate)
            }
            .allowsHitTesting(false)
        }
    }
}
