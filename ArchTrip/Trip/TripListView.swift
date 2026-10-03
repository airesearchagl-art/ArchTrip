import SwiftUI

struct TripListView: View {
    @Environment(AppSession.self) private var session
    @State private var showingNewTrip = false

    var body: some View {
        let partition = Trip.partition(session.trips, today: Date(), calendar: .current)
        List {
            if !session.tripFailures.isEmpty {
                DecodeFailureSection(failures: session.tripFailures)
            }
            if session.tripsLoadFailed {
                Label("Couldn't load data", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if !partition.upcoming.isEmpty {
                Section("Upcoming") {
                    ForEach(partition.upcoming) { trip in
                        NavigationLink(value: TripRoute(tripID: trip.id)) {
                            TripCard(trip: trip)
                        }
                    }
                }
            }
            if !partition.past.isEmpty {
                Section("Past") {
                    ForEach(partition.past) { trip in
                        NavigationLink(value: TripRoute(tripID: trip.id)) {
                            TripCard(trip: trip)
                        }
                    }
                }
            }
        }
        .overlay {
            if !session.hasLoadedTrips {
                ProgressView()
            } else if session.trips.isEmpty && session.tripFailures.isEmpty && !session.tripsLoadFailed {
                ContentUnavailableView {
                    Label("No trips yet", systemImage: "suitcase")
                } description: {
                    Text("Add your first business trip.")
                } actions: {
                    Button("Add Trip") { showingNewTrip = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewTrip = true
                } label: {
                    Label("Add Trip", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingNewTrip) {
            TripEditorView(trip: nil)
        }
    }
}

struct TripCard: View {
    let trip: Trip
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: trip.title)
                .font(.headline)
            if !trip.destination.isEmpty {
                Label {
                    Text(verbatim: trip.destination)
                } icon: {
                    Image(systemName: "mappin.and.ellipse")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Text(verbatim: DateFormatting.dateRange(trip.startDate, trip.endDate, locale: locale, calendar: .current))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// Fail-visible notice for documents that exist but could not be read.
struct DecodeFailureSection: View {
    let failures: [DecodeFailure]

    var body: some View {
        Section {
            DisclosureGroup {
                ForEach(failures) { failure in
                    VStack(alignment: .leading) {
                        Text(verbatim: failure.documentID)
                            .font(.caption.monospaced())
                        Text(verbatim: failure.reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            } label: {
                Label("\(failures.count) items couldn't be loaded", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }
}
