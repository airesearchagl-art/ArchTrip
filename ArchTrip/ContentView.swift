import SwiftUI

/// G1 developer spike screen. Not production UI.
struct ContentView: View {
    @Environment(SyncSpikeModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section("Auth") {
                    LabeledContent("Status", value: authLabel)
                    if case .signedOut = model.authState {
                        Button("Sign In Anonymously") { Task { await model.signIn() } }
                    }
                    if case .failed = model.authState {
                        Button("Retry Sign In") { Task { await model.signIn() } }
                    }
                }

                if model.uid != nil {
                    Section("Sync") {
                        LabeledContent("Snapshot", value: model.isFromCache ? "cache" : "server")
                        LabeledContent("Pending writes", value: model.hasPendingWrites ? "yes" : "no")
                        Toggle("Firestore network", isOn: Binding(
                            get: { model.isNetworkEnabled },
                            set: { enabled in Task { await model.setNetworkEnabled(enabled) } }
                        ))
                        Button("Create Test Trip") { model.createTestTrip() }
                        Button("Read Trips") { Task { await model.readTrips() } }
                    }

                    Section("Trips (\(model.trips.count))") {
                        ForEach(model.trips) { trip in
                            VStack(alignment: .leading) {
                                Text(trip.title)
                                Text("\(trip.destination) · \(trip.startDate.formatted(date: .abbreviated, time: .omitted))–\(trip.endDate.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Log") {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle("G1 Sync Spike")
        }
    }

    private var authLabel: String {
        switch model.authState {
        case .notConfigured: "Firebase not configured"
        case .signedOut: "Signed out"
        case .signingIn: "Signing in…"
        case .signedIn(let uid): "uid \(uid.prefix(8))…"
        case .failed(let message): "Failed: \(message)"
        }
    }
}

#Preview {
    ContentView()
        .environment(SyncSpikeModel())
}
