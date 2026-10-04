import SwiftUI

struct RootView: View {
    @Environment(AppSession.self) private var session
    @State private var showingSettings = false

    var body: some View {
        Group {
            if case .ready = session.state {
                TabView {
                    Tab("Trips", systemImage: "suitcase") {
                        NavigationStack {
                            TripListView()
                                .navigationTitle(Text(verbatim: "ArchTrip"))
                                .toolbar { settingsButton }
                                .navigationDestination(for: TripRoute.self) { route in
                                    TripDashboardView(tripID: route.tripID)
                                }
                        }
                    }
                    Tab("Architecture", systemImage: "building.columns") {
                        NavigationStack {
                            ArchitectureView()
                                .toolbar { settingsButton }
                                .navigationDestination(for: BuildingRoute.self) { route in
                                    BuildingDetailView(buildingID: route.buildingID)
                                }
                        }
                    }
                }
            } else {
                NavigationStack {
                    statusContent
                        .navigationTitle(Text(verbatim: "ArchTrip"))
                        .toolbar { settingsButton }
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .alert(
            "Couldn't save changes",
            isPresented: Binding(
                get: { session.saveFailure != nil },
                set: { if !$0 { session.dismissSaveFailure() } }
            )
        ) {
            Button("OK") { session.dismissSaveFailure() }
        } message: {
            Text("The server didn't accept the change, so it was undone on this device.")
        }
    }

    private var settingsButton: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showingSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch session.state {
        case .notConfigured:
            ContentUnavailableView(
                "Setup incomplete",
                systemImage: "exclamationmark.triangle",
                description: Text("This build has no server configuration.")
            )
        case .connecting, .ready:
            ProgressView("Connecting…")
        case .failed:
            ContentUnavailableView {
                Label("Couldn't connect", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check your network connection and try again.")
            } actions: {
                Button("Try Again") {
                    Task { await session.signIn() }
                }
            }
        }
    }
}

struct TripRoute: Hashable {
    let tripID: String
}

struct BuildingRoute: Hashable {
    let buildingID: String
}
