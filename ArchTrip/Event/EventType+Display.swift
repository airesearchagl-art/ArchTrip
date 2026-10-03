import SwiftUI

extension EventType {
    var label: LocalizedStringKey {
        switch self {
        case .flight: "Flight"
        case .train: "Train"
        case .car: "Car"
        case .walk: "Walk"
        case .hotel: "Hotel"
        case .business: "Business"
        case .architecture: "Architecture Visit"
        case .food: "Food"
        case .other: "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .flight: "airplane"
        case .train: "tram.fill"
        case .car: "car.fill"
        case .walk: "figure.walk"
        case .hotel: "bed.double.fill"
        case .business: "briefcase.fill"
        case .architecture: "building.columns.fill"
        case .food: "fork.knife"
        case .other: "ellipsis.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .flight, .train, .car, .walk: .blue
        case .hotel: .indigo
        case .business: .brown
        case .architecture: .teal
        case .food: .orange
        case .other: .gray
        }
    }
}
