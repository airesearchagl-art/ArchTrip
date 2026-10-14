import SwiftUI

/// RF-03: the confirmation screen for deleting a Trip, and the screen a stopped deletion
/// is resumed from (by Trip ID, with or without the Trip still existing). It lists what
/// the server holds under the Trip (read fresh, never from the cache), says that the
/// deletion cannot be undone and that Buildings stay, and only then offers the one
/// destructive action. The deletion does not start while offline, with unsynced writes,
/// or with too many Events; the reason is shown instead. "Deleted" is shown only once
/// the server lists nothing; a stop says what was acknowledged, what is unconfirmed, and
/// what is known about the Trip itself.
struct TripDeletionView: View {
    let tripID: String
    /// The Trip as the list knows it, for the heading; nil when it is already gone.
    let trip: Trip?
    /// Called once the server has confirmed that nothing is left.
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
                        if let trip {
                            Text(verbatim: trip.title)
                                .font(.headline)
                            Text(verbatim: DateFormatting.dateRange(trip.startDate, trip.endDate, locale: locale, calendar: .current))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Trip (deletion in progress)")
                                .font(.headline)
                            Text("ID \(String(tripID.prefix(8)))…")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
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
                                if !summary.tripExists {
                                    Text("The trip is no longer on the server (verified).")
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
                guard run == nil, let uid = session.uid else { return }
                let run = TripDeletionRun(deleter: session.tripDeleter, uid: uid, tripID: tripID, ledger: session.deletionLedger)
                self.run = run
                run.check()
            }
            .onChange(of: state) { _, newState in
                switch newState {
                case .done:
                    session.logTripDeletion("confirmed for trip \(tripID.prefix(8))")
                    onDeleted()
                case .stopped(let stop):
                    session.logTripDeletion("stopped for trip \(tripID.prefix(8)): \(stop.reasonCode) acknowledgedEvents=\(stop.acknowledgedEvents) trip=\(stop.tripStatus.rawValue) recorded=\(stop.needsFollowUp)\(run?.ledgerWarning.map { " [\($0)]" } ?? "")")
                case .blocked(let problem):
                    session.logTripDeletion("not started for trip \(tripID.prefix(8)): \(problem)\(run?.ledgerWarning.map { " [\($0)]" } ?? "")")
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
                if !summary.tripExists {
                    Text("Delete the \(summary.eventCount) remaining events")
                } else if summary.eventCount == 0 {
                    Text("Delete Trip")
                } else {
                    Text("Delete trip and \(summary.eventCount) events")
                }
            }
        case .deleting(let acknowledged, let total):
            HStack(spacing: 8) {
                ProgressView()
                Text("Deleting… \(acknowledged) of \(total)")
            }
            .foregroundStyle(.secondary)
        case .stopped(let stop):
            stopRows(stop)
            Button("Check again") { run?.checkAgain() }
            Text("Check again waits for queued writes, then lists the server; only what is still there can be deleted.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if stop.needsFollowUp {
                Text("This deletion is kept in the trip list until the server confirms it, also after a restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .done:
            Label("Deleted", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        }
    }

    /// What stopped the run, what the server acknowledged, and what is known about the
    /// Trip. Acknowledged counts are the only ones called "deleted"; a batch without an
    /// acknowledgement is unconfirmed; the Trip's own line comes from listings and
    /// acknowledgements only, never from the absence of one.
    @ViewBuilder
    private func stopRows(_ stop: TripDeletion.Stop) -> some View {
        switch stop.reason {
        case .batchFailed(let problem):
            Label(Self.text(for: problem), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text("Deletion stopped.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .batchUnconfirmed(let events, let includesTrip):
            Label {
                if includesTrip {
                    Text("No reply from the server. A sent batch (\(events) events and the trip) may still apply once connected.")
                } else {
                    Text("No reply from the server. A sent batch (\(events) events) may still apply once connected.")
                }
            } icon: {
                Image(systemName: "clock.badge.questionmark")
            }
            .foregroundStyle(.orange)
        case .verificationFailed(let problem):
            Label("The result couldn't be verified on the server. Check again before assuming anything was deleted.", systemImage: "questionmark.circle")
                .foregroundStyle(.orange)
            Text(Self.text(for: problem))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .leftovers(let events, let tripExists):
            Label {
                if tripExists {
                    Text("\(events) events and the trip are still there after verification.")
                } else {
                    Text("\(events) events are still there after verification.")
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .foregroundStyle(.orange)
        }
        if stop.tripStatus == .deletionAcknowledged {
            Text("Confirmed deleted: \(stop.acknowledgedEvents) events and the trip")
        } else {
            Text("Confirmed deleted: \(stop.acknowledgedEvents) events")
        }
        Text(Self.text(for: stop.tripStatus))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    static func text(for status: TripDeletion.TripStatus) -> LocalizedStringKey {
        switch status {
        case .present: "The trip is still on the server (last listing)."
        case .deletionAcknowledged: "The server acknowledged the trip's deletion. Remaining events are deleted after checking again."
        case .verifiedGone: "The trip is no longer on the server (verified)."
        case .unknown: "Whether the trip is deleted is not confirmed."
        }
    }

    static func text(for problem: TripDeletion.Problem) -> LocalizedStringKey {
        switch problem {
        case .unsyncedWrites: "Not in sync with the server (offline, or changes not sent yet). Check the connection and try again once synced."
        case .offline: "Can't delete while offline. Connect and try again."
        case .denied: "The server rejected the deletion."
        case .noReply: "No reply from the server. The deletion may still complete once connected. Check again."
        case .tooManyEvents(let count): "This trip has too many events to delete here (\(count))."
        case .ledgerUnavailable: "Can't save the deletion record on this device, so the deletion won't start."
        case .other(let domain, let code): "Couldn't delete (\(domain) \(code))."
        }
    }
}

/// A row in the Trip list for a deletion that stopped after something was sent: the
/// Trip ID, what is known, and the way back into the confirmation screen.
struct PendingTripDeletionRow: View {
    let record: PendingTripDeletion
    let resume: () -> Void

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text("Deletion of trip \(String(record.tripID.prefix(8)))… stopped before the server confirmed it.")
            } icon: {
                Image(systemName: "trash.slash")
            }
            .foregroundStyle(.orange)
            Text(TripDeletionView.text(for: record.tripStatus))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Confirmed deleted: \(record.acknowledgedEvents) events")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Last attempt \(DateFormatting.time(record.updatedAt, locale: locale))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Resume") { resume() }
                .font(.subheadline)
                .buttonStyle(.borderless)
        }
        .multilineTextAlignment(.leading)
    }
}
