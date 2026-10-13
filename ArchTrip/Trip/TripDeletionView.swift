import SwiftUI

/// RF-03: the confirmation screen for deleting a Trip. It lists what the server holds
/// under the Trip (read fresh, never from the cache), says that the deletion cannot be
/// undone and that Buildings stay, and only then offers the one destructive action.
/// The deletion does not start while offline, with unsynced writes, or with too many
/// Events; the reason is shown instead.
struct TripDeletionView: View {
    let trip: Trip
    /// Called once the server has acknowledged every batch.
    let onDeleted: () -> Void

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var run: TripDeletionRun?

    private var state: TripDeletionRun.State { run?.state ?? .idle }

    private var isDeleting: Bool {
        if case .deleting = state { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: trip.title)
                            .font(.headline)
                        Text(verbatim: DateFormatting.dateRange(trip.startDate, trip.endDate, locale: locale, calendar: .current))
                            .foregroundStyle(.secondary)
                    }
                    if case .ready(let summary) = state {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(summary.eventCount) events")
                                if summary.unreadableEventCount > 0 {
                                    Text("\(summary.unreadableEventCount) of them can't be read and will be deleted too.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "calendar")
                        }
                    }
                    Label("Buildings are kept. They're shared across trips.", systemImage: "building.columns")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("What will be deleted")
                }
                Section {
                    Label("This can't be undone.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Section {
                    actionRows
                }
            }
            .navigationTitle("Delete this trip?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        run?.cancel()
                        dismiss()
                    }
                    .disabled(isDeleting)
                }
            }
            .interactiveDismissDisabled(isDeleting)
            .task {
                guard run == nil, let uid = session.uid, let store = session.store else { return }
                let run = TripDeletionRun(deleter: store, uid: uid, tripID: trip.id)
                self.run = run
                run.check()
            }
            .onChange(of: state) { _, newState in
                switch newState {
                case .done:
                    session.logTripDeletion("completed for trip \(trip.id.prefix(8))")
                    onDeleted()
                case .failed(let problem, let deleted):
                    session.logTripDeletion("stopped for trip \(trip.id.prefix(8)) after \(deleted) events: \(problem)")
                case .blocked(let problem):
                    session.logTripDeletion("not started for trip \(trip.id.prefix(8)): \(problem)")
                default:
                    break
                }
            }
            .onDisappear { run?.cancel() }
        }
    }

    @ViewBuilder
    private var actionRows: some View {
        switch state {
        case .idle, .checking:
            HStack(spacing: 8) {
                ProgressView()
                Text("Checking the server…")
            }
            .foregroundStyle(.secondary)
        case .blocked(let problem):
            Label(Self.text(for: problem), systemImage: "xmark.octagon")
                .foregroundStyle(.orange)
            Button("Check again") { run?.checkAgain() }
        case .ready(let summary):
            Button(role: .destructive) {
                run?.delete()
            } label: {
                if summary.eventCount == 0 {
                    Text("Delete Trip")
                } else {
                    Text("Delete trip and \(summary.eventCount) events")
                }
            }
        case .deleting(let done, let total):
            HStack(spacing: 8) {
                ProgressView()
                Text("Deleting… \(done) of \(total)")
            }
            .foregroundStyle(.secondary)
        case .failed(let problem, let deleted):
            Label(Self.text(for: problem), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text("Deletion stopped after \(deleted) events. The trip stays until all its events are gone.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Retry") { run?.checkAgain() }
        case .done:
            Label("Deleted", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        }
    }

    static func text(for problem: TripDeletion.Problem) -> LocalizedStringKey {
        switch problem {
        case .unsyncedWrites: "Not in sync with the server (offline, or changes not sent yet). Check the connection and try again once synced."
        case .offline: "Can't delete while offline. Connect and try again."
        case .denied: "The server rejected the deletion."
        case .noReply: "No reply from the server. The deletion may still complete once connected. Check again."
        case .tooManyEvents(let count): "This trip has too many events to delete here (\(count))."
        case .other(let domain, let code): "Couldn't delete (\(domain) \(code))."
        }
    }
}
