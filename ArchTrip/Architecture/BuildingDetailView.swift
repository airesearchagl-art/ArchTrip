import SwiftUI

struct BuildingDetailView: View {
    let buildingID: String

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
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
            if building.hasCoordinate {
                Section {
                    BuildingMapPreview(building: building)
                        .frame(height: 180)
                        .listRowInsets(EdgeInsets())
                    Button {
                        building.openInMaps()
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
                LabeledContent("Address") {
                    Text(verbatim: building.address.isEmpty ? "–" : building.address)
                        .multilineTextAlignment(.trailing)
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
}
