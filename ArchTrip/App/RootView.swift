import SwiftUI

struct RootView: View {
    @Environment(AppSession.self) private var session
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text(verbatim: "ArchTrip"))
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showingSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                }
                .navigationDestination(for: TripRoute.self) { route in
                    TripDashboardView(tripID: route.tripID)
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

    @ViewBuilder
    private var content: some View {
        switch session.state {
        case .notConfigured:
            ContentUnavailableView(
                "Setup incomplete",
                systemImage: "exclamationmark.triangle",
                description: Text("This build has no server configuration.")
            )
        case .connecting:
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
        case .ready:
            TripListView()
        }
    }
}

struct TripRoute: Hashable {
    let tripID: String
}
