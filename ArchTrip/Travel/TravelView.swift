import MapKit
import SwiftUI

/// The two Events a Travel / Free Time gap lies between.
struct TravelTarget: Identifiable {
    let from: Event
    let to: Event

    var id: String { "\(from.id)->\(to.id)" }
}

/// Travel between two Events (MVP): pick the Events, settle both points, a mode and a
/// time, then ask Apple Maps. Car and walking show a route; transit shows an estimated
/// time and opens Apple Maps. Everything the search returns is shown here and nowhere
/// else: no field of any Event, Building or document is written from it.
struct TravelView: View {
    let trip: Trip
    /// The Trip's Events as the dashboard sees them now; a changed or deleted Event
    /// makes a result stale.
    let events: [Event]
    let target: TravelTarget

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var fromID: String
    @State private var toID: String
    @State private var mode: TravelMode = .car
    @State private var anchorIsArrival = false
    @State private var anchorDate: Date
    /// Points picked on the spot for this search only. Dropped with the screen.
    @State private var fromCandidate: PlaceResult?
    @State private var toCandidate: PlaceResult?
    @State private var picking: Side?
    @State private var search = TravelSearch(router: MapKitTravelRouter())

    enum Side: String, Identifiable {
        case from
        case to

        var id: String { rawValue }
    }

    init(trip: Trip, events: [Event], target: TravelTarget) {
        self.trip = trip
        self.events = events
        self.target = target
        _fromID = State(initialValue: target.from.id)
        _toID = State(initialValue: target.to.id)
        _anchorDate = State(initialValue: target.from.endDate)
    }

    // MARK: Inputs

    private var timedEvents: [Event] {
        events.filter(\.isTimed).sorted(by: TimelineBuilder.chronological)
    }

    private var fromEvent: Event? { events.first { $0.id == fromID } }
    private var toEvent: Event? { events.first { $0.id == toID } }

    private func event(_ side: Side) -> Event? {
        side == .from ? fromEvent : toEvent
    }

    private func candidate(_ side: Side) -> PlaceResult? {
        side == .from ? fromCandidate : toCandidate
    }

    private func endpoint(_ side: Side) -> TravelEndpoint? {
        guard let event = event(side) else { return nil }
        if let candidate = candidate(side) { return .candidate(candidate) }
        return TravelEndpoint.resolve(event: event, buildings: session.buildings)
    }

    private var anchor: TravelAnchor {
        anchorIsArrival ? .arriveBy(anchorDate) : .departAt(anchorDate)
    }

    /// Nil when an Event is gone (deleted while this screen is open).
    private var key: TravelRequestKey? {
        guard let from = fromEvent, let to = toEvent, let fromEndpoint = endpoint(.from), let toEndpoint = endpoint(.to) else { return nil }
        return TravelRequestKey(
            fromEventID: from.id, fromEventUpdatedAt: from.updatedAt, from: fromEndpoint,
            toEventID: to.id, toEventUpdatedAt: to.updatedAt, to: toEndpoint,
            mode: mode, anchor: anchor
        )
    }

    /// The point for one side, once its linked place is fetched or a candidate is picked.
    private func point(_ side: Side) -> TravelPoint? {
        switch endpoint(side) {
        case .linkedPlace(let placeID, _, _):
            guard let place = session.places.place(for: placeID) else { return nil }
            return TravelPoint(name: place.name ?? "", latitude: place.latitude, longitude: place.longitude, placeID: placeID)
        case .candidate(let result):
            return TravelPoint(
                name: result.name.isEmpty ? result.address : result.name,
                latitude: result.latitude, longitude: result.longitude, placeID: result.identifier
            )
        case .unresolved, nil:
            return nil
        }
    }

    private var linkedPlaceIDs: Set<String> {
        Set([endpoint(.from), endpoint(.to)].compactMap { endpoint in
            if case .linkedPlace(let placeID, _, _) = endpoint { return placeID }
            return nil
        })
    }

