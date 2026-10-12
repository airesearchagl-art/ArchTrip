import SwiftUI

struct RootView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false

    var body: some View {
        content
            // Place lookups (v0.2): retry shown failures once on return to the foreground,
            // and drop values nobody is showing under memory pressure.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { session.places.handleForeground() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                session.places.discardUndisplayed()
            }
    }

    private var content: some View {
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
        case .signedOut:
            SignInView()
        }
    }
}

struct TripRoute: Hashable {
    let tripID: String
}

struct BuildingRoute: Hashable {
    let buildingID: String
}
