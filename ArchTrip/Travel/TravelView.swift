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
///
/// A point the user picks is kept on the Event as its travel point (`TravelPointSetting`):
/// the result's Place ID, or, for a result without one, the search text the user typed.
/// It is written by its own two-field update and shown again by every travel search the
/// Event appears in; the setting on screen is always what the listener delivers, and its
/// save state ("syncing", "saved", "save failed") comes from the server's reply.
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
    /// Results picked on this screen, each bound to the Event and to the setting it was
    /// picked against (`TravelPickedCandidate`): shown while the Event still holds that
    /// setting or the one the pick requested, dropped when the listener delivers anything
    /// else or the write fails. Dropped with the screen.
    @State private var fromCandidate: TravelPickedCandidate?
    @State private var toCandidate: TravelPickedCandidate?
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

    private func candidate(_ side: Side) -> TravelPickedCandidate? {
        side == .from ? fromCandidate : toCandidate
    }

    private func setCandidate(_ candidate: TravelPickedCandidate?, _ side: Side) {
        if side == .from { fromCandidate = candidate } else { toCandidate = candidate }
    }

    /// Follows the listener for each picked result: records that the setting its pick
    /// requested has been delivered, and drops it once the Event holds anything else
    /// (another screen or device changed, cleared or broke the setting, or reverted it
    /// after the reflection), so nothing new is hidden behind an old candidate.
    private func reconcileCandidates() {
        for side in [Side.from, .to] {
            guard let candidate = candidate(side) else { continue }
            setCandidate(event(side).flatMap { candidate.reconciled(with: $0) }, side)
        }
    }

    /// What the Event and its Building hold, as the listener delivers them.
    private func stored(_ side: Side) -> TravelEndpoint? {
        guard let event = event(side) else { return nil }
        return TravelEndpoint.resolve(event: event, buildings: session.buildings)
    }

    private func endpoint(_ side: Side) -> TravelEndpoint? {
        guard let event = event(side), let stored = stored(side) else { return nil }
        return TravelEndpoint.shown(stored: stored, candidate: candidate(side), event: event)
    }

    /// The Building's place, whatever the Event's own setting: what "Back to the
    /// building's place" returns to.
    private func buildingDefault(_ side: Side) -> TravelEndpoint? {
        guard let event = event(side) else { return nil }
        return TravelEndpoint.buildingDefault(event: event, buildings: session.buildings)
    }

    private func writeStatus(_ side: Side) -> TravelPointWriteTracker.Status? {
        guard let event = event(side) else { return nil }
        return session.travelPointWrites.status(for: event.id)
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

    /// The point for one side, once its place is fetched or a result is picked.
    private func point(_ side: Side) -> TravelPoint? {
        switch endpoint(side) {
        case .linkedPlace(let placeID, _, _), .savedPlace(let placeID):
            guard let place = session.places.place(for: placeID) else { return nil }
            return TravelPoint(name: place.name ?? "", latitude: place.latitude, longitude: place.longitude, placeID: placeID)
        case .candidate(let result):
            return TravelPoint(
                name: result.name.isEmpty ? result.address : result.name,
                latitude: result.latitude, longitude: result.longitude, placeID: result.identifier
            )
        case .savedQuery, .unreadableSetting, .unresolved, nil:
            return nil
        }
    }

    /// Place IDs fetched while shown: linked Buildings' and saved points'.
    private var heldPlaceIDs: Set<String> {
        Set([endpoint(.from), endpoint(.to)].compactMap { endpoint in
            switch endpoint {
            case .linkedPlace(let placeID, _, _), .savedPlace(let placeID): placeID
            default: nil
            }
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
            // What the listener delivers decides what is shown; an old candidate never
            // covers a setting that changed elsewhere.
            .onChange(of: events) { reconcileCandidates() }
            .onChange(of: anchorIsArrival) { resetAnchorDate() }
            // Any change of the inputs abandons a search for the old ones; a result that
            // already arrived is kept and shown as stale.
            .onChange(of: key) {
                if search.isSearching { search.cancel() }
            }
            // A rejected save: the listener restores the stored setting, and the picked
            // result is no longer shown as if it were the point.
            .onChange(of: writeStatus(.from)) { _, status in
                if status == .failed { fromCandidate = nil }
            }
            .onChange(of: writeStatus(.to)) { _, status in
                if status == .failed { toCandidate = nil }
            }
            .sheet(item: $picking) { side in
                TravelCandidatePicker(source: endpoint(side)?.querySource ?? .empty) { result, outcome in
                    apply(outcome, result: result, to: side)
                }
            }
            // Screen interest in the places: fetched while shown, released after.
            .task(id: heldPlaceIDs) {
                guard !heldPlaceIDs.isEmpty else { return }
                await session.places.hold(heldPlaceIDs)
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

    /// What the picker decided: a Place ID or typed search text is written to the Event
    /// unless it already holds the same; a result used for this search only writes nothing.
    private func apply(_ outcome: TravelPickOutcome, result: PlaceResult, to side: Side) {
        guard let event = event(side) else { return }
        switch outcome {
        case .savePlace(let id):
            if event.travelPoint != .place(id: id) { session.setTravelPoint(.place(id: id), for: event) }
        case .saveQuery(let text):
            if event.travelPoint != .query(text) { session.setTravelPoint(.query(text), for: event) }
        case .thisSearchOnly:
            break
        }
        setCandidate(TravelPickedCandidate(result: result, outcome: outcome, eventID: event.id, settingAtPick: event.travelPoint), side)
    }

    /// Clears the Event's saved travel point (its own two-field update); the Building's
    /// place or nothing is used again. Sent only when the listener shows a setting to
    /// clear. This is not the same as dropping a result picked for this search.
    private func clearSetting(_ side: Side) {
        guard let event = event(side), event.travelPoint != nil else { return }
        session.setTravelPoint(nil, for: event)
        setCandidate(nil, side)
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
            Text("Only the ID of the chosen result, or the search text you typed, is saved. Names, addresses, coordinates, routes and travel times are not.")
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
                placeRow(placeID)
                statusRow(side)
                Button("Pick another point") { picking = side }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
            case .savedPlace(let placeID):
                placeRow(placeID)
                Text("Saved point, fetched from its ID")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if buildingDefault(side) != nil {
                    Label("Using the chosen point instead of the building's place", systemImage: "pin")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                limitRow(side)
                statusRow(side)
                settingButtons(side, change: "Change")
            case .savedQuery:
                Label("Previous search text restored. Pick a candidate again (the candidate itself isn't saved).", systemImage: "magnifyingglass")
                    .foregroundStyle(.secondary)
                if buildingDefault(side) != nil {
                    Label("Using the chosen point instead of the building's place", systemImage: "pin")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                limitRow(side)
                statusRow(side)
                settingButtons(side, change: "Pick a candidate")
            case .unreadableSetting(let reason):
                Label("The saved point can't be read (invalid format). The building's place is not used automatically.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(verbatim: reason)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                statusRow(side)
                settingButtons(side, change: "Pick a candidate")
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
                outcomeRow(side)
                statusRow(side)
                // Two different things can be cleared here: the result picked for this
                // search (screen only), and, when the Event holds a setting (a saved
                // query, or one the pick did not touch), that saved setting itself.
                HStack(spacing: 16) {
                    Button("Change") { picking = side }
                    Button("Clear this search's candidate", role: .destructive) { setCandidate(nil, side) }
                }
                .font(.subheadline)
                .buttonStyle(.borderless)
                if event(side)?.travelPoint != nil {
                    clearSettingButton(side)
                }
            case .unresolved:
                Label("No usable point yet. Pick a candidate for this search.", systemImage: "mappin.slash")
                    .foregroundStyle(.secondary)
                statusRow(side)
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

    /// Change or clear the Event's saved setting. The clear button says where it goes back
    /// to: the Building's place when the Building has one, else nothing.
    private func settingButtons(_ side: Side, change: LocalizedStringKey) -> some View {
        HStack(spacing: 16) {
            Button(change) { picking = side }
            clearSettingButton(side)
        }
        .font(.subheadline)
        .buttonStyle(.borderless)
    }

    /// Clears the Event's saved setting; the title says where that goes back to.
    private func clearSettingButton(_ side: Side) -> some View {
        let clearTitle: LocalizedStringKey = buildingDefault(side) != nil ? "Back to the building's place" : "Clear the point setting"
        return Button(clearTitle, role: .destructive) { clearSetting(side) }
            .font(.subheadline)
            .buttonStyle(.borderless)
    }

    /// A stored value over this version's bound: shown and used, but the Event cannot be
    /// saved by the editor until it is cleared.
    @ViewBuilder
    private func limitRow(_ side: Side) -> some View {
        if let setting = event(side)?.travelPoint, setting.exceedsWriteLimit {
            switch setting {
            case .place:
                Text("The saved place ID is longer than this version's limit (128 characters). It can be shown and used for routes, but clear it before saving edits to this event.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .query:
                Text("The saved search text is longer than this version's limit (200 characters). Clear it before saving edits to this event.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .unreadable:
                EmptyView()
            }
        }
    }

    /// The server's verdict on the latest write for this Event, never the local cache.
    @ViewBuilder
    private func statusRow(_ side: Side) -> some View {
        switch writeStatus(side) {
        case .syncing:
            Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .saved:
            Label("Saved", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed:
            Label("Save failed", systemImage: "xmark.octagon")
                .font(.caption)
                .foregroundStyle(.orange)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private func outcomeRow(_ side: Side) -> some View {
        switch candidate(side)?.outcome {
        case .saveQuery:
            Text("Only the search text you typed is saved. You'll pick a candidate again next time.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .thisSearchOnly(.notSaved):
            Text("Only for this search. Not saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .thisSearchOnly(.identifierTooLong):
            Text("This result's ID is too long to save. It's used for this search only.")
                .font(.caption)
                .foregroundStyle(.orange)
        case .savePlace, nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private func placeRow(_ placeID: String) -> some View {
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

    /// Hands both points to Apple Maps with the chosen mode. A fetched place goes as
    /// MapKit's own item, so Maps shows it by name.
    private func openInAppleMaps(mode: TravelMode) {
        guard let from = mapItem(.from), let to = mapItem(.to) else { return }
        MKMapItem.openMaps(with: [from, to], launchOptions: [MKLaunchOptionsDirectionsModeKey: MapKitTravelRouter.launchDirectionsMode(for: mode)])
    }

    private func mapItem(_ side: Side) -> MKMapItem? {
        switch endpoint(side) {
        case .linkedPlace(let placeID, _, _), .savedPlace(let placeID):
            if let item = session.places.place(for: placeID)?.mapItem { return item }
        default:
            break
        }
        guard let point = point(side) else { return nil }
        return MapKitTravelRouter.mapItem(for: point)
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
/// it). A result with an ID saves that ID; one without first asks, in its own field, for
/// the search text to save, pre-filled only with the user's own words (never with the
/// Event's auto-filled text or an Apple result's name or address) and skipped at will.
private struct TravelCandidatePicker: View {
    let source: TravelQuerySource
    let onPick: (PlaceResult, TravelPickOutcome) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var search: PlaceSearch
    /// A result without an ID, waiting for the user to say what, if anything, to save.
    @State private var pendingPick: PlaceResult?
    @State private var saveText = ""

    init(source: TravelQuerySource, onPick: @escaping (PlaceResult, TravelPickOutcome) -> Void) {
        self.source = source
        self.onPick = onPick
        _query = State(initialValue: source.text)
        var searcher: any PlaceSearching = MapKitPlaceSearcher()
        #if DEBUG
        searcher = TravelPointFaults.searcher(wrapping: searcher)
        #endif
        _search = State(initialValue: PlaceSearch(searcher: searcher))
    }

    private var saveIssue: TravelQueryProvenance.Issue? {
        TravelQueryProvenance.issue(saveText)
    }

    var body: some View {
        let title: LocalizedStringKey = pendingPick == nil ? "Pick the place for this search" : "Save the search text?"
        NavigationStack {
            Form {
                if let pending = pendingPick {
                    saveSections(pending)
                } else {
                    searchSections
                }
            }
            .navigationTitle(title)
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
                if !TravelQueryProvenance.trimmed(source.text).isEmpty { search.search(source.text) }
            }
        }
    }

    @ViewBuilder
    private var searchSections: some View {
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
                        .disabled(TravelQueryProvenance.trimmed(query).isEmpty)
                        .buttonStyle(.borderless)
                }
            }
        } footer: {
            Text("Used for searching only. What is saved is decided after you pick a result.")
        }
        if search.isActive {
            resultSection(.pointOfInterest, title: "Places", empty: "No places found.", failed: "Couldn't search places.")
            resultSection(.address, title: "Addresses", empty: "No addresses found.", failed: "Couldn't search addresses.")
        }
    }

    /// The separate field for the search text to save. It starts with the user's own text
    /// only (`TravelQueryProvenance.prefill`); there is no way for the chosen result's
    /// name or address to get into it other than the user typing.
    @ViewBuilder
    private func saveSections(_ result: PlaceResult) -> some View {
        Section {
            resultLabel(result)
        } header: {
            Text("Chosen result")
        }
        Section {
            TextField("Search text to save", text: $saveText, axis: .vertical)
                .lineLimit(1...3)
            if saveIssue == .tooLong {
                Text("The search text is too long (200 characters max).")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("This result has no ID, so only the search text you type can be saved. Next time it comes back into the search field and you pick a candidate again.")
                if saveIssue == .empty, source != .empty {
                    Text("The search text is auto-filled and isn't saved. Type the search text yourself to save it.")
                }
            }
        }
        Section {
            Button("Save and use") {
                onPick(result, .saveQuery(TravelQueryProvenance.trimmed(saveText)))
                dismiss()
            }
            .disabled(saveIssue != nil)
            Button("Use for this search only") {
                onPick(result, .thisSearchOnly(.notSaved))
                dismiss()
            }
            Button("Back") { pendingPick = nil }
        }
    }

    /// A result with an ID decides itself; one without goes to the save step.
    private func choose(_ result: PlaceResult) {
        if let outcome = TravelQueryProvenance.outcome(for: result) {
            onPick(result, outcome)
            dismiss()
        } else {
            saveText = TravelQueryProvenance.prefill(source: source, searchText: query)
            pendingPick = result
        }
    }

    private func resultLabel(_ result: PlaceResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: result.name.isEmpty ? result.address : result.name).foregroundStyle(.primary)
            if !result.name.isEmpty, !result.address.isEmpty {
                Text(verbatim: result.address).font(.caption).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.leading)
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
                        choose(result)
                    } label: {
                        resultLabel(result)
                    }
                }
            }
        } header: {
            Text(title)
        }
    }
}