    private var canSearch: Bool {
        key != nil && point(.from) != nil && point(.to) != nil && !search.isSearching
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Form {
                eventsSection
                pointsSection
                modeAndTimeSection
                Section {
                    searchRows
                } footer: {
                    Text("Shown here only. Nothing from this result is saved to the event or the server.")
                }
                resultSection
            }
            .navigationTitle("Travel between events")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        search.cancel()
                        dismiss()
                    }
                }
            }
            .onChange(of: fromID) {
                fromCandidate = nil
                resetAnchorDate()
            }
            .onChange(of: toID) {
                toCandidate = nil
                resetAnchorDate()
            }
            .onChange(of: anchorIsArrival) { resetAnchorDate() }
            // Any change of the inputs abandons a search for the old ones; a result that
            // already arrived is kept and shown as stale.
            .onChange(of: key) {
                if search.isSearching { search.cancel() }
            }
            .sheet(item: $picking) { side in
                TravelCandidatePicker(hint: endpoint(side)?.hint ?? "") { result in
                    if side == .from { fromCandidate = result } else { toCandidate = result }
                }
            }
            // Screen interest in the linked places: fetched while shown, released after.
            .task(id: linkedPlaceIDs) {
                guard !linkedPlaceIDs.isEmpty else { return }
                await session.places.hold(linkedPlaceIDs)
            }
            .onDisappear { search.cancel() }
        }
    }

    private func resetAnchorDate() {
        if anchorIsArrival, let to = toEvent {
            anchorDate = to.startDate
        } else if let from = fromEvent {
            anchorDate = from.endDate
        }
    }

    // MARK: Sections

    private var eventsSection: some View {
        Section {
            Picker("From event", selection: $fromID) {
                ForEach(timedEvents) { event in
                    Text(verbatim: eventLabel(event)).tag(event.id)
                }
            }
            Picker("To event", selection: $toID) {
                ForEach(timedEvents) { event in
                    Text(verbatim: eventLabel(event)).tag(event.id)
                }
            }
        } header: {
            Text("Events")
        }
    }

    private func eventLabel(_ event: Event) -> String {
        "\(DateFormatting.time(event.startDate, locale: locale)) \(event.title)"
    }

    private var pointsSection: some View {
        Section {
            endpointRow(.from, title: "From")
            endpointRow(.to, title: "To")
        } header: {
            Text("Points")
        } footer: {
            if fromCandidate != nil || toCandidate != nil {
                Text("Only for this search. Not saved.")
            }
        }
    }

    @ViewBuilder
    private func endpointRow(_ side: Side, title: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let event = event(side) {
                    Text(verbatim: event.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            switch endpoint(side) {
            case .linkedPlace(let placeID, _, _):
                linkedPlaceRow(placeID)
                Button("Pick another point for this search") { picking = side }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
            case .candidate(let result):
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: result.name.isEmpty ? result.address : result.name)
                        if !result.name.isEmpty, !result.address.isEmpty {
                            Text(verbatim: result.address).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "mappin")
                }
                HStack(spacing: 16) {
                    Button("Change") { picking = side }
                    Button("Clear", role: .destructive) {
                        if side == .from { fromCandidate = nil } else { toCandidate = nil }
                    }
                }
                .font(.subheadline)
                .buttonStyle(.borderless)
            case .unresolved:
                Label("No usable point yet. Pick a candidate for this search.", systemImage: "mappin.slash")
                    .foregroundStyle(.secondary)
                Button("Pick a candidate") { picking = side }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
            case nil:
                Label("This event is no longer available", systemImage: "calendar.badge.exclamationmark")
                    .foregroundStyle(.orange)
            }
        }
        .multilineTextAlignment(.leading)
    }

    @ViewBuilder
    private func linkedPlaceRow(_ placeID: String) -> some View {
        let state = session.places.state(for: placeID)
        switch state {
        case .resolved(let place, _, _):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: place.name ?? "–")
                    if let address = place.address {
                        Text(verbatim: address).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "mappin.circle.fill").foregroundStyle(.green)
            }
        case .idle, .loading:
            PlaceStatusLabel(state: state)
        case .failed:
            PlaceStatusLabel(state: state)
            Button {
                session.places.retry(placeID)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
        }
    }

    private var modeAndTimeSection: some View {
        Section {
            Picker("Mode", selection: $mode) {
                Text("Car").tag(TravelMode.car)
                Text("Walk").tag(TravelMode.walk)
                Text("Transit").tag(TravelMode.transit)
            }
            .pickerStyle(.segmented)
            Picker("Time", selection: $anchorIsArrival) {
                Text("Depart at").tag(false)
                Text("Arrive by").tag(true)
            }
            .pickerStyle(.segmented)
            DatePicker(anchorIsArrival ? "Arrive by" : "Depart at", selection: $anchorDate)
        } header: {
            Text("Mode and time")
        } footer: {
            if mode == .transit {
                Text("Transit: Apple Maps gives an estimated time only. Open Apple Maps for lines and times.")
            }
        }
    }

    @ViewBuilder
    private var searchRows: some View {
        Button {
            guard let key, let from = point(.from), let to = point(.to) else { return }
            search.search(key, from: from, to: to)
        } label: {
            Label("Search route", systemImage: "arrow.triangle.turn.up.right.diamond")
        }
        .disabled(!canSearch)
        if search.isSearching {
            HStack(spacing: 8) {
                ProgressView()
                Text("Searching route…")
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        switch search.state {
        case .idle, .searching:
            EmptyView()
        case .result(let result, let resultKey):
            if let key, resultKey == key {
                Section {
                    resultRows(result)
                } header: {
                    Text("Result")
                } footer: {
                    Text("From Apple Maps, for the time chosen above. Not saved.")
                }
            } else {
                staleSection
            }
        case .failed(let failure, let failedKey):
            if let key, failedKey == key {
                Section {
                    Label(Self.text(for: failure), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Retry") {
                        guard let from = point(.from), let to = point(.to) else { return }
                        search.search(key, from: from, to: to)
                    }
                    .disabled(!canSearch)
                }
            } else {
                staleSection
            }
        }
    }

    private var staleSection: some View {
        Section {
            Label("The inputs changed. Search again.", systemImage: "arrow.clockwise")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func resultRows(_ result: TravelResult) -> some View {
        LabeledContent("Estimated travel time") {
            durationText(TimelineBuilder.hoursAndMinutes(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: result.expectedTravelTime)))
        }
        switch result.kind {
        case .route(let distance, let steps, let path):
            LabeledContent("Distance") { Text(verbatim: Self.distanceText(distance, locale: locale)) }
            timesRows(result)
            if path.count > 1 {
                RoutePreview(path: path, from: point(.from), to: point(.to))
                    .frame(height: 180)
                    .listRowInsets(EdgeInsets())
            }
            if !steps.isEmpty {
                DisclosureGroup {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        Text(verbatim: step).font(.caption)
                    }
                } label: {
                    Text("Directions")
                }
            }
        case .eta(let distance):
            if distance > 0 {
                LabeledContent("Distance") { Text(verbatim: Self.distanceText(distance, locale: locale)) }
            }
            timesRows(result)
            Text("Transit: Apple Maps gives an estimated time only. Open Apple Maps for lines and times.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Button {
            openInAppleMaps(mode: result.mode)
        } label: {
            Label("Open in Apple Maps", systemImage: "map")
        }
    }

    @ViewBuilder
    private func timesRows(_ result: TravelResult) -> some View {
        if let departure = result.expectedDeparture {
            LabeledContent("Departure") { Text(verbatim: DateFormatting.time(departure, locale: locale)) }
        }
        if let arrival = result.expectedArrival {
            LabeledContent("Arrival") { Text(verbatim: DateFormatting.time(arrival, locale: locale)) }
        }
    }

    private func durationText(_ duration: (hours: Int, minutes: Int)) -> Text {
        switch (duration.hours, duration.minutes) {
        case (0, let minutes): Text("\(minutes) min")
        case (let hours, 0): Text("\(hours) hr")
        case (let hours, let minutes): Text("\(hours) hr \(minutes) min")
        }
    }

    static func distanceText(_ meters: CLLocationDistance, locale: Locale) -> String {
        let measurement = Measurement(value: meters, unit: UnitLength.meters)
        return measurement.formatted(.measurement(width: .abbreviated, usage: .road).locale(locale))
    }

    static func text(for failure: PlaceFetchFailure) -> LocalizedStringKey {
        switch failure {
        case .notFound: "No route found."
        case .offline: "Route search needs a network connection."
        case .timeout: "The route search timed out."
        case .throttled: "Too many requests. Try again later."
        case .transport, .server: "Couldn't search the route."
        }
    }

    /// Hands both points to Apple Maps with the chosen mode. A linked place goes as
    /// MapKit's own item when fetched, so Maps shows it by name.
    private func openInAppleMaps(mode: TravelMode) {
        guard let from = mapItem(.from), let to = mapItem(.to) else { return }
        MKMapItem.openMaps(with: [from, to], launchOptions: [MKLaunchOptionsDirectionsModeKey: MapKitTravelRouter.launchDirectionsMode(for: mode)])
    }

    private func mapItem(_ side: Side) -> MKMapItem? {
        if case .linkedPlace(let placeID, _, _) = endpoint(side), let item = session.places.place(for: placeID)?.mapItem {
            return item
        }
        return point(side).map(MapKitTravelRouter.mapItem(for:))
    }
}

/// The route's path on a small, non-interactive map with both ends marked.
private struct RoutePreview: View {
    let path: [TravelCoordinate]
    let from: TravelPoint?
    let to: TravelPoint?

    var body: some View {
        let coordinates = path.map(\.coordinate)
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        Map(initialPosition: .rect(polyline.boundingMapRect.insetBy(dx: -polyline.boundingMapRect.width * 0.15, dy: -polyline.boundingMapRect.height * 0.15))) {
            MapPolyline(coordinates: coordinates)
                .stroke(.blue, lineWidth: 4)
            if let from {
                Marker(from.name, systemImage: "figure.walk.departure", coordinate: from.coordinate)
            }
            if let to {
                Marker(to.name, systemImage: "flag.checkered", coordinate: to.coordinate)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Picks a point for one travel search: the same two-section Apple Maps search as the
/// Building editor, but any result can be chosen (a Place ID is not needed to route to
/// it) and the choice lives only in the travel screen. Nothing is written anywhere.
private struct TravelCandidatePicker: View {
    let hint: String
    let onPick: (PlaceResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var search = PlaceSearch(searcher: MapKitPlaceSearcher())

    init(hint: String, onPick: @escaping (PlaceResult) -> Void) {
        self.hint = hint
        self.onPick = onPick
        _query = State(initialValue: hint)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Search for a place or address", text: $query)
                            .multilineTextAlignment(.leading)
                            .submitLabel(.search)
                            .onSubmit { search.search(query) }
                        if search.isSearching {
                            ProgressView()
                        } else {
                            Button("Search") { search.search(query) }
                                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .buttonStyle(.borderless)
                        }
                    }
                } footer: {
                    Text("Only for this search. Not saved.")
                }
                if search.isActive {
                    resultSection(.pointOfInterest, title: "Places", empty: "No places found.", failed: "Couldn't search places.")
                    resultSection(.address, title: "Addresses", empty: "No addresses found.", failed: "Couldn't search addresses.")
                }
            }
            .navigationTitle("Pick the place for this search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        search.cancel()
                        dismiss()
                    }
                }
            }
            .onChange(of: query) { search.queryChanged(query) }
            .onDisappear { search.cancel() }
            .task {
                // The suggested query is searched for convenience; the user still picks.
                if !hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { search.search(hint) }
            }
        }
    }

    private func resultSection(
        _ kind: PlaceSearchKind, title: LocalizedStringKey, empty: LocalizedStringKey, failed: LocalizedStringKey
    ) -> some View {
        Section {
            switch search.state(of: kind) {
            case .idle:
                EmptyView()
            case .searching:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching…")
                }
                .foregroundStyle(.secondary)
            case .empty:
                Text(empty).foregroundStyle(.secondary)
            case .failed:
                Label(failed, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            case .results(let results):
                ForEach(results) { result in
                    Button {
                        onPick(result)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: result.name.isEmpty ? result.address : result.name).foregroundStyle(.primary)
                            if !result.name.isEmpty, !result.address.isEmpty {
                                Text(verbatim: result.address).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .multilineTextAlignment(.leading)
                    }
                }
            }
        } header: {
            Text(title)
        }
    }
}
