import SwiftUI

struct BuildingEditorView: View {
    let existing: Building?

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var architect: String
    @State private var yearText: String
    @State private var address: String
    @State private var latitude: Double?
    @State private var longitude: Double?
    @State private var visitMinutes: Int
    @State private var priority: Int
    @State private var visited: Bool
    @State private var note: String
    /// The Apple Maps Place ID, kept exactly as MapKit gave it (v0.2).
    @State private var applePlaceId: String?

    @State private var query = ""
    @State private var results: [PlaceResult] = []
    @State private var isSearching = false
    @State private var searchFailed = false
    /// A tapped result awaiting confirmation. Discarded by Back; nothing is kept from it.
    @State private var pendingCandidate: PlaceResult?
    /// The result linked in this editing session, only for showing its name while the
    /// editor is open. It never enters the directory: after a save, the place is fetched
    /// again like any other, once the stored Building is shown. Dropped with the editor.
    @State private var linkedCandidate: PlaceResult?
    @State private var confirmingUnlink = false
    @State private var hasSaved = false

    init(building: Building?) {
        existing = building
        _name = State(initialValue: building?.name ?? "")
        _architect = State(initialValue: building?.architect ?? "")
        _yearText = State(initialValue: building?.completedYear.map(String.init) ?? "")
        _address = State(initialValue: building?.address ?? "")
        _latitude = State(initialValue: building?.latitude)
        _longitude = State(initialValue: building?.longitude)
        _visitMinutes = State(initialValue: building?.visitMinutes ?? Building.defaultVisitMinutes)
        _priority = State(initialValue: building?.priority ?? Building.defaultPriority)
        _visited = State(initialValue: building?.visited ?? false)
        _note = State(initialValue: building?.note ?? "")
        _applePlaceId = State(initialValue: building?.applePlaceId)
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var completedYear: Int? { Int(trimmed(yearText)) }

    private var draft: Building {
        let now = Date()
        let createdAt = existing?.createdAt ?? now
        return Building(
            id: existing?.id ?? UUID().uuidString,
            name: trimmed(name),
            architect: trimmed(architect),
            completedYear: trimmed(yearText).isEmpty ? nil : completedYear,
            address: trimmed(address),
            latitude: latitude,
            longitude: longitude,
            visitMinutes: visitMinutes,
            priority: priority,
            visited: visited,
            note: trimmed(note),
            createdAt: createdAt,
            updatedAt: max(now, createdAt),
            applePlaceId: applePlaceId
        )
    }

    private var issue: LocalizedStringKey? {
        if trimmed(name).isEmpty { return "Enter a name." }
        if !trimmed(yearText).isEmpty, completedYear.map(Building.completedYearRange.contains) != true {
            return "Enter a valid year."
        }
        let draft = draft
        if !draft.isValid { return "Some fields are too long." }
        if draft.applePlaceIdExceedsLimit {
            return "This place ID can't be saved by this version. Unlink the place or update the app."
        }
        return nil
    }

    /// Stored address or coordinates that a linked Building does not display.
    private var hasUnusedStoredLocation: Bool {
        applePlaceId != nil && (latitude != nil || !trimmed(address).isEmpty)
    }

    var body: some View {
        let navigationTitle: LocalizedStringKey = existing == nil ? "New Building" : "Edit Building"
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Name") {
                        TextField("Name", text: $name, prompt: Text("e.g. Sapporo Concert Hall Kitara"))
                    }
                    LabeledContent("Architect") {
                        TextField("Architect", text: $architect)
                    }
                    LabeledContent("Completed year") {
                        TextField("Completed year", text: $yearText, prompt: Text("e.g. 1997"))
                            .keyboardType(.numberPad)
                    }
                    LabeledContent("Address") {
                        TextField("Address", text: $address, axis: .vertical)
                    }
                    if latitude != nil, longitude != nil {
                        HStack {
                            Label("Location set", systemImage: "mappin.circle.fill")
                                .foregroundStyle(applePlaceId == nil ? .green : .secondary)
                            Spacer()
                            Button("Clear", role: .destructive) {
                                latitude = nil
                                longitude = nil
                            }
                            .buttonStyle(.borderless)
                        }
                    } else if applePlaceId == nil {
                        Label("No location", systemImage: "mappin.slash")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    if let issue {
                        Text(issue).foregroundStyle(.red)
                    } else if hasUnusedStoredLocation {
                        Text("The stored address and coordinates aren't used while a place is linked. Unlinking shows them again.")
                    }
                }
                placeSection
                Section {
                    Stepper(value: $visitMinutes, in: Building.visitMinutesRange, step: 15) {
                        LabeledContent("Visit duration") {
                            Text("\(visitMinutes) min")
                        }
                    }
                    Picker("Priority", selection: $priority) {
                        Text("High").tag(3)
                        Text("Normal").tag(2)
                        Text("Low").tag(1)
                    }
                    Toggle("Visited", isOn: $visited)
                }
                Section {
                    TextField("Note", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                        .multilineTextAlignment(.leading)
                }
            }
            .multilineTextAlignment(.trailing)
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(issue != nil)
                }
            }
            .sheet(item: $pendingCandidate) { candidate in
                PlaceCandidateView(
                    candidate: candidate,
                    duplicates: PlaceLink.duplicates(of: candidate.allIdentifiers, in: session.buildings, excluding: existing?.id),
                    onLink: { link(candidate) },
                    onBack: { pendingCandidate = nil }
                )
            }
            .confirmationDialog("Unlink this place?", isPresented: $confirmingUnlink, titleVisibility: .visible) {
                Button("Unlink place", role: .destructive) {
                    applePlaceId = nil
                    linkedCandidate = nil
                }
            } message: {
                if latitude != nil || !trimmed(address).isEmpty {
                    Text("Unlinking shows the stored address and coordinates again.")
                } else {
                    Text("Unlinking leaves this building without a location.")
                }
            }
        }
    }

    // MARK: Apple Maps place (v0.2)

    /// Search Apple Maps and link one result by its Place ID. Nothing else from the result
    /// is copied into the Building: no name, address or coordinates (Option A / D-022).
    /// Results without a usable ID are shown but cannot be linked.
    private var placeSection: some View {
        Section {
            if let applePlaceId {
                HStack {
                    Label("Linked to Apple Maps", systemImage: "mappin.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Unlink place", role: .destructive) { confirmingUnlink = true }
                        .buttonStyle(.borderless)
                }
                if let placeName = linkedCandidate?.name ?? session.places.place(for: applePlaceId)?.name, !placeName.isEmpty {
                    Text(verbatim: placeName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            } else {
                HStack {
                    TextField("Search for a place or address", text: $query)
                        .multilineTextAlignment(.leading)
                        .submitLabel(.search)
                        .onSubmit { Task { await search() } }
                    if isSearching {
                        ProgressView()
                    } else {
                        Button("Search") { Task { await search() } }
                            .disabled(trimmed(query).isEmpty)
                            .buttonStyle(.borderless)
                    }
                }
                if searchFailed {
                    Text("Search needs a network connection. Try again later.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                ForEach(results) { result in
                    if let issue = result.linkIssue {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: result.name).foregroundStyle(.secondary)
                            Text(verbatim: result.address)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Label(issue == .noIdentifier ? "This place has no ID." : "This place's ID can't be saved.", systemImage: "nosign")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        .multilineTextAlignment(.leading)
                        .accessibilityElement(children: .combine)
                        .accessibilityHint(Text("Can't be linked"))
                    } else {
                        Button {
                            pendingCandidate = result
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: result.name).foregroundStyle(.primary)
                                Text(verbatim: result.address)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .multilineTextAlignment(.leading)
                        }
                    }
                }
            }
        } header: {
            Text("Apple Maps place")
        } footer: {
            if applePlaceId == nil {
                Text("Search Apple Maps and link a place. Only its ID is saved.")
            }
        }
    }

    private func search() async {
        let text = trimmed(query)
        guard !text.isEmpty else { return }
        isSearching = true
        searchFailed = false
        defer { isSearching = false }
        do {
            results = try await PlaceResult.search(text)
        } catch {
            results = []
            searchFailed = true
        }
    }

    /// Links the confirmed candidate: only its Place ID enters the draft. The result list
    /// and the query are cleared; the name, address and coordinates fields are untouched.
    private func link(_ candidate: PlaceResult) {
        guard candidate.linkIssue == nil, let identifier = candidate.identifier else { return }
        applePlaceId = identifier
        linkedCandidate = candidate
        pendingCandidate = nil
        results = []
        query = ""
    }

    private func save() {
        let building = draft
        guard building.isWritable, !hasSaved else { return }
        hasSaved = true
        if let existing {
            session.updateBuilding(building, replacing: existing)
        } else {
            session.createBuilding(building)
        }
        // Nothing from the candidate is cached here: the server may still reject the write,
        // so the place is fetched normally once the stored Building appears on screen.
        dismiss()
    }
}

/// The tapped search result on an Apple map, with its name and address (shown, not
/// saved), a duplicate warning, and the one action that keeps its ID. Back keeps nothing.
private struct PlaceCandidateView: View {
    let candidate: PlaceResult
    let duplicates: [Building]
    let onLink: () -> Void
    let onBack: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    MapPreview(title: candidate.name, coordinate: candidate.coordinate)
                        .frame(height: 180)
                        .listRowInsets(EdgeInsets())
                    LabeledContent("Place") {
                        Text(verbatim: candidate.name.isEmpty ? "–" : candidate.name)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Address") {
                        Text(verbatim: candidate.address.isEmpty ? "–" : candidate.address)
                            .multilineTextAlignment(.trailing)
                    }
                } footer: {
                    Text("Only the place's ID is saved. Its name, address and map are fetched from Apple Maps when shown.")
                }
                if !duplicates.isEmpty {
                    Section {
                        Label {
                            Text("A building for this place already exists: \(duplicates.map(\.name).joined(separator: ", "))")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        .foregroundStyle(.orange)
                    }
                }
                Section {
                    Button("Link this place") { onLink() }
                }
            }
            .navigationTitle("Confirm place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { onBack() }
                }
            }
        }
    }
}
