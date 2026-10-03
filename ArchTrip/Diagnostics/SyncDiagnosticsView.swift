import SwiftUI

/// Developer-only Firebase sync diagnostics (moved from the G1 spike screen).
/// Intentionally English and technical; reachable only via Settings.
struct SyncDiagnosticsView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        List {
            Section {
                row("Auth", value: authLabel)
            } header: {
                Text(verbatim: "Firebase")
            }

            if session.uid != nil {
                Section {
                    row("Snapshot", value: session.tripsFromCache ? "cache" : "server")
                    row("Pending writes", value: session.tripsHavePendingWrites ? "yes" : "no")
                    row("Trips", value: "\(session.trips.count)")
                    row("Decode failures", value: "\(session.tripFailures.count)")
                    Toggle(isOn: Binding(
                        get: { session.isNetworkEnabled },
                        set: { enabled in Task { await session.setNetworkEnabled(enabled) } }
                    )) {
                        Text(verbatim: "Firestore network")
                    }
                    Button {
                        session.saveTrip(Trip.makeTest())
                    } label: {
                        Text(verbatim: "Create Test Trip")
                    }
                    Button {
                        Task { await session.readTripsForDiagnostics() }
                    } label: {
                        Text(verbatim: "Read Trips")
                    }
                } header: {
                    Text(verbatim: "Sync")
                }
            }

            Section {
                ForEach(Array(session.log.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line).font(.caption.monospaced())
                }
            } header: {
                Text(verbatim: "Log")
            }
        }
        .navigationTitle("Developer Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, value: String) -> some View {
        LabeledContent {
            Text(verbatim: value)
        } label: {
            Text(verbatim: title)
        }
    }

    private var authLabel: String {
        switch session.state {
        case .notConfigured: "Firebase not configured"
        case .connecting: "Signing in…"
        case .ready(let uid): "anonymous uid \(uid.prefix(8))…"
        case .failed: "Sign-in failed"
        }
    }
}
