import MapKit
import SwiftUI

struct ArchitectureView: View {
    private enum Mode: Hashable {
        case list
        case map
    }

    @Environment(AppSession.self) private var session
    @State private var mode: Mode = .list
    @State private var showingNewBuilding = false

    var body: some View {
        Group {
            switch mode {
            case .list: BuildingListContent(onAdd: { showingNewBuilding = true })
            case .map: BuildingMapContent()
            }
        }
        .navigationTitle("Architecture")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $mode) {
                    Label("List", systemImage: "list.bullet").tag(Mode.list)
                    Label("Map", systemImage: "map").tag(Mode.map)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewBuilding = true
                } label: {
                    Label("Add Building", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingNewBuilding) {
            BuildingEditorView(building: nil)
        }
    }
}

/// Not yet visited first, then higher priority, then name.
nonisolated enum BuildingOrdering {
    static func sorted(_ buildings: [Building]) -> [Building] {
        buildings.sorted { lhs, rhs in
            if lhs.visited != rhs.visited { return !lhs.visited }
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            if lhs.name != rhs.name { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            return lhs.id < rhs.id
        }
    }
}

private struct BuildingListContent: View {
    let onAdd: () -> Void

    @Environment(AppSession.self) private var session
    @State private var pendingDelete: Building?

    var body: some View {
        List {
            if !session.buildingFailures.isEmpty {
                DecodeFailureSection(failures: session.buildingFailures)
            }
            if session.buildingsLoadFailed {
                Label("Couldn't load data", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            ForEach(BuildingOrdering.sorted(session.buildings)) { building in
                NavigationLink(value: BuildingRoute(buildingID: building.id)) {
                    BuildingRow(building: building)
                }
                .swipeActions {
                    Button("Delete", role: .destructive) {
                        pendingDelete = building
                    }
                }
            }
        }
        .overlay {
            if !session.hasLoadedBuildings {
                ProgressView()
            } else if session.buildings.isEmpty && session.buildingFailures.isEmpty && !session.buildingsLoadFailed {
                ContentUnavailableView {
                    Label("No buildings yet", systemImage: "building.columns")
                } description: {
                    Text("Add buildings you want to visit.")
                } actions: {
                    Button("Add Building", action: onAdd)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .confirmationDialog(
            "Delete this building?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { building in
            Button("Delete", role: .destructive) {
                session.deleteBuilding(building)
            }
        } message: { _ in
            Text("Trip events that use this building are kept.")
        }
    }
}

struct BuildingRow: View {
    let building: Building

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: building.visited ? "checkmark.circle.fill" : "building.columns.fill")
                .foregroundStyle(building.visited ? Color.green : Color.teal)
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: building.name)
                    .font(.headline)
                if !building.architect.isEmpty {
                    Text(verbatim: building.architect)
                        .font(.subheadline)
                }
                if !building.address.isEmpty {
                    Text(verbatim: building.address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(building.priorityLabel)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(building.priorityColor.opacity(0.15), in: .capsule)
                        .foregroundStyle(building.priorityColor)
                    if building.visited {
                        Text("Visited")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    if !building.hasCoordinate {
                        Label("No location", systemImage: "mappin.slash")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct BuildingMapContent: View {
    @Environment(AppSession.self) private var session
    @State private var position: MapCameraPosition = .automatic
    @State private var selection: String?

    private var mapped: [Building] {
        session.buildings.filter(\.hasCoordinate)
    }

    var body: some View {
        Map(position: $position, selection: $selection) {
            ForEach(mapped) { building in
                if let coordinate = building.coordinate {
                    Marker(building.name, systemImage: "building.columns.fill", coordinate: coordinate)
                        .tint(building.visited ? .green : building.priorityColor)
                        .tag(building.id)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if let id = selection, let building = session.building(id: id) {
                    NavigationLink(value: BuildingRoute(buildingID: building.id)) {
                        BuildingRow(building: building)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(.regularMaterial, in: .rect(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                }
                let unmapped = session.buildings.count - mapped.count
                if unmapped > 0 {
                    Text("\(unmapped) buildings without a location are shown in the list only.")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: .capsule)
                }
            }
            .padding()
        }
        .onChange(of: mapped.map(\.id)) {
            position = .automatic
        }
    }
}
