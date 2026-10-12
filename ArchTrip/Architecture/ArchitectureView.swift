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

    @Environment(AppSession.self) private var session

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
                // A linked Building shows the state of its place lookup here, never an
                // address (the place's address appears with a map in the detail view, and
                // the stored text is unused while linked). Unlinked rows are unchanged.
                if let placeID = building.applePlaceId {
                    PlaceStatusLabel(state: session.places.state(for: placeID))
                        .font(.caption)
                } else if !building.address.isEmpty {
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
                    if !building.hasPlace, !building.hasCoordinate {
                        Label("No location", systemImage: "mappin.slash")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        // Screen interest: the place is looked up while the row is on screen and the
        // request is cancelled when the row goes (`.task` cancels on disappear).
        .task(id: building.applePlaceId) {
            guard let placeID = building.applePlaceId else { return }
            await session.places.hold(placeID)
        }
    }
}

private struct BuildingMapContent: View {
    @Environment(AppSession.self) private var session
    @State private var position: MapCameraPosition = .automatic
    @State private var selection: String?

    /// Buildings with a location now: unlinked ones by their stored coordinates, linked
    /// ones by their fetched place only (`BuildingLocation`, no fallback).
    private var mapped: [(building: Building, coordinate: CLLocationCoordinate2D)] {
        session.buildings.compactMap { building in
            let location = BuildingLocation.resolve(building, place: building.applePlaceId.flatMap(session.places.place(for:)))
            guard let coordinates = location.coordinates else { return nil }
            return (building, CLLocationCoordinate2D(latitude: coordinates.latitude, longitude: coordinates.longitude))
        }
    }

    private var placeIDs: Set<String> {
        Set(session.buildings.compactMap(\.applePlaceId))
    }

    /// Identity and position of every pin: the camera re-frames when either changes,
    /// including a place arriving later or a coordinate changing under the same ID.
    private var cameraKey: [String] {
        mapped.map { "\($0.building.id)|\($0.coordinate.latitude)|\($0.coordinate.longitude)" }
    }

    var body: some View {
        Map(position: $position, selection: $selection) {
            ForEach(mapped, id: \.building.id) { entry in
                Marker(entry.building.name, systemImage: "building.columns.fill", coordinate: entry.coordinate)
                    .tint(entry.building.visited ? .green : entry.building.priorityColor)
                    .tag(entry.building.id)
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
                let unlocated = session.buildings.filter { !$0.hasPlace && !$0.hasCoordinate }.count
                if unlocated > 0 {
                    Text("\(unlocated) buildings without a location are shown in the list only.")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: .capsule)
                }
                let waiting = session.buildings.filter { $0.hasPlace }.count - mapped.filter(\.building.hasPlace).count
                if waiting > 0 {
                    Text("\(waiting) buildings are waiting for their place.")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: .capsule)
                }
            }
            .padding()
        }
        .onChange(of: cameraKey) {
            position = .automatic
        }
        .onChange(of: cameraKey.map { $0.split(separator: "|").first.map(String.init) ?? "" }) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
        // Screen interest in every linked place while the map is shown.
        .task(id: placeIDs) {
            guard !placeIDs.isEmpty else { return }
            await session.places.hold(placeIDs)
        }
    }
}
