import SwiftUI

struct BuildingDetailView: View {
    let buildingID: String

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var editing = false
    @State private var addingToTrip = false
    @State private var confirmingDelete = false

    var body: some View {
        if let building = session.building(id: buildingID) {
            detail(building)
        } else {
            ContentUnavailableView("This building is no longer available", systemImage: "building.columns")
        }
    }

    private func detail(_ building: Building) -> some View {
        List {
            if building.hasPlace, let placeID = building.applePlaceId {
                placeSection(building, placeID: placeID)
            } else if let coordinate = building.coordinate {
                Section {
                    MapPreview(title: building.name, coordinate: coordinate)
                        .frame(height: 180)
                        .listRowInsets(EdgeInsets())
                    Button {
                        building.openInMaps(place: nil)
                    } label: {
                        Label("Open in Apple Maps", systemImage: "map")
                    }
                }
            }
            Section {
                LabeledContent("Architect") {
                    Text(verbatim: building.architect.isEmpty ? "–" : building.architect)
                }
                LabeledContent("Completed year") {
                    Text(verbatim: building.completedYear.map(String.init) ?? "–")
                }
                // A linked Building's address comes from its place (above); the stored text
                // stays in the document, unused, until the user unlinks or clears it.
                if !building.hasPlace {
                    LabeledContent("Address") {
                        Text(verbatim: building.address.isEmpty ? "–" : building.address)
                            .multilineTextAlignment(.trailing)
                    }
                }
                LabeledContent("Visit duration") {
                    Text("\(building.visitMinutes) min")
                }
                LabeledContent("Priority") {
                    Text(building.priorityLabel).foregroundStyle(building.priorityColor)
                }
                LabeledContent("Visited") {
                    Image(systemName: building.visited ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(building.visited ? .green : .secondary)
                        .accessibilityLabel(building.visited ? Text("Visited") : Text("Not visited"))
                }
            }
            if !building.note.isEmpty {
                Section("Note") {
                    Text(verbatim: building.note)
                }
            }
            Section {
                Button {
                    addingToTrip = true
                } label: {
                    Label("Add to Trip", systemImage: "calendar.badge.plus")
                }
                Button("Delete Building", role: .destructive) {
                    confirmingDelete = true
                }
            }
        }
        .navigationTitle(Text(verbatim: building.name))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { editing = true }
            }
        }
        // Screen interest in the place: fetched while shown, cancelled when the view goes.
        .task(id: building.applePlaceId) {
            guard let placeID = building.applePlaceId else { return }
            await session.places.hold(placeID)
        }
        .sheet(isPresented: $editing) {
            BuildingEditorView(building: building)
        }
        .sheet(isPresented: $addingToTrip) {
            AddBuildingToTripView(building: building)
        }
        .confirmationDialog("Delete this building?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                session.deleteBuilding(building)
                dismiss()
            }
        } message: {
            Text("Trip events that use this building are kept.")
        }
    }

    /// The linked place as fetched now: map, name and address together (never the stored
    /// coordinates), or the explicit state of the lookup with a manual retry.
    @ViewBuilder
    private func placeSection(_ building: Building, placeID: String) -> some View {
        let state = session.places.state(for: placeID)
        Section {
            switch state {
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Fetching place…").foregroundStyle(.secondary)
                }
            case .resolved(let place, let fetchedAt, let stale):
                MapPreview(title: building.name, coordinate: place.coordinate)
                    .frame(height: 180)
                    .listRowInsets(EdgeInsets())
                LabeledContent("Place") {
                    Text(verbatim: place.name ?? "–")
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Address") {
                    Text(verbatim: place.address ?? "–")
                        .multilineTextAlignment(.trailing)
                }
                if stale {
                    Text("Fetched at \(DateFormatting.time(fetchedAt, locale: locale))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    building.openInMaps(place: place)
                } label: {
                    Label("Open in Apple Maps", systemImage: "map")
                }
            case .failed:
                PlaceStatusLabel(state: state)
                Button {
                    session.places.retry(placeID)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }
        } header: {
            Text("Apple Maps place")
        }
    }
}
